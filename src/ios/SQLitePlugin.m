/*
 * Copyright (c) 2012-present Christopher J. Brody (aka Chris Brody)
 * Copyright (C) 2011 Davide Bertola
 *
 * This library is available under the terms of the MIT License (2008).
 * See http://opensource.org/licenses/alphabetical for full text.
 */

#import "SQLitePlugin.h"

#import "sqlite3.h"
#include <string.h>

// Defines Macro to only log lines when in DEBUG mode
#ifdef DEBUG
#   define DLog(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);
#else
#   define DLog(...)
#endif

#if !__has_feature(objc_arc)
#   error "Missing objc_arc feature"
#endif

// CustomPSPDFThreadSafeMutableDictionary interface copied from
// CustomPSPDFThreadSafeMutableDictionary.m:
//
// Dictionary-Subclasss whose primitive operations are thread safe.
@interface CustomPSPDFThreadSafeMutableDictionary : NSMutableDictionary
@end

@implementation SQLitePlugin

@synthesize openDBs;
@synthesize appDBPaths;

-(void)pluginInitialize
{
    DLog(@"Initializing SQLitePlugin");

    {
        openDBs = [CustomPSPDFThreadSafeMutableDictionary dictionaryWithCapacity:0];
        appDBPaths = [NSMutableDictionary dictionaryWithCapacity:0];

        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
        DLog(@"Detected docs path: %@", docs);
        [appDBPaths setObject: docs forKey:@"docs"];

        NSString *libs = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
        DLog(@"Detected Library path: %@", libs);
        [appDBPaths setObject: libs forKey:@"libs"];

        NSString *nosync = [libs stringByAppendingPathComponent:@"LocalDatabase"];
        NSError *err;

        // GENERAL NOTE: no `nosync` directory path entry to be added
        // to appDBPaths map in case of any isses creating the
        // required directory or setting the resource value for
        // NSURLIsExcludedFromBackupKey
        //
        // This is to avoid potential for issue raised here:
        // https://github.com/xpbrew/cordova-sqlite-storage/issues/907

        if ([[NSFileManager defaultManager] fileExistsAtPath: nosync])
        {
            DLog(@"no cloud sync directory already exists at path: %@", nosync);
        }
        else
        {
            if ([[NSFileManager defaultManager] createDirectoryAtPath: nosync withIntermediateDirectories:NO attributes: nil error:&err])
            {
                DLog(@"no cloud sync directory created with path: %@", nosync);
            }
            else
            {
                // STOP HERE & LOG WITH INTERNAL PLUGIN ERROR:
                NSLog(@"INTERNAL PLUGIN ERROR: could not create no cloud sync directory at path: %@", nosync);
                return;
            }
        }

        {
            {
                // Set the resource value for NSURLIsExcludedFromBackupKey
                NSURL *nosyncURL = [ NSURL fileURLWithPath: nosync];
                if (![nosyncURL setResourceValue: [NSNumber numberWithBool: YES] forKey: NSURLIsExcludedFromBackupKey error: &err])
                {
                    // STOP HERE & LOG WITH INTERNAL PLUGIN ERROR:
                    NSLog(@"INTERNAL PLUGIN ERROR: error setting nobackup flag in LocalDatabase directory: %@", err);
                    return;
                }

                // now ready to add `nosync` entry to appDBPaths:
                DLog(@"no cloud sync at path: %@", nosync);
                [appDBPaths setObject: nosync forKey:@"nosync"];
            }
        }
    }
}

-(id) getDBPath:(NSString *)dbFile at:(NSString *)atkey appGroup:(NSString *)appGroup {
    if (dbFile == NULL) {
        return NULL;
    }
    if (atkey == NULL) {
        return NULL;
    }

    NSString *dbdir = NULL;

    if ([atkey isEqualToString:@"appgroup"]) {
        if (appGroup == NULL) {
            return NULL;
        }

        NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:appGroup];
        if (groupURL == NULL) {
            return NULL;
        }

        dbdir = [groupURL path];
    } else {
        dbdir = [appDBPaths objectForKey:atkey];
    }

    if (dbdir == NULL) {
        // INTERNAL PLUGIN ERROR:
        return NULL;
    }

    NSString *dbPath = [dbdir stringByAppendingPathComponent: dbFile];
    return dbPath;
}

-(BOOL) validateDatabaseAtPath:(NSString *)dbPath errorMessage:(NSString **)errorMessage
{
    sqlite3 *db = NULL;
    sqlite3_stmt *statement = NULL;
    int openResult = sqlite3_open_v2([dbPath UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);

    if (openResult != SQLITE_OK) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Unable to open database for validation: %s", db != NULL ? sqlite3_errmsg(db) : "unknown SQLite error"];
        }
        if (db != NULL) sqlite3_close(db);
        return NO;
    }

    int prepareResult = sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &statement, NULL);
    BOOL valid = NO;
    NSString *checkMessage = nil;

    if (prepareResult == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *result = sqlite3_column_text(statement, 0);
        if (result != NULL) checkMessage = [NSString stringWithUTF8String:(const char *)result];
        valid = [checkMessage isEqualToString:@"ok"];
    }

    if (!valid && errorMessage != NULL) {
        NSString *detail = checkMessage != nil ? checkMessage : [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        *errorMessage = [NSString stringWithFormat:@"Database failed SQLite quick_check: %@", detail];
    }

    if (statement != NULL) sqlite3_finalize(statement);
    sqlite3_close(db);
    return valid;
}

-(BOOL) removeDatabaseSidecarsAtPath:(NSString *)dbPath errorMessage:(NSString **)errorMessage
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    for (NSString *suffix in @[@"-journal", @"-wal", @"-shm"]) {
        NSString *sidecarPath = [dbPath stringByAppendingString:suffix];
        if (![fileManager fileExistsAtPath:sidecarPath]) continue;

        NSError *error = nil;
        if (![fileManager removeItemAtPath:sidecarPath error:&error]) {
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"Unable to remove destination database sidecar: %@", error];
            }
            return NO;
        }
    }

    return YES;
}

-(BOOL) removeDatabaseAtPath:(NSString *)dbPath errorMessage:(NSString **)errorMessage
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Keep the main file until last so a partial cleanup can be retried.
    for (NSString *suffix in @[@"-journal", @"-wal", @"-shm", @""]) {
        NSString *itemPath = [dbPath stringByAppendingString:suffix];
        if (![fileManager fileExistsAtPath:itemPath]) continue;

        NSError *error = nil;
        if (![fileManager removeItemAtPath:itemPath error:&error]) {
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"Unable to delete database file: %@", error];
            }
            return NO;
        }
    }

    return YES;
}

-(BOOL) createDatabaseSnapshotFromPath:(NSString *)sourcePath toPath:(NSString *)destinationPath errorMessage:(NSString **)errorMessage
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *temporaryPath = [NSString stringWithFormat:@"%@.prepare-%@.tmp", destinationPath, [[NSUUID UUID] UUIDString]];
    sqlite3 *sourceDB = NULL;
    sqlite3 *destinationDB = NULL;
    sqlite3_backup *backup = NULL;
    BOOL success = NO;
    int sourceOpenResult;
    int destinationOpenResult;
    int backupResult = SQLITE_OK;
    int finishResult = SQLITE_OK;
    int busyAttempts = 0;
    NSError *fileError = nil;

    sourceOpenResult = sqlite3_open_v2([sourcePath UTF8String], &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
    if (sourceOpenResult != SQLITE_OK) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Unable to open source database for backup: %s", sourceDB != NULL ? sqlite3_errmsg(sourceDB) : "unknown SQLite error"];
        }
        goto cleanup;
    }

    destinationOpenResult = sqlite3_open_v2([temporaryPath UTF8String], &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (destinationOpenResult != SQLITE_OK) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Unable to create temporary database backup: %s", destinationDB != NULL ? sqlite3_errmsg(destinationDB) : "unknown SQLite error"];
        }
        goto cleanup;
    }

    sqlite3_busy_timeout(sourceDB, 5000);
    sqlite3_busy_timeout(destinationDB, 5000);
    backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main");

    if (backup == NULL) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Unable to initialize SQLite backup: %s", sqlite3_errmsg(destinationDB)];
        }
        goto cleanup;
    }

    while (YES) {
        backupResult = sqlite3_backup_step(backup, 128);

        if (backupResult == SQLITE_DONE) break;
        if (backupResult == SQLITE_OK) {
            busyAttempts = 0;
            continue;
        }
        if ((backupResult == SQLITE_BUSY || backupResult == SQLITE_LOCKED) && busyAttempts < 100) {
            busyAttempts++;
            [NSThread sleepForTimeInterval:0.05];
            continue;
        }
        break;
    }

    finishResult = sqlite3_backup_finish(backup);
    backup = NULL;

    if (backupResult != SQLITE_DONE || finishResult != SQLITE_OK) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"SQLite backup failed (%d/%d): %s", backupResult, finishResult, sqlite3_errmsg(destinationDB)];
        }
        goto cleanup;
    }

    sqlite3_close(destinationDB);
    destinationDB = NULL;
    sqlite3_close(sourceDB);
    sourceDB = NULL;

    if (![self validateDatabaseAtPath:temporaryPath errorMessage:errorMessage]) goto cleanup;
    if (![self removeDatabaseSidecarsAtPath:destinationPath errorMessage:errorMessage]) goto cleanup;

    if ([fileManager fileExistsAtPath:destinationPath]) {
        NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
        NSURL *temporaryURL = [NSURL fileURLWithPath:temporaryPath];
        if (![fileManager replaceItemAtURL:destinationURL withItemAtURL:temporaryURL backupItemName:nil options:0 resultingItemURL:nil error:&fileError]) {
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"Unable to replace destination database: %@", fileError];
            }
            goto cleanup;
        }
    } else if (![fileManager moveItemAtPath:temporaryPath toPath:destinationPath error:&fileError]) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Unable to install prepared database: %@", fileError];
        }
        goto cleanup;
    }

    success = YES;

cleanup:
    if (backup != NULL) sqlite3_backup_finish(backup);
    if (destinationDB != NULL) sqlite3_close(destinationDB);
    if (sourceDB != NULL) sqlite3_close(sourceDB);
    if ([fileManager fileExistsAtPath:temporaryPath]) [fileManager removeItemAtPath:temporaryPath error:nil];
    return success;
}

-(BOOL) backupDatabaseFromPath:(NSString *)sourcePath toPath:(NSString *)backupPath backupName:(NSString *)backupName errorMessage:(NSString **)errorMessage
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([openDBs objectForKey:backupName] != NULL) {
        if (errorMessage != NULL) *errorMessage = @"Close the backup database before replacing it";
        return NO;
    }

    for (NSString *suffix in @[@"-journal", @"-wal", @"-shm"]) {
        if ([fileManager fileExistsAtPath:[backupPath stringByAppendingString:suffix]]) {
            if (errorMessage != NULL) *errorMessage = @"The backup database has active SQLite sidecar files; close all connections to the backup before replacing it";
            return NO;
        }
    }

    return [self createDatabaseSnapshotFromPath:sourcePath toPath:backupPath errorMessage:errorMessage];
}

-(void)echoStringValue: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult * pluginResult = nil;
    NSMutableDictionary * options = [command.arguments objectAtIndex:0];

    NSString * string_value = [options objectForKey:@"value"];

    DLog(@"echo string value: %@", string_value);

    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:string_value];
    [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
}

-(void)open: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self openNow: command];
    }];
}

-(void)openNow: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];

    NSString *dbfilename = [options objectForKey:@"name"];

    NSString *dblocation = [options objectForKey:@"dblocation"];
    if (dblocation == NULL) dblocation = @"docs";
    // DLog(@"using db location: %@", dblocation);

    NSString *appGroup = [options objectForKey:@"iosDatabaseLocationAppGroup"];
    NSString *dbname = [self getDBPath:dbfilename at:dblocation appGroup:appGroup];

    if (!sqlite3_threadsafe()) {
        // INTERNAL PLUGIN ERROR:
        NSLog(@"INTERNAL PLUGIN ERROR: sqlite3_threadsafe() returns false value");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: sqlite3_threadsafe() returns false value"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
        return;
    } else if (dbname == NULL) {
        // INTERNAL PLUGIN ERROR - NOT EXPECTED:
        NSLog(@"INTERNAL PLUGIN ERROR (NOT EXPECTED): open with database name missing");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: open with database name missing"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
        return;
    } else {
        NSValue *dbPointer = [openDBs objectForKey:dbfilename];

        if (dbPointer != NULL) {
            // NO LONGER EXPECTED due to BUG 666 workaround solution:
            // DLog(@"Reusing existing database connection for db name %@", dbfilename);
            NSLog(@"INTERNAL PLUGIN ERROR: database already open for db name: %@ (db file name: %@)", dbname, dbfilename);
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: database already open"];
            [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
            return;
        }

        @synchronized(self) {
            const char *name = [dbname UTF8String];
            sqlite3 *db;

            DLog(@"open full db path: %@", dbname);

            if (sqlite3_open(name, &db) != SQLITE_OK) {
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to open DB"];
                [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
                return;
            } else {
                sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL);

                // for SQLCipher version:
                // NSString *dbkey = [options objectForKey:@"key"];
                // const char *key = NULL;
                // if (dbkey != NULL) key = [dbkey UTF8String];
                // if (key != NULL) sqlite3_key(db, key, strlen(key));

                // Attempt to read the SQLite master table [to support SQLCipher version]:
                if(sqlite3_exec(db, (const char*)"SELECT count(*) FROM sqlite_master;", NULL, NULL, NULL) == SQLITE_OK) {
                    dbPointer = [NSValue valueWithPointer:db];
                    [openDBs setObject: dbPointer forKey: dbfilename];
                    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Database opened"];
                } else {
                    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to open DB with key"];
                    // XXX TODO: close the db handle & [perhaps] remove from openDBs!!
                }
            }
        }
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];

    // DLog(@"open cb finished ok");
}

-(void) close: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self closeNow: command];
    }];
}

-(void)closeNow: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];

    NSString *dbFileName = [options objectForKey:@"path"];

    if (dbFileName == NULL) {
        // Should not happen:
        DLog(@"No db name specified for close");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify database path"];
    } else {
        NSValue *val = [openDBs objectForKey:dbFileName];
        sqlite3 *db = [val pointerValue];

        if (db == NULL) {
            // Should not happen:
            DLog(@"close: db name was not open: %@", dbFileName);
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: Specified db was not open"];
        }
        else {
            DLog(@"close db name: %@", dbFileName);
            sqlite3_close (db);
            [openDBs removeObjectForKey:dbFileName];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"DB closed"];
        }
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
}

-(void) delete: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self deleteNow: command];
    }];
}

-(void)deleteNow: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];

    NSString *dbFileName = [options objectForKey:@"path"];

    NSString *dblocation = [options objectForKey:@"dblocation"];
    if (dblocation == NULL) dblocation = @"docs";

    if (dbFileName==NULL) {
        // Should not happen:
        DLog(@"No db name specified for delete");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify database path"];
    } else {
        NSString *appGroup = [options objectForKey:@"iosDatabaseLocationAppGroup"];
        NSString *dbPath = [self getDBPath:dbFileName at:dblocation appGroup:appGroup];

        if (dbPath == NULL) {
            // INTERNAL PLUGIN ERROR - NOT EXPECTED:
            NSLog(@"INTERNAL PLUGIN ERROR (NOT EXPECTED): delete with no valid database path found");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: delete with no valid database path found"];
            [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
            return;
        }

        if ([[NSFileManager defaultManager]fileExistsAtPath:dbPath]) {
            DLog(@"delete full db path: %@", dbPath);
            [[NSFileManager defaultManager]removeItemAtPath:dbPath error:nil];
            [openDBs removeObjectForKey:dbFileName];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"DB deleted"];
        } else {
            DLog(@"delete: db was not found: %@", dbPath);
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The database does not exist on that path"];
        }
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(void) copyDatabase: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self copyDatabaseNow: command];
    }];
}

-(void)copyDatabaseNow: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];

    NSString *dbFileName = [options objectForKey:@"path"];
    NSString *fromLocation = [options objectForKey:@"fromDblocation"];
    NSString *toLocation = [options objectForKey:@"toDblocation"];
    NSString *fromAppGroup = [options objectForKey:@"fromAppGroup"];
    NSString *toAppGroup = [options objectForKey:@"toAppGroup"];
    BOOL deleteOriginal = [[options objectForKey:@"deleteOriginal"] boolValue];
    BOOL overwrite = [[options objectForKey:@"overwrite"] boolValue];

    if (dbFileName == NULL) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify database path"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    NSString *fromPath = [self getDBPath:dbFileName at:fromLocation appGroup:fromAppGroup];
    NSString *toPath = [self getDBPath:dbFileName at:toLocation appGroup:toAppGroup];

    if (fromPath == NULL || toPath == NULL) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: copy with no valid database path found"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];

    if (![fileManager fileExistsAtPath:fromPath]) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The source database does not exist on that path"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    if ([fromPath isEqualToString:toPath]) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Source and destination database paths are the same"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    BOOL destinationExists = [fileManager fileExistsAtPath:toPath];
    NSError *err = nil;
    NSArray *suffixes = @[@"", @"-journal", @"-wal", @"-shm"];

    if (destinationExists && !overwrite) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Destination database already exists"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    if (destinationExists && overwrite) {
        for (NSString *suffix in suffixes) {
            NSString *destinationItemPath = [toPath stringByAppendingString:suffix];

            if (![fileManager fileExistsAtPath:destinationItemPath]) {
                continue;
            }

            if (![fileManager removeItemAtPath:destinationItemPath error:&err]) {
                NSString *message = [NSString stringWithFormat:@"Unable to overwrite destination database file: %@", err];
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
                [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
                return;
            }
        }
    }

    for (NSString *suffix in suffixes) {
        NSString *sourceItemPath = [fromPath stringByAppendingString:suffix];
        NSString *destinationItemPath = [toPath stringByAppendingString:suffix];

        if (![fileManager fileExistsAtPath:sourceItemPath]) {
            continue;
        }

        if (![fileManager copyItemAtPath:sourceItemPath toPath:destinationItemPath error:&err]) {
            NSString *message = [NSString stringWithFormat:@"Unable to copy database file: %@", err];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }
    }

    if (deleteOriginal) {
        for (NSString *suffix in suffixes) {
            NSString *sourceItemPath = [fromPath stringByAppendingString:suffix];

            if (![fileManager fileExistsAtPath:sourceItemPath]) {
                continue;
            }

            if (![fileManager removeItemAtPath:sourceItemPath error:&err]) {
                NSString *message = [NSString stringWithFormat:@"Database copied but unable to delete original database file: %@", err];
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
                [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
                return;
            }
        }

        [openDBs removeObjectForKey:dbFileName];
    }

    NSString *resultMessage = destinationExists ? @"Database overwritten" : @"Database copied";
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:resultMessage];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(void) prepareDatabase: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self prepareDatabaseNow: command];
    }];
}

-(void)prepareDatabaseNow: (CDVInvokedUrlCommand*)command
{
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];
    NSString *primaryName = [options objectForKey:@"primaryName"];
    NSString *primaryLocation = [options objectForKey:@"primaryDblocation"];
    NSString *primaryAppGroup = [options objectForKey:@"primaryAppGroup"];
    NSString *legacyName = [options objectForKey:@"legacyName"];
    NSString *legacyLocation = [options objectForKey:@"legacyDblocation"];
    NSString *legacyAppGroup = [options objectForKey:@"legacyAppGroup"];
    NSString *backupName = [options objectForKey:@"backupName"];
    NSString *backupLocation = [options objectForKey:@"backupDblocation"];
    NSString *backupAppGroup = [options objectForKey:@"backupAppGroup"];
    BOOL migrateLegacyIfNeeded = [[options objectForKey:@"migrateLegacyIfNeeded"] boolValue];
    BOOL backupIfExists = [[options objectForKey:@"backupIfExists"] boolValue];
    BOOL restoreIfMissing = [[options objectForKey:@"restoreIfMissing"] boolValue];
    BOOL deleteLegacyAfterMigration = [[options objectForKey:@"deleteLegacyAfterMigration"] boolValue];

    NSString *primaryPath = [self getDBPath:primaryName at:primaryLocation appGroup:primaryAppGroup];
    NSString *legacyPath = legacyLocation != NULL ? [self getDBPath:legacyName at:legacyLocation appGroup:legacyAppGroup] : NULL;
    NSString *backupPath = backupLocation != NULL ? [self getDBPath:backupName at:backupLocation appGroup:backupAppGroup] : NULL;

    if (primaryPath == NULL || (legacyLocation != NULL && legacyPath == NULL) || (backupLocation != NULL && backupPath == NULL)) {
        CDVPluginResult *pathError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: prepareDatabase with no valid database path found"];
        [self.commandDelegate sendPluginResult:pathError callbackId:command.callbackId];
        return;
    }

    if ((legacyPath != NULL && [primaryPath isEqualToString:legacyPath]) ||
        (backupPath != NULL && [primaryPath isEqualToString:backupPath]) ||
        (legacyPath != NULL && backupPath != NULL && [legacyPath isEqualToString:backupPath])) {
        CDVPluginResult *samePathError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Primary, legacy, and backup database paths must be different"];
        [self.commandDelegate sendPluginResult:samePathError callbackId:command.callbackId];
        return;
    }

    if (deleteLegacyAfterMigration && (legacyPath == NULL || backupPath == NULL || !backupIfExists)) {
        CDVPluginResult *deleteOptionsError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Enabled legacy and backup paths are required to delete the legacy database"];
        [self.commandDelegate sendPluginResult:deleteOptionsError callbackId:command.callbackId];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL primaryExisted = [fileManager fileExistsAtPath:primaryPath];
    BOOL legacyExists = legacyPath != NULL && [fileManager fileExistsAtPath:legacyPath];
    BOOL backupExists = backupPath != NULL && [fileManager fileExistsAtPath:backupPath];
    BOOL backupUpdated = NO;
    BOOL legacyDeleted = NO;
    NSString *action = @"new";
    NSString *errorMessage = nil;

    if (primaryExisted) {
        action = @"ready";
    } else if (restoreIfMissing && backupExists) {
        if (![self createDatabaseSnapshotFromPath:backupPath toPath:primaryPath errorMessage:&errorMessage]) {
            CDVPluginResult *restoreError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
            [self.commandDelegate sendPluginResult:restoreError callbackId:command.callbackId];
            return;
        }
        action = @"restored";
    } else if (migrateLegacyIfNeeded && legacyExists) {
        if (![self createDatabaseSnapshotFromPath:legacyPath toPath:primaryPath errorMessage:&errorMessage]) {
            CDVPluginResult *migrationError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
            [self.commandDelegate sendPluginResult:migrationError callbackId:command.callbackId];
            return;
        }
        action = @"migrated";
    }

    BOOL primaryNowExists = [fileManager fileExistsAtPath:primaryPath];
    if (backupIfExists && backupPath != NULL && primaryNowExists && ![action isEqualToString:@"restored"]) {
        if (![self backupDatabaseFromPath:primaryPath toPath:backupPath backupName:backupName errorMessage:&errorMessage]) {
            CDVPluginResult *backupError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
            [self.commandDelegate sendPluginResult:backupError callbackId:command.callbackId];
            return;
        }
        backupUpdated = YES;
        if ([action isEqualToString:@"ready"]) action = @"backed-up";
    }

    BOOL backupNowExists = backupPath != NULL && [fileManager fileExistsAtPath:backupPath];
    if (deleteLegacyAfterMigration && primaryNowExists && legacyExists && !backupNowExists) {
        CDVPluginResult *missingBackupError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Legacy database was not deleted because the prepared backup is missing"];
        [self.commandDelegate sendPluginResult:missingBackupError callbackId:command.callbackId];
        return;
    }

    if (deleteLegacyAfterMigration && primaryNowExists && legacyExists) {
        if (![self removeDatabaseAtPath:legacyPath errorMessage:&errorMessage]) {
            CDVPluginResult *legacyDeleteError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
            [self.commandDelegate sendPluginResult:legacyDeleteError callbackId:command.callbackId];
            return;
        }
        legacyDeleted = YES;
    }

    NSDictionary *result = @{
        @"action": action,
        @"primaryExisted": @(primaryExisted),
        @"primaryExists": @(primaryNowExists),
        @"legacyExists": @(legacyExists),
        @"legacyDeleted": @(legacyDeleted),
        @"backupExists": @(backupExists),
        @"backupUpdated": @(backupUpdated)
    };
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(void) backupDatabase: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self backupDatabaseNow: command];
    }];
}

-(void)backupDatabaseNow: (CDVInvokedUrlCommand*)command
{
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];
    NSString *sourceName = [options objectForKey:@"sourceName"];
    NSString *sourceLocation = [options objectForKey:@"sourceDblocation"];
    NSString *sourceAppGroup = [options objectForKey:@"sourceAppGroup"];
    NSString *backupName = [options objectForKey:@"backupName"];
    NSString *backupLocation = [options objectForKey:@"backupDblocation"];
    NSString *backupAppGroup = [options objectForKey:@"backupAppGroup"];

    NSString *sourcePath = [self getDBPath:sourceName at:sourceLocation appGroup:sourceAppGroup];
    NSString *backupPath = [self getDBPath:backupName at:backupLocation appGroup:backupAppGroup];

    if (sourcePath == NULL || backupPath == NULL) {
        CDVPluginResult *pathError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: backupDatabase with no valid database path found"];
        [self.commandDelegate sendPluginResult:pathError callbackId:command.callbackId];
        return;
    }

    if ([sourcePath isEqualToString:backupPath]) {
        CDVPluginResult *samePathError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Source and backup database paths must be different"];
        [self.commandDelegate sendPluginResult:samePathError callbackId:command.callbackId];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:sourcePath]) {
        CDVPluginResult *missingSourceError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The backup source database does not exist on that path"];
        [self.commandDelegate sendPluginResult:missingSourceError callbackId:command.callbackId];
        return;
    }

    BOOL backupExisted = [fileManager fileExistsAtPath:backupPath];
    NSString *errorMessage = nil;
    if (![self backupDatabaseFromPath:sourcePath toPath:backupPath backupName:backupName errorMessage:&errorMessage]) {
        CDVPluginResult *backupError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
        [self.commandDelegate sendPluginResult:backupError callbackId:command.callbackId];
        return;
    }

    NSDictionary *result = @{
        @"action": @"backed-up",
        @"sourceExists": @(YES),
        @"backupExisted": @(backupExisted),
        @"backupExists": @([fileManager fileExistsAtPath:backupPath]),
        @"backupUpdated": @(YES)
    };
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(void) restoreDatabase: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self restoreDatabaseNow: command];
    }];
}

-(void)restoreDatabaseNow: (CDVInvokedUrlCommand*)command
{
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];
    NSString *sourceName = [options objectForKey:@"sourceName"];
    NSString *sourceLocation = [options objectForKey:@"sourceDblocation"];
    NSString *sourceAppGroup = [options objectForKey:@"sourceAppGroup"];
    NSString *destinationName = [options objectForKey:@"destinationName"];
    NSString *destinationLocation = [options objectForKey:@"destinationDblocation"];
    NSString *destinationAppGroup = [options objectForKey:@"destinationAppGroup"];
    BOOL deleteSource = [[options objectForKey:@"deleteSource"] boolValue];

    NSString *sourcePath = [self getDBPath:sourceName at:sourceLocation appGroup:sourceAppGroup];
    NSString *destinationPath = [self getDBPath:destinationName at:destinationLocation appGroup:destinationAppGroup];

    if (sourcePath == NULL || destinationPath == NULL) {
        CDVPluginResult *pathError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: restoreDatabase with no valid database path found"];
        [self.commandDelegate sendPluginResult:pathError callbackId:command.callbackId];
        return;
    }

    if ([sourcePath isEqualToString:destinationPath]) {
        CDVPluginResult *samePathError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Source and destination database paths must be different"];
        [self.commandDelegate sendPluginResult:samePathError callbackId:command.callbackId];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:sourcePath]) {
        CDVPluginResult *missingSourceError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The restore source database does not exist on that path"];
        [self.commandDelegate sendPluginResult:missingSourceError callbackId:command.callbackId];
        return;
    }

    if ([openDBs objectForKey:destinationName] != NULL) {
        CDVPluginResult *openDestinationError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Close the destination database before calling restoreDatabase"];
        [self.commandDelegate sendPluginResult:openDestinationError callbackId:command.callbackId];
        return;
    }

    if (deleteSource && [openDBs objectForKey:sourceName] != NULL) {
        CDVPluginResult *openSourceError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Close the restore source database before using deleteSource"];
        [self.commandDelegate sendPluginResult:openSourceError callbackId:command.callbackId];
        return;
    }

    for (NSString *suffix in @[@"-journal", @"-wal", @"-shm"]) {
        if ([fileManager fileExistsAtPath:[destinationPath stringByAppendingString:suffix]]) {
            CDVPluginResult *sidecarError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The destination database has active SQLite sidecar files; close all app and extension connections before restoring"];
            [self.commandDelegate sendPluginResult:sidecarError callbackId:command.callbackId];
            return;
        }
    }

    NSString *errorMessage = nil;
    if (![self validateDatabaseAtPath:sourcePath errorMessage:&errorMessage]) {
        CDVPluginResult *validationError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
        [self.commandDelegate sendPluginResult:validationError callbackId:command.callbackId];
        return;
    }

    BOOL destinationExisted = [fileManager fileExistsAtPath:destinationPath];
    if (![self createDatabaseSnapshotFromPath:sourcePath toPath:destinationPath errorMessage:&errorMessage]) {
        CDVPluginResult *restoreError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
        [self.commandDelegate sendPluginResult:restoreError callbackId:command.callbackId];
        return;
    }

    BOOL sourceDeleted = NO;
    if (deleteSource) {
        if (![self removeDatabaseAtPath:sourcePath errorMessage:&errorMessage]) {
            NSString *message = [NSString stringWithFormat:@"Database restored but the source could not be deleted: %@", errorMessage];
            CDVPluginResult *deleteError = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
            [self.commandDelegate sendPluginResult:deleteError callbackId:command.callbackId];
            return;
        }
        sourceDeleted = YES;
    }

    NSDictionary *result = @{
        @"action": @"restored",
        @"destinationExisted": @(destinationExisted),
        @"destinationExists": @([fileManager fileExistsAtPath:destinationPath]),
        @"sourceDeleted": @(sourceDeleted)
    };
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}


-(void) backgroundExecuteSqlBatch: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self executeSqlBatchNow: command];
    }];
}

-(void) executeSqlBatchNow: (CDVInvokedUrlCommand*)command
{
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:0];
    NSMutableDictionary *dbargs = [options objectForKey:@"dbargs"];
    NSMutableArray *executes = [options objectForKey:@"executes"];

    CDVPluginResult* pluginResult;

    {
        for (NSMutableDictionary *dict in executes) {
            CDVPluginResult *result = [self executeSqlWithDict:dict andArgs:dbargs];
            if ([result.status intValue] == CDVCommandStatus_ERROR) {
                /* add error with result.message: */
                NSMutableDictionary *r = [NSMutableDictionary dictionaryWithCapacity:0];
                [r setObject:@"error" forKey:@"type"];
                [r setObject:result.message forKey:@"error"];
                [r setObject:result.message forKey:@"result"];
                [results addObject: r];
            } else {
                /* add result with result.message: */
                NSMutableDictionary *r = [NSMutableDictionary dictionaryWithCapacity:0];
                [r setObject:@"success" forKey:@"type"];
                [r setObject:result.message forKey:@"result"];
                [results addObject: r];
            }
        }

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:results];
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(void) executeSql: (CDVInvokedUrlCommand*)command
{
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];
    NSMutableDictionary *dbargs = [options objectForKey:@"dbargs"];
    NSMutableDictionary *ex = [options objectForKey:@"ex"];

    CDVPluginResult * pluginResult = [self executeSqlWithDict: ex andArgs: dbargs];

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(CDVPluginResult*) executeSqlWithDict: (NSMutableDictionary*)options andArgs: (NSMutableDictionary*)dbargs
{
    NSString *dbFileName = [dbargs objectForKey:@"dbname"];
    if (dbFileName == NULL) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify database path"];
    }

    NSMutableArray *params = [options objectForKey:@"params"]; // optional

    NSValue *dbPointer = [openDBs objectForKey:dbFileName];
    if (dbPointer == NULL) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: No such database, you must open it first"];
    }
    sqlite3 *db = [dbPointer pointerValue];

    NSString *sql = [options objectForKey:@"sql"];
    if (sql == NULL) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify a sql query to execute"];
    }

    const char *sql_stmt = [sql UTF8String];
    NSDictionary *error = nil;
    sqlite3_stmt *statement;
    int result, i, column_type, count;
    int previousRowsAffected, nowRowsAffected, diffRowsAffected;
    long long previousInsertId, nowInsertId;
    BOOL keepGoing = YES;
    BOOL hasInsertId;
    NSMutableDictionary *resultSet = [NSMutableDictionary dictionaryWithCapacity:0];
    NSMutableArray *resultRows = [NSMutableArray arrayWithCapacity:0];
    NSMutableDictionary *entry;
    NSObject *columnValue;
    NSString *columnName;
    NSObject *insertId;
    NSObject *rowsAffected;

    hasInsertId = NO;
    previousRowsAffected = sqlite3_total_changes(db);
    previousInsertId = sqlite3_last_insert_rowid(db);

    if (sqlite3_prepare_v2(db, sql_stmt, -1, &statement, NULL) != SQLITE_OK) {
        error = [SQLitePlugin captureSQLiteErrorFromDb:db];
        keepGoing = NO;
    } else if (params != NULL) {
        for (int b = 0; b < params.count; b++) {
            result = [self bindStatement:statement withArg:[params objectAtIndex:b] atIndex:(b+1)];
            if (result != SQLITE_OK) {
                error = [SQLitePlugin captureSQLiteErrorFromDb:db];
                keepGoing = NO;
                break;
            }
        }
    }

    while (keepGoing) {
        result = sqlite3_step (statement);
        switch (result) {

            case SQLITE_ROW:
                i = 0;
                entry = [NSMutableDictionary dictionaryWithCapacity:0];
                count = sqlite3_column_count(statement);

                while (i < count) {
                    columnValue = nil;
                    columnName = [NSString stringWithFormat:@"%s", sqlite3_column_name(statement, i)];

                    column_type = sqlite3_column_type(statement, i);
                    switch (column_type) {
                        case SQLITE_INTEGER:
                            columnValue = [NSNumber numberWithLongLong: sqlite3_column_int64(statement, i)];
                            break;
                        case SQLITE_FLOAT:
                            columnValue = [NSNumber numberWithDouble: sqlite3_column_double(statement, i)];
                            break;
                        case SQLITE_BLOB:
                        case SQLITE_TEXT:
                            columnValue = [[NSString alloc] initWithBytes:(char *)sqlite3_column_text(statement, i)
                                                                   length:sqlite3_column_bytes(statement, i)
                                                                 encoding:NSUTF8StringEncoding];
                            break;
                        case SQLITE_NULL:
                        // just in case (should not happen):
                        default:
                            columnValue = [NSNull null];
                            break;
                    }

                    if (columnValue) {
                        [entry setObject:columnValue forKey:columnName];
                    }

                    i++;
                }
                [resultRows addObject:entry];
                break;

            case SQLITE_DONE:
                nowRowsAffected = sqlite3_total_changes(db);
                diffRowsAffected = nowRowsAffected - previousRowsAffected;
                rowsAffected = [NSNumber numberWithInt:diffRowsAffected];
                nowInsertId = sqlite3_last_insert_rowid(db);
                if (diffRowsAffected > 0 && nowInsertId != 0) {
                    hasInsertId = YES;
                    insertId = [NSNumber numberWithLongLong:sqlite3_last_insert_rowid(db)];
                }
                keepGoing = NO;
                break;

            default:
                error = [SQLitePlugin captureSQLiteErrorFromDb:db];
                keepGoing = NO;
        }
    }

    sqlite3_finalize (statement);

    if (error) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:error];
    }

    [resultSet setObject:resultRows forKey:@"rows"];
    [resultSet setObject:rowsAffected forKey:@"rowsAffected"];
    if (hasInsertId) {
        [resultSet setObject:insertId forKey:@"insertId"];
    }
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:resultSet];
}

-(int)bindStatement:(sqlite3_stmt *)statement withArg:(NSObject *)arg atIndex:(int)argIndex
{
    int bindResult = SQLITE_ERROR;

    if ([arg isEqual:[NSNull null]]) {
        // bind null:
        bindResult = sqlite3_bind_null(statement, argIndex);
    } else if ([arg isKindOfClass:[NSNumber class]]) {
        // bind NSNumber (int64 or double):
        NSNumber *numberArg = (NSNumber *)arg;
        const char *numberType = [numberArg objCType];

        // Bind each number as INTEGER (long long int) or REAL (double):
        if (strcmp(numberType, @encode(int)) == 0 ||
            strcmp(numberType, @encode(long long int)) == 0) {
            bindResult = sqlite3_bind_int64(statement, argIndex, [numberArg longLongValue]);
        } else {
            bindResult = sqlite3_bind_double(statement, argIndex, [numberArg doubleValue]);
        }
    } else {
        // bind NSString (text):
        NSString *stringArg;

        if ([arg isKindOfClass:[NSString class]]) {
            stringArg = (NSString *)arg;
        } else {
            stringArg = [arg description]; // convert to text
        }

        // always bind text string as UTF-8 (sqlite does internal conversion if necessary):
        NSData *data = [stringArg dataUsingEncoding:NSUTF8StringEncoding];
        bindResult = sqlite3_bind_text(statement, argIndex, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    }

    return bindResult;
}

-(void)dealloc
{
    int i;
    NSArray *keys = [openDBs allKeys];
    NSValue *pointer;
    NSString *key;
    sqlite3 *db;

    /* close db the user forgot */
    for (i=0; i<[keys count]; i++) {
        key = [keys objectAtIndex:i];
        pointer = [openDBs objectForKey:key];
        db = [pointer pointerValue];
        sqlite3_close (db);
    }
}

+(NSDictionary *)captureSQLiteErrorFromDb:(struct sqlite3 *)db
{
    int code = sqlite3_errcode(db);
    int webSQLCode = [SQLitePlugin mapSQLiteErrorCode:code];
#if INCLUDE_SQLITE_ERROR_INFO
    int extendedCode = sqlite3_extended_errcode(db);
#endif
    const char *message = sqlite3_errmsg(db);

    NSMutableDictionary *error = [NSMutableDictionary dictionaryWithCapacity:4];

    [error setObject:[NSNumber numberWithInt:webSQLCode] forKey:@"code"];
    [error setObject:[NSString stringWithUTF8String:message] forKey:@"message"];

#if INCLUDE_SQLITE_ERROR_INFO
    [error setObject:[NSNumber numberWithInt:code] forKey:@"sqliteCode"];
    [error setObject:[NSNumber numberWithInt:extendedCode] forKey:@"sqliteExtendedCode"];
    [error setObject:[NSString stringWithUTF8String:message] forKey:@"sqliteMessage"];
#endif

    return error;
}

+(int)mapSQLiteErrorCode:(int)code
{
    // map the sqlite error code to
    // the websql error code
    switch(code) {
        case SQLITE_ERROR:
            return SYNTAX_ERR_;
        case SQLITE_FULL:
            return QUOTA_ERR;
        case SQLITE_CONSTRAINT:
            return CONSTRAINT_ERR;
        default:
            return UNKNOWN_ERR;
    }
}

@end /* vim: set expandtab : */
