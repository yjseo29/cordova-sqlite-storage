/*
 * Copyright (c) 2012-present Christopher J. Brody (aka Chris Brody)
 * Copyright (c) 2005-2010, Nitobi Software Inc.
 * Copyright (c) 2010, IBM Corporation
 */

package io.sqlc;

import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.system.Os;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;

import java.lang.IllegalArgumentException;

import java.util.Map;
import java.util.UUID;

import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class SQLitePlugin extends CordovaPlugin {

    /**
     * Concurrent database runner map.
     *
     * NOTE: no public static accessor to db (runner) map since it is not
     * expected to work properly with db threading.
     *
     * FUTURE TBD put DBRunner into a public class that can provide external accessor.
     *
     * ADDITIONAL NOTE: Storing as Map<String, DBRunner> to avoid portabiity issue
     * between Java 6/7/8 as discussed in:
     * https://gist.github.com/AlainODea/1375759b8720a3f9f094
     *
     * THANKS to @NeoLSN (Jason Yang/楊朝傑) for giving the pointer in:
     * https://github.com/litehelpers/Cordova-sqlite-storage/issues/727
     */
    private Map<String, DBRunner> dbrmap = new ConcurrentHashMap<String, DBRunner>();

    /**
     * NOTE: Using default constructor, no explicit constructor.
     */

    /**
     * Executes the request and returns PluginResult.
     *
     * @param actionAsString The action to execute.
     * @param args   JSONArry of arguments for the plugin.
     * @param cbc    Callback context from Cordova API
     * @return       Whether the action was valid.
     */
    @Override
    public boolean execute(String actionAsString, JSONArray args, CallbackContext cbc) {

        Action action;
        try {
            action = Action.valueOf(actionAsString);
        } catch (IllegalArgumentException e) {
            // shouldn't ever happen
            Log.e(SQLitePlugin.class.getSimpleName(), "unexpected error", e);
            return false;
        }

        try {
            return executeAndPossiblyThrow(action, args, cbc);
        } catch (JSONException e) {
            // TODO: signal JSON problem to JS
            Log.e(SQLitePlugin.class.getSimpleName(), "unexpected error", e);
            return false;
        }
    }

    private boolean executeAndPossiblyThrow(Action action, JSONArray args, CallbackContext cbc)
            throws JSONException {

        boolean status = true;
        JSONObject o;
        String echo_value;
        String dbname;

        switch (action) {
            case echoStringValue:
                o = args.getJSONObject(0);
                echo_value = o.getString("value");
                cbc.success(echo_value);
                break;

            case open:
                o = args.getJSONObject(0);
                dbname = o.getString("name");
                // open database and start reading its queue
                this.startDatabase(dbname, o, cbc);
                break;

            case close:
                o = args.getJSONObject(0);
                dbname = o.getString("path");
                // put request in the q to close the db
                this.closeDatabase(dbname, cbc);
                break;

            case delete:
                o = args.getJSONObject(0);
                dbname = o.getString("path");

                deleteDatabase(dbname, cbc);

                break;

            case backupDatabase:
                o = args.getJSONObject(0);
                this.backupDatabase(o.getString("sourceName"), o.getString("backupName"), cbc);
                break;

            case restoreDatabase:
                o = args.getJSONObject(0);
                this.restoreDatabase(o.getString("sourceName"), o.getString("destinationName"), o.optBoolean("deleteSource", false), cbc);
                break;

            case executeSqlBatch:
            case backgroundExecuteSqlBatch:
                JSONObject allargs = args.getJSONObject(0);
                JSONObject dbargs = allargs.getJSONObject("dbargs");
                dbname = dbargs.getString("dbname");
                JSONArray txargs = allargs.getJSONArray("executes");

                if (txargs.isNull(0)) {
                    cbc.error("INTERNAL PLUGIN ERROR: missing executes list");
                } else {
                    int len = txargs.length();
                    String[] queries = new String[len];
                    JSONArray[] jsonparams = new JSONArray[len];

                    for (int i = 0; i < len; i++) {
                        JSONObject a = txargs.getJSONObject(i);
                        queries[i] = a.getString("sql");
                        jsonparams[i] = a.getJSONArray("params");
                    }

                    // put db query in the queue to be executed in the db thread:
                    DBQuery q = new DBQuery(queries, jsonparams, cbc);
                    DBRunner r = dbrmap.get(dbname);
                    if (r != null) {
                        try {
                            r.q.put(q);
                        } catch(Exception e) {
                            Log.e(SQLitePlugin.class.getSimpleName(), "couldn't add to queue", e);
                            cbc.error("INTERNAL PLUGIN ERROR: couldn't add to queue");
                        }
                    } else {
                        cbc.error("INTERNAL PLUGIN ERROR: database not open");
                    }
                }
                break;
        }

        return status;
    }

    /**
     * Clean up and close all open databases.
     */
    @Override
    public void onDestroy() {
        while (!dbrmap.isEmpty()) {
            String dbname = dbrmap.keySet().iterator().next();

            this.closeDatabaseNow(dbname);

            DBRunner r = dbrmap.get(dbname);
            try {
                // stop the db runner thread:
                r.q.put(new DBQuery());
            } catch(Exception e) {
                Log.e(SQLitePlugin.class.getSimpleName(), "INTERNAL PLUGIN CLEANUP ERROR: could not stop db thread due to exception", e);
            }
            dbrmap.remove(dbname);
        }
    }

    // --------------------------------------------------------------------------
    // LOCAL METHODS
    // --------------------------------------------------------------------------

    private void startDatabase(String dbname, JSONObject options, CallbackContext cbc) {
        DBRunner r = dbrmap.get(dbname);

        if (r != null) {
            // NO LONGER EXPECTED due to BUG 666 workaround solution:
            cbc.error("INTERNAL ERROR: database already open for db name: " + dbname);
        } else {
            r = new DBRunner(dbname, options, cbc);
            dbrmap.put(dbname, r);
            this.cordova.getThreadPool().execute(r);
        }
    }
    /**
     * Open a database.
     *
     * @param dbName   The name of the database file
     */
    private SQLiteAndroidDatabase openDatabase(String dbname, CallbackContext cbc, boolean old_impl) throws Exception {
        try {
            // ASSUMPTION: no db (connection/handle) is already stored in the map
            // [should be true according to the code in DBRunner.run()]

            File dbfile = this.cordova.getActivity().getDatabasePath(dbname);

            if (!dbfile.exists()) {
                dbfile.getParentFile().mkdirs();
            }

            Log.v("info", "Open sqlite db: " + dbfile.getAbsolutePath());

            SQLiteAndroidDatabase mydb = old_impl ? new SQLiteAndroidDatabase() : new SQLiteConnectorDatabase();
            mydb.open(dbfile);

            if (cbc != null) // XXX Android locking/closing BUG workaround
                cbc.success();

            return mydb;
        } catch (Exception e) {
            if (cbc != null) // XXX Android locking/closing BUG workaround
                cbc.error("can't open database " + e);
            throw e;
        }
    }

    /**
     * Close a database (in another thread).
     *
     * @param dbName   The name of the database file
     */
    private void closeDatabase(String dbname, CallbackContext cbc) {
        DBRunner r = dbrmap.get(dbname);
        if (r != null) {
            try {
                r.q.put(new DBQuery(false, cbc));
            } catch(Exception e) {
                if (cbc != null) {
                    cbc.error("couldn't close database" + e);
                }
                Log.e(SQLitePlugin.class.getSimpleName(), "couldn't close database", e);
            }
        } else {
            if (cbc != null) {
                cbc.success();
            }
        }
    }

    /**
     * Close a database (in the current thread).
     *
     * @param dbname   The name of the database file
     */
    private void closeDatabaseNow(String dbname) {
        DBRunner r = dbrmap.get(dbname);

        if (r != null) {
            SQLiteAndroidDatabase mydb = r.mydb;

            if (mydb != null)
                mydb.closeDatabaseNow();
        }
    }

    private void deleteDatabase(String dbname, CallbackContext cbc) {
        DBRunner r = dbrmap.get(dbname);
        if (r != null) {
            try {
                r.q.put(new DBQuery(true, cbc));
            } catch(Exception e) {
                if (cbc != null) {
                    cbc.error("couldn't close database" + e);
                }
                Log.e(SQLitePlugin.class.getSimpleName(), "couldn't close database", e);
            }
        } else {
            boolean deleteResult = this.deleteDatabaseNow(dbname);
            if (deleteResult) {
                cbc.success();
            } else {
                cbc.error("couldn't delete database");
            }
        }
    }

    /**
     * Delete a database.
     *
     * @param dbName   The name of the database file
     *
     * @return true if successful or false if an exception was encountered
     */
    private boolean deleteDatabaseNow(String dbname) {
        File dbfile = this.cordova.getActivity().getDatabasePath(dbname);

        try {
            return cordova.getActivity().deleteDatabase(dbfile.getAbsolutePath());
        } catch (Exception e) {
            Log.e(SQLitePlugin.class.getSimpleName(), "couldn't delete database", e);
            return false;
        }
    }

    private boolean databaseFilesMatch(File first, File second) throws IOException {
        return first.getCanonicalPath().equals(second.getCanonicalPath());
    }

    private boolean hasDatabaseSidecars(File dbfile) {
        String path = dbfile.getAbsolutePath();
        return new File(path + "-journal").exists() ||
            new File(path + "-wal").exists() ||
            new File(path + "-shm").exists();
    }

    private void removeDatabaseSidecars(File dbfile) throws IOException {
        String path = dbfile.getAbsolutePath();
        String[] suffixes = new String[] { "-journal", "-wal", "-shm" };

        for (String suffix : suffixes) {
            File sidecar = new File(path + suffix);
            if (sidecar.exists() && !sidecar.delete()) {
                throw new IOException("couldn't delete SQLite sidecar: " + sidecar.getAbsolutePath());
            }
        }
    }

    private void deleteDatabaseFiles(File dbfile) throws IOException {
        removeDatabaseSidecars(dbfile);
        if (dbfile.exists() && !dbfile.delete()) {
            throw new IOException("couldn't delete database file: " + dbfile.getAbsolutePath());
        }
    }

    private void checkpointDatabaseFile(File dbfile) throws Exception {
        SQLiteDatabase db = null;
        Cursor cursor = null;
        try {
            db = SQLiteDatabase.openDatabase(dbfile.getAbsolutePath(), null, SQLiteDatabase.OPEN_READWRITE);
            cursor = db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null);
            if (cursor.moveToFirst() && cursor.getInt(0) != 0) {
                throw new IOException("WAL checkpoint could not complete because the database is busy");
            }
        } finally {
            if (cursor != null) cursor.close();
            if (db != null) db.close();
        }
    }

    private void validateDatabaseFile(File dbfile) throws Exception {
        SQLiteDatabase db = null;
        Cursor cursor = null;
        String checkMessage = null;
        try {
            db = SQLiteDatabase.openDatabase(dbfile.getAbsolutePath(), null, SQLiteDatabase.OPEN_READWRITE);
            cursor = db.rawQuery("PRAGMA quick_check", null);
            if (cursor.moveToFirst()) checkMessage = cursor.getString(0);
        } finally {
            if (cursor != null) cursor.close();
            if (db != null) db.close();
        }

        if (!"ok".equals(checkMessage)) {
            throw new IOException("Database failed SQLite quick_check: " + (checkMessage == null ? "no result" : checkMessage));
        }
    }

    private void copyFile(File source, File destination) throws IOException {
        File parent = destination.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("couldn't create database directory: " + parent.getAbsolutePath());
        }

        FileInputStream input = null;
        FileOutputStream output = null;
        try {
            input = new FileInputStream(source);
            output = new FileOutputStream(destination);
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            output.flush();
            output.getFD().sync();
        } finally {
            if (output != null) output.close();
            if (input != null) input.close();
        }
    }

    private void installVerifiedDatabaseCopy(File source, File destination) throws Exception {
        if (hasDatabaseSidecars(destination)) {
            throw new IOException("The destination database has active SQLite sidecar files; close all connections before replacing it");
        }

        File temporary = new File(destination.getAbsolutePath() + ".prepare-" + UUID.randomUUID().toString() + ".tmp");
        try {
            copyFile(source, temporary);
            validateDatabaseFile(temporary);
            removeDatabaseSidecars(temporary);

            if (hasDatabaseSidecars(destination)) {
                throw new IOException("The destination database became active while it was being prepared");
            }

            Os.rename(temporary.getAbsolutePath(), destination.getAbsolutePath());
        } finally {
            try {
                removeDatabaseSidecars(temporary);
            } catch (Exception ignored) {
                Log.w(SQLitePlugin.class.getSimpleName(), "couldn't remove temporary SQLite sidecars", ignored);
            }
            if (temporary.exists() && !temporary.delete()) {
                Log.w(SQLitePlugin.class.getSimpleName(), "couldn't remove temporary database file: " + temporary.getAbsolutePath());
            }
        }
    }

    private void prepareClosedDestinationForRestore(File destination) throws Exception {
        if (!hasDatabaseSidecars(destination)) return;
        if (!destination.exists()) {
            throw new IOException("The destination database is missing but SQLite sidecar files remain");
        }

        checkpointDatabaseFile(destination);
        removeDatabaseSidecars(destination);
        if (hasDatabaseSidecars(destination)) {
            throw new IOException("The destination database still has active SQLite sidecar files after checkpoint");
        }
    }

    private JSONObject backupDatabaseNow(String sourceName, String backupName, SQLiteAndroidDatabase openSource) throws Exception {
        File source = this.cordova.getActivity().getDatabasePath(sourceName);
        File backup = this.cordova.getActivity().getDatabasePath(backupName);

        if (databaseFilesMatch(source, backup)) {
            throw new IOException("Source and backup database paths must be different");
        }
        if (!source.exists()) {
            throw new IOException("The backup source database does not exist on that path");
        }
        if (dbrmap.get(backupName) != null) {
            throw new IOException("Close the backup database before replacing it");
        }

        if (openSource != null) {
            if (openSource.hasActiveTransaction()) {
                throw new IOException("Wait for the active database transaction to finish before calling backupDatabase");
            }
            openSource.checkpointDatabase();
        } else {
            checkpointDatabaseFile(source);
        }

        boolean backupExisted = backup.exists();
        installVerifiedDatabaseCopy(source, backup);

        JSONObject result = new JSONObject();
        result.put("action", "backed-up");
        result.put("sourceExists", true);
        result.put("backupExisted", backupExisted);
        result.put("backupExists", backup.exists());
        result.put("backupUpdated", true);
        return result;
    }

    private void backupDatabase(final String sourceName, final String backupName, final CallbackContext cbc) {
        if (sourceName.equals(backupName)) {
            cbc.error("Source and backup database paths must be different");
            return;
        }

        DBRunner sourceRunner = dbrmap.get(sourceName);
        if (sourceRunner != null) {
            try {
                sourceRunner.q.put(new DBQuery(backupName, cbc));
            } catch (Exception e) {
                cbc.error("couldn't queue database backup: " + e.getMessage());
            }
            return;
        }

        this.cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                try {
                    cbc.success(backupDatabaseNow(sourceName, backupName, null));
                } catch (Exception e) {
                    Log.e(SQLitePlugin.class.getSimpleName(), "couldn't back up database", e);
                    cbc.error("couldn't back up database: " + e.getMessage());
                }
            }
        });
    }

    private void restoreDatabase(final String sourceName, final String destinationName, final boolean deleteSource, final CallbackContext cbc) {
        if (sourceName.equals(destinationName)) {
            cbc.error("Source and destination database paths must be different");
            return;
        }
        if (dbrmap.get(destinationName) != null) {
            cbc.error("Close the destination database before calling restoreDatabase");
            return;
        }
        if (dbrmap.get(sourceName) != null) {
            cbc.error("Close the restore source database before calling restoreDatabase");
            return;
        }

        this.cordova.getThreadPool().execute(new Runnable() {
            public void run() {
                File source = cordova.getActivity().getDatabasePath(sourceName);
                File destination = cordova.getActivity().getDatabasePath(destinationName);
                try {
                    if (databaseFilesMatch(source, destination)) {
                        throw new IOException("Source and destination database paths must be different");
                    }
                    if (!source.exists()) {
                        throw new IOException("The restore source database does not exist on that path");
                    }

                    checkpointDatabaseFile(source);
                    validateDatabaseFile(source);
                    boolean destinationExisted = destination.exists();
                    prepareClosedDestinationForRestore(destination);
                    installVerifiedDatabaseCopy(source, destination);

                    boolean sourceDeleted = false;
                    if (deleteSource) {
                        try {
                            deleteDatabaseFiles(source);
                            sourceDeleted = true;
                        } catch (Exception e) {
                            throw new IOException("Database restored but the source could not be deleted: " + e.getMessage());
                        }
                    }

                    JSONObject result = new JSONObject();
                    result.put("action", "restored");
                    result.put("destinationExisted", destinationExisted);
                    result.put("destinationExists", destination.exists());
                    result.put("sourceDeleted", sourceDeleted);
                    cbc.success(result);
                } catch (Exception e) {
                    Log.e(SQLitePlugin.class.getSimpleName(), "couldn't restore database", e);
                    cbc.error("couldn't restore database: " + e.getMessage());
                }
            }
        });
    }

    private class DBRunner implements Runnable {
        final String dbname;
        private boolean oldImpl;
        private boolean bugWorkaround;

        final BlockingQueue<DBQuery> q;
        final CallbackContext openCbc;

        SQLiteAndroidDatabase mydb;

        DBRunner(final String dbname, JSONObject options, CallbackContext cbc) {
            this.dbname = dbname;
            this.oldImpl = options.has("androidOldDatabaseImplementation");
            Log.v(SQLitePlugin.class.getSimpleName(), "Android db implementation: built-in android.database.sqlite package");
            this.bugWorkaround = this.oldImpl && options.has("androidBugWorkaround");
            if (this.bugWorkaround)
                Log.v(SQLitePlugin.class.getSimpleName(), "Android db closing/locking workaround applied");

            this.q = new LinkedBlockingQueue<DBQuery>();
            this.openCbc = cbc;
        }

        public void run() {
            try {
                this.mydb = openDatabase(dbname, this.openCbc, this.oldImpl);
            } catch (Exception e) {
                Log.e(SQLitePlugin.class.getSimpleName(), "unexpected error, stopping db thread", e);
                dbrmap.remove(dbname);
                return;
            }

            DBQuery dbq = null;

            try {
                dbq = q.take();

                while (!dbq.stop) {
                    if (dbq.backupName != null) {
                        try {
                            dbq.cbc.success(backupDatabaseNow(dbname, dbq.backupName, mydb));
                        } catch (Exception e) {
                            Log.e(SQLitePlugin.class.getSimpleName(), "couldn't back up open database", e);
                            dbq.cbc.error("couldn't back up database: " + e.getMessage());
                        }
                    } else {
                        mydb.executeSqlBatch(dbq.queries, dbq.jsonparams, dbq.cbc);

                        if (this.bugWorkaround && dbq.queries.length == 1 && dbq.queries[0] == "COMMIT")
                            mydb.bugWorkaround();
                    }

                    dbq = q.take();
                }
            } catch (Exception e) {
                Log.e(SQLitePlugin.class.getSimpleName(), "unexpected error", e);
            }

            if (dbq != null && dbq.close) {
                try {
                    closeDatabaseNow(dbname);

                    dbrmap.remove(dbname); // (should) remove ourself

                    if (!dbq.delete) {
                        dbq.cbc.success();
                    } else {
                        try {
                            boolean deleteResult = deleteDatabaseNow(dbname);
                            if (deleteResult) {
                                dbq.cbc.success();
                            } else {
                                dbq.cbc.error("couldn't delete database");
                            }
                        } catch (Exception e) {
                            Log.e(SQLitePlugin.class.getSimpleName(), "couldn't delete database", e);
                            dbq.cbc.error("couldn't delete database: " + e);
                        }
                    }
                } catch (Exception e) {
                    Log.e(SQLitePlugin.class.getSimpleName(), "couldn't close database", e);
                    if (dbq.cbc != null) {
                        dbq.cbc.error("couldn't close database: " + e);
                    }
                }
            }
        }
    }

    private final class DBQuery {
        // XXX TODO replace with DBRunner action enum:
        final boolean stop;
        final boolean close;
        final boolean delete;
        final String[] queries;
        final JSONArray[] jsonparams;
        final CallbackContext cbc;
        final String backupName;

        DBQuery(String[] myqueries, JSONArray[] params, CallbackContext c) {
            this.stop = false;
            this.close = false;
            this.delete = false;
            this.queries = myqueries;
            this.jsonparams = params;
            this.cbc = c;
            this.backupName = null;
        }

        DBQuery(String backupName, CallbackContext cbc) {
            this.stop = false;
            this.close = false;
            this.delete = false;
            this.queries = null;
            this.jsonparams = null;
            this.cbc = cbc;
            this.backupName = backupName;
        }

        DBQuery(boolean delete, CallbackContext cbc) {
            this.stop = true;
            this.close = true;
            this.delete = delete;
            this.queries = null;
            this.jsonparams = null;
            this.cbc = cbc;
            this.backupName = null;
        }

        // signal the DBRunner thread to stop:
        DBQuery() {
            this.stop = true;
            this.close = false;
            this.delete = false;
            this.queries = null;
            this.jsonparams = null;
            this.cbc = null;
            this.backupName = null;
        }
    }

    private static enum Action {
        echoStringValue,
        open,
        close,
        delete,
        backupDatabase,
        restoreDatabase,
        executeSqlBatch,
        backgroundExecuteSqlBatch,
    }
}

/* vim: set expandtab : */
