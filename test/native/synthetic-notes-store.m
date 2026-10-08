// Test fixture generator. Loads only the installed CoreData model, never NotesShared.
// Every object is a generic NSManagedObject, avoiding private awakeFromInsert hooks.
// Invoke only through the scratch-only sandbox in test-private-writer-synthetic-store.mjs.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#include <unistd.h>
extern const int SANDBOX_CHECK_NO_REPORT;
extern int sandbox_check(pid_t, const char *, int, ...);

static NSManagedObject *Insert(NSManagedObjectContext *context, NSString *name) {
  NSEntityDescription *entity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[name];
  if (!entity || entity.isAbstract) @throw [NSException exceptionWithName:@"UnsupportedModel" reason:name userInfo:nil];
  return [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:context];
}
static void Set(NSManagedObject *object, NSString *key, id value) {
  if (!object.entity.propertiesByName[key])
    @throw [NSException exceptionWithName:@"UnsupportedModel" reason:key userInfo:nil];
  [object setValue:value forKey:key];
}
static NSDate *FixtureDate(void) { return [NSDate dateWithTimeIntervalSince1970:1700000000]; }
static void CloudState(NSManagedObjectContext *context, NSManagedObject *object) {
  NSManagedObject *state = Insert(context, @"ICCloudState");
  Set(state, @"currentLocalVersion", @1);
  Set(state, @"latestVersionSyncedToCloud", @0);
  Set(state, @"inCloud", @NO);
  Set(state, @"localVersionDate", FixtureDate());
  Set(state, @"cloudSyncingObject", object);
  Set(object, @"needsInitialFetchFromCloud", @NO);
  Set(object, @"needsToBeFetchedFromCloud", @NO);
}
static BOOL IsUUID(NSString *value) {
  return [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static NSString *const InlineIdentifier = @"66666666-6666-4666-8666-666666666666";
static NSString *const ExtraInlineIdentifier = @"88888888-8888-4888-8888-888888888888";
static BOOL IsFixedPublicPayload(NSData *payload) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(payload.bytes, (CC_LONG)payload.length, digest);
  NSMutableString *hex = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
  return [hex isEqualToString:@"ac93f271962eddbc6511ce12064ae1ac423e91546c8eff356a9ecddc765fa0d1"];
}
static NSManagedObject *HiddenInline(NSManagedObjectContext *context, NSManagedObject *note, NSString *identifier) {
  NSManagedObject *row = Insert(context, @"ICInlineAttachment");
  Set(row, @"identifier", identifier);
  Set(row, @"tokenContentIdentifier", identifier);
  Set(row, @"typeUTI", @"com.apple.notes.inlinetextattachment.dividerline");
  Set(row, @"markedForDeletion", @NO);
  Set(row, @"note", note);
  // Match the fixed cloud-state infrastructure of every generated cloud row;
  // otherwise Notes' ordinary lazy initialization inserts one at rehearsal.
  CloudState(context, row);
  return row;
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    @try {
      NSString *mode = argc == 6 ? @(argv[5]) : @"";
      BOOL receiptFixture = [mode isEqualToString:@"--receipt-fixture"];
      BOOL mutate = [@[@"--inline-token", @"--inline-tombstone", @"--inline-add-hidden", @"--inline-restore"] containsObject:mode];
      BOOL scopeFixture = [mode isEqualToString:@"--scope-fixture"] || receiptFixture;
      if (argc != 5 && !(argc == 6 && (scopeFixture || mutate))) return 2;
      NSString *storePath = @(argv[1]), *payloadPath = @(argv[2]);
      NSString *noteIdentifier = @(argv[3]), *notesReplicaIdentifier = @(argv[4]);
      // Caller paths are confined by the mandatory surrounding sandbox. Refuse
      // replacing any existing database or consuming a non-UUID identity.
      if (!storePath.isAbsolutePath || !payloadPath.isAbsolutePath || !IsUUID(noteIdentifier) ||
          !IsUUID(notesReplicaIdentifier) ||
          [NSFileManager.defaultManager fileExistsAtPath:storePath] != mutate) return 3;
      if ((receiptFixture || mutate) && (![noteIdentifier isEqualToString:@"33333333-3333-4333-8333-333333333333"] ||
          ![notesReplicaIdentifier isEqualToString:@"11111111-1111-4111-8111-111111111111"])) return 3;
      NSString *root = [[storePath stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
      NSString *payloadRoot = [[payloadPath stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
      const char *realHome = getenv("HOME");
      NSString *privateSentinel = realHome ? [@(realHome) stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"] : nil;
      // Policy inspection only: these paths are never opened. The generator
      // must itself refuse accidental invocation outside the denying sandbox.
      if (!([root hasPrefix:@"/tmp/apple-notes-synthetic-fixture-"] ||
            [root hasPrefix:@"/private/tmp/apple-notes-synthetic-fixture-"]) ||
          ![root isEqualToString:payloadRoot] || !privateSentinel ||
          sandbox_check(getpid(), "file-read-data", 1 | SANDBOX_CHECK_NO_REPORT, privateSentinel.UTF8String) != 1 ||
          sandbox_check(getpid(), "network-outbound", SANDBOX_CHECK_NO_REPORT, NULL) != 1 ||
          sandbox_check(getpid(), "mach-lookup", 2 | SANDBOX_CHECK_NO_REPORT, "com.apple.cfprefsd.agent") != 1 ||
          objc_getClass("ICNote") != Nil) return 10;
      NSData *payload = [NSData dataWithContentsOfFile:payloadPath];
      if (!payload.length || payload.length > 1024 * 1024) return 4;
      // Receipt/drift modes may only consume the deterministic public seed.
      // Mutation modes never apply these bytes to the existing note body.
      if ((receiptFixture || mutate) && !IsFixedPublicPayload(payload)) return 4;
      if (mutate) {
        NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:storePath];
        NSData *header = [file readDataOfLength:20];
        [file closeFile];
        const unsigned char *bytes = header.bytes;
        if (header.length != 20 || memcmp(bytes, "SQLite format 3\0", 16) != 0 || bytes[18] != 2 || bytes[19] != 2)
          return 14; // Refuse any store not already in the writer's WAL mode.
      }
      NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:
          [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/NotesShared.framework/Resources/NoteData.mom"]];
      if (!model) return 5;
      // Opening a generated store for fixed row drift must also fetch generic
      // objects; never resolve the model's private managed-object classes.
      for (NSEntityDescription *entity in model.entities) entity.managedObjectClassName = @"NSManagedObject";
      NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
      NSDictionary *options = @{
        NSMigratePersistentStoresAutomaticallyOption: @NO,
        NSInferMappingModelAutomaticallyOption: @NO,
        NSPersistentHistoryTrackingKey: @YES,
        // Fresh generation closes a journal-free baseline. Fixed drift must
        // retain the WAL mode already established by the production writer,
        // rather than make its next refusal reopen/convert the database.
        NSSQLitePragmasOption: @{ @"journal_mode": mutate ? @"WAL" : @"DELETE" },
      };
      NSError *error = nil;
      NSPersistentStore *store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
          URL:[NSURL fileURLWithPath:storePath] options:options error:&error];
      if (!store) { NSLog(@"Synthetic store creation failed: %@", error); return 6; }
      NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
      context.persistentStoreCoordinator = coordinator;
      context.mergePolicy = NSErrorMergePolicy;
      context.undoManager = nil;
      context.transactionAuthor = @"synthetic-fixture-generator";
      if (mutate) {
        // Fixed generated rows only. No arbitrary entity, key, identifier or
        // payload may be supplied; generic objects avoid private model hooks.
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        request.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", noteIdentifier];
        NSArray *notes = [context executeFetchRequest:request error:&error];
        if (notes.count != 1) return 11;
        NSManagedObject *note = notes.firstObject;
        NSManagedObject *data = [note valueForKey:@"noteData"];
        NSData *beforeBody = [[data valueForKey:@"data"] copy];
        NSDate *beforeDate = [[note valueForKey:@"modificationDate"] copy];
        NSManagedObject *primary = nil, *extra = nil;
        for (NSManagedObject *row in [note valueForKey:@"inlineAttachments"]) {
          NSString *identifier = [row valueForKey:@"identifier"];
          if ([identifier isEqualToString:InlineIdentifier]) primary = row;
          else if ([identifier isEqualToString:ExtraInlineIdentifier]) extra = row;
          else return 12;
        }
        if (!primary) return 12;
        if ([mode isEqualToString:@"--inline-token"]) Set(primary, @"tokenContentIdentifier", ExtraInlineIdentifier);
        else if ([mode isEqualToString:@"--inline-tombstone"]) Set(primary, @"markedForDeletion", @YES);
        else if ([mode isEqualToString:@"--inline-add-hidden"]) { if (extra) return 12; HiddenInline(context, note, ExtraInlineIdentifier); }
        else {
          Set(primary, @"tokenContentIdentifier", InlineIdentifier);
          Set(primary, @"markedForDeletion", @NO);
          if (extra) [context deleteObject:extra];
        }
        if (![[data valueForKey:@"data"] isEqual:beforeBody] || ![[note valueForKey:@"modificationDate"] isEqual:beforeDate]) return 13;
        if (![context save:&error]) return 7;
        [context reset];
        if (![coordinator removePersistentStore:store error:&error]) return 8;
        puts("{\"mutated\":true,\"frameworkLoaded\":false,\"bodyPreserved\":true,\"modificationDatePreserved\":true}");
        return 0;
      }
      NSManagedObject *account = Insert(context, @"ICAccount");
      NSManagedObject *folder = Insert(context, @"ICFolder");
      NSManagedObject *note = Insert(context, @"ICNote");
      NSManagedObject *data = Insert(context, @"ICNoteData");
      Set(account, @"identifier", @"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA");
      Set(account, @"name", @"Synthetic Account");
      Set(account, @"accountType", @0);
      Set(account, @"owner", account);
      // Despite the property's name, NotesShared initializes this dictionary
      // with bundle identifier keys and UUID string values. Preseed only test
      // identities so its lazy initialization does not change the account on
      // the first note-only write. No production account metadata is copied.
      Set(account, @"replicaIDToBundleIdentifier", @{
        @"com.apple.Notes": notesReplicaIdentifier,
        @"com.apple.Notes.IntentsExtension": @"44444444-4444-4444-8444-444444444444",
        @"com.apple.Notes.SharingExtension": @"55555555-5555-4555-8555-555555555555",
      });
      CloudState(context, account);
      Set(folder, @"identifier", @"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB");
      Set(folder, @"title", @"Synthetic Folder");
      Set(folder, @"account", account);
      Set(folder, @"owner", account);
      Set(folder, @"folderType", @0);
      CloudState(context, folder);
      if (scopeFixture) {
        // A fixed, public hierarchy for independently exercising each scope
        // condition. The two forbidden folders are outside the target chain.
        NSArray *identifiers = @[
          @"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
          @"DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",
          @"EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE",
        ];
        NSArray *titles = @[ @"Synthetic Parent", @"Synthetic Forbidden One", @"Synthetic Forbidden Two" ];
        for (NSUInteger index = 0; index < identifiers.count; index++) {
          NSManagedObject *extra = Insert(context, @"ICFolder");
          Set(extra, @"identifier", identifiers[index]);
          Set(extra, @"title", titles[index]);
          Set(extra, @"account", account);
          Set(extra, @"owner", account);
          Set(extra, @"folderType", @0);
          CloudState(context, extra);
          if (index == 0) Set(folder, @"parent", extra);
        }
      }
      Set(note, @"identifier", noteIdentifier);
      Set(note, @"title", @"Synthetic fixture");
      Set(note, @"account", account);
      Set(note, @"folder", folder);
      Set(note, @"creationDate", FixtureDate());
      Set(note, @"modificationDate", FixtureDate());
      Set(note, @"lastViewedModificationDate", FixtureDate());
      Set(note, @"noteData", data);
      Set(data, @"data", payload);
      CloudState(context, note);
      // Deliberately hidden owned row: no glyph, file, media relation or table
      // CRDT. a1 must include it even though the note body never references it.
      if (receiptFixture) HiddenInline(context, note, InlineIdentifier);
      if (![context save:&error]) { NSLog(@"Synthetic graph save failed: %@", error); return 7; }
      [context reset];
      if (![coordinator removePersistentStore:store error:&error]) { NSLog(@"Synthetic store close failed: %@", error); return 8; }
      if (receiptFixture) puts("{\"created\":true,\"frameworkLoaded\":false,\"notes\":1,\"accounts\":1,\"folders\":4,\"inlineAttachments\":1}");
      else printf("{\"created\":true,\"frameworkLoaded\":false,\"notes\":1,\"accounts\":1,\"folders\":%d}\n", scopeFixture ? 4 : 1);
      return 0;
    } @catch (NSException *error) {
      NSLog(@"Synthetic generator failed: %@: %@", error.name, error.reason);
      return 9;
    }
  }
}
