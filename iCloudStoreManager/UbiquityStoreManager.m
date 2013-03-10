//
//  UbiquityStoreManager.m
//  UbiquityStoreManager
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "UbiquityStoreManager.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else

#import <Cocoa/Cocoa.h>

#endif

NSString *const UbiquityManagedStoreDidChangeNotification = @"UbiquityManagedStoreDidChangeNotification";
NSString *const UbiquityManagedStoreDidImportChangesNotification = @"UbiquityManagedStoreDidImportChangesNotification";
NSString *const StoreUUIDKey                         = @"USMStoreUUIDKey"; // cloud: The UUID of the active cloud store.
NSString *const CloudEnabledKey                      = @"USMCloudEnabledKey"; // local: Whether the user wants the app on this device to use iCloud.
NSString *const CloudStoreDirectory                  = @"CloudStore.nosync";
NSString *const CloudLogsDirectory                   = @"CloudLogs";

@interface UbiquityStoreManager ()<NSFilePresenter>

@property (nonatomic, copy) NSString               *contentName;
@property (nonatomic, strong) NSManagedObjectModel *model;
@property (nonatomic, copy) NSURL                  *localStoreURL;
@property (nonatomic, copy) NSString               *containerIdentifier;
@property (nonatomic, copy) NSDictionary           *additionalStoreOptions;
@property (nonatomic, readonly) NSString           *storeUUID;
@property (nonatomic, strong) NSString             *tentativeStoreUUID;
@property (nonatomic, strong) NSOperationQueue     *persistentStorageQueue;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;

@property(nonatomic, strong) id <NSObject, NSCopying, NSCoding> currentIdentityToken;
@end


@implementation UbiquityStoreManager {
    NSPersistentStoreCoordinator *_persistentStoreCoordinator;
    NSOperationQueue *_presentedItemOperationQueue;
}

- (id)initStoreNamed:(NSString *)contentName withManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)localStoreURL
 containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions
            delegate:(id <UbiquityStoreManagerDelegate>)delegate {

    if (!(self = [super init]))
        return nil;

    // Parameters.
    _delegate               = delegate;
    _contentName            = contentName == nil? @"UbiquityStore": contentName;
    _model                  = model == nil? [NSManagedObjectModel mergedModelFromBundles:nil]: model;
    if (!localStoreURL)
        localStoreURL = [[[self URLForApplicationContainer]
                                URLByAppendingPathComponent:self.contentName isDirectory:NO]
                                URLByAppendingPathExtension:@"sqlite"];
    _localStoreURL          = localStoreURL;
    _containerIdentifier    = containerIdentifier;
    _additionalStoreOptions = additionalStoreOptions == nil? [NSDictionary dictionary]: additionalStoreOptions;

    // Private vars.
    _migrationStrategy = UbiquityStoreMigrationStrategyCopyEntities;
    _persistentStorageQueue = [NSOperationQueue new];
    _persistentStorageQueue.name = [NSString stringWithFormat:@"%@PersistenceQueue", NSStringFromClass([self class])];
    _persistentStorageQueue.maxConcurrentOperationCount = 1;
    _presentedItemOperationQueue = [NSOperationQueue new];
    _presentedItemOperationQueue.name = [NSString stringWithFormat:@"%@PresenterQueue", NSStringFromClass([self class])];

    // Observe application events.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyValueStoreChanged:)
                                                 name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification
                                               object:[NSUbiquitousKeyValueStore defaultStore]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cloudStoreChanged:)
                                                 name:NSUbiquityIdentityDidChangeNotification
                                               object:nil];
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
#else
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
#endif
    [NSFileCoordinator addFilePresenter:self];

    [self loadStore];
    
    return self;
}

- (void)dealloc {

    [NSFileCoordinator removeFilePresenter:self];
    [self.persistentStoreCoordinator tryLock];
    [self clearStore];
    [self.persistentStoreCoordinator unlock];
}

#pragma mark - File Handling

- (NSURL *)URLForApplicationContainer {

    NSURL *applicationSupportURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                           inDomains:NSUserDomainMask] lastObject];

#if TARGET_OS_IPHONE
    // On iOS, each app is in a sandbox so we don't need to app-scope this directory.
    return applicationSupportURL;
#else
    // The directory is shared between all apps on the system so we need to scope it for the running app.
    applicationSupportURL = [applicationSupportURL URLByAppendingPathComponent:[NSRunningApplication currentApplication].bundleIdentifier isDirectory:YES];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:applicationSupportURL
                                  withIntermediateDirectories:YES attributes:nil error:&error])
        [self error:error cause:UbiquityStoreErrorCauseCreateStorePath context:applicationSupportURL.path];

    return applicationSupportURL;
#endif
}

- (NSURL *)URLForCloudContainer {

    return [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:self.containerIdentifier];
}

- (NSURL *)URLForCloudStoreDirectory {

    // We put the database in the ubiquity container with a .nosync extension (must not be synced by iCloud),
    // so that its presence is tied closely to whether iCloud is enabled or not on the device
    // and the user can delete the store by deleting his iCloud data for the app from Settings.
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudStoreDirectory isDirectory:YES];
}

- (NSURL *)URLForCloudStore {

    // Our cloud store is in the cloud store databases directory and is identified by the active storeUUID.
    return [[[self URLForCloudStoreDirectory] URLByAppendingPathComponent:self.storeUUID isDirectory:NO] URLByAppendingPathExtension:@"sqlite"];
}

- (NSURL *)URLForCloudContentDirectory {

    // The transaction logs are in the ubiquity container and are synced by iCloud.
    return [[self URLForCloudContainer] URLByAppendingPathComponent:CloudLogsDirectory isDirectory:YES];
}

- (NSURL *)URLForCloudContent {

    // Our cloud store's logs are in the cloud store transaction logs directory and is identified by the active storeUUID.
    return [[self URLForCloudContentDirectory] URLByAppendingPathComponent:self.storeUUID isDirectory:YES];
}

- (NSURL *)URLForLocalStoreDirectory {
    
    return [self.localStoreURL URLByDeletingLastPathComponent];
}

- (NSURL *)URLForLocalStore {

    return self.localStoreURL;
}


#pragma mark - Utilities

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {

    va_list argList;
    va_start(argList, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:log:)])
        [self.delegate ubiquityStoreManager:self log:message];
    else
        NSLog(@"UbiquityStoreManager: %@", message);
}

- (void)error:(NSError *)error cause:(UbiquityStoreErrorCause)cause context:(id)context {

    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didEncounterError:cause:context:)])
        [self.delegate ubiquityStoreManager:self didEncounterError:error cause:cause context:context];
    else {
        [self log:@"Error (cause:%u): %@", cause, error];

        if (context)
            [self log:@"    - Context   : %@", context];
        NSError *underlyingError = [[error userInfo] objectForKey:NSUnderlyingErrorKey];
        if (underlyingError)
            [self log:@"    - Underlying: %@", underlyingError];
        NSArray *detailedErrors = [[error userInfo] objectForKey:NSDetailedErrorsKey];
        for (NSError *detailedError in detailedErrors)
            [self log:@"    - Detail    : %@", detailedError];
    }
}

#pragma mark - Store Management

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {

    if (!_persistentStoreCoordinator) {
        _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mergeChanges:)
                                                     name:NSPersistentStoreDidImportUbiquitousContentChangesNotification
                                                   object:_persistentStoreCoordinator];
    }

    return _persistentStoreCoordinator;
}

- (void)resetPersistentStoreCoordinator {

    BOOL wasLocked = NO;
    if (_persistentStoreCoordinator) {
        wasLocked = ![_persistentStoreCoordinator tryLock];
        [_persistentStoreCoordinator unlock];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_persistentStoreCoordinator];
    }

    if (wasLocked)
        [self.persistentStoreCoordinator lock];
}

- (void)clearStore {

    [self log:@"Clearing stores, will load %@ store...", self.cloudEnabled?@"cloud": @"local"];
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:willLoadStoreIsCloud:)])
        [self.delegate ubiquityStoreManager:self willLoadStoreIsCloud:self.cloudEnabled];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                            object:self userInfo:nil];
    });

    // Remove the store from the coordinator.
    NSError *error = nil;
    for (NSPersistentStore *store in self.persistentStoreCoordinator.persistentStores)
        if (![self.persistentStoreCoordinator removePersistentStore:store error:&error])
            [self error:error cause:UbiquityStoreErrorCauseClearStore context:store];

    if ([self.persistentStoreCoordinator.persistentStores count])
        // We couldn't remove all the stores, make a new PSC instead.
        [self resetPersistentStoreCoordinator];
}

- (void)loadStore {

    [self log:@"Will load %@ store...", self.cloudEnabled ? @"cloud" : @"local"];
    if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:willLoadStoreIsCloud:)])
        [self.delegate ubiquityStoreManager:self willLoadStoreIsCloud:self.cloudEnabled];

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self.persistentStoreCoordinator lock];
        @try {
            if (self.cloudEnabled)
                [self loadCloudStore];
            else
                [self loadLocalStore];
        } @finally {
            [self.persistentStoreCoordinator unlock];
        }
    }];
}

- (void)loadCloudStore {

    NSError *error = nil;
    UbiquityStoreErrorCause cause;
    id context = nil;
    @try {
        [self clearStore];

        // Check if the user is logged into iCloud on the device.
        if (![self URLForCloudContainer]) {
            cause = UbiquityStoreErrorCauseNoAccount;
            return;
        }

        // Create the path to the cloud store.
        NSURL *cloudStoreURL = [self URLForCloudStore];
        NSURL *localStoreURL = [self URLForLocalStore];
        NSURL *cloudStoreContentURL = [self URLForCloudContent];
        NSURL *cloudStoreDirectoryURL = [self URLForCloudStoreDirectory];
        BOOL storeExists = [[NSFileManager defaultManager] fileExistsAtPath:cloudStoreURL.path];
        BOOL storeContentExists = [[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:cloudStoreContentURL error:nil];
        if (storeExists && !storeContentExists) {
            // We have a cloud store but no cloud content.  The cloud content was deleted:
            // The existing store cannot sync anymore and needs to be recreated.
            if (![[NSFileManager defaultManager] removeItemAtURL:cloudStoreURL error:&error])
                [self error:error cause:cause = UbiquityStoreErrorCauseDeleteStore context:context = cloudStoreURL.path];
        }
        if (![[NSFileManager defaultManager] createDirectoryAtPath:cloudStoreDirectoryURL.path
                                       withIntermediateDirectories:YES attributes:nil error:&error])
            [self error:error cause:cause = UbiquityStoreErrorCauseCreateStorePath context:context = cloudStoreDirectoryURL.path];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:cloudStoreContentURL.path
                                       withIntermediateDirectories:YES attributes:nil error:&error])
            [self error:error cause:cause = UbiquityStoreErrorCauseCreateStorePath context:context = cloudStoreContentURL.path];

        // Add cloud store to PSC.
        NSMutableDictionary *cloudStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                self.contentName, NSPersistentStoreUbiquitousContentNameKey,
                cloudStoreContentURL, NSPersistentStoreUbiquitousContentURLKey,
                @YES, NSMigratePersistentStoresAutomaticallyOption,
                @YES, NSInferMappingModelAutomaticallyOption,
                nil];
        NSMutableDictionary *localStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                @YES, NSReadOnlyPersistentStoreOption,
                nil];
        [cloudStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];
        [localStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];

        // Now load the cloud store.  If possible, first migrate the local store to it.
        UbiquityStoreMigrationStrategy migrationStrategy = self.migrationStrategy;
        if (![self cloudSafeForSeeding] || ![[NSFileManager defaultManager] fileExistsAtPath:localStoreURL.path])
            migrationStrategy = UbiquityStoreMigrationStrategyNone;

        switch (migrationStrategy) {
            case UbiquityStoreMigrationStrategyCopyEntities: {
                [self log:@"Migrating local store to new cloud store using strategy: UbiquityStoreMigrationStrategyCopyEntities"];

                // Open local and cloud store.
                NSPersistentStoreCoordinator *localCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
                NSPersistentStore *localStore = [localCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                               configuration:nil URL:localStoreURL
                                                                                     options:localStoreOptions
                                                                                       error:&error];
                if (!localStore) {
                    [self error:error cause:cause = UbiquityStoreErrorCauseOpenLocalStore context:context = localStoreURL.path];
                    break;
                }

                NSPersistentStoreCoordinator *cloudCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.model];
                NSPersistentStore *cloudStore = [cloudCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                               configuration:nil URL:cloudStoreURL
                                                                                     options:cloudStoreOptions
                                                                                       error:&error];
                if (!cloudStore) {
                    [self error:error cause:cause = UbiquityStoreErrorCauseOpenCloudStore context:context = cloudStoreURL.path];
                    break;
                }

                // Set up contexts for them.
                NSManagedObjectContext *localContext = [NSManagedObjectContext new];
                NSManagedObjectContext *cloudContext = [NSManagedObjectContext new];
                localContext.persistentStoreCoordinator = localCoordinator;
                cloudContext.persistentStoreCoordinator = cloudCoordinator;

                // Copy metadata.
                NSMutableDictionary *metadata = [[localCoordinator metadataForPersistentStore:localStore] mutableCopy];
                [metadata addEntriesFromDictionary:[cloudCoordinator metadataForPersistentStore:cloudStore]];
                [cloudCoordinator setMetadata:metadata forPersistentStore:cloudStore];

                // Migrate entities.
                BOOL migrationFailure = NO;
                NSMutableDictionary *migratedIDsBySourceID = [[NSMutableDictionary alloc] initWithCapacity:500];
                for (NSEntityDescription *entity in self.model.entities) {
                    NSFetchRequest *fetch = [NSFetchRequest new];
                    fetch.entity = entity;
                    fetch.fetchBatchSize = 500;
                    fetch.relationshipKeyPathsForPrefetching = entity.relationshipsByName.allKeys;

                    NSArray *localObjects = [localContext executeFetchRequest:fetch error:&error];
                    if (!localObjects) {
                        migrationFailure = YES;
                        break;
                    }

                    for (NSManagedObject *localObject in localObjects)
                        [self copyMigrateObject:localObject toContext:cloudContext usingMigrationCache:migratedIDsBySourceID];
                }

                // Save migrated entities.
                if (!migrationFailure && ![cloudContext save:&error])
                    migrationFailure = YES;

                // Handle failure by cleaning up the cloud store.
                if (migrationFailure) {
                    [self error:error cause:cause = UbiquityStoreErrorCauseMigrateLocalToCloudStore context:context = cloudStoreURL.path];

                    if (![cloudCoordinator removePersistentStore:cloudStore error:&error])
                        [self error:error cause:cause = UbiquityStoreErrorCauseClearStore context:cloudStore];
                    [self removeItemAtURL:cloudStoreURL localOnly:NO];
                    break;
                }

                // Add the store now that migration is finished.
                if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                   configuration:nil URL:cloudStoreURL
                                                                         options:cloudStoreOptions
                                                                           error:&error])
                    [self error:error cause:cause = UbiquityStoreErrorCauseMigrateLocalToCloudStore context:context = cloudStoreURL.path];

                break;
            }

            case UbiquityStoreMigrationStrategyIOS: {
                [self log:@"Migrating local store to new cloud store using strategy: UbiquityStoreMigrationStrategyIOS"];

                // Add the store to migrate.
                NSPersistentStore *localStore = [self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                                              configuration:nil URL:localStoreURL
                                                                                                    options:localStoreOptions
                                                                                                      error:&error];

                if (!localStore) {
                    [self error:error cause:cause = UbiquityStoreErrorCauseOpenLocalStore context:context = localStoreURL.path];
                    break;
                }

                if (![self.persistentStoreCoordinator migratePersistentStore:localStore
                                                                       toURL:cloudStoreURL
                                                                     options:cloudStoreOptions
                                                                    withType:NSSQLiteStoreType
                                                                       error:&error]) {
                    [self error:error cause:cause = UbiquityStoreErrorCauseMigrateLocalToCloudStore context:context = cloudStoreURL.path];
                    [self clearStore];
                }
                break;
            }

            case UbiquityStoreMigrationStrategyManual: {
                [self log:@"Migrating local store to new cloud store using strategy: UbiquityStoreMigrationStrategyManual"];

                if (![self.delegate ubiquityStoreManager:self
                                    manuallyMigrateStore:localStoreURL withOptions:localStoreOptions
                                                 toStore:cloudStoreURL withOptions:cloudStoreOptions error:&error]) {
                    [self error:error cause:cause = UbiquityStoreErrorCauseMigrateLocalToCloudStore context:context = cloudStoreURL.path];
                    [self removeItemAtURL:cloudStoreURL localOnly:NO];
                    break;
                }

                // Add the store now that migration is finished.
                if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                   configuration:nil URL:cloudStoreURL
                                                                         options:cloudStoreOptions
                                                                           error:&error])
                    [self error:error cause:cause = UbiquityStoreErrorCauseOpenCloudStore context:context = cloudStoreURL.path];

                break;
            }

            case UbiquityStoreMigrationStrategyNone: {
                [self log:@"Loading cloud store without local store migration."];

                // Just add the store without first migrating to it.
                if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                   configuration:nil URL:cloudStoreURL
                                                                         options:cloudStoreOptions
                                                                           error:&error])
                    [self error:error cause:cause = UbiquityStoreErrorCauseOpenCloudStore context:context = cloudStoreURL.path];
                break;
            }
        }
    }
    @catch (id exception) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:2];
        if (exception)
            [userInfo setObject:[exception description] forKey:NSLocalizedFailureReasonErrorKey];
        if (error)
            [userInfo setObject:error forKey:NSUnderlyingErrorKey];
        [self error:[NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:userInfo]
              cause:cause = UbiquityStoreErrorCauseMigrateLocalToCloudStore context:context = exception];
        [self clearStore];
    }
    @finally {
        BOOL cloudWasEnabled = [self.persistentStoreCoordinator.persistentStores count] > 0;
        if (cloudWasEnabled) {
            [self confirmTentativeStoreUUID];
            [self log:@"iCloud enabled (UUID:%@) and successfully loaded cloud store.", self.storeUUID];
        }
        else {
            // If this happens, the cloud store is desynced.
            // Until it is either fixed or destroyed, the cloud store will be unavailable to the user.
            [self resetTentativeStoreUUID];

            if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)]) {
                [self log:@"iCloud enabled but failed to load cloud store (cause:%u, %@). Application will handle failure.", cause, context];
            } else {
                [self log:@"iCloud enabled but failed to load cloud store (cause:%u, %@). Will fall back to local store.", cause, context];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (cloudWasEnabled) {
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:self.persistentStoreCoordinator isCloud:YES];

                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            } else if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:YES];
            else
                self.cloudEnabled = NO;
        });
    }
}

- (void)loadLocalStore {

    UbiquityStoreErrorCause cause;
    id context = nil;
    @try {
        [self clearStore];

        // Load local store if iCloud is disabled.
        NSError *error = nil;
        NSMutableDictionary *localStoreOptions = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                @YES, NSMigratePersistentStoresAutomaticallyOption,
                @YES, NSInferMappingModelAutomaticallyOption,
                nil];
        [localStoreOptions addEntriesFromDictionary:self.additionalStoreOptions];

        // Make sure local store directory exists.
        if (![[NSFileManager defaultManager] createDirectoryAtPath:[self URLForLocalStoreDirectory].path
                                       withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self error:error cause:cause = UbiquityStoreErrorCauseCreateStorePath context:context = [self URLForLocalStoreDirectory].path];
            return;
        }

        // Add local store to PSC.
        NSURL *localStoreURL = [self URLForLocalStore];
        if (![self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                           configuration:nil URL:localStoreURL
                                                                 options:localStoreOptions
                                                                   error:&error]) {
            [self error:error cause:cause = UbiquityStoreErrorCauseOpenLocalStore context:context = localStoreURL.path];
            return;
        }
    }
    @finally {
        BOOL localWasEnabled = [self.persistentStoreCoordinator.persistentStores count] > 0;
        if (localWasEnabled) {
            [self log:@"iCloud disabled and successfully loaded local store."];
        }
        else {
            if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:wasCloud:)]) {
                [self log:@"iCloud disabled but failed to load local store (cause:%u, %@). Application will handle failure.", cause, context];
            } else {
                [self log:@"iCloud disabled but failed to load local store (cause:%u, %@). No store available to application.", cause, context];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (localWasEnabled) {
                if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:didLoadStoreForCoordinator:isCloud:)])
                    [self.delegate ubiquityStoreManager:self didLoadStoreForCoordinator:self.persistentStoreCoordinator isCloud:NO];

                [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidChangeNotification
                                                                    object:self userInfo:nil];
            } else if ([self.delegate respondsToSelector:@selector(ubiquityStoreManager:failedLoadingStoreWithCause:context:wasCloud:)])
                [self.delegate ubiquityStoreManager:self failedLoadingStoreWithCause:cause context:context wasCloud:NO];
        });
    }
}

- (id)copyMigrateObject:(NSManagedObject *)sourceObject toContext:(NSManagedObjectContext *)destinationContext usingMigrationCache:(NSMutableDictionary *)migratedIDsBySourceID {

    if (!sourceObject)
        return nil;

    NSManagedObjectID *destinationObjectID = [migratedIDsBySourceID objectForKey:sourceObject.objectID];
    if (destinationObjectID)
        return [destinationContext objectWithID:destinationObjectID];

    @autoreleasepool {
        // Create migrated object.
        NSEntityDescription *entity = sourceObject.entity;
        NSManagedObject *destinationObject = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:destinationContext];
        [migratedIDsBySourceID setObject:destinationObject.objectID forKey:sourceObject.objectID];

        // Set attributes
        for (NSString *key in entity.attributesByName.allKeys)
            [destinationObject setPrimitiveValue:[sourceObject primitiveValueForKey:key] forKey:key];

        // Set relationships recursively
        for (NSRelationshipDescription *relationDescription in entity.relationshipsByName.allValues) {
            NSString *key = relationDescription.name;
            id value = nil;

            if (relationDescription.isToMany) {
                value = [[destinationObject primitiveValueForKey:key] mutableCopy];

                for (NSManagedObject *element in [sourceObject primitiveValueForKey:key])
                    [value addObject:[self copyMigrateObject:element toContext:destinationContext usingMigrationCache:migratedIDsBySourceID]];
            }
            else
                value = [self copyMigrateObject:[sourceObject primitiveValueForKey:key] toContext:destinationContext usingMigrationCache:migratedIDsBySourceID];

            [destinationObject setPrimitiveValue:value forKey:key];
        }

        return destinationObject;
    }
}


- (BOOL)cloudSafeForSeeding {

    if ([[NSUbiquitousKeyValueStore defaultStore] objectForKey:StoreUUIDKey])
        // Migration is only safe when there is no storeUUID yet (the store is not in the cloud yet).
        return NO;

    if ([[NSFileManager defaultManager] fileExistsAtPath:[self URLForCloudStore].path])
        // Migration is only safe when the cloud store does not yet exist.
        return NO;

    return YES;
}

- (void)removeItemAtURL:(NSURL *)directoryURL localOnly:(BOOL)localOnly {

    NSError *error = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:directoryURL
                                                                              options:NSFileCoordinatorWritingForDeleting
                                                                                error:&error byAccessor:
     ^(NSURL *newURL) {
         NSError *error_ = nil;
         if (localOnly && [[NSFileManager defaultManager] isUbiquitousItemAtURL:newURL]) {
             if (![[NSFileManager defaultManager] evictUbiquitousItemAtURL:newURL error:&error_])
                 [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
         } else {
             if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error_])
                 [self error:error_ cause:UbiquityStoreErrorCauseDeleteStore context:newURL.path];
         }
     }];
    if (error)
        [self error:error cause:UbiquityStoreErrorCauseDeleteStore context:directoryURL.path];
}

- (void)deleteCloudContainerLocalOnly:(BOOL)localOnly {
    
    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the cloud container %@.", localOnly ? @"on this device" : @"on this device and in the cloud"];

            [self clearStore];

            // Delete the whole cloud container.
            [self removeItemAtURL:[self URLForCloudContainer] localOnly:localOnly];

            // Unset the storeUUID so a new one will be created.
            [self resetTentativeStoreUUID];
            if (!localOnly) {
                NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
                [cloud synchronize];
                for (id key in [[cloud dictionaryRepresentation] allKeys])
                    [cloud removeObjectForKey:key];
                [cloud synchronize];
            }

            [self loadStore];
    }];
}

- (void)deleteCloudStoreLocalOnly:(BOOL)localOnly {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the cloud store (UUID:%@) %@.", self.storeUUID, localOnly ? @"on this device" : @"on this device and in the cloud"];

            [self clearStore];

            // Clean up any cloud stores and transaction logs.
            [self removeItemAtURL:[self URLForCloudStoreDirectory] localOnly:localOnly];
            [self removeItemAtURL:[self URLForCloudContentDirectory] localOnly:localOnly];

            // Unset the storeUUID so a new one will be created.
            [self resetTentativeStoreUUID];
            if (!localOnly) {
                NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
                [cloud removeObjectForKey:StoreUUIDKey];
                [cloud synchronize];
            }

            [self loadStore];
    }];
}

- (void)deleteLocalStore {

    [self.persistentStorageQueue addOperationWithBlock:^{
        [self log:@"Will delete the local store."];

            [self clearStore];

            // Remove just the local store.
            [self removeItemAtURL:[self URLForLocalStoreDirectory] localOnly:YES];

            [self loadStore];
    }];
}

#pragma mark - Properties

- (BOOL)cloudEnabled {

    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    return [local boolForKey:CloudEnabledKey];
}

- (void)setCloudEnabled:(BOOL)enabled {

    if (self.cloudEnabled == enabled)
     // No change, do nothing to avoid a needless store reload.
        return;

    NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
    [local setBool:enabled forKey:CloudEnabledKey];
    [self loadStore];
}

- (NSString *)storeUUID {

    NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
    NSString *storeUUID = [cloud objectForKey:StoreUUIDKey];

    // If no storeUUID is set yet, create a new storeUUID and return that as long as no storeUUID is set yet.
    // When the migration to the new storeUUID is successful, we update the iCloud's KVS with a call to -setStoreUUID.
    if (!storeUUID) {
        if (!self.tentativeStoreUUID)
            self.tentativeStoreUUID = [[NSUUID UUID] UUIDString];
        storeUUID = self.tentativeStoreUUID;
    }

    return storeUUID;
}

/**
 * When a tentativeStoreUUID is set, this operation confirms it and writes it as the new storeUUID to the iCloud KVS.
 */
- (void)confirmTentativeStoreUUID {

    if (self.tentativeStoreUUID) {
        NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
        [cloud setObject:self.tentativeStoreUUID forKey:StoreUUIDKey];
        [cloud synchronize];

        [self resetTentativeStoreUUID];
    }
}

/**
 * When a tentativeStoreUUID is set, this operation resets it so that a new one will be generated if necessary.
 */
- (void)resetTentativeStoreUUID {

    self.tentativeStoreUUID = nil;
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL {

    if (self.cloudEnabled)
        return [self URLForCloudContent];

    return [self URLForLocalStore];
}

-(NSOperationQueue *)presentedItemOperationQueue {

    return _presentedItemOperationQueue;
}

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler {

    completionHandler(nil);

    // Reload the PSC's store.
    [self clearStore];

    NSError *error;
    if (self.cloudEnabled)
        if (![[NSFileManager defaultManager] removeItemAtURL:[self URLForCloudStore] error:&error])
            [self error:error cause:UbiquityStoreErrorCauseDeleteStore context:[self URLForCloudStore].path];

    [self loadStore];
}


#pragma mark - Notifications

- (void)applicationDidBecomeActive:(NSNotification *)note {

    // Check for iCloud identity changes (ie. user logs into another iCloud account).
    if (![self.currentIdentityToken isEqual:[[NSFileManager defaultManager] ubiquityIdentityToken]])
        [self cloudStoreChanged:nil];
}

- (void)applicationWillEnterForeground:(NSNotification *)note {

    [self loadStore];
}

- (void)applicationDidEnterBackground:(NSNotification *)note {

    [self clearStore];
}

- (void)applicationWillTerminate:(NSNotification *)note {

    [self clearStore];
}

- (void)keyValueStoreChanged:(NSNotification *)note {

    NSArray *changedKeys = (NSArray *)[note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangedKeysKey];
    if ([changedKeys containsObject:StoreUUIDKey])
        // The UUID of the active store changed.  We need to switch to the newly activated store.
        [self cloudStoreChanged:nil];
}

/**
 * Triggered when:
 * 1. Ubiquity identity changed (eg. iCloud account changed in settings)
 * 2. Store file was deleted (eg. iCloud container deleted in settings)
 * 3. StoreUUID changed (eg. switched to a new cloud store on another device)
 */
- (void)cloudStoreChanged:(NSNotification *)note {

    // Update the identity token in case it changed.
    self.currentIdentityToken = [[NSFileManager defaultManager] ubiquityIdentityToken];

    // Don't reload the store when the local one is active.
    if (!self.cloudEnabled)
        return;

    // Reload the store.
    [self log:@"Cloud store changed.  StoreUUID: %@, Identity: %@", self.storeUUID, self.currentIdentityToken];
    [self loadStore];
}

- (void)mergeChanges:(NSNotification *)note {

    [self log:@"Importing ubiquity changes:\n%@", note.userInfo];
    [self.persistentStorageQueue addOperationWithBlock:^{
        NSManagedObjectContext *moc = [self.delegate managedObjectContextForUbiquityChangesInManager:self];
        [moc performBlockAndWait:^{
            [moc mergeChangesFromContextDidSaveNotification:note];

            NSError *error = nil;
            if (![moc save:&error]) {
                [self error:error cause:UbiquityStoreErrorCauseImportChanges context:note];

                // Try to reload the store to see if it's still viable.
                // If not, either the application will handle it or we'll fall back to the local store.
                // TODO: Verify that this works reliably.
                [self loadStore];
            }
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:UbiquityManagedStoreDidImportChangesNotification object:self
                                                              userInfo:[note userInfo]];
        });
    }];
}

@end
