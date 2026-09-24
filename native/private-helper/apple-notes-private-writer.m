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

// Smart folders (#181). A smart folder is an ordinary synced ICFolder row
// with folderType 2 and a stored query document; Notes' own query model
// (ICQueryObjC / ICFilterSelection) parses and regenerates it.
static const APIRequirement kSmartFolderAPI[] = {
    {"ICFolder", "newFolderInAccount:", YES},
    {"ICFolder", "newFolderInParentFolder:", YES},
    {"ICFolder", "isTitleValid:account:parentFolder:error:", YES},
    {"ICFolder", "setTitle:", NO},
    {"ICFolder", "setFolderType:", NO},
    {"ICFolder", "setSmartFolderQueryJSON:", NO},
    {"ICFolder", "setSmartFolderQueryObjC:", NO},
    {"ICFolder", "smartFolderQueryObjC", NO},
    {"ICFolder", "canAddSubfolder", NO},
    {"ICFolder", "markForDeletion", NO},
    {"ICFolder", "updateChangeCountWithReason:", NO},
    {"ICAccount", "defaultAccountInContext:", YES},
    {"ICHashtag", "standardizedHashtagRepresentationForDisplayText:", YES},
    {"ICQueryObjC", "objc_queryForNotesMatchingFilterSelection:", YES},
    {"ICQueryObjC", "canBeEdited", NO},
    {"ICQueryObjC", "predicate", NO},
    {"ICQueryObjC", "entityName", NO},
    {"ICQueryObjC", "minimumSupportedVersion", NO},
    {"ICQueryObjC", "filterSelectionWithManagedObjectContext:account:", NO},
    {"ICFilterSelection", "isValid", NO},
    {"ICFilterSelection", "isEmpty", NO},
    {"ICFilterSelection", "hasEmptySelection", NO},
    {"ICFilterSelection", "filterTypeSelections", NO},
    {"ICFilterSelection", "emptyFilterTypeSelections", NO},
    {"ICFilterSelection", "invalidFilterTypeSelectionCombinations", NO},
    {"ICFilterSelection", "incompatibleLockedNotesFilterTypeSelections", NO},
};

static const ModelRequirement kSmartFolderModelProperties[] = {
    {"ICFolder",
     "identifier,title,folderType,smartFolderQueryJSON,markedForDeletion,account,parent,"
     "dateForLastTitleModification,parentModificationDate,cloudState"},
    {"ICAccount", "identifier,name"},
    {"ICHashtag", "identifier,standardizedContent,displayText,account,markedForDeletion"},
    {"ICNote", "folder"},
};

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

static BOOL gFrameworkLoaded = NO;
// A handler sets gWriteRequest when the request may save, and the save
// helpers set gSaveAttempted just before the first save. An error raised
// while gSaveAttempted is still NO provably saved nothing, so main() reports
// it as committed: false instead of leaving it indeterminate.
static BOOL gWriteRequest = NO;
static BOOL gSaveAttempted = NO;
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
  FeatureSmartFolders,
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
  if (feature == FeatureSmartFolders) {
    [missing addObjectsFromArray:MissingModelPropertiesIn(kSmartFolderModelProperties,
                                                          COUNT(kSmartFolderModelProperties))];
    [missing addObjectsFromArray:MissingAPI(kSmartFolderAPI, COUNT(kSmartFolderAPI))];
  }
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
static id Send1(id target, const char *sel, id arg) {
  return ((id(*)(id, SEL, id))objc_msgSend)(target, sel_registerName(sel), arg);
}
static id Send2(id target, const char *sel, id a, id b) {
  return ((id(*)(id, SEL, id, id))objc_msgSend)(target, sel_registerName(sel), a, b);
}
static void SendVoid1(id target, const char *sel, id arg) {
  ((void (*)(id, SEL, id))objc_msgSend)(target, sel_registerName(sel), arg);
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
static NSDictionary *HandleReadSmartFolder(NSDictionary *request);
static NSDictionary *HandleCreateSmartFolder(NSDictionary *request);
static NSDictionary *HandleUpdateSmartFolder(NSDictionary *request);
static NSDictionary *HandleDeleteSmartFolder(NSDictionary *request);

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
    {"read_smart_folder", "identifier", HandleReadSmartFolder},
    {"create_smart_folder", "title,queryJSON,account,parentIdentifier", HandleCreateSmartFolder},
    {"update_smart_folder", "identifier,queryJSON,ifRevision", HandleUpdateSmartFolder},
    {"delete_smart_folder", "identifier,dryRun,ifRevision", HandleDeleteSmartFolder},
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
      @"smartFolders" : FeatureReport(FeatureSmartFolders, contextOK, contextReason),
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

#pragma mark - Smart folders

// A smart folder is an ordinary synced ICFolder row with folderType 2 and a
// stored query document instead of notes. There is no AppleScript or
// Shortcuts interface for creating or editing one. Every query goes through
// Notes' own query model (ICQueryObjC / ICFilterSelection), and a query Notes
// cannot store without changing its meaning is refused.
//
// Folders have no note revision, so the smart-folder writes compare an `f1:`
// folder revision (FolderRevision below) as their ifRevision token. Creating
// a folder has nothing to compare: its guard is that no active folder with
// that title exists in the destination.

// Limits keep a hostile query from exhausting the writer before Notes' own
// parser sees it. Real smart folders are a handful of clauses.
#define SMART_MAX_QUERY_BYTES (64 * 1024)
#define SMART_MAX_DEPTH 32
#define SMART_MAX_NODES 256
#define SMART_MAX_TITLE_UTF16 256
#define SMART_MAX_STRING_UTF16 1024

static NSString *const kSmartCreateReason = @"apple-notes-mcp create_smart_folder";
static NSString *const kSmartUpdateReason = @"apple-notes-mcp update_smart_folder";
static NSString *const kSmartDeleteReason = @"apple-notes-mcp delete_smart_folder";

static BOOL IsJSONBool(id value) {
  return [value isKindOfClass:[NSNumber class]] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL IsJSONInteger(id value, double minimum, double maximum) {
  if (![value isKindOfClass:[NSNumber class]] || IsJSONBool(value)) return NO;
  double number = [value doubleValue];
  return isfinite(number) && floor(number) == number && number >= minimum && number <= maximum;
}

static BOOL IsJSONFiniteNumber(id value) {
  return [value isKindOfClass:[NSNumber class]] && !IsJSONBool(value) && isfinite([value doubleValue]);
}

static BOOL HasExactlyKeys(id object, NSArray<NSString *> *keys) {
  return [object isKindOfClass:[NSDictionary class]] && [object count] == keys.count &&
         [[NSSet setWithArray:[object allKeys]] isEqualToSet:[NSSet setWithArray:keys]];
}

// Compact JSON with sorted keys: the one form every query comparison uses, so
// key order and whitespace never decide equality.
static NSString *CanonicalJSON(id object) {
  if (![NSJSONSerialization isValidJSONObject:object]) return nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSDictionary *ParseJSONDictionary(NSString *text) {
  if (![text isKindOfClass:[NSString class]] || !text.length) return nil;
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

static NSString *CanonicalQueryText(NSString *text) {
  NSDictionary *parsed = ParseJSONDictionary(text);
  return parsed ? CanonicalJSON(parsed) : nil;
}

static BOOL HasControlCharacters(NSString *text) {
  return [text rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound;
}

static BOOL IsTrimmedPlainString(id value, NSUInteger maxLength) {
  if (![value isKindOfClass:[NSString class]]) return NO;
  NSString *text = value;
  return text.length > 0 && text.length <= maxLength && !HasControlCharacters(text) &&
         [text isEqualToString:[text stringByTrimmingCharactersInSet:NSCharacterSet
                                                                         .whitespaceAndNewlineCharacterSet]];
}

static NSString *StringAttr(id object, NSString *key) {
  id value = object ? [object valueForKey:key] : nil;
  return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL BoolAttr(id object, NSString *key) {
  id value = object ? [object valueForKey:key] : nil;
  return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static NSInteger FolderKind(id folder) {
  id value = folder ? [folder valueForKey:@"folderType"] : nil;
  return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : NSIntegerMin;
}

static NSArray *FetchRows(NSManagedObjectContext *context, NSString *entity, NSPredicate *predicate) {
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity];
  request.predicate = predicate;
  request.returnsObjectsAsFaults = NO;
  NSError *error = nil;
  NSArray *rows = [context executeFetchRequest:request error:&error];
  if (!rows)
    Fail(@"store_unavailable", [NSString stringWithFormat:@"%@ fetch failed", entity],
         @{@"detail" : OrNull(error.localizedDescription)});
  return rows;
}

static NSUInteger CountRows(NSManagedObjectContext *context, NSString *entity, NSPredicate *predicate) {
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity];
  request.predicate = predicate;
  NSError *error = nil;
  NSUInteger count = [context countForFetchRequest:request error:&error];
  if (count == NSNotFound)
    Fail(@"store_unavailable", [NSString stringWithFormat:@"%@ count failed", entity],
         @{@"detail" : OrNull(error.localizedDescription)});
  return count;
}

// Folder identifiers are UUIDs for CloudKit folders and short tokens such as
// DefaultFolder-CloudKit for system folders.
static BOOL IsFolderIdentifier(id value) {
  if (![value isKindOfClass:[NSString class]] || [value length] == 0 || [value length] > 128) return NO;
  NSCharacterSet *allowed = [NSCharacterSet
      characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"];
  return [[value stringByTrimmingCharactersInSet:allowed] length] == 0;
}

// Resolves a folder by stable identifier or by the server's x-coredata folder
// id. Refuses a reference that matches more than one row.
static NSManagedObject *FetchFolderRef(NSManagedObjectContext *context, NSString *ref, NSString *field) {
  if ([ref hasPrefix:@"x-coredata://"]) {
    NSURL *url = [NSURL URLWithString:ref];
    NSManagedObjectID *objectID =
        url ? [context.persistentStoreCoordinator managedObjectIDForURIRepresentation:url] : nil;
    if (!objectID || ![objectID.entity.name isEqualToString:@"ICFolder"])
      Fail(@"not_found", [NSString stringWithFormat:@"`%@` does not name a folder in this store", field], nil);
    NSManagedObject *folder = [context existingObjectWithID:objectID error:nil];
    if (!folder)
      Fail(@"not_found", [NSString stringWithFormat:@"`%@` does not name an existing folder", field], nil);
    return folder;
  }
  if (!IsFolderIdentifier(ref))
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"`%@` must be a folder identifier or x-coredata folder id", field], nil);
  NSArray *rows =
      FetchRows(context, @"ICFolder", [NSPredicate predicateWithFormat:@"identifier ==[c] %@", ref]);
  if (rows.count == 0) Fail(@"not_found", [NSString stringWithFormat:@"No folder matches `%@`", field], nil);
  if (rows.count > 1)
    Fail(@"ambiguous", [NSString stringWithFormat:@"`%@` matches more than one folder row", field], nil);
  return rows.firstObject;
}

static NSManagedObject *FetchByIdentifier(NSManagedObjectContext *context, NSString *entity,
                                          NSString *identifier) {
  NSArray *rows =
      FetchRows(context, entity, [NSPredicate predicateWithFormat:@"identifier == %@", identifier]);
  if (rows.count == 0)
    Fail(@"not_found", [NSString stringWithFormat:@"%@ %@ no longer exists", entity, identifier], nil);
  if (rows.count > 1)
    Fail(@"ambiguous", [NSString stringWithFormat:@"More than one %@ row has that identifier", entity], nil);
  return rows.firstObject;
}

static NSManagedObject *ResolveAccount(NSManagedObjectContext *context, NSString *ref) {
  if (!IsTrimmedPlainString(ref, SMART_MAX_STRING_UTF16))
    Fail(@"invalid_request", @"`account` must be an account identifier or name", nil);
  NSArray *accounts = FetchRows(context, @"ICAccount", nil);
  NSMutableArray *byIdentifier = [NSMutableArray array];
  NSMutableArray *byName = [NSMutableArray array];
  for (NSManagedObject *account in accounts) {
    if (BoolAttr(account, @"markedForDeletion")) continue;
    if ([StringAttr(account, @"identifier") isEqualToString:ref]) [byIdentifier addObject:account];
    if ([StringAttr(account, @"name") isEqualToString:ref]) [byName addObject:account];
  }
  NSArray *matches = byIdentifier.count ? byIdentifier : byName;
  if (matches.count == 0) Fail(@"not_found", @"No active Notes account has that identifier or name", nil);
  if (matches.count > 1)
    Fail(@"ambiguous", @"More than one Notes account has that name; pass its identifier", nil);
  return matches.firstObject;
}

static BOOL IsTrashFolder(NSManagedObject *folder) {
  NSString *identifier = StringAttr(folder, @"identifier");
  if ([identifier hasPrefix:@"TrashFolder-"]) return YES;
  id account = [folder valueForKey:@"account"];
  if (account && [account respondsToSelector:sel_registerName("trashFolder")]) {
    id trash = Send(account, "trashFolder");
    if (trash && [[trash objectID] isEqual:folder.objectID]) return YES;
  }
  return NO;
}

// A smart folder may live at an account root or inside an ordinary folder.
// A smart folder is never a destination (the same rule as the server's
// smart-folder destination guard), nor the trash, a shared folder, or a
// folder being deleted.
static void RequireSmartFolderParent(NSManagedObject *parent) {
  if (BoolAttr(parent, @"markedForDeletion"))
    Fail(@"unsupported_folder", @"The parent folder is deleted", nil);
  if (FolderKind(parent) == 2)
    Fail(@"unsupported_folder",
         @"The parent is a smart folder; smart folders cannot hold notes or folders",
         @{@"reason" : @"smart_folder_destination"});
  if (FolderKind(parent) != 0)
    Fail(@"unsupported_folder", @"The parent must be an ordinary folder, not a system folder", nil);
  if (IsTrashFolder(parent)) Fail(@"unsupported_folder", @"The parent cannot be Recently Deleted", nil);
  if ([parent respondsToSelector:sel_registerName("isSharedViaICloud")] &&
      SendBool(parent, "isSharedViaICloud"))
    Fail(@"unsupported_folder", @"The parent folder is shared", nil);
  if (!SendBool(parent, "canAddSubfolder"))
    Fail(@"unsupported_folder", @"Notes reports that this folder cannot hold a subfolder", nil);
}

// Resolves where a smart folder goes. Sets *account always and *parent only
// for a nested destination.
static void ResolveDestination(NSManagedObjectContext *context, NSString *accountRef, NSString *parentRef,
                               NSManagedObject *__strong *account, NSManagedObject *__strong *parent) {
  *parent = nil;
  if (parentRef) {
    *parent = FetchFolderRef(context, parentRef, @"parentIdentifier");
    RequireSmartFolderParent(*parent);
    *account = [*parent valueForKey:@"account"];
  } else if (accountRef) {
    *account = ResolveAccount(context, accountRef);
  } else {
    id fallback = Send1(objc_getClass("ICAccount"), "defaultAccountInContext:", context);
    *account = [fallback isKindOfClass:[NSManagedObject class]] ? fallback : nil;
    if (!*account)
      Fail(@"invalid_request", @"Notes has no default account here; pass account or parentIdentifier", nil);
  }
  if (!*account || !StringAttr(*account, @"identifier"))
    Fail(@"unsupported_folder", @"The destination has no account with a stable identifier", nil);
}

#pragma mark Query normalization

typedef struct {
  NSUInteger nodes;
  NSUInteger filters;
} QueryBudget;

static NSSet<NSString *> *BooleanFilters(void) {
  static NSSet *set;
  if (!set)
    set = [NSSet setWithArray:@[
      @"checklist", @"checklistInProgress", @"checklistCompleted", @"attachment", @"pinned", @"systemPaper",
      @"passwordProtected", @"shared", @"mention", @"tagged"
    ]];
  return set;
}

// A tag clause names a tag by its display text. Notes stores the
// standardized form, which only Notes' own standardizer produces, and the tag
// must exist exactly once in the destination account.
static NSString *ResolveTag(id requested, NSManagedObject *account, NSManagedObjectContext *context,
                            NSMutableDictionary<NSString *, NSDictionary *> *resolved) {
  if (!IsTrimmedPlainString(requested, SMART_MAX_STRING_UTF16))
    Fail(@"invalid_query", @"A tag filter needs a non-empty tag name", nil);
  NSString *name = requested;
  while ([name hasPrefix:@"#"]) name = [name substringFromIndex:1];
  if (!name.length) Fail(@"invalid_query", @"A tag filter needs a non-empty tag name", nil);
  id standardized = Send1(objc_getClass("ICHashtag"), "standardizedHashtagRepresentationForDisplayText:", name);
  if (![standardized isKindOfClass:[NSString class]] || ![standardized length])
    Fail(@"invalid_query", [NSString stringWithFormat:@"Notes cannot standardize the tag #%@", name], nil);
  NSArray *tags =
      FetchRows(context, @"ICHashtag", [NSPredicate predicateWithFormat:@"standardizedContent == %@", standardized]);
  NSMutableArray *here = [NSMutableArray array];
  NSUInteger elsewhere = 0;
  for (NSManagedObject *tag in tags) {
    if (BoolAttr(tag, @"markedForDeletion")) continue;
    if ([[[tag valueForKey:@"account"] objectID] isEqual:account.objectID])
      [here addObject:tag];
    else
      elsewhere++;
  }
  if (here.count > 1)
    Fail(@"ambiguous", [NSString stringWithFormat:@"Tag #%@ is ambiguous in the destination account", name], nil);
  if (here.count == 0)
    Fail(@"tag_not_found",
         elsewhere ? [NSString stringWithFormat:@"Tag #%@ exists only in another account", name]
                   : [NSString stringWithFormat:@"Tag #%@ does not exist in the destination account", name],
         nil);
  NSManagedObject *tag = here.firstObject;
  if (!resolved[standardized])
    resolved[standardized] = @{
      @"requested" : requested,
      @"standardizedContent" : standardized,
      @"displayText" : OrNull(StringAttr(tag, @"displayText")),
      @"identifier" : OrNull(StringAttr(tag, @"identifier")),
    };
  return standardized;
}

static NSString *ResolveFilterFolder(id requested, NSManagedObject *account, NSManagedObjectContext *context) {
  if (![requested isKindOfClass:[NSString class]])
    Fail(@"invalid_query", @"A folder filter needs a folder identifier", nil);
  NSManagedObject *folder = FetchFolderRef(context, requested, @"folder filter");
  if (![[[folder valueForKey:@"account"] objectID] isEqual:account.objectID])
    Fail(@"invalid_query", @"A folder filter names a folder in another account", nil);
  if (BoolAttr(folder, @"markedForDeletion") || FolderKind(folder) != 0 || IsTrashFolder(folder))
    Fail(@"invalid_query", @"Folder filters may name only active ordinary folders", nil);
  return StringAttr(folder, @"identifier");
}

static BOOL IsRelativeRange(id value) {
  if (HasExactlyKeys(value, @[ @"type" ])) return IsJSONInteger(value[@"type"], 0, 5);
  return HasExactlyKeys(value, @[ @"type", @"customAmount", @"customUnit" ]) &&
         IsJSONInteger(value[@"type"], 6, 6) && IsJSONInteger(value[@"customAmount"], 1, 100000) &&
         IsJSONInteger(value[@"customUnit"], 0, 4);
}

static id NormalizeClause(id node, NSUInteger depth, QueryBudget *budget, NSManagedObject *account,
                          NSManagedObjectContext *context,
                          NSMutableDictionary<NSString *, NSDictionary *> *resolvedTags) {
  if (depth > SMART_MAX_DEPTH || ++budget->nodes > SMART_MAX_NODES)
    Fail(@"invalid_query", @"The query is nested too deeply or has too many clauses", nil);
  if (![node isKindOfClass:[NSDictionary class]] || [node count] != 1)
    Fail(@"invalid_query", @"Every query clause must be an object with exactly one key", nil);
  NSString *key = [node allKeys].firstObject;
  id value = node[key];
  if ([key isEqualToString:@"and"] || [key isEqualToString:@"or"]) {
    if (![value isKindOfClass:[NSArray class]] || [value count] == 0)
      Fail(@"invalid_query", [NSString stringWithFormat:@"`%@` needs a non-empty array of clauses", key], nil);
    NSMutableArray *children = [NSMutableArray array];
    for (id child in value)
      [children addObject:NormalizeClause(child, depth + 1, budget, account, context, resolvedTags)];
    return @{key : children};
  }
  if ([key isEqualToString:@"not"])
    return @{key : NormalizeClause(value, depth + 1, budget, account, context, resolvedTags)};
  budget->filters++;
  if ([BooleanFilters() containsObject:key]) {
    if (!IsJSONBool(value))
      Fail(@"invalid_query", [NSString stringWithFormat:@"`%@` must be true or false", key], nil);
    return node;
  }
  if ([key isEqualToString:@"attachmentSection"]) {
    if (!IsJSONInteger(value, 1, 7))
      Fail(@"invalid_query", @"`attachmentSection` must be an integer from 1 to 7", nil);
    return node;
  }
  if ([key isEqualToString:@"tag"]) return @{key : ResolveTag(value, account, context, resolvedTags)};
  if ([key isEqualToString:@"folder"]) return @{key : ResolveFilterFolder(value, account, context)};
  if ([key isEqualToString:@"creationDateRelativeRange"] ||
      [key isEqualToString:@"modificationDateRelativeRange"]) {
    if (!IsRelativeRange(value))
      Fail(@"invalid_query",
           [NSString stringWithFormat:@"`%@` needs {type: 0-5} or {type: 6, customAmount >= 1, customUnit: 0-4}",
                                      key],
           nil);
    return node;
  }
  if ([key isEqualToString:@"creationDateRange"] || [key isEqualToString:@"modificationDateRange"]) {
    if (!HasExactlyKeys(value, @[ @"fromDate", @"toDate" ]) || !IsJSONFiniteNumber(value[@"fromDate"]) ||
        !IsJSONFiniteNumber(value[@"toDate"]) ||
        [value[@"fromDate"] doubleValue] > [value[@"toDate"] doubleValue])
      Fail(@"invalid_query",
           [NSString stringWithFormat:@"`%@` needs finite fromDate <= toDate (seconds since 2001-01-01 UTC)",
                                      key],
           nil);
    return node;
  }
  if ([key isEqualToString:@"sharedParticipant"] || [key isEqualToString:@"mentionParticipant"]) {
    if (!IsTrimmedPlainString(value, SMART_MAX_STRING_UTF16))
      Fail(@"invalid_query", [NSString stringWithFormat:@"`%@` needs a participant identifier", key], nil);
    return node;
  }
  Fail(@"invalid_query", [NSString stringWithFormat:@"Unsupported query clause `%@`", key], nil);
  return nil;
}

// Notes resolves a folder filter only inside an `or` group (the shape its
// editor writes). A folder clause anywhere else gets a one-item `or` around
// it, which does not change what it matches.
static id WrapFolderLeaves(id node, BOOL parentIsOr) {
  if (![node isKindOfClass:[NSDictionary class]] || [node count] != 1) return node;
  NSString *key = [node allKeys].firstObject;
  id value = node[key];
  if ([key isEqualToString:@"folder"]) return parentIsOr ? node : @{@"or" : @[ node ]};
  if ([key isEqualToString:@"not"]) return @{key : WrapFolderLeaves(value, NO)};
  if (([key isEqualToString:@"and"] || [key isEqualToString:@"or"]) && [value isKindOfClass:[NSArray class]]) {
    NSMutableArray *children = [NSMutableArray array];
    for (id child in value) [children addObject:WrapFolderLeaves(child, [key isEqualToString:@"or"])];
    return @{key : children};
  }
  return node;
}

// Peels Notes' outer {"and":[{"deleted":bool}, X]} wrapper (and any
// single-child "and" around it) so the caller may send either the bare filter
// tree or a document copied from an existing smart folder.
static id StripDeletedWrapper(id body, BOOL *hasWrapper, BOOL *includeDeleted) {
  for (NSUInteger depth = 0; depth < SMART_MAX_DEPTH; depth++) {
    if (![body isKindOfClass:[NSDictionary class]] || [body count] != 1 ||
        ![body[@"and"] isKindOfClass:[NSArray class]])
      return body;
    NSArray *items = body[@"and"];
    if (items.count == 1 && [items[0] isKindOfClass:[NSDictionary class]]) {
      body = items[0];
      continue;
    }
    if (items.count != 2 || !HasExactlyKeys(items[0], @[ @"deleted" ])) return body;
    if (!IsJSONBool(items[0][@"deleted"])) Fail(@"invalid_query", @"`deleted` must be true or false", nil);
    BOOL value = [items[0][@"deleted"] boolValue];
    if (*hasWrapper && value != *includeDeleted)
      Fail(@"invalid_query", @"The query has conflicting `deleted` wrappers", nil);
    *hasWrapper = YES;
    *includeDeleted = value;
    body = items[1];
  }
  Fail(@"invalid_query", @"The query is nested too deeply", nil);
  return nil;
}

// A comparison form for query meaning: single-child groups unwrapped, nested
// groups of the same operator flattened, a redundant {"deleted": <outer>}
// inside an `and` dropped (Notes repeats it next to some filters), and
// children sorted. Two documents with equal forms match the same notes.
static id SemanticNode(id node, BOOL includeDeleted, NSUInteger depth) {
  if (depth > SMART_MAX_DEPTH * 2 || ![node isKindOfClass:[NSDictionary class]] || [node count] != 1)
    return node;
  NSString *key = [node allKeys].firstObject;
  id value = node[key];
  if ([key isEqualToString:@"not"]) return @{key : SemanticNode(value, includeDeleted, depth + 1)};
  if (!([key isEqualToString:@"and"] || [key isEqualToString:@"or"]) || ![value isKindOfClass:[NSArray class]])
    return node;
  NSMutableArray *children = [NSMutableArray array];
  NSDictionary *redundant = @{@"deleted" : @(includeDeleted)};
  for (id child in value) {
    id form = SemanticNode(child, includeDeleted, depth + 1);
    if ([key isEqualToString:@"and"] && [form isEqual:redundant]) continue;
    if ([form isKindOfClass:[NSDictionary class]] && [form count] == 1 && [form[key] isKindOfClass:[NSArray class]])
      [children addObjectsFromArray:form[key]];
    else
      [children addObject:form];
  }
  if (children.count == 1) return children.firstObject;
  [children sortUsingComparator:^NSComparisonResult(id a, id b) {
    return [CanonicalJSON(a) ?: @"" compare:CanonicalJSON(b) ?: @""];
  }];
  return @{key : children};
}

static NSString *SemanticQueryJSON(NSDictionary *document) {
  BOOL hasWrapper = NO, includeDeleted = NO;
  id body = nil;
  @try {
    body = StripDeletedWrapper(document[@"type"], &hasWrapper, &includeDeleted);
  } @catch (HelperError *e) {
    return nil;
  }
  return CanonicalJSON(
      @{@"includeDeleted" : @(includeDeleted), @"filter" : SemanticNode(body, includeDeleted, 0)});
}

static void SetFolderType(id folder, short type) {
  ((void (*)(id, SEL, short))objc_msgSend)(folder, sel_registerName("setFolderType:"), type);
}

static BOOL IsEmptyCollection(id value) {
  return !value || ([value respondsToSelector:@selector(count)] && [value count] == 0);
}

// Hands the normalized document to Notes' own query model on a scratch
// folder in a READ-ONLY stack (nothing there can ever be saved), then asks
// Notes to regenerate the document from the parsed filter selection. The
// regenerated form is what gets stored, so Notes' editor can open it.
static NSDictionary *NativeValidateQuery(NSDictionary *document, NSManagedObject *account,
                                         NSManagedObjectContext *readOnlyContext) {
  NSString *json = CanonicalJSON(document);
  id scratch = Send1(objc_getClass("ICFolder"), "newFolderInAccount:", account);
  if (!scratch) Fail(@"private_api_unavailable", @"Notes did not create a scratch folder for validation", nil);
  @try {
    SendVoid1(scratch, "setSmartFolderQueryJSON:", json);
    SetFolderType(scratch, 2);
    id query = Send(scratch, "smartFolderQueryObjC");
    if (!query || !SendBool(query, "canBeEdited") || !Send(query, "predicate"))
      Fail(@"invalid_query", @"Notes' query parser rejected the query", nil);
    if (![Send(query, "entityName") isEqual:@"ICNote"])
      Fail(@"invalid_query", @"Notes parsed the query for the wrong entity", nil);
    id selection =
        Send2(query, "filterSelectionWithManagedObjectContext:account:", readOnlyContext, account.objectID);
    if (!selection || !SendBool(selection, "isValid") || SendBool(selection, "isEmpty") ||
        SendBool(selection, "hasEmptySelection"))
      Fail(@"invalid_query", @"Notes could not resolve every filter in the query", nil);
    for (NSString *problem in @[
           @"emptyFilterTypeSelections", @"invalidFilterTypeSelectionCombinations",
           @"incompatibleLockedNotesFilterTypeSelections"
         ])
      if (!IsEmptyCollection(Send(selection, problem.UTF8String)))
        Fail(@"invalid_query", @"Notes reports incompatible or empty filters in the query",
             @{@"nativeProblem" : problem});
    NSArray *filterTypes = Send(selection, "filterTypeSelections");
    if (![filterTypes isKindOfClass:[NSArray class]] || filterTypes.count == 0)
      Fail(@"invalid_query", @"Notes found no filters in the query", nil);
    for (id filter in filterTypes) {
      if ([filter respondsToSelector:sel_registerName("isEmpty")] && SendBool(filter, "isEmpty"))
        Fail(@"invalid_query", @"Notes left a filter in the query unresolved", nil);
      if ([filter respondsToSelector:sel_registerName("unresolvedParticipants")] &&
          !IsEmptyCollection(Send(filter, "unresolvedParticipants")))
        Fail(@"invalid_query", @"A shared or mention participant does not resolve in the destination account",
             nil);
    }

    id regenerated = Send1(objc_getClass("ICQueryObjC"), "objc_queryForNotesMatchingFilterSelection:", selection);
    if (!regenerated || !SendBool(regenerated, "canBeEdited") || !Send(regenerated, "predicate"))
      Fail(@"invalid_query", @"Notes could not regenerate the query", nil);
    SendVoid1(scratch, "setSmartFolderQueryObjC:", regenerated);
    NSDictionary *nativeDocument = ParseJSONDictionary(StringAttr(scratch, @"smartFolderQueryJSON"));
    NSString *nativeJSON = nativeDocument ? CanonicalJSON(nativeDocument) : nil;
    if (!nativeJSON) Fail(@"invalid_query", @"Notes regenerated an unreadable query document", nil);
    // Notes' filter model cannot represent every boolean tree: observed on
    // macOS 27.2, it drops a `not` and collapses some `and` groups. Storing
    // its regeneration is only safe when it means exactly what was asked.
    NSString *requestedMeaning = SemanticQueryJSON(document);
    NSString *nativeMeaning = SemanticQueryJSON(nativeDocument);
    if (!requestedMeaning || ![requestedMeaning isEqualToString:nativeMeaning])
      Fail(@"query_not_representable",
           @"Notes' smart-folder model cannot store this query without changing its meaning", @{
             @"requestedMeaning" : OrNull(requestedMeaning),
             @"nativeMeaning" : OrNull(nativeMeaning),
             @"nativeQueryJSON" : nativeJSON
           });

    // Round trip: the stored form must parse back to the same filter count.
    SendVoid1(scratch, "setSmartFolderQueryJSON:", nativeJSON);
    id reparsed = Send(scratch, "smartFolderQueryObjC");
    id reselection = reparsed ? Send2(reparsed, "filterSelectionWithManagedObjectContext:account:",
                                      readOnlyContext, account.objectID)
                              : nil;
    NSArray *refilterTypes = reselection ? Send(reselection, "filterTypeSelections") : nil;
    if (!reselection || !SendBool(reselection, "isValid") || ![refilterTypes isKindOfClass:[NSArray class]] ||
        refilterTypes.count != filterTypes.count)
      Fail(@"invalid_query", @"Notes' regenerated query does not parse back to the same filters", nil);
    return @{
      @"queryJSON" : nativeJSON,
      @"filterCount" : @(filterTypes.count),
      @"nativeMinimumSupportedVersion" :
          @(((long long (*)(id, SEL))objc_msgSend)(reparsed, sel_registerName("minimumSupportedVersion"))),
    };
  } @finally {
    [readOnlyContext deleteObject:scratch];
    [readOnlyContext processPendingChanges];
  }
}

// Full pipeline for a requested query in a destination account: parse,
// structural checks, tag and folder resolution, then Notes' own validation.
static NSDictionary *ResolveSmartFolderQuery(NSString *queryText, NSManagedObject *account,
                                             NSManagedObjectContext *readOnlyContext) {
  if ([queryText lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > SMART_MAX_QUERY_BYTES)
    Fail(@"invalid_query", @"`queryJSON` exceeds 64 KiB", nil);
  NSDictionary *document = ParseJSONDictionary(queryText);
  if (!document) Fail(@"invalid_query", @"`queryJSON` must be one JSON object", nil);
  if (!HasExactlyKeys(document, @[ @"entity", @"type" ]) || ![document[@"entity"] isEqual:@"note"] ||
      ![document[@"type"] isKindOfClass:[NSDictionary class]])
    Fail(@"invalid_query", @"The query must be {\"entity\":\"note\",\"type\":{...}}", nil);
  BOOL hasWrapper = NO, includeDeleted = NO;
  id body = StripDeletedWrapper(document[@"type"], &hasWrapper, &includeDeleted);
  QueryBudget budget = {0, 0};
  NSMutableDictionary *resolvedTags = [NSMutableDictionary dictionary];
  id normalized = NormalizeClause(body, 0, &budget, account, readOnlyContext, resolvedTags);
  if (budget.filters == 0) Fail(@"invalid_query", @"The query needs at least one filter", nil);
  if (!normalized[@"and"] && !normalized[@"or"]) normalized = @{@"and" : @[ normalized ]};
  normalized = WrapFolderLeaves(normalized, NO);
  NSDictionary *normalizedDocument =
      @{@"entity" : @"note", @"type" : @{@"and" : @[ @{@"deleted" : @(includeDeleted)}, normalized ]}};
  NSDictionary *native = NativeValidateQuery(normalizedDocument, account, readOnlyContext);
  NSString *requested = CanonicalJSON(document);
  NSArray *tags = [resolvedTags.allValues sortedArrayUsingDescriptors:@[
    [NSSortDescriptor sortDescriptorWithKey:@"standardizedContent" ascending:YES]
  ]];
  return @{
    @"requestedQueryJSON" : requested,
    @"queryJSON" : native[@"queryJSON"],
    @"queryNormalized" : @((BOOL)![requested isEqualToString:native[@"queryJSON"]]),
    @"deletedWrapperAdded" : @((BOOL)!hasWrapper),
    @"resolvedTags" : tags,
    @"filterCount" : native[@"filterCount"],
    @"nativeQueryValidated" : @YES,
    @"nativeMinimumSupportedVersion" : native[@"nativeMinimumSupportedVersion"],
  };
}

#pragma mark Folder state

static NSDictionary *FolderCloudSyncState(NSManagedObject *folder) {
  id cloud = [folder valueForKey:@"cloudState"];
  BOOL inICloud = [folder respondsToSelector:sel_registerName("isInICloudAccount")] &&
                  SendBool(folder, "isInICloudAccount");
  if (!cloud) return @{@"available" : @NO, @"inICloudAccount" : @(inICloud)};
  long long current = [[cloud valueForKey:@"currentLocalVersion"] longLongValue];
  long long synced = [[cloud valueForKey:@"latestVersionSyncedToCloud"] longLongValue];
  return @{
    @"available" : @YES,
    @"inICloudAccount" : @(inICloud),
    @"currentLocalVersion" : @(current),
    @"latestVersionSyncedToCloud" : @(synced),
    @"uploadPending" : @((BOOL)(current > synced)),
  };
}

static NSString *StoredCanonicalQuery(NSManagedObject *folder) {
  return CanonicalQueryText(StringAttr(folder, @"smartFolderQueryJSON"));
}

// Opaque compare-and-swap token over every fact a smart-folder update or
// delete depends on: identity, title, type, stored query, account, parent,
// deletion flag, child and note counts, the title timestamp, and the cloud
// state's local version.
static NSString *FolderRevision(NSManagedObject *folder, NSUInteger children, NSUInteger notes) {
  id parent = [folder valueForKey:@"parent"];
  id account = [folder valueForKey:@"account"];
  NSDate *titleDate = [folder valueForKey:@"dateForLastTitleModification"];
  NSDictionary *cloud = FolderCloudSyncState(folder);
  NSString *canonical = [NSString
      stringWithFormat:@"f1\x1f%@\x1f%@\x1f%ld\x1f%@\x1f%@\x1f%@\x1f%d\x1f%lu\x1f%lu\x1f%.6f\x1f%@",
                       StringAttr(folder, @"identifier") ?: @"", StringAttr(folder, @"title") ?: @"",
                       (long)FolderKind(folder),
                       StoredCanonicalQuery(folder) ?: (StringAttr(folder, @"smartFolderQueryJSON") ?: @""),
                       account ? (StringAttr(account, @"identifier") ?: @"") : @"",
                       parent ? (StringAttr(parent, @"identifier") ?: @"") : @"",
                       BoolAttr(folder, @"markedForDeletion"), (unsigned long)children, (unsigned long)notes,
                       [titleDate isKindOfClass:[NSDate class]] ? titleDate.timeIntervalSinceReferenceDate : 0.0,
                       cloud[@"currentLocalVersion"] ?: @"none"];
  return [@"f1:" stringByAppendingString:SHA256Hex([canonical dataUsingEncoding:NSUTF8StringEncoding])];
}

static NSDictionary *FolderState(NSManagedObject *folder, NSManagedObjectContext *context) {
  NSUInteger children =
      CountRows(context, @"ICFolder", [NSPredicate predicateWithFormat:@"parent == %@", folder]);
  NSUInteger notes = CountRows(context, @"ICNote", [NSPredicate predicateWithFormat:@"folder == %@", folder]);
  id parent = [folder valueForKey:@"parent"];
  id account = [folder valueForKey:@"account"];
  NSString *raw = StringAttr(folder, @"smartFolderQueryJSON");
  return @{
    @"identifier" : OrNull(StringAttr(folder, @"identifier")),
    @"objectURI" : folder.objectID.URIRepresentation.absoluteString,
    @"title" : OrNull(StringAttr(folder, @"title")),
    @"folderType" : @(FolderKind(folder)),
    @"accountIdentifier" : OrNull(account ? StringAttr(account, @"identifier") : nil),
    @"parentIdentifier" : OrNull(parent ? StringAttr(parent, @"identifier") : nil),
    @"queryJSON" : OrNull(CanonicalQueryText(raw) ?: raw),
    @"markedForDeletion" : @(BoolAttr(folder, @"markedForDeletion")),
    @"childFolderCount" : @(children),
    @"physicalNoteCount" : @(notes),
    @"titleDurability" : [[folder valueForKey:@"dateForLastTitleModification"] isKindOfClass:[NSDate class]]
        ? @"stamped"
        : @"missing",
    @"parentDurability" : parent ? ([[folder valueForKey:@"parentModificationDate"] isKindOfClass:[NSDate class]]
                                        ? @"stamped"
                                        : @"missing")
                                 : [NSNull null],
    @"revision" : FolderRevision(folder, children, notes),
    @"cloudSync" : FolderCloudSyncState(folder),
  };
}

static NSArray<NSManagedObject *> *ActiveFoldersTitled(NSManagedObjectContext *context, NSString *title,
                                                       NSManagedObject *account, NSManagedObject *parent) {
  NSMutableArray *matches = [NSMutableArray array];
  for (NSManagedObject *folder in
       FetchRows(context, @"ICFolder",
                 [NSPredicate predicateWithFormat:@"account == %@ AND title == %@", account, title])) {
    if (BoolAttr(folder, @"markedForDeletion")) continue;
    id folderParent = [folder valueForKey:@"parent"];
    BOOL sameParent = parent ? [[folderParent objectID] isEqual:parent.objectID] : folderParent == nil;
    if (sameParent) [matches addObject:folder];
  }
  return matches;
}

// Before any save, the context may hold only the changes this action means
// to make. A NotesShared factory or setter that touches anything else makes
// the write refuse instead of saving side effects nobody reviewed.
static void RequireExpectedChanges(NSManagedObjectContext *context, NSArray<NSManagedObject *> *allowed,
                                   NSSet<NSString *> *allowedInsertedEntities) {
  [context processPendingChanges];
  NSMutableSet *allowedIDs = [NSMutableSet set];
  for (NSManagedObject *object in allowed)
    if (object) [allowedIDs addObject:object.objectID];
  NSMutableArray *unexpected = [NSMutableArray array];
  for (NSManagedObject *object in context.deletedObjects)
    [unexpected addObject:[@"deleted " stringByAppendingString:object.entity.name]];
  for (NSManagedObject *object in context.insertedObjects)
    if (![allowedIDs containsObject:object.objectID] &&
        ![allowedInsertedEntities containsObject:object.entity.name])
      [unexpected addObject:[@"inserted " stringByAppendingString:object.entity.name]];
  for (NSManagedObject *object in context.updatedObjects) {
    if ([allowedIDs containsObject:object.objectID]) continue;
    // Cloud-state rows belong to the object whose change count moved.
    if ([object.entity.name isEqualToString:@"ICCloudState"]) continue;
    [unexpected addObject:[@"updated " stringByAppendingString:object.entity.name]];
  }
  if (unexpected.count) {
    [context rollback];
    Fail(@"unexpected_changes", @"NotesShared staged changes beyond the requested write; nothing was saved",
         @{@"committed" : @NO, @"unexpected" : unexpected});
  }
}

static void SaveFolderOrFail(NSManagedObjectContext *context) {
  NSError *saveError = nil;
  gSaveAttempted = YES;
  if (![context save:&saveError]) {
    [context rollback];
    BOOL conflict =
        saveError.code == NSManagedObjectMergeError || saveError.code == NSPersistentStoreSaveConflictsError;
    Fail(conflict ? @"revision_conflict" : @"save_failed",
         conflict ? @"Notes changed the folder during the write; nothing was saved"
                  : @"The Core Data save failed; nothing was saved",
         @{@"committed" : @NO, @"detail" : OrNull(saveError.localizedDescription)});
  }
}

// The writer never uploads (see HandleAppendPlainText). `saved` NO means the
// call wrote nothing, so there is nothing for Notes.app to push.
static NSDictionary *FolderPushFields(StoreLocation store, BOOL saved) {
  BOOL hostRunning = NotesAppRunning();
  return @{
    @"pushScheduled" : @NO,
    @"syncHostRunning" : @(hostRunning),
    @"pushState" : saved ? (hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch") : @"not_applicable",
    @"storeKind" : store.isCopy ? @"copy" : @"live",
  };
}

// Re-reads the folder through a brand-new read-only stack and checks every
// persisted fact the write promised. Returns the fresh state or sets
// *errorOut; never trusts the writing context.
static NSDictionary *VerifySmartFolder(StoreLocation store, NSString *identifier, NSString *title,
                                       NSString *queryJSON, NSString *accountIdentifier,
                                       NSString *parentIdentifier, NSString **errorOut) {
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *folder = FetchByIdentifier(fresh, @"ICFolder", identifier);
    NSDictionary *state = FolderState(folder, fresh);
    NSString *problem = nil;
    if (![state[@"title"] isEqual:title])
      problem = @"title";
    else if ([state[@"folderType"] integerValue] != 2)
      problem = @"folderType";
    else if (![state[@"queryJSON"] isEqual:queryJSON])
      problem = @"query";
    else if (![state[@"accountIdentifier"] isEqual:accountIdentifier])
      problem = @"account";
    else if (![state[@"parentIdentifier"] isEqual:OrNull(parentIdentifier)])
      problem = @"parent";
    else if ([state[@"markedForDeletion"] boolValue])
      problem = @"deletion flag";
    else if (![state[@"titleDurability"] isEqual:@"stamped"])
      problem = @"title timestamp";
    else if (parentIdentifier && ![state[@"parentDurability"] isEqual:@"stamped"])
      problem = @"parent timestamp";
    if (!problem) {
      id query = Send(folder, "smartFolderQueryObjC");
      if (!query || !Send(query, "predicate")) problem = @"native parse of the stored query";
    }
    if (problem) {
      *errorOut = [NSString stringWithFormat:@"The persisted smart folder does not match the request (%@)", problem];
      return nil;
    }
    return state;
  } @catch (HelperError *e) {
    *errorOut = e.reason;
    return nil;
  }
}

static void FailFolderVerification(NSString *message, NSString *identifier, NSString *revisionBefore) {
  Fail(@"verification_failed", message ?: @"Read-back failed", @{
    @"committed" : @YES,
    @"identifier" : OrNull(identifier),
    @"revisionBefore" : OrNull(revisionBefore)
  });
}

static NSString *OptionalString(NSDictionary *request, NSString *key) {
  id value = request[key];
  if (!value) return nil;
  if (![value isKindOfClass:[NSString class]] || ![value length])
    Fail(@"invalid_request", [NSString stringWithFormat:@"`%@` must be a non-empty string", key], nil);
  return value;
}

static NSString *RequireFolderRevision(NSDictionary *request) {
  NSString *value = RequireString(request, @"ifRevision");
  if (![value hasPrefix:@"f1:"] || value.length != 67)
    Fail(@"invalid_request", @"`ifRevision` must be a folder revision from native-read-smart-folder", nil);
  return value;
}

// The smart folder a read, update, or delete names: a UUID, exactly one row,
// folder type 2.
static NSManagedObject *FetchSmartFolder(NSManagedObjectContext *context, NSString *identifier) {
  NSManagedObject *folder = FetchByIdentifier(context, @"ICFolder", identifier);
  if (FolderKind(folder) != 2)
    Fail(@"unsupported_folder", @"That folder is not a smart folder", @{@"folderType" : @(FolderKind(folder))});
  return folder;
}

#pragma mark Smart folder actions

static NSDictionary *HandleReadSmartFolder(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  RequireFeature(FeatureSmartFolders);
  NSManagedObjectContext *context = OpenContext(ResolveStore(), YES);
  NSMutableDictionary *result = [FolderState(FetchSmartFolder(context, identifier), context) mutableCopy];
  result[@"status"] = @"ok";
  result[@"syncHostRunning"] = @(NotesAppRunning());
  return result;
}

// Creates a smart folder. Idempotent: an existing smart folder with the same
// title, destination, and stored query is reported without a write. There is
// no revision to compare, since the folder does not exist yet; the guard is
// the title check in the write context itself, right before the save.
static NSDictionary *HandleCreateSmartFolder(NSDictionary *request) {
  gWriteRequest = YES;
  NSString *title = RequireString(request, @"title");
  if (!IsTrimmedPlainString(title, SMART_MAX_TITLE_UTF16))
    Fail(@"invalid_request", @"`title` must be 1-256 characters with no control characters or edge whitespace",
         nil);
  NSString *queryText = RequireString(request, @"queryJSON");
  NSString *accountRef = OptionalString(request, @"account");
  NSString *parentRef = OptionalString(request, @"parentIdentifier");
  if (accountRef && parentRef) Fail(@"invalid_request", @"Pass account or parentIdentifier, not both", nil);
  RequireFeature(FeatureSmartFolders);

  StoreLocation store = ResolveStore();
  // Destination and query are resolved and validated in a read-only stack.
  NSManagedObjectContext *validation = OpenContext(store, YES);
  NSManagedObject *destinationAccount = nil, *destinationParent = nil;
  ResolveDestination(validation, accountRef, parentRef, &destinationAccount, &destinationParent);
  NSString *accountIdentifier = StringAttr(destinationAccount, @"identifier");
  NSString *parentIdentifier = destinationParent ? StringAttr(destinationParent, @"identifier") : nil;
  NSDictionary *resolution = ResolveSmartFolderQuery(queryText, destinationAccount, validation);
  NSString *queryJSON = resolution[@"queryJSON"];

  NSManagedObjectContext *context = OpenContext(store, NO);
  NSManagedObject *account = FetchByIdentifier(context, @"ICAccount", accountIdentifier);
  NSManagedObject *parent = parentIdentifier ? FetchByIdentifier(context, @"ICFolder", parentIdentifier) : nil;
  if (parent) RequireSmartFolderParent(parent);
  NSArray *existing = ActiveFoldersTitled(context, title, account, parent);
  if (existing.count > 1)
    Fail(@"ambiguous", @"More than one active folder has this exact title in the destination",
         @{@"committed" : @NO});

  NSMutableDictionary *response = [resolution mutableCopy];
  if (existing.count == 1) {
    NSManagedObject *folder = existing.firstObject;
    NSString *identifier = StringAttr(folder, @"identifier");
    if (FolderKind(folder) != 2)
      Fail(@"folder_exists", @"An ordinary folder with this title already exists in the destination",
           @{@"committed" : @NO, @"identifier" : OrNull(identifier)});
    NSString *current = StoredCanonicalQuery(folder);
    if (![current isEqualToString:queryJSON])
      Fail(@"folder_exists",
           @"A smart folder with this title has a different query; change it with native-update-smart-folder",
           @{@"committed" : @NO, @"identifier" : OrNull(identifier), @"currentQueryJSON" : OrNull(current)});
    [response addEntriesFromDictionary:FolderState(folder, context)];
    response[@"status"] = @"ok";
    response[@"changed"] = @NO;
    response[@"existing"] = @YES;
    response[@"committed"] = @NO;
    [response addEntriesFromDictionary:FolderPushFields(store, NO)];
    return response;
  }

  NSError *titleError = nil;
  BOOL titleValid = ((BOOL(*)(id, SEL, id, id, id, NSError **))objc_msgSend)(
      objc_getClass("ICFolder"), sel_registerName("isTitleValid:account:parentFolder:error:"), title, account,
      parent, &titleError);
  if (!titleValid)
    Fail(@"invalid_request", @"Notes rejects this folder title in the destination",
         @{@"committed" : @NO, @"detail" : OrNull(titleError.localizedDescription)});

  NSManagedObject *folder = parent ? Send1(objc_getClass("ICFolder"), "newFolderInParentFolder:", parent)
                                   : Send1(objc_getClass("ICFolder"), "newFolderInAccount:", account);
  if (![folder isKindOfClass:[NSManagedObject class]])
    Fail(@"private_api_unavailable", @"Notes' folder factory returned nothing", @{@"committed" : @NO});
  SendVoid1(folder, "setTitle:", title);
  SendVoid1(folder, "setSmartFolderQueryJSON:", queryJSON);
  SetFolderType(folder, 2);
  // -setTitle: and the factories leave the CloudKit last-writer-wins stamps
  // nil, which lets the first server echo revert the title or drop the
  // parent. Stamp them so the new values win.
  NSDate *now = [NSDate date];
  [folder setValue:now forKey:@"dateForLastTitleModification"];
  if (parent) [folder setValue:now forKey:@"parentModificationDate"];
  SendVoid1(folder, "updateChangeCountWithReason:", kSmartCreateReason);
  NSMutableArray *allowed = [NSMutableArray arrayWithObjects:folder, account, nil];
  if (parent) [allowed addObject:parent];
  RequireExpectedChanges(context, allowed, [NSSet setWithObject:@"ICCloudState"]);
  NSString *identifier = StringAttr(folder, @"identifier");
  SaveFolderOrFail(context);

  NSString *error = nil;
  NSDictionary *state =
      VerifySmartFolder(store, identifier, title, queryJSON, accountIdentifier, parentIdentifier, &error);
  if (!state) FailFolderVerification(error, identifier, nil);
  [response addEntriesFromDictionary:state];
  response[@"status"] = @"created";
  response[@"changed"] = @YES;
  response[@"existing"] = @NO;
  response[@"committed"] = @YES;
  response[@"verified"] = @YES;
  [response addEntriesFromDictionary:FolderPushFields(store, YES)];
  return response;
}

// Replaces one smart folder's query, guarded by its folder revision.
static NSDictionary *HandleUpdateSmartFolder(NSDictionary *request) {
  gWriteRequest = YES;
  NSString *identifier = RequireIdentifier(request);
  NSString *queryText = RequireString(request, @"queryJSON");
  NSString *ifRevision = RequireFolderRevision(request);
  RequireFeature(FeatureSmartFolders);

  StoreLocation store = ResolveStore();
  NSManagedObjectContext *validation = OpenContext(store, YES);
  NSManagedObject *current = FetchSmartFolder(validation, identifier);
  NSManagedObject *currentAccount = [current valueForKey:@"account"];
  if (!currentAccount) Fail(@"unsupported_folder", @"The smart folder has no account", nil);
  NSDictionary *resolution = ResolveSmartFolderQuery(queryText, currentAccount, validation);
  NSString *queryJSON = resolution[@"queryJSON"];

  NSManagedObjectContext *context = OpenContext(store, NO);
  NSManagedObject *folder = FetchSmartFolder(context, identifier);
  NSDictionary *before = FolderState(folder, context);
  NSString *revisionBefore = before[@"revision"];
  if (![revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The smart folder changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : revisionBefore});
  if ([before[@"markedForDeletion"] boolValue])
    Fail(@"unsupported_folder", @"The smart folder is deleted", @{@"committed" : @NO});

  NSMutableDictionary *response = [resolution mutableCopy];
  NSString *previous = StoredCanonicalQuery(folder);
  if ([previous isEqualToString:queryJSON]) {
    [response addEntriesFromDictionary:before];
    response[@"status"] = @"ok";
    response[@"changed"] = @NO;
    response[@"committed"] = @NO;
    response[@"revisionBefore"] = revisionBefore;
    response[@"revisionAfter"] = revisionBefore;
    [response addEntriesFromDictionary:FolderPushFields(store, NO)];
    return response;
  }
  SendVoid1(folder, "setSmartFolderQueryJSON:", queryJSON);
  if (![[folder valueForKey:@"dateForLastTitleModification"] isKindOfClass:[NSDate class]])
    [folder setValue:[NSDate date] forKey:@"dateForLastTitleModification"];
  id parent = [folder valueForKey:@"parent"];
  if (parent && ![[folder valueForKey:@"parentModificationDate"] isKindOfClass:[NSDate class]])
    [folder setValue:[NSDate date] forKey:@"parentModificationDate"];
  SendVoid1(folder, "updateChangeCountWithReason:", kSmartUpdateReason);
  RequireExpectedChanges(context, @[ folder ], [NSSet set]);
  SaveFolderOrFail(context);

  NSString *error = nil;
  NSDictionary *state = VerifySmartFolder(store, identifier, before[@"title"], queryJSON,
                                          before[@"accountIdentifier"],
                                          parent ? before[@"parentIdentifier"] : nil, &error);
  if (!state) FailFolderVerification(error, identifier, revisionBefore);
  [response addEntriesFromDictionary:state];
  response[@"status"] = @"updated";
  response[@"changed"] = @YES;
  response[@"committed"] = @YES;
  response[@"verified"] = @YES;
  response[@"previousQueryJSON"] = OrNull(previous);
  response[@"revisionBefore"] = revisionBefore;
  response[@"revisionAfter"] = state[@"revision"];
  [response addEntriesFromDictionary:FolderPushFields(store, YES)];
  return response;
}

// Deletes one empty smart folder. Two phases: the dry run opens the store
// read-only and returns the plan with the folder revision; the apply must
// present it as ifRevision.
static NSDictionary *HandleDeleteSmartFolder(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  id dryRunValue = request[@"dryRun"];
  if (!IsJSONBool(dryRunValue)) Fail(@"invalid_request", @"`dryRun` must be true or false", nil);
  BOOL dryRun = [dryRunValue boolValue];
  NSString *ifRevision = nil;
  if (dryRun && request[@"ifRevision"])
    Fail(@"invalid_request", @"`ifRevision` is only accepted with dryRun false", nil);
  if (!dryRun) {
    gWriteRequest = YES;
    ifRevision = RequireFolderRevision(request);
  }
  RequireFeature(FeatureSmartFolders);

  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, dryRun);
  NSManagedObject *folder = FetchSmartFolder(context, identifier);
  NSDictionary *plan = FolderState(folder, context);
  if ([plan[@"markedForDeletion"] boolValue])
    Fail(@"unsupported_folder", @"The smart folder is already deleted", nil);
  if ([plan[@"childFolderCount"] integerValue] != 0)
    Fail(@"unsupported_folder", @"The smart folder has child folders", nil);
  if ([plan[@"physicalNoteCount"] integerValue] != 0)
    Fail(@"unsupported_folder", @"Notes are physically stored in this folder; it is not an empty smart folder",
         nil);
  NSString *revisionBefore = plan[@"revision"];
  if (dryRun) {
    NSMutableDictionary *response = [plan mutableCopy];
    response[@"status"] = @"planned";
    response[@"dryRun"] = @YES;
    response[@"committed"] = @NO;
    return response;
  }
  if (![revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The smart folder changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : revisionBefore});

  SendVoid(folder, "markForDeletion");
  if (!BoolAttr(folder, @"markedForDeletion")) {
    [context rollback];
    Fail(@"save_failed", @"Notes did not mark the folder for deletion; nothing was saved", @{@"committed" : @NO});
  }
  SendVoid1(folder, "updateChangeCountWithReason:", kSmartDeleteReason);
  id account = [folder valueForKey:@"account"];
  id parent = [folder valueForKey:@"parent"];
  NSMutableArray *allowed = [NSMutableArray arrayWithObject:folder];
  if (account) [allowed addObject:account];
  if (parent) [allowed addObject:parent];
  RequireExpectedChanges(context, allowed, [NSSet set]);
  SaveFolderOrFail(context);

  // Tombstone proof through a new stack: same row, same identity and
  // destination, now marked for deletion, and still empty.
  NSString *problem = nil;
  NSDictionary *after = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    after = FolderState(FetchByIdentifier(fresh, @"ICFolder", identifier), fresh);
    if (![after[@"markedForDeletion"] boolValue])
      problem = @"not marked for deletion";
    else if (![after[@"title"] isEqual:plan[@"title"]] ||
             ![after[@"accountIdentifier"] isEqual:plan[@"accountIdentifier"]] ||
             ![after[@"parentIdentifier"] isEqual:plan[@"parentIdentifier"]])
      problem = @"identity or destination changed";
    else if ([after[@"childFolderCount"] integerValue] || [after[@"physicalNoteCount"] integerValue])
      problem = @"gained contents";
  } @catch (HelperError *e) {
    problem = e.reason;
  }
  if (problem)
    FailFolderVerification([NSString stringWithFormat:@"Tombstone read-back failed: %@", problem], identifier,
                           revisionBefore);
  NSMutableDictionary *response = [after mutableCopy];
  response[@"status"] = @"deleted";
  response[@"dryRun"] = @NO;
  response[@"committed"] = @YES;
  response[@"verified"] = @YES;
  response[@"revisionBefore"] = revisionBefore;
  response[@"revisionAfter"] = after[@"revision"];
  [response addEntriesFromDictionary:FolderPushFields(store, YES)];
  return response;
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
      if (gWriteRequest && !gSaveAttempted && !out[@"committed"]) out[@"committed"] = @NO;
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
