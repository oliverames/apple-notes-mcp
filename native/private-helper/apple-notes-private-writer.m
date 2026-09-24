// apple-notes-private-writer: opt-in native WRITE helper for apple-notes-mcp.
//
// This is a separate program from apple-notes-private-helper.m, which is
// read-only and stays that way. The read-only helper is what
// `setup --native-helper` builds; this writer is only built by
// `setup --native-writer`, into its own binary with its own checksum
// manifest, and the MCP server only dispatches to it when both
// APPLE_NOTES_MCP_ENABLE_PRIVATE=1 and APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1
// are set (src/services/privateWriter.ts). The writer checks the second
// switch itself before it opens the live store read-write.
//
// Speaks one JSON object in on stdin and one JSON object out on stdout. It
// loads Apple's private NotesShared framework at runtime, opens the Notes
// Core Data store through NotesShared's own managed object model and store
// options, and performs only the whitelisted actions in kActions below.
//
// Every write action follows one contract: an `ifRevision` compare-and-swap
// token checked against the persisted note before anything changes, an edit
// through NotesShared's own model (never SQL), a Core Data save with
// NSErrorMergePolicy so a concurrent Notes.app save wins, a fresh read-back
// through a brand-new coordinator, and an explicit `committed` flag on every
// failure that happens after the save.
//
// This is UNSUPPORTED PRIVATE API. Every class and selector is resolved at
// runtime and checked before use; a missing one fails closed with
// `private_api_unavailable` instead of crashing. The helper never issues SQL,
// never spawns a shell, and never dispatches a caller-supplied selector.
//
// Build (src/services/privateWriterBuild.ts; `apple-notes-mcp setup --native-writer`):
//   xcrun clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreData \
//     -framework AppKit -DHELPER_SOURCE_SHA256='"<sha256 of this file>"' \
//     -o apple-notes-private-writer apple-notes-private-writer.m
//
// Adding an action: write a `static NSDictionary *HandleX(NSDictionary *)`,
// list the NotesShared selectors it needs in an APIRequirement table (so
// `probe` can report it), and add one row to kActions with its name and
// allowed request keys. The dispatcher rejects any other key. Add the action
// to WRITER_ACTIONS in src/services/privateWriter.ts too, as "read" or
// "write"; setup refuses a writer whose action list differs.

#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>

#define PROTOCOL_VERSION 1
#define MAX_INPUT_BYTES (1024 * 1024)
#define MAX_APPEND_UTF16 50000

#ifndef HELPER_SOURCE_SHA256
#define HELPER_SOURCE_SHA256 "unset"
#endif

static NSString *const kFrameworkPath =
    @"/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared";
static NSString *const kTransactionAuthor = @"apple-notes-mcp-private-helper";
static NSString *const kChangeReason = @"apple-notes-mcp append_plain_text";
static NSString *const kEnableEnv = @"APPLE_NOTES_MCP_ENABLE_PRIVATE";
static NSString *const kWritesEnv = @"APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES";
static NSString *const kCopyStoreEnv = @"APPLE_NOTES_MCP_PRIVATE_STORE";

#pragma mark - Errors

@interface HelperError : NSException
@end
@implementation HelperError
@end

// Throwing keeps every handler linear: validation failures unwind to main(),
// which renders exactly one JSON error object.
static void Fail(NSString *code, NSString *message, NSDictionary *extra) {
  NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:code forKey:@"code"];
  if (extra) [info addEntriesFromDictionary:extra];
  @throw [HelperError exceptionWithName:code reason:message userInfo:info];
}

#pragma mark - Output

static void EmitAndExit(NSDictionary *object, int status) {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                 options:NSJSONWritingSortedKeys
                                                   error:&error];
  if (!data) {
    data = [@"{\"code\":\"internal_error\",\"message\":\"response serialization failed\","
            @"\"status\":\"error\"}" dataUsingEncoding:NSUTF8StringEncoding];
    status = 1;
  }
  fwrite(data.bytes, 1, data.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);
  exit(status);
}

static NSString *ISODate(NSDate *date) {
  if (![date isKindOfClass:[NSDate class]]) return nil;
  static NSISO8601DateFormatter *formatter;
  if (!formatter) {
    formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions =
        NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
  }
  return [formatter stringFromDate:date];
}

static id OrNull(id value) { return value ?: [NSNull null]; }

static NSString *SHA256Hex(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

#pragma mark - Runtime API surface

// Everything the helper calls on NotesShared, grouped by the feature that
// needs it. `probe` reports each feature's missing entries; handlers call
// RequireFeature() before touching the framework.
typedef struct {
  const char *cls;
  const char *sel;  // NULL = class only
  BOOL classMethod;
} APIRequirement;

static const APIRequirement kModelAPI[] = {
    {"ICPersistentContainer", "managedObjectModel", YES},
    {"ICPersistentContainer", "standardStoreOptions", YES},
    {"ICNote", NULL, NO},
    {"ICNoteData", NULL, NO},
    {"ICCloudState", NULL, NO},
};

static const APIRequirement kReadAPI[] = {
    {"ICNote", "mergeableString", NO},
    {"ICNote", "isDeletedOrInTrash", NO},
    {"ICNote", "isSharedViaICloud", NO},
    {"ICNote", "isEditable", NO},
    {"ICTTMergeableString", "attributedString", NO},
};

// Core Data properties are @dynamic: their accessors do not exist until Core
// Data generates them, so they are checked against the managed object model
// (entity name, then property names) rather than with respondsToSelector:.
typedef struct {
  const char *entity;
  const char *properties;  // comma-separated
} ModelRequirement;

static const ModelRequirement kModelProperties[] = {
    {"ICNote",
     "identifier,title,modificationDate,creationDate,folder,account,noteData,cloudState,"
     "isPasswordProtected,markedForDeletion,needsInitialFetchFromCloud"},
    {"ICNoteData", "data"},
    {"ICCloudState", "currentLocalVersion,latestVersionSyncedToCloud"},
    {"ICFolder", "identifier"},
};

static const APIRequirement kAppendAPI[] = {
    {"ICTTMergeableString", "beginEditing", NO},
    {"ICTTMergeableString", "endEditing", NO},
    {"ICTTMergeableString", "insertAttributedString:atIndex:", NO},
    {"ICNote", "edited:range:changeInLength:", NO},
    {"ICNote", "saveNoteData", NO},
    {"ICNote", "updateChangeCountWithReason:", NO},
    {"ICNote", "regenerateTitle:snippet:", NO},
};

// Native CRDT tables: row and cell edits go through ICTable (a CRTable) and
// are serialized back into the attachment by ICAttachmentTableModel.
static const APIRequirement kTableAPI[] = {
    {"ICTable", "registerWithICCRCoder", YES},
    {"ICAttachment", "tableModel", NO},
    {"ICAttachment", "saveMergeableDataIfNeeded", NO},
    {"ICAttachment", "updateChangeCountWithReason:", NO},
    {"ICAttachmentTableModel", "table", NO},
    {"ICAttachmentTableModel", "writeMergeableData", NO},
    {"ICAttachmentTableModel", "regenerateTextContentInNote", NO},
    {"ICTable", "rowCount", NO},
    {"ICTable", "columnCount", NO},
    {"ICTable", "identifierForRowAtIndex:", NO},
    {"ICTable", "identifierForColumnAtIndex:", NO},
    {"ICTable", "removeRowAtIndex:", NO},
    {"ICTable", "insertRowAtIndex:", NO},
    {"ICTable", "stringForColumnIndex:rowIndex:", NO},
    {"ICTable", "setAttributedString:columnIndex:rowIndex:", NO},
    {"ICTTAttachment", "attachmentIdentifier", NO},
    {"ICNote", "updateChangeCountWithReason:", NO},
};

// Tombstoning an attachment is the same call Notes makes when a user deletes
// one: CloudKit then deletes the record on other devices.
static const APIRequirement kPruneAPI[] = {
    {"ICAttachment", "markForDeletion", NO},
    {"ICAttachment", "updateMarkedForDeletionStateAttachmentIsInUse:", NO},
    {"ICNote", "rangeForAttachment:", NO},
};

static const ModelRequirement kTableModelProperties[] = {
    {"ICNote", "attachments"},
    {"ICAttachment", "identifier,typeUTI,note,parentAttachment,markedForDeletion,mergeableData"},
};

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

static BOOL gFrameworkLoaded = NO;
static NSString *gFrameworkError = nil;

static void LoadFramework(void) {
  static BOOL attempted = NO;
  if (attempted) return;
  attempted = YES;
  if (dlopen(kFrameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) {
    gFrameworkLoaded = YES;
  } else {
    const char *reason = dlerror();
    gFrameworkError = reason ? @(reason) : @"dlopen failed";
  }
}

static NSArray<NSString *> *MissingAPI(const APIRequirement *list, size_t count) {
  NSMutableArray *missing = [NSMutableArray array];
  for (size_t i = 0; i < count; i++) {
    Class cls = objc_getClass(list[i].cls);
    if (!cls) {
      [missing addObject:@(list[i].cls)];
      continue;
    }
    if (!list[i].sel) continue;
    SEL sel = sel_registerName(list[i].sel);
    BOOL ok = list[i].classMethod ? [cls respondsToSelector:sel]
                                  : [cls instancesRespondToSelector:sel];
    if (!ok)
      [missing addObject:[NSString stringWithFormat:@"%s[%s %s]", list[i].classMethod ? "+" : "-",
                                                     list[i].cls, list[i].sel]];
  }
  return missing;
}

static NSArray<NSString *> *MissingModelPropertiesIn(const ModelRequirement *list, size_t count) {
  Class container = objc_getClass("ICPersistentContainer");
  SEL modelSel = sel_registerName("managedObjectModel");
  if (!container || ![container respondsToSelector:modelSel]) return @[ @"managed object model" ];
  NSManagedObjectModel *model = ((id(*)(id, SEL))objc_msgSend)(container, modelSel);
  if (![model isKindOfClass:[NSManagedObjectModel class]]) return @[ @"managed object model" ];
  NSMutableArray *missing = [NSMutableArray array];
  for (size_t i = 0; i < count; i++) {
    NSEntityDescription *entity = model.entitiesByName[@(list[i].entity)];
    if (!entity) {
      [missing addObject:[NSString stringWithFormat:@"entity %s", list[i].entity]];
      continue;
    }
    for (NSString *name in [@(list[i].properties) componentsSeparatedByString:@","])
      if (!entity.propertiesByName[name])
        [missing addObject:[NSString stringWithFormat:@"%s.%@", list[i].entity, name]];
  }
  return missing;
}

static NSArray<NSString *> *MissingModelProperties(void) {
  return MissingModelPropertiesIn(kModelProperties, COUNT(kModelProperties));
}

// Every feature past FeatureRead needs the read surface plus its own.
typedef NS_ENUM(NSInteger, Feature) {
  FeatureModel,
  FeatureRead,
  FeatureAppend,
  FeatureTables,
  FeaturePruneTable,
};

static NSArray<NSString *> *MissingForFeature(Feature feature) {
  LoadFramework();
  if (!gFrameworkLoaded) return @[ @"NotesShared.framework" ];
  NSMutableArray *missing = [NSMutableArray array];
  [missing addObjectsFromArray:MissingAPI(kModelAPI, COUNT(kModelAPI))];
  if (missing.count) return missing;
  if (feature >= FeatureRead) {
    [missing addObjectsFromArray:MissingModelProperties()];
    [missing addObjectsFromArray:MissingAPI(kReadAPI, COUNT(kReadAPI))];
  }
  if (feature == FeatureAppend)
    [missing addObjectsFromArray:MissingAPI(kAppendAPI, COUNT(kAppendAPI))];
  if (feature == FeatureTables || feature == FeaturePruneTable) {
    [missing addObjectsFromArray:MissingModelPropertiesIn(kTableModelProperties,
                                                          COUNT(kTableModelProperties))];
    [missing addObjectsFromArray:MissingAPI(kTableAPI, COUNT(kTableAPI))];
  }
  if (feature == FeaturePruneTable)
    [missing addObjectsFromArray:MissingAPI(kPruneAPI, COUNT(kPruneAPI))];
  return missing;
}

static void RequireFeature(Feature feature) {
  NSArray *missing = MissingForFeature(feature);
  if (missing.count)
    Fail(@"private_api_unavailable",
         @"Required NotesShared classes or selectors are not available on this macOS",
         @{@"missing" : missing});
}

// Typed wrappers around objc_msgSend. Selectors are compile-time constants.
static id Send(id target, const char *sel) {
  return ((id(*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}
static BOOL SendBool(id target, const char *sel) {
  return ((BOOL(*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}
// Void methods must not go through Send(): ARC would retain whatever garbage
// sits in the return register.
static void SendVoid(id target, const char *sel) {
  ((void (*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}
static NSUInteger SendUInt(id target, const char *sel) {
  return ((NSUInteger(*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}

#pragma mark - Store

typedef struct {
  NSString *path;
  BOOL isCopy;
} StoreLocation;

static NSString *LiveStorePath(void) {
  return [NSHomeDirectory()
      stringByAppendingPathComponent:
          @"Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"];
}

static BOOL SameFile(NSString *a, NSString *b) {
  struct stat sa, sb;
  if (stat(a.fileSystemRepresentation, &sa) != 0) return NO;
  if (stat(b.fileSystemRepresentation, &sb) != 0) return NO;
  return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

// The copy-store override exists for tests. It must never resolve to the
// live database, including through a symlink or hard link.
static StoreLocation ResolveStore(void) {
  NSString *override = NSProcessInfo.processInfo.environment[kCopyStoreEnv];
  NSString *live = LiveStorePath();
  if (override.length) {
    NSString *resolved = [override stringByResolvingSymlinksInPath];
    NSString *liveResolved = [live stringByResolvingSymlinksInPath];
    NSString *liveDir = [liveResolved stringByDeletingLastPathComponent];
    if ([resolved isEqualToString:liveResolved] || SameFile(resolved, live) ||
        [resolved hasPrefix:[liveDir stringByAppendingString:@"/"]])
      Fail(@"invalid_request", @"APPLE_NOTES_MCP_PRIVATE_STORE must point at a copy, not the live store",
           nil);
    if (![NSFileManager.defaultManager fileExistsAtPath:resolved])
      Fail(@"store_unavailable", @"APPLE_NOTES_MCP_PRIVATE_STORE does not exist", nil);
    return (StoreLocation){resolved, YES};
  }
  return (StoreLocation){live, NO};
}

// Opens NotesShared's model over the store with Notes' own store options
// (persistent history tracking + remote change notifications), which is what
// lets a running Notes.app merge the helper's saves. Reads add
// NSReadOnlyPersistentStoreOption so a read can never write.
static NSManagedObjectContext *OpenContext(StoreLocation store, BOOL readOnly) {
  RequireFeature(FeatureModel);
  if (!store.isCopy && ![NSProcessInfo.processInfo.environment[kEnableEnv] isEqualToString:@"1"])
    Fail(@"disabled", @"The private helper is disabled; set APPLE_NOTES_MCP_ENABLE_PRIVATE=1 to opt in",
         nil);
  // Second, independent switch for read-write opens of the live store. The
  // client checks it too; this keeps the binary safe when run by hand.
  if (!readOnly && !store.isCopy &&
      ![NSProcessInfo.processInfo.environment[kWritesEnv] isEqualToString:@"1"])
    Fail(@"writes_disabled",
         @"Private writes are disabled; set APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1 to opt in",
         @{@"committed" : @NO});
  if (![NSFileManager.defaultManager isReadableFileAtPath:store.path])
    Fail(@"store_unavailable",
         @"NoteStore.sqlite is not readable. Grant Full Disk Access to the app that launches the MCP "
         @"server, then relaunch it.",
         nil);
  Class container = objc_getClass("ICPersistentContainer");
  NSManagedObjectModel *model = Send(container, "managedObjectModel");
  NSDictionary *standard = Send(container, "standardStoreOptions");
  if (![model isKindOfClass:[NSManagedObjectModel class]] ||
      ![standard isKindOfClass:[NSDictionary class]])
    Fail(@"private_api_unavailable", @"NotesShared did not return a model and store options", nil);
  NSMutableDictionary *options = [standard mutableCopy];
  // Never migrate: a model/store mismatch means this helper is out of date.
  options[NSMigratePersistentStoresAutomaticallyOption] = @NO;
  options[NSInferMappingModelAutomaticallyOption] = @NO;
  if (readOnly) options[NSReadOnlyPersistentStoreOption] = @YES;
  NSPersistentStoreCoordinator *coordinator =
      [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  NSPersistentStore *persistent =
      [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                configuration:nil
                                          URL:[NSURL fileURLWithPath:store.path]
                                      options:options
                                        error:&error];
  if (!persistent)
    Fail(@"store_unavailable", @"Could not open the Notes store with the NotesShared model",
         @{@"detail" : error.localizedDescription ?: @"unknown"});
  NSManagedObjectContext *context =
      [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  context.transactionAuthor = kTransactionAuthor;
  // Optimistic locking: if Notes.app saves the same row between our fetch and
  // our save, the save fails instead of silently overwriting.
  context.mergePolicy = NSErrorMergePolicy;
  context.undoManager = nil;
  return context;
}

#pragma mark - Note lookup and state

static NSRegularExpression *UUIDPattern(void) {
  static NSRegularExpression *re;
  if (!re)
    re = [NSRegularExpression
        regularExpressionWithPattern:@"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
                                     @"[0-9A-Fa-f]{12}$"
                             options:0
                               error:nil];
  return re;
}

static BOOL IsUUID(id value) {
  return [value isKindOfClass:[NSString class]] &&
         [UUIDPattern() numberOfMatchesInString:value options:0 range:NSMakeRange(0, [value length])] ==
             1;
}

static NSManagedObject *FetchNote(NSManagedObjectContext *context, NSString *identifier) {
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
  request.predicate = [NSPredicate predicateWithFormat:@"identifier ==[c] %@", identifier];
  request.fetchLimit = 2;
  request.returnsObjectsAsFaults = NO;
  NSError *error = nil;
  NSArray *rows = [context executeFetchRequest:request error:&error];
  if (!rows) Fail(@"store_unavailable", @"Note fetch failed", @{@"detail" : OrNull(error.localizedDescription)});
  if (rows.count == 0) Fail(@"not_found", @"No note has that identifier", nil);
  if (rows.count > 1) Fail(@"unsupported_note", @"More than one note row has that identifier", nil);
  return rows.firstObject;
}

static NSData *NoteBodyData(NSManagedObject *note) {
  id noteData = Send(note, "noteData");
  if (!noteData) return nil;
  id data = [noteData valueForKey:@"data"];
  return [data isKindOfClass:[NSData class]] ? data : nil;
}

// Opaque compare-and-swap token over the persisted native state an append
// depends on: identity, folder, deletion/lock flags, modification date, and
// a digest of the serialized CRDT body. Any persisted edit (text, style,
// attachment glyph) changes the body digest.
static NSString *RevisionToken(NSManagedObject *note) {
  id folder = [note valueForKey:@"folder"];
  NSData *body = NoteBodyData(note);
  NSDate *modified = [note valueForKey:@"modificationDate"];
  NSString *canonical = [NSString
      stringWithFormat:@"r1\x1f%@\x1f%@\x1f%d\x1f%d\x1f%.6f\x1f%@",
                       [note valueForKey:@"identifier"] ?: @"",
                       folder ? ([folder valueForKey:@"identifier"] ?: @"") : @"",
                       [[note valueForKey:@"markedForDeletion"] boolValue],
                       SendBool(note, "isPasswordProtected"),
                       modified ? modified.timeIntervalSinceReferenceDate : 0.0,
                       body ? SHA256Hex(body) : @"none"];
  return [@"r1:" stringByAppendingString:SHA256Hex([canonical dataUsingEncoding:NSUTF8StringEncoding])];
}

// The note's visible text. On macOS 27 the mergeable string is an
// ICTTMergeableAttributedString whose `-string` returns an attributed string,
// so the plain text comes from `-attributedString`.
static NSString *BodyText(id mergeableString) {
  if (!mergeableString) return nil;
  id attributed = Send(mergeableString, "attributedString");
  return [attributed isKindOfClass:[NSAttributedString class]] ? [attributed string] : nil;
}

static BOOL NotesAppRunning(void) {
  return [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Notes"].count > 0;
}

static NSDictionary *CloudSyncState(NSManagedObject *note) {
  id cloud = Send(note, "cloudState");
  BOOL inICloud = [note respondsToSelector:sel_registerName("isInICloudAccount")]
                      ? SendBool(note, "isInICloudAccount")
                      : NO;
  if (!cloud) return @{@"inICloudAccount" : @(inICloud), @"available" : @NO};
  long long current = [[cloud valueForKey:@"currentLocalVersion"] longLongValue];
  long long synced = [[cloud valueForKey:@"latestVersionSyncedToCloud"] longLongValue];
  return @{
    @"available" : @YES,
    @"inICloudAccount" : @(inICloud),
    @"currentLocalVersion" : @(current),
    @"latestVersionSyncedToCloud" : @(synced),
    // Notes' own upload eligibility test: a local version newer than the
    // last version it recorded as synced.
    @"uploadPending" : @((BOOL)(current > synced)),
  };
}

static NSDictionary *NoteState(NSManagedObject *note) {
  id folder = [note valueForKey:@"folder"];
  id account = [note valueForKey:@"account"];
  BOOL locked = SendBool(note, "isPasswordProtected");
  NSMutableDictionary *state = [@{
    @"identifier" : OrNull([note valueForKey:@"identifier"]),
    @"objectURI" : note.objectID.URIRepresentation.absoluteString,
    @"title" : OrNull([note valueForKey:@"title"]),
    @"modificationDate" : OrNull(ISODate([note valueForKey:@"modificationDate"])),
    @"creationDate" : OrNull(ISODate([note valueForKey:@"creationDate"])),
    @"folderIdentifier" : OrNull(folder ? [folder valueForKey:@"identifier"] : nil),
    @"accountIdentifier" : OrNull(account ? [account valueForKey:@"identifier"] : nil),
    @"passwordProtected" : @(locked),
    @"deletedOrInTrash" : @(SendBool(note, "isDeletedOrInTrash")),
    @"sharedViaICloud" : @(SendBool(note, "isSharedViaICloud")),
    @"editable" : @(SendBool(note, "isEditable")),
    @"bodyAvailable" : @((BOOL)(NoteBodyData(note) != nil)),
    @"revision" : RevisionToken(note),
    @"cloudSync" : CloudSyncState(note),
  } mutableCopy];
  if (!locked) {
    id ms = Send(note, "mergeableString");
    NSString *text = BodyText(ms);
    if ([text isKindOfClass:[NSString class]]) state[@"bodyLengthUTF16"] = @(text.length);
  }
  return state;
}

#pragma mark - Request validation

static NSString *RequireString(NSDictionary *request, NSString *key) {
  id value = request[key];
  if (![value isKindOfClass:[NSString class]] || [value length] == 0)
    Fail(@"invalid_request", [NSString stringWithFormat:@"`%@` must be a non-empty string", key], nil);
  return value;
}

static NSString *RequireIdentifier(NSDictionary *request) {
  NSString *identifier = RequireString(request, @"identifier");
  if (!IsUUID(identifier)) Fail(@"invalid_request", @"`identifier` must be a Notes UUID", nil);
  return identifier;
}

#pragma mark - Actions

static NSDictionary *HandleHello(NSDictionary *request);
static NSDictionary *HandleProbe(NSDictionary *request);
static NSDictionary *HandleReadNoteState(NSDictionary *request);
static NSDictionary *HandleAppendPlainText(NSDictionary *request);
static NSDictionary *HandleReadSyncState(NSDictionary *request);
static NSDictionary *HandleReadTables(NSDictionary *request);
static NSDictionary *HandleDeleteTableRow(NSDictionary *request);
static NSDictionary *HandleInsertTableRow(NSDictionary *request);
static NSDictionary *HandleSetTableCell(NSDictionary *request);
static NSDictionary *HandlePruneOrphanTable(NSDictionary *request);

typedef struct {
  const char *name;
  const char *allowedKeys;  // comma-separated, beyond `protocol` and `action`
  NSDictionary *(*handler)(NSDictionary *);
} ActionSpec;

// The whitelist. Order is the order `hello` reports.
static const ActionSpec kActions[] = {
    {"hello", "", HandleHello},
    {"probe", "", HandleProbe},
    {"read_note_state", "identifier", HandleReadNoteState},
    {"append_plain_text", "identifier,text,ifRevision", HandleAppendPlainText},
    {"read_sync_state", "identifiers", HandleReadSyncState},
    {"read_tables", "identifier", HandleReadTables},
    {"delete_table_row", "identifier,tableIdentifier,rowIdentifier,dryRun,ifRevision,ifTableDigest",
     HandleDeleteTableRow},
    {"insert_table_row", "identifier,tableIdentifier,afterRowIdentifier,cells,ifRevision,ifTableDigest",
     HandleInsertTableRow},
    {"set_table_cell",
     "identifier,tableIdentifier,rowIdentifier,columnIdentifier,text,ifRevision,ifTableDigest",
     HandleSetTableCell},
    {"prune_orphan_table", "identifier,tableIdentifier,dryRun,ifRevision,ifTableDigest",
     HandlePruneOrphanTable},
};

static NSArray<NSString *> *ActionNames(void) {
  NSMutableArray *names = [NSMutableArray array];
  for (size_t i = 0; i < COUNT(kActions); i++) [names addObject:@(kActions[i].name)];
  return names;
}

static NSDictionary *HandleHello(NSDictionary *request) {
  (void)request;
  return @{
    @"status" : @"ok",
    @"protocolVersion" : @(PROTOCOL_VERSION),
    @"sourceSha256" : @HELPER_SOURCE_SHA256,
    @"role" : @"writer",
    @"readOnly" : @NO,
    @"actions" : ActionNames(),
  };
}

static NSDictionary *FeatureReport(Feature feature, BOOL contextOK, NSString *contextReason) {
  NSArray *missing = MissingForFeature(feature);
  if (missing.count)
    return @{@"available" : @NO, @"reason" : @"private_api_unavailable", @"missing" : missing};
  if (!contextOK)
    return @{@"available" : @NO, @"reason" : contextReason ?: @"store_unavailable", @"missing" : @[]};
  return @{@"available" : @YES, @"reason" : [NSNull null], @"missing" : @[]};
}

static NSDictionary *HandleProbe(NSDictionary *request) {
  (void)request;
  LoadFramework();
  NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
  NSString *osVersion = [NSString
      stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
  NSString *notesVersion = [NSBundle bundleWithPath:@"/System/Applications/Notes.app"]
                               .infoDictionary[@"CFBundleShortVersionString"];

  BOOL contextOK = NO;
  NSString *contextReason = nil;
  NSString *contextDetail = nil;
  NSNumber *noteCount = nil;
  StoreLocation store = {nil, NO};
  @try {
    store = ResolveStore();
    NSManagedObjectContext *context = OpenContext(store, YES);
    NSFetchRequest *count = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    NSError *error = nil;
    NSUInteger n = [context countForFetchRequest:count error:&error];
    if (n == NSNotFound) {
      contextReason = @"store_unavailable";
      contextDetail = error.localizedDescription;
    } else {
      contextOK = YES;
      noteCount = @(n);
    }
  } @catch (HelperError *e) {
    contextReason = e.userInfo[@"code"];
    contextDetail = e.reason;
  }

  return @{
    @"status" : @"ok",
    @"protocolVersion" : @(PROTOCOL_VERSION),
    @"sourceSha256" : @HELPER_SOURCE_SHA256,
    @"role" : @"writer",
    @"readOnly" : @NO,
    @"writesEnabled" : @([NSProcessInfo.processInfo.environment[kWritesEnv] isEqualToString:@"1"]),
    @"os" : @{@"version" : osVersion, @"notesAppVersion" : OrNull(notesVersion)},
    @"framework" : @{@"loaded" : @(gFrameworkLoaded), @"error" : OrNull(gFrameworkError)},
    @"store" : @{
      @"kind" : store.path ? (store.isCopy ? @"copy" : @"live") : [NSNull null],
      @"opened" : @(contextOK),
      @"reason" : OrNull(contextReason),
      @"detail" : OrNull(contextDetail),
      @"noteRows" : OrNull(noteCount),
    },
    @"syncHostRunning" : @(NotesAppRunning()),
    @"features" : @{
      @"readNoteState" : FeatureReport(FeatureRead, contextOK, contextReason),
      @"appendPlainText" : FeatureReport(FeatureAppend, contextOK, contextReason),
      @"tables" : FeatureReport(FeatureTables, contextOK, contextReason),
      @"pruneOrphanTable" : FeatureReport(FeaturePruneTable, contextOK, contextReason),
    },
  };
}

static NSDictionary *HandleReadNoteState(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  RequireFeature(FeatureRead);
  NSManagedObjectContext *context = OpenContext(ResolveStore(), YES);
  NSManagedObject *note = FetchNote(context, identifier);
  NSMutableDictionary *result = [NoteState(note) mutableCopy];
  result[@"status"] = @"ok";
  result[@"syncHostRunning"] = @(NotesAppRunning());
  return result;
}

// Refuses every note shape this first write path does not model.
static void RequireAppendableNote(NSManagedObject *note) {
  if (SendBool(note, "isPasswordProtected"))
    Fail(@"unsupported_note", @"Locked notes are not supported", nil);
  if (SendBool(note, "isDeletedOrInTrash") || [[note valueForKey:@"markedForDeletion"] boolValue])
    Fail(@"unsupported_note", @"Deleted or trashed notes are not supported", nil);
  if (![note valueForKey:@"folder"]) Fail(@"unsupported_note", @"Folderless notes are not supported", nil);
  if (SendBool(note, "isSharedViaICloud"))
    Fail(@"unsupported_note", @"Collaborative (shared) notes are not supported", nil);
  if (!SendBool(note, "isEditable")) Fail(@"unsupported_note", @"Notes reports this note as not editable", nil);
  if ([[note valueForKey:@"needsInitialFetchFromCloud"] boolValue] || !NoteBodyData(note))
    Fail(@"unsupported_note", @"The note body has not finished downloading from iCloud", nil);
}

static void ValidateAppendText(NSString *text) {
  if (text.length > MAX_APPEND_UTF16)
    Fail(@"invalid_request", @"`text` exceeds 50000 UTF-16 code units", nil);
  NSMutableCharacterSet *forbidden = [NSMutableCharacterSet controlCharacterSet];
  [forbidden removeCharactersInString:@"\n\t"];
  [forbidden addCharactersInString:@"\uFFFC\u2028\u2029"];
  if ([text rangeOfCharacterFromSet:forbidden].location != NSNotFound)
    Fail(@"invalid_request",
         @"`text` may contain only printable characters, tabs and \\n newlines (no \\r, "
         @"attachment glyphs, or other control characters)",
         nil);
}

// The paragraph style of a Notes paragraph rides on its terminating newline.
// When the body does not already end in a newline, the separator we insert
// becomes the terminator of the old last paragraph, so it carries that
// paragraph's style value (found by class, not by key name). The appended
// text itself carries no attributes and becomes plain body paragraphs.
static NSAttributedString *SeparatorFor(NSAttributedString *existing) {
  if (existing.length == 0) return nil;
  if ([existing.string hasSuffix:@"\n"]) return nil;
  NSDictionary *attrs = [existing attributesAtIndex:existing.length - 1 effectiveRange:NULL];
  NSMutableDictionary *kept = [NSMutableDictionary dictionary];
  for (NSString *key in attrs) {
    NSString *className = NSStringFromClass([attrs[key] class]);
    if ([className containsString:@"ParagraphStyle"]) kept[key] = attrs[key];
  }
  return [[NSAttributedString alloc] initWithString:@"\n" attributes:kept];
}

static NSDictionary *HandleAppendPlainText(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  NSString *text = RequireString(request, @"text");
  NSString *ifRevision = RequireString(request, @"ifRevision");
  ValidateAppendText(text);
  RequireFeature(FeatureAppend);

  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, NO);
  NSManagedObject *note = FetchNote(context, identifier);
  RequireAppendableNote(note);

  NSString *revisionBefore = RevisionToken(note);
  if (![revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : revisionBefore});

  id ms = Send(note, "mergeableString");
  NSAttributedString *existing = ms ? Send(ms, "attributedString") : nil;
  if (![existing isKindOfClass:[NSAttributedString class]])
    Fail(@"unsupported_note", @"The note body could not be loaded as a mergeable string", nil);
  NSString *before = [existing.string copy];
  NSAttributedString *separator = SeparatorFor(existing);
  NSMutableAttributedString *insertion = [NSMutableAttributedString new];
  if (separator) [insertion appendAttributedString:separator];
  [insertion appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
  NSUInteger at = existing.length;

  // Edit through the CRDT so the change merges with other devices' edits.
  SendVoid(ms, "beginEditing");
  ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
      ms, sel_registerName("insertAttributedString:atIndex:"), insertion, at);
  SendVoid(ms, "endEditing");
  ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
      note, sel_registerName("edited:range:changeInLength:"), NSTextStorageEditedCharacters,
      NSMakeRange(at, insertion.length), (NSInteger)insertion.length);
  ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(note, sel_registerName("regenerateTitle:snippet:"), YES,
                                                YES);
  if (!SendBool(note, "saveNoteData"))
    Fail(@"save_failed", @"NotesShared did not serialize the edited body", @{@"committed" : @NO});
  [note setValue:[NSDate date] forKey:@"modificationDate"];
  // Bumps the cloud state's local version so Notes treats the note as
  // needing upload.
  ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("updateChangeCountWithReason:"),
                                        kChangeReason);

  NSError *saveError = nil;
  if (![context save:&saveError]) {
    [context rollback];
    BOOL conflict = saveError.code == NSManagedObjectMergeError ||
                    saveError.code == NSPersistentStoreSaveConflictsError;
    Fail(conflict ? @"revision_conflict" : @"save_failed",
         conflict ? @"Notes changed the note during the write; nothing was saved"
                  : @"The Core Data save failed; nothing was saved",
         @{@"committed" : @NO, @"detail" : OrNull(saveError.localizedDescription)});
  }

  // Fresh read-back through a brand-new coordinator so no in-memory state
  // from the write can satisfy the check.
  NSString *expected = [before stringByAppendingString:[insertion string]];
  NSDictionary *after = nil;
  BOOL verified = NO;
  NSString *verifyDetail = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *reread = FetchNote(fresh, identifier);
    id freshString = Send(reread, "mergeableString");
    NSString *persisted = BodyText(freshString);
    verified = [persisted isEqualToString:expected];
    if (!verified) verifyDetail = @"The persisted body does not equal the previous body plus the appended text";
    after = NoteState(reread);
  } @catch (HelperError *e) {
    verifyDetail = e.reason;
  }
  if (!verified)
    Fail(@"verification_failed", verifyDetail ?: @"Read-back failed",
         @{@"committed" : @YES, @"revisionBefore" : revisionBefore});

  BOOL hostRunning = NotesAppRunning();
  return @{
    @"status" : @"updated",
    @"committed" : @YES,
    @"verified" : @YES,
    @"identifier" : identifier,
    @"appendedUTF16" : @(insertion.length),
    @"separatorInserted" : @((BOOL)(separator != nil)),
    @"revisionBefore" : revisionBefore,
    @"revisionAfter" : after[@"revision"],
    @"modificationDate" : after[@"modificationDate"],
    @"title" : after[@"title"],
    @"cloudSync" : after[@"cloudSync"],
    // The helper never uploads: CloudKit access needs Notes.app's private
    // entitlements. It only records upload eligibility. See TECHNICAL_NOTES.
    @"pushScheduled" : @NO,
    @"syncHostRunning" : @(hostRunning),
    @"pushState" : hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch",
    @"storeKind" : store.isCopy ? @"copy" : @"live",
  };
}

#pragma mark - Sync state

#define MAX_SYNC_IDENTIFIERS 50

// Read-only upload bookkeeping for notes and folders. The helper saves
// through its own Core Data stack and only Notes.app can upload, so after a
// write the server reads these counters (and can nudge Notes.app, see
// src/services/privateSyncNudge.ts). Reports Notes' own counters; it never
// infers an upload the counters do not record.
static NSDictionary *SyncStateFor(NSManagedObjectContext *context, NSString *identifier) {
  for (NSString *entity in @[ @"ICNote", @"ICFolder" ]) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity];
    request.predicate = [NSPredicate predicateWithFormat:@"identifier ==[c] %@", identifier];
    request.fetchLimit = 2;
    NSError *error = nil;
    NSArray *rows = [context executeFetchRequest:request error:&error];
    if (!rows)
      Fail(@"store_unavailable", @"Sync state fetch failed",
           @{@"detail" : OrNull(error.localizedDescription)});
    if (rows.count > 1) return @{@"identifier" : identifier, @"found" : @NO, @"reason" : @"ambiguous"};
    if (rows.count == 0) continue;
    NSManagedObject *object = rows.firstObject;
    BOOL isNote = [entity isEqualToString:@"ICNote"];
    id folder = isNote ? [object valueForKey:@"folder"] : nil;
    id cloud = [object valueForKey:@"cloudState"];
    NSMutableDictionary *state = [@{
      @"identifier" : identifier,
      @"found" : @YES,
      @"kind" : isNote ? @"note" : @"folder",
      @"objectURI" : object.objectID.URIRepresentation.absoluteString,
      @"markedForDeletion" : @([[object valueForKey:@"markedForDeletion"] boolValue]),
      @"inICloudAccount" : @((BOOL)([object respondsToSelector:sel_registerName("isInICloudAccount")] &&
                                    SendBool(object, "isInICloudAccount"))),
      @"cloudStateAvailable" : @((BOOL)(cloud != nil)),
    } mutableCopy];
    if (cloud) {
      long long current = [[cloud valueForKey:@"currentLocalVersion"] longLongValue];
      long long synced = [[cloud valueForKey:@"latestVersionSyncedToCloud"] longLongValue];
      state[@"currentLocalVersion"] = @(current);
      state[@"latestVersionSyncedToCloud"] = @(synced);
      state[@"uploadPending"] = @((BOOL)(current > synced));
    }
    if (isNote) {
      state[@"folderIdentifier"] = OrNull(folder ? [folder valueForKey:@"identifier"] : nil);
      state[@"folderObjectURI"] =
          OrNull(folder ? [folder objectID].URIRepresentation.absoluteString : nil);
      state[@"passwordProtected"] = @(SendBool(object, "isPasswordProtected"));
      state[@"deletedOrInTrash"] = @(SendBool(object, "isDeletedOrInTrash"));
      state[@"sharedViaICloud"] = @(SendBool(object, "isSharedViaICloud"));
      state[@"revision"] = RevisionToken(object);
    }
    return state;
  }
  return @{@"identifier" : identifier, @"found" : @NO, @"reason" : @"not_found"};
}

static NSDictionary *HandleReadSyncState(NSDictionary *request) {
  id identifiers = request[@"identifiers"];
  if (![identifiers isKindOfClass:[NSArray class]] || [identifiers count] == 0 ||
      [identifiers count] > MAX_SYNC_IDENTIFIERS)
    Fail(@"invalid_request", @"`identifiers` must be an array of 1-50 note or folder identifiers", nil);
  for (id identifier in identifiers)
    if (!IsUUID(identifier)) Fail(@"invalid_request", @"Every identifier must be a Notes UUID", nil);
  RequireFeature(FeatureRead);
  NSManagedObjectContext *context = OpenContext(ResolveStore(), YES);
  NSMutableArray *objects = [NSMutableArray array];
  for (NSString *identifier in identifiers) [objects addObject:SyncStateFor(context, identifier)];
  // Library-wide backlog with Notes' own upload-eligibility test.
  NSFetchRequest *pending = [NSFetchRequest fetchRequestWithEntityName:@"ICCloudState"];
  pending.predicate =
      [NSPredicate predicateWithFormat:@"currentLocalVersion > latestVersionSyncedToCloud"];
  NSError *error = nil;
  NSUInteger backlog = [context countForFetchRequest:pending error:&error];
  return @{
    @"status" : @"ok",
    @"objects" : objects,
    @"pendingUploadCount" : backlog == NSNotFound ? [NSNull null] : @(backlog),
    @"syncHostRunning" : @(NotesAppRunning()),
  };
}

#pragma mark - Tables

// Notes tables are attachments (UTI com.apple.notes.table) whose content is a
// CRDT document in ICAttachment.mergeableData. The body holds one U+FFFC glyph
// per visible table, carrying an ICTTAttachment that names the attachment.
// Rows and columns have stable native identifiers, so every row and cell
// action selects by identifier, never by position alone.
//
// Table writes carry two compare-and-swap tokens: `ifRevision` (the note's
// r1: revision, which covers the body) and `ifTableDigest` (a t1: digest of
// the table attachment's serialized CRDT document). Row deletion and orphan
// pruning are two-phase: a dry run opens the store read-only and returns the
// plan with both tokens; the apply must present them unchanged.

static NSString *const kTableUTI = @"com.apple.notes.table";
#define MAX_TABLE_DIMENSION 1000
#define MAX_TABLE_CELLS 10000
#define MAX_CELL_UTF16 10000

static void RegisterTableCoder(void) {
  // A headless process must register ICTable with the CRDT coder before it
  // opens a table document; Notes.app does this during its own launch.
  static BOOL registered = NO;
  if (registered) return;
  registered = YES;
  SendVoid(objc_getClass("ICTable"), "registerWithICCRCoder");
}

// Row and column identities are CRDT objects; their UUID is the stable,
// serializable part.
static NSString *IdentityText(id value) {
  if ([value isKindOfClass:[NSString class]] && [value length]) return [value uppercaseString];
  if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
  return nil;
}

// Always an immutable copy: `-[NSAttributedString string]` on a mutable
// backing store is a live view, and a snapshot must not change when the table
// is edited afterwards.
static NSString *TextOf(id value) {
  if ([value isKindOfClass:[NSAttributedString class]]) return [[value string] copy];
  if ([value isKindOfClass:[NSString class]]) return [value copy];
  if (value && [value respondsToSelector:sel_registerName("attributedString")]) {
    id attributed = Send(value, "attributedString");
    if ([attributed isKindOfClass:[NSAttributedString class]]) return [[attributed string] copy];
  }
  return @"";
}

static NSAttributedString *BodyAttributedString(NSManagedObject *note) {
  id ms = Send(note, "mergeableString");
  id attributed = ms ? Send(ms, "attributedString") : nil;
  return [attributed isKindOfClass:[NSAttributedString class]] ? attributed : nil;
}

// Number of U+FFFC glyphs in the body that name this attachment.
static NSUInteger GlyphCountFor(NSAttributedString *body, NSString *attachmentIdentifier) {
  __block NSUInteger count = 0;
  if (!body.length) return 0;
  SEL identifierSel = sel_registerName("attachmentIdentifier");
  [body enumerateAttribute:@"NSAttachment"
                   inRange:NSMakeRange(0, body.length)
                   options:0
                usingBlock:^(id value, NSRange range, BOOL *stop) {
                  (void)stop;
                  if (!value || ![value respondsToSelector:identifierSel]) return;
                  id named = Send(value, "attachmentIdentifier");
                  if (![named isKindOfClass:[NSString class]] ||
                      [named caseInsensitiveCompare:attachmentIdentifier] != NSOrderedSame)
                    return;
                  NSString *slice = [body.string substringWithRange:range];
                  for (NSUInteger i = 0; i < slice.length; i++)
                    if ([slice characterAtIndex:i] == 0xFFFC) count++;
                }];
  return count;
}

static BOOL IsActiveTopLevelTable(NSManagedObject *attachment) {
  return [[attachment valueForKey:@"typeUTI"] isEqual:kTableUTI] &&
         ![attachment valueForKey:@"parentAttachment"] &&
         ![[attachment valueForKey:@"markedForDeletion"] boolValue];
}

static NSArray<NSManagedObject *> *ActiveTables(NSManagedObject *note) {
  NSMutableArray *tables = [NSMutableArray array];
  for (NSManagedObject *attachment in [note valueForKey:@"attachments"])
    if (IsActiveTopLevelTable(attachment)) [tables addObject:attachment];
  [tables sortUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a valueForKey:@"identifier"] compare:[b valueForKey:@"identifier"]];
  }];
  return tables;
}

// Compare-and-swap token over one table attachment: identity, deletion state,
// and the exact serialized CRDT document. Any persisted cell, row, or column
// change alters it. The note revision separately covers the body.
static NSString *TableDigest(NSManagedObject *attachment) {
  NSData *data = [attachment valueForKey:@"mergeableData"];
  NSString *canonical =
      [NSString stringWithFormat:@"t1\x1f%@\x1f%d\x1f%@", [attachment valueForKey:@"identifier"] ?: @"",
                                 [[attachment valueForKey:@"markedForDeletion"] boolValue],
                                 [data isKindOfClass:[NSData class]] ? SHA256Hex(data) : @"none"];
  return [@"t1:" stringByAppendingString:SHA256Hex([canonical dataUsingEncoding:NSUTF8StringEncoding])];
}

static id TableOf(NSManagedObject *attachment, id *modelOut) {
  RegisterTableCoder();
  id model = Send(attachment, "tableModel");
  id table = model ? Send(model, "table") : nil;
  if (modelOut) *modelOut = model;
  return table;
}

static id RowIdentityAt(id table, NSUInteger index) {
  return ((id(*)(id, SEL, NSUInteger))objc_msgSend)(table, sel_registerName("identifierForRowAtIndex:"),
                                                     index);
}
static id ColumnIdentityAt(id table, NSUInteger index) {
  return ((id(*)(id, SEL, NSUInteger))objc_msgSend)(
      table, sel_registerName("identifierForColumnAtIndex:"), index);
}
static NSString *CellText(id table, NSUInteger column, NSUInteger row) {
  return TextOf(((id(*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(
      table, sel_registerName("stringForColumnIndex:rowIndex:"), column, row));
}

// The semantic table: column identifiers and, per row, its identifier and the
// plain text of each cell. Returns nil with *reason set when the table is too
// large or its identities are missing or duplicated.
static NSDictionary *TableSnapshot(id table, NSString **reason) {
  if (!table) {
    if (reason) *reason = @"The table document could not be loaded";
    return nil;
  }
  NSUInteger rows = SendUInt(table, "rowCount");
  NSUInteger columns = SendUInt(table, "columnCount");
  if (rows > MAX_TABLE_DIMENSION || columns > MAX_TABLE_DIMENSION ||
      (columns && rows > MAX_TABLE_CELLS / columns)) {
    if (reason) *reason = @"The table exceeds 1000 rows or columns or 10000 cells";
    return nil;
  }
  NSMutableArray *columnIds = [NSMutableArray array];
  for (NSUInteger c = 0; c < columns; c++) {
    NSString *identity = IdentityText(ColumnIdentityAt(table, c));
    if (!identity || [columnIds containsObject:identity]) {
      if (reason) *reason = @"A table column has no unique native identifier";
      return nil;
    }
    [columnIds addObject:identity];
  }
  NSMutableArray *rowList = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (NSUInteger r = 0; r < rows; r++) {
    NSString *identity = IdentityText(RowIdentityAt(table, r));
    if (!identity || [seen containsObject:identity]) {
      if (reason) *reason = @"A table row has no unique native identifier";
      return nil;
    }
    [seen addObject:identity];
    NSMutableArray *cells = [NSMutableArray array];
    for (NSUInteger c = 0; c < columns; c++) [cells addObject:CellText(table, c, r)];
    [rowList addObject:@{@"identifier" : identity, @"cells" : cells}];
  }
  return @{@"columnIdentifiers" : columnIds, @"rows" : rowList};
}

static NSUInteger IndexOfRow(NSDictionary *snapshot, NSString *rowIdentifier) {
  NSArray *rows = snapshot[@"rows"];
  for (NSUInteger i = 0; i < rows.count; i++)
    if ([rows[i][@"identifier"] caseInsensitiveCompare:rowIdentifier] == NSOrderedSame) return i;
  return NSNotFound;
}

static NSDictionary *TableSummary(NSManagedObject *attachment, NSAttributedString *body) {
  NSString *identifier = [attachment valueForKey:@"identifier"];
  NSUInteger glyphs = GlyphCountFor(body, identifier);
  NSMutableDictionary *summary = [@{
    @"identifier" : identifier ?: @"",
    @"glyphCount" : @(glyphs),
    @"orphan" : @((BOOL)(glyphs == 0)),
    @"digest" : TableDigest(attachment),
  } mutableCopy];
  NSString *reason = nil;
  NSDictionary *snapshot = TableSnapshot(TableOf(attachment, NULL), &reason);
  if (snapshot) {
    summary[@"readable"] = @YES;
    summary[@"rowCount"] = @([snapshot[@"rows"] count]);
    summary[@"columnCount"] = @([snapshot[@"columnIdentifiers"] count]);
    summary[@"columnIdentifiers"] = snapshot[@"columnIdentifiers"];
    summary[@"rows"] = snapshot[@"rows"];
  } else {
    summary[@"readable"] = @NO;
    summary[@"unreadableReason"] = reason ?: @"unknown";
  }
  return summary;
}

static NSDictionary *HandleReadTables(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  RequireFeature(FeatureTables);
  NSManagedObjectContext *context = OpenContext(ResolveStore(), YES);
  NSManagedObject *note = FetchNote(context, identifier);
  if (SendBool(note, "isPasswordProtected"))
    Fail(@"unsupported_note", @"Locked notes are not supported", nil);
  NSAttributedString *body = BodyAttributedString(note);
  NSMutableArray *tables = [NSMutableArray array];
  for (NSManagedObject *attachment in ActiveTables(note))
    [tables addObject:TableSummary(attachment, body)];
  return @{
    @"status" : @"ok",
    @"identifier" : identifier,
    @"revision" : RevisionToken(note),
    @"deletedOrInTrash" : @(SendBool(note, "isDeletedOrInTrash")),
    @"sharedViaICloud" : @(SendBool(note, "isSharedViaICloud")),
    @"tableCount" : @(tables.count),
    @"tables" : tables,
    @"syncHostRunning" : @(NotesAppRunning()),
  };
}

// Request helpers shared by the table actions.

static BOOL RequireBool(NSDictionary *request, NSString *key) {
  id value = request[key];
  // NSJSONSerialization decodes true/false as the __NSCFBoolean singletons.
  if (value != (id)kCFBooleanTrue && value != (id)kCFBooleanFalse)
    Fail(@"invalid_request", [NSString stringWithFormat:@"`%@` must be true or false", key], nil);
  return [value boolValue];
}

static NSString *RequireUUIDField(NSDictionary *request, NSString *key) {
  NSString *value = RequireString(request, key);
  if (!IsUUID(value)) Fail(@"invalid_request", [NSString stringWithFormat:@"`%@` must be a UUID", key], nil);
  return value;
}

static NSString *RequireToken(NSDictionary *request, NSString *key, NSString *prefix) {
  NSString *value = RequireString(request, key);
  if (![value hasPrefix:prefix] || value.length != prefix.length + 64)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"`%@` must be a token from a fresh read or dry run", key], nil);
  return value;
}

// Dry runs take no guards; applies need both. Mixing them is refused so a
// caller cannot mistake one for the other. Returns YES for an apply.
static BOOL RequireGuards(NSDictionary *request, BOOL dryRun, NSString **ifRevision,
                          NSString **ifTableDigest) {
  if (dryRun) {
    if (request[@"ifRevision"] || request[@"ifTableDigest"])
      Fail(@"invalid_request", @"`ifRevision` and `ifTableDigest` are only accepted with dryRun false",
           nil);
    return NO;
  }
  *ifRevision = RequireToken(request, @"ifRevision", @"r1:");
  *ifTableDigest = RequireToken(request, @"ifTableDigest", @"t1:");
  return YES;
}

static void ValidateCellText(NSString *text) {
  if (text.length > MAX_CELL_UTF16)
    Fail(@"invalid_request", @"Cell text exceeds 10000 UTF-16 code units", nil);
  NSMutableCharacterSet *forbidden = [NSMutableCharacterSet controlCharacterSet];
  [forbidden removeCharactersInString:@"\n\t"];
  [forbidden addCharactersInString:@"\uFFFC\u2028\u2029"];
  if ([text rangeOfCharacterFromSet:forbidden].location != NSNotFound)
    Fail(@"invalid_request",
         @"Cell text may contain only printable characters, tabs and \\n newlines", nil);
}

typedef struct {
  StoreLocation store;
  NSManagedObjectContext *context;
  NSManagedObject *note;
  NSManagedObject *attachment;
  NSString *revision;
  NSString *tableDigest;
  NSString *bodyText;
} TableTarget;

// Resolves the note and one of its table attachments, applying the same note
// refusals as every other write. `visible` requires exactly one body glyph;
// otherwise the table must have none (an orphan). A dry run opens the store
// read-only.
static TableTarget ResolveTableTarget(NSDictionary *request, BOOL readOnly, BOOL visible,
                                      Feature feature) {
  NSString *identifier = RequireIdentifier(request);
  NSString *tableIdentifier = RequireUUIDField(request, @"tableIdentifier");
  RequireFeature(feature);
  TableTarget target;
  target.store = ResolveStore();
  target.context = OpenContext(target.store, readOnly);
  target.note = FetchNote(target.context, identifier);
  RequireAppendableNote(target.note);
  NSAttributedString *body = BodyAttributedString(target.note);
  if (!body) Fail(@"unsupported_note", @"The note body could not be loaded as a mergeable string", nil);
  target.bodyText = [body.string copy];
  target.attachment = nil;
  for (NSManagedObject *attachment in [target.note valueForKey:@"attachments"])
    if ([[attachment valueForKey:@"identifier"] caseInsensitiveCompare:tableIdentifier] == NSOrderedSame)
      target.attachment = attachment;
  if (!target.attachment) Fail(@"not_found", @"The note has no attachment with that tableIdentifier", nil);
  if (![[target.attachment valueForKey:@"typeUTI"] isEqual:kTableUTI])
    Fail(@"invalid_request", @"That attachment is not a table", nil);
  if (!IsActiveTopLevelTable(target.attachment))
    Fail(@"unsupported_attachment", @"The table is nested or already marked for deletion", nil);
  NSUInteger glyphs = GlyphCountFor(body, tableIdentifier);
  if (visible && glyphs != 1)
    Fail(@"unsupported_attachment",
         glyphs ? @"The table appears more than once in the body"
                : @"The table has no glyph in the body (an orphan); use prune_orphan_table",
         @{@"glyphCount" : @(glyphs)});
  if (!visible && glyphs != 0)
    Fail(@"unsupported_attachment", @"The table is visible in the body, so it is not an orphan",
         @{@"glyphCount" : @(glyphs)});
  target.revision = RevisionToken(target.note);
  target.tableDigest = TableDigest(target.attachment);
  return target;
}

// The compare-and-swap step: the persisted note revision and table digest
// must equal the caller's tokens before anything changes.
static void CompareTableGuards(TableTarget target, NSString *ifRevision, NSString *ifTableDigest) {
  if (![ifRevision isEqualToString:target.revision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : target.revision});
  if (![ifTableDigest isEqualToString:target.tableDigest])
    Fail(@"attachment_conflict", @"The table changed since ifTableDigest was read",
         @{@"committed" : @NO, @"currentTableDigest" : target.tableDigest});
}

static void SaveOnce(NSManagedObjectContext *context) {
  NSError *saveError = nil;
  if ([context save:&saveError]) return;
  [context rollback];
  BOOL conflict = saveError.code == NSManagedObjectMergeError ||
                  saveError.code == NSPersistentStoreSaveConflictsError;
  Fail(conflict ? @"revision_conflict" : @"save_failed",
       conflict ? @"Notes changed the note during the write; nothing was saved"
                : @"The Core Data save failed; nothing was saved",
       @{@"committed" : @NO, @"detail" : OrNull(saveError.localizedDescription)});
}

// The writer never uploads (see HandleAppendPlainText).
static NSDictionary *PushFields(StoreLocation store) {
  BOOL hostRunning = NotesAppRunning();
  return @{
    @"pushScheduled" : @NO,
    @"syncHostRunning" : @(hostRunning),
    @"pushState" : hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch",
    @"storeKind" : store.isCopy ? @"copy" : @"live",
  };
}

static NSManagedObject *AttachmentNamed(NSManagedObject *note, NSString *identifier) {
  for (NSManagedObject *candidate in [note valueForKey:@"attachments"])
    if ([[candidate valueForKey:@"identifier"] isEqualToString:identifier]) return candidate;
  return nil;
}

// Serializes an edited table, marks it and the note changed, saves once, and
// proves through a brand-new Core Data stack that the body is untouched and
// the table now equals `expected` exactly.
static NSDictionary *CommitTableEdit(TableTarget target, id model, NSString *reason,
                                     NSDictionary *expected) {
  NSString *tableIdentifier = [target.attachment valueForKey:@"identifier"];
  NSString *noteIdentifier = [target.note valueForKey:@"identifier"];
  SendVoid(model, "writeMergeableData");
  SendVoid(model, "regenerateTextContentInNote");
  SendVoid(target.attachment, "saveMergeableDataIfNeeded");
  NSDate *now = [NSDate date];
  if (target.attachment.entity.propertiesByName[@"modificationDate"])
    [target.attachment setValue:now forKey:@"modificationDate"];
  ((void (*)(id, SEL, id))objc_msgSend)(target.attachment,
                                        sel_registerName("updateChangeCountWithReason:"), reason);
  [target.note setValue:now forKey:@"modificationDate"];
  ((void (*)(id, SEL, id))objc_msgSend)(target.note, sel_registerName("updateChangeCountWithReason:"),
                                        reason);
  SaveOnce(target.context);

  NSString *verifyDetail = nil;
  NSDictionary *after = nil;
  NSString *digestAfter = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(target.store, YES);
    NSManagedObject *note = FetchNote(fresh, noteIdentifier);
    NSAttributedString *body = BodyAttributedString(note);
    NSManagedObject *attachment = AttachmentNamed(note, tableIdentifier);
    NSString *reasonText = nil;
    NSDictionary *snapshot = attachment ? TableSnapshot(TableOf(attachment, NULL), &reasonText) : nil;
    if (![body.string isEqualToString:target.bodyText])
      verifyDetail = @"The note body changed during a table-only edit";
    else if (GlyphCountFor(body, tableIdentifier) != 1)
      verifyDetail = @"The table glyph is no longer present exactly once";
    else if (!snapshot)
      verifyDetail = reasonText ?: @"The table could not be re-read";
    else if (![snapshot isEqual:expected])
      verifyDetail = @"The persisted table does not equal the planned result";
    if (!verifyDetail) {
      digestAfter = TableDigest(attachment);
      after = NoteState(note);
    }
  } @catch (HelperError *e) {
    verifyDetail = e.reason;
  }
  if (verifyDetail)
    Fail(@"verification_failed", verifyDetail,
         @{@"committed" : @YES, @"revisionBefore" : target.revision});
  NSMutableDictionary *result = [@{
    @"status" : @"updated",
    @"dryRun" : @NO,
    @"committed" : @YES,
    @"verified" : @YES,
    @"identifier" : noteIdentifier,
    @"tableIdentifier" : tableIdentifier,
    @"revisionBefore" : target.revision,
    @"revisionAfter" : after[@"revision"],
    @"tableDigestBefore" : target.tableDigest,
    @"tableDigestAfter" : digestAfter,
    @"rowCount" : @([expected[@"rows"] count]),
    @"columnCount" : @([expected[@"columnIdentifiers"] count]),
    @"modificationDate" : after[@"modificationDate"],
    @"cloudSync" : after[@"cloudSync"],
  } mutableCopy];
  [result addEntriesFromDictionary:PushFields(target.store)];
  return result;
}

static NSDictionary *LoadedSnapshot(TableTarget target, id *tableOut, id *modelOut) {
  id model = nil;
  id table = TableOf(target.attachment, &model);
  NSString *reason = nil;
  NSDictionary *snapshot = TableSnapshot(table, &reason);
  if (!snapshot || !model) Fail(@"unsupported_attachment", reason ?: @"The table could not be loaded", nil);
  if (tableOut) *tableOut = table;
  if (modelOut) *modelOut = model;
  return snapshot;
}

static NSDictionary *HandleDeleteTableRow(NSDictionary *request) {
  BOOL dryRun = RequireBool(request, @"dryRun");
  NSString *rowIdentifier = RequireUUIDField(request, @"rowIdentifier");
  NSString *ifRevision = nil, *ifTableDigest = nil;
  BOOL apply = RequireGuards(request, dryRun, &ifRevision, &ifTableDigest);
  TableTarget target = ResolveTableTarget(request, !apply, YES, FeatureTables);
  // Guards first, so a stale plan reports a conflict rather than a missing row.
  if (apply) CompareTableGuards(target, ifRevision, ifTableDigest);
  id table = nil, model = nil;
  NSDictionary *snapshot = LoadedSnapshot(target, &table, &model);
  NSUInteger index = IndexOfRow(snapshot, rowIdentifier);
  if (index == NSNotFound) Fail(@"not_found", @"The table has no row with that rowIdentifier", nil);
  NSArray *rows = snapshot[@"rows"];
  if (rows.count < 2) Fail(@"unsupported_attachment", @"A table's only row cannot be deleted", nil);
  NSMutableArray *remaining = [rows mutableCopy];
  [remaining removeObjectAtIndex:index];
  NSDictionary *expected = @{@"columnIdentifiers" : snapshot[@"columnIdentifiers"], @"rows" : remaining};

  NSDictionary *plan = @{
    @"identifier" : [target.note valueForKey:@"identifier"],
    @"tableIdentifier" : [target.attachment valueForKey:@"identifier"],
    @"rowIdentifier" : rows[index][@"identifier"],
    @"rowIndex" : @(index),
    @"rowCells" : rows[index][@"cells"],
    @"rowCountBefore" : @(rows.count),
    @"columnCount" : @([snapshot[@"columnIdentifiers"] count]),
  };
  if (!apply) {
    NSMutableDictionary *result = [plan mutableCopy];
    [result addEntriesFromDictionary:@{
      @"status" : @"planned",
      @"dryRun" : @YES,
      @"committed" : @NO,
      @"revision" : target.revision,
      @"tableDigest" : target.tableDigest,
    }];
    return result;
  }
  ((void (*)(id, SEL, NSUInteger))objc_msgSend)(table, sel_registerName("removeRowAtIndex:"), index);
  NSMutableDictionary *result =
      [CommitTableEdit(target, model, @"apple-notes-mcp delete_table_row", expected) mutableCopy];
  [result addEntriesFromDictionary:plan];
  return result;
}

static NSDictionary *HandleInsertTableRow(NSDictionary *request) {
  id cellsValue = request[@"cells"];
  NSArray *cells = cellsValue ?: @[];
  if (![cells isKindOfClass:[NSArray class]])
    Fail(@"invalid_request", @"`cells` must be an array of strings", nil);
  for (id cell in cells) {
    if (![cell isKindOfClass:[NSString class]])
      Fail(@"invalid_request", @"`cells` must be an array of strings", nil);
    ValidateCellText(cell);
  }
  NSString *after = request[@"afterRowIdentifier"] ? RequireUUIDField(request, @"afterRowIdentifier") : nil;
  NSString *ifRevision = nil, *ifTableDigest = nil;
  RequireGuards(request, NO, &ifRevision, &ifTableDigest);
  TableTarget target = ResolveTableTarget(request, NO, YES, FeatureTables);
  CompareTableGuards(target, ifRevision, ifTableDigest);
  id table = nil, model = nil;
  NSDictionary *snapshot = LoadedSnapshot(target, &table, &model);
  NSArray *columns = snapshot[@"columnIdentifiers"];
  NSArray *rows = snapshot[@"rows"];
  if (cells.count > columns.count)
    Fail(@"invalid_request", @"`cells` has more entries than the table has columns", nil);
  if (rows.count >= MAX_TABLE_DIMENSION || (rows.count + 1) * columns.count > MAX_TABLE_CELLS)
    Fail(@"unsupported_attachment", @"The table is already at the row or cell limit", nil);
  NSUInteger index = rows.count;
  if (after) {
    NSUInteger found = IndexOfRow(snapshot, after);
    if (found == NSNotFound) Fail(@"not_found", @"The table has no row with that afterRowIdentifier", nil);
    index = found + 1;
  }

  ((id(*)(id, SEL, NSUInteger))objc_msgSend)(table, sel_registerName("insertRowAtIndex:"), index);
  NSString *newRow = IdentityText(RowIdentityAt(table, index));
  if (!newRow || IndexOfRow(snapshot, newRow) != NSNotFound) {
    [target.context rollback];
    Fail(@"internal_error", @"The inserted row has no new native identifier", @{@"committed" : @NO});
  }
  NSMutableArray *newCells = [NSMutableArray array];
  for (NSUInteger c = 0; c < columns.count; c++) {
    NSString *text = c < cells.count ? cells[c] : @"";
    [newCells addObject:text];
    if (!text.length) continue;
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(
        table, sel_registerName("setAttributedString:columnIndex:rowIndex:"),
        [[NSAttributedString alloc] initWithString:text], c, index);
  }
  NSMutableArray *expectedRows = [rows mutableCopy];
  [expectedRows insertObject:@{@"identifier" : newRow, @"cells" : newCells} atIndex:index];
  NSMutableDictionary *result =
      [CommitTableEdit(target, model, @"apple-notes-mcp insert_table_row",
                       @{@"columnIdentifiers" : columns, @"rows" : expectedRows}) mutableCopy];
  result[@"rowIdentifier"] = newRow;
  result[@"rowIndex"] = @(index);
  return result;
}

static NSDictionary *HandleSetTableCell(NSDictionary *request) {
  NSString *rowIdentifier = RequireUUIDField(request, @"rowIdentifier");
  NSString *columnIdentifier = RequireUUIDField(request, @"columnIdentifier");
  id textValue = request[@"text"];
  if (![textValue isKindOfClass:[NSString class]])
    Fail(@"invalid_request", @"`text` must be a string (it may be empty)", nil);
  NSString *text = textValue;
  ValidateCellText(text);
  NSString *ifRevision = nil, *ifTableDigest = nil;
  RequireGuards(request, NO, &ifRevision, &ifTableDigest);
  TableTarget target = ResolveTableTarget(request, NO, YES, FeatureTables);
  CompareTableGuards(target, ifRevision, ifTableDigest);
  id table = nil, model = nil;
  NSDictionary *snapshot = LoadedSnapshot(target, &table, &model);
  NSUInteger row = IndexOfRow(snapshot, rowIdentifier);
  if (row == NSNotFound) Fail(@"not_found", @"The table has no row with that rowIdentifier", nil);
  NSArray *columns = snapshot[@"columnIdentifiers"];
  NSUInteger column = NSNotFound;
  for (NSUInteger c = 0; c < columns.count; c++)
    if ([columns[c] caseInsensitiveCompare:columnIdentifier] == NSOrderedSame) column = c;
  if (column == NSNotFound) Fail(@"not_found", @"The table has no column with that columnIdentifier", nil);

  NSString *previous = snapshot[@"rows"][row][@"cells"][column];
  ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(
      table, sel_registerName("setAttributedString:columnIndex:rowIndex:"),
      [[NSAttributedString alloc] initWithString:text], column, row);
  NSMutableArray *rows = [snapshot[@"rows"] mutableCopy];
  NSMutableArray *cells = [rows[row][@"cells"] mutableCopy];
  cells[column] = text;
  rows[row] = @{@"identifier" : rows[row][@"identifier"], @"cells" : cells};
  NSMutableDictionary *result =
      [CommitTableEdit(target, model, @"apple-notes-mcp set_table_cell",
                       @{@"columnIdentifiers" : columns, @"rows" : rows}) mutableCopy];
  result[@"rowIdentifier"] = rows[row][@"identifier"];
  result[@"columnIdentifier"] = columns[column];
  result[@"previousText"] = previous;
  return result;
}

// An orphan is an active top-level table attachment of this note that no body
// glyph names: invisible in Notes, but still synced and still counted.
// Tombstoning it is Notes' own deletion path, so CloudKit removes it on other
// devices. The body is never edited.
static NSDictionary *HandlePruneOrphanTable(NSDictionary *request) {
  BOOL dryRun = RequireBool(request, @"dryRun");
  NSString *ifRevision = nil, *ifTableDigest = nil;
  BOOL apply = RequireGuards(request, dryRun, &ifRevision, &ifTableDigest);
  TableTarget target = ResolveTableTarget(request, !apply, NO, FeaturePruneTable);
  if (apply) CompareTableGuards(target, ifRevision, ifTableDigest);
  NSRange range = ((NSRange(*)(id, SEL, id))objc_msgSend)(
      target.note, sel_registerName("rangeForAttachment:"), target.attachment);
  if (range.location != NSNotFound && range.length != 0)
    Fail(@"unsupported_attachment", @"Notes still reports a body range for this table", nil);
  NSString *tableIdentifier = [target.attachment valueForKey:@"identifier"];
  NSString *reason = nil;
  NSDictionary *snapshot = TableSnapshot(TableOf(target.attachment, NULL), &reason);
  NSUInteger activeBefore = ActiveTables(target.note).count;
  NSMutableDictionary *plan = [@{
    @"identifier" : [target.note valueForKey:@"identifier"],
    @"tableIdentifier" : tableIdentifier,
    @"glyphCount" : @0,
    @"activeTableCountBefore" : @(activeBefore),
    @"readable" : @((BOOL)(snapshot != nil)),
  } mutableCopy];
  if (snapshot) {
    plan[@"rowCount"] = @([snapshot[@"rows"] count]);
    plan[@"columnCount"] = @([snapshot[@"columnIdentifiers"] count]);
    // The first row lets a person recognise the table before approving.
    if ([snapshot[@"rows"] count]) plan[@"firstRowCells"] = snapshot[@"rows"][0][@"cells"];
  }
  if (!apply) {
    [plan addEntriesFromDictionary:@{
      @"status" : @"planned",
      @"dryRun" : @YES,
      @"committed" : @NO,
      @"revision" : target.revision,
      @"tableDigest" : target.tableDigest,
    }];
    return plan;
  }

  ((void (*)(id, SEL, BOOL))objc_msgSend)(
      target.attachment, sel_registerName("updateMarkedForDeletionStateAttachmentIsInUse:"), NO);
  SendVoid(target.attachment, "markForDeletion");
  if (![[target.attachment valueForKey:@"markedForDeletion"] boolValue]) {
    [target.context rollback];
    Fail(@"save_failed", @"The table did not enter the deleted state; nothing was saved",
         @{@"committed" : @NO});
  }
  // A note-level change count bump makes Notes treat the note as changed and
  // puts the note row in the save, so a concurrent Notes save conflicts.
  ((void (*)(id, SEL, id))objc_msgSend)(target.note, sel_registerName("updateChangeCountWithReason:"),
                                        @"apple-notes-mcp prune_orphan_table");
  SaveOnce(target.context);

  NSString *verifyDetail = nil;
  NSDictionary *after = nil;
  NSUInteger activeAfter = 0;
  @try {
    NSManagedObjectContext *fresh = OpenContext(target.store, YES);
    NSManagedObject *note = FetchNote(fresh, plan[@"identifier"]);
    NSManagedObject *attachment = AttachmentNamed(note, tableIdentifier);
    activeAfter = ActiveTables(note).count;
    if (![BodyAttributedString(note).string isEqualToString:target.bodyText])
      verifyDetail = @"The note body changed during the prune";
    else if (attachment && ![[attachment valueForKey:@"markedForDeletion"] boolValue])
      verifyDetail = @"The table is not marked for deletion after the save";
    else if (activeAfter + 1 != activeBefore)
      verifyDetail = @"The active table count did not drop by exactly one";
    else
      after = NoteState(note);
  } @catch (HelperError *e) {
    verifyDetail = e.reason;
  }
  if (verifyDetail)
    Fail(@"verification_failed", verifyDetail,
         @{@"committed" : @YES, @"revisionBefore" : target.revision});
  [plan addEntriesFromDictionary:@{
    @"status" : @"updated",
    @"dryRun" : @NO,
    @"committed" : @YES,
    @"verified" : @YES,
    @"removedTableIdentifier" : tableIdentifier,
    @"activeTableCountAfter" : @(activeAfter),
    @"revisionBefore" : target.revision,
    @"revisionAfter" : after[@"revision"],
    @"cloudSync" : after[@"cloudSync"],
  }];
  [plan addEntriesFromDictionary:PushFields(target.store)];
  return plan;
}

#pragma mark - Main

static NSData *ReadStdin(void) {
  NSMutableData *data = [NSMutableData data];
  char buffer[65536];
  size_t n;
  while ((n = fread(buffer, 1, sizeof buffer, stdin)) > 0) {
    [data appendBytes:buffer length:n];
    if (data.length > MAX_INPUT_BYTES) Fail(@"input_too_large", @"Request exceeds 1 MiB", nil);
  }
  return data;
}

static NSDictionary *Dispatch(void) {
  NSData *input = ReadStdin();
  if (input.length == 0) Fail(@"invalid_json", @"Empty request", nil);
  NSError *error = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:input options:0 error:&error];
  if (![parsed isKindOfClass:[NSDictionary class]])
    Fail(@"invalid_json", @"Request must be one JSON object", nil);
  NSDictionary *request = parsed;
  id protocol = request[@"protocol"];
  if (![protocol isKindOfClass:[NSNumber class]] || [protocol integerValue] != PROTOCOL_VERSION)
    Fail(@"protocol_mismatch",
         [NSString stringWithFormat:@"This helper speaks protocol %d", PROTOCOL_VERSION],
         @{@"protocolVersion" : @(PROTOCOL_VERSION)});
  id action = request[@"action"];
  if (![action isKindOfClass:[NSString class]]) Fail(@"invalid_request", @"`action` is required", nil);
  for (size_t i = 0; i < COUNT(kActions); i++) {
    if (![action isEqualToString:@(kActions[i].name)]) continue;
    NSMutableSet *allowed = [NSMutableSet setWithArray:@[ @"protocol", @"action" ]];
    NSString *extra = @(kActions[i].allowedKeys);
    if (extra.length) [allowed addObjectsFromArray:[extra componentsSeparatedByString:@","]];
    for (NSString *key in request)
      if (![allowed containsObject:key])
        Fail(@"invalid_request", [NSString stringWithFormat:@"Unknown request field `%@`", key], nil);
    return kActions[i].handler(request);
  }
  Fail(@"unknown_action", @"Action is not in the whitelist", @{@"actions" : ActionNames()});
  return nil;
}

int main(void) {
  @autoreleasepool {
    @try {
      EmitAndExit(Dispatch(), 0);
    } @catch (HelperError *e) {
      NSMutableDictionary *out = [e.userInfo mutableCopy];
      out[@"status"] = @"error";
      out[@"message"] = e.reason ?: @"error";
      EmitAndExit(out, 1);
    } @catch (NSException *e) {
      EmitAndExit(@{
        @"status" : @"error",
        @"code" : @"internal_error",
        @"message" : [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""],
      },
                  1);
    }
  }
  return 1;
}
