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
//     -framework AppKit -framework PencilKit -DHELPER_SOURCE_SHA256='"<sha256 of this file>"' \
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
#import <PencilKit/PencilKit.h>
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

// An embedded Info.plist gives the writer a bundle identifier. PencilKit
// needs one to build a PKDrawing (add_paper): it records its CRDT replica
// identity in the process's preferences domain and traps when there is none.
// The domain is ~/Library/Preferences/io.github.apple-notes-mcp.private-writer.plist.
__attribute__((used, section("__TEXT,__info_plist"))) static const char kInfoPlist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>"
    "<key>CFBundleIdentifier</key><string>io.github.apple-notes-mcp.private-writer</string>"
    "<key>CFBundleName</key><string>apple-notes-private-writer</string>"
    "</dict></plist>\n";

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

typedef NS_ENUM(NSInteger, Feature) { FeatureModel, FeatureRead, FeatureAppend };

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
  if (feature >= FeatureAppend)
    [missing addObjectsFromArray:MissingAPI(kAppendAPI, COUNT(kAppendAPI))];
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
static NSDictionary *HandleAddPaper(NSDictionary *request);
static NSDictionary *PaperWriteFeatureReport(BOOL contextOK, NSString *contextReason);

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
    {"add_paper", "identifier,ifRevision,drawing,format,dryRun", HandleAddPaper},
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
      @"addPaper" : PaperWriteFeatureReport(contextOK, contextReason),
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

#pragma mark - Paper authoring

// add_paper appends one drawing to the end of a note as a new attachment:
// a Paper drawing (com.apple.paper), or a classic drawing (com.apple.drawing.2)
// when Paper cannot be created or the caller asks for one. The drawing is built
// from caller strokes as a public PKDrawing and handed to NotesShared, which
// creates the attachment through its own model. Nothing here writes SQL or
// Paper bundle bytes itself.
//
// Paper keeps its drawing in a bundle on disk,
// `Accounts/<account>/Paper/Bundles/<attachment>.bundle`, beside the store.
// Two rules keep the live container safe:
// - On a copy store every ICAccount directory method is redirected beside the
//   copy for the life of the process, so the bundle and any preview land
//   there, never in the live container.
// - Verification of a live Paper write decodes a private temporary copy of the
//   new bundle, so the read-back never opens or checkpoints the live bundle.

#define MAX_AUTHOR_STROKES 4096
#define MAX_AUTHOR_POINTS 100000
#define MAX_AUTHOR_COORDINATE 1000000.0
#define MAX_AUTHOR_WIDTH 8192.0
#define MAX_PAPER_BUNDLE_FILES 2048
#define MAX_PAPER_BUNDLE_BYTES (512LL * 1024 * 1024)

static NSString *const kPaperChangeReason = @"apple-notes-mcp add_paper";
static NSString *const kPaperUTI = @"com.apple.paper";
static NSString *const kInlineDrawingUTI = @"com.apple.drawing.2";
static NSString *const kLegacyDrawingUTI = @"com.apple.drawing";

// Inks whose identifier survives PencilKit's serialization on macOS 27. The
// monoline ink is stored as pen there and the reed ink is not recognized, so
// neither is offered: a stroke must come back as the ink that was asked for.
static const char *const kAuthorInks[] = {"pen", "pencil", "marker", "fountainpen", "watercolor", "crayon"};

// What the read-back needs to decode the saved drawing.
static const APIRequirement kPaperDecodeAPI[] = {
    {"ICSystemPaperDrawingsHelper", "drawingsForAttachment:", YES},
    {"ICAttachment", "typeUTIIsSystemPaper:", YES},
    {"PKDrawing", "strokes", NO},
    {"PKStroke", "path", NO},
};

static const ModelRequirement kPaperModelProperties[] = {
    {"ICAttachment", "identifier,typeUTI,note"},
};

// Every ICAccount method that yields a directory Notes reads or writes
// attachment files under, with the subdirectory it maps to inside a sandbox
// root. All of them are redirected together or not at all.
typedef struct {
  const char *sel;
  const char *suffix;
} AccountDirectory;

static const AccountDirectory kAccountDirectories[] = {
    {"accountFilesDirectoryURL", ""},
    {"accountFilesDirectoryURLInApplicationDataContainer", ""},
    {"systemPaperDirectoryURL", "Paper"},
    {"systemPaperBundlesDirectoryURL", "Paper/Bundles"},
    {"systemPaperTemporaryDirectoryURL", "Paper/Temporary"},
    {"fallbackImageDirectoryURL", "FallbackImages"},
    {"fallbackPDFDirectoryURL", "FallbackPDFs"},
    {"previewImageDirectoryURL", "Previews"},
    {"mediaDirectoryURL", "Media"},
    {"exportableMediaDirectoryURL", "ExportableMedia"},
    {"temporaryDirectoryURL", "Temporary"},
};

// Common to both attachment formats.
static const APIRequirement kPaperWriteAPI[] = {
    {"ICNote", "rangeForAttachment:", NO},
    {"ICNote", "beginEditing", NO},
    {"ICNote", "endEditing", NO},
    {"ICTTAttachment", "setAttachmentIdentifier:", NO},
    {"ICTTAttachment", "setAttachmentUTI:", NO},
    {"ICAttachment", "updateChangeCountWithReason:", NO},
    {"PKDrawing", "initWithStrokes:", NO},
    {"PKStroke", "initWithInk:strokePath:transform:mask:", NO},
    {"PKStrokePath", "initWithControlPoints:creationDate:", NO},
    {"PKStrokePoint", "initWithLocation:timeOffset:size:opacity:force:azimuth:altitude:", NO},
    {"PKInk", "initWithInkType:color:", NO},
};

static const APIRequirement kPaperFormatAPI[] = {
    {"ICPaperAttachmentCreationHelper", "createSystemPaperAttachmentWithPKDrawing:inNote:", YES},
    {"ICAttachment", "paperBundleURL", NO},
};

static const APIRequirement kInlineDrawingFormatAPI[] = {
    {"ICNote", "addInlineDrawingAttachmentWithAnalytics:", NO},
    {"ICAttachment", "setMergeableData:", NO},
    {"ICAttachment", "inlineDrawingModel", NO},
    {"ICAttachmentInlineDrawingModel", "newDrawingFromMergeableData", NO},
};

// Everything add_paper needs except the attachment format itself.
static NSArray<NSString *> *MissingForPaperWrite(void) {
  NSMutableArray *missing = [MissingForFeature(FeatureAppend) mutableCopy];
  if (!gFrameworkLoaded) return missing;
  [missing addObjectsFromArray:MissingAPI(kPaperDecodeAPI, COUNT(kPaperDecodeAPI))];
  [missing addObjectsFromArray:MissingAPI(kPaperWriteAPI, COUNT(kPaperWriteAPI))];
  [missing addObjectsFromArray:MissingModelPropertiesIn(kPaperModelProperties, COUNT(kPaperModelProperties))];
  Class account = objc_getClass("ICAccount");
  for (size_t i = 0; i < COUNT(kAccountDirectories); i++)
    if (!account || ![account instancesRespondToSelector:sel_registerName(kAccountDirectories[i].sel)])
      [missing addObject:[NSString stringWithFormat:@"-[ICAccount %s]", kAccountDirectories[i].sel]];
  return [[NSOrderedSet orderedSetWithArray:missing] array];
}

static NSArray<NSString *> *AvailablePaperFormats(void) {
  NSMutableArray *formats = [NSMutableArray array];
  if (!gFrameworkLoaded) return formats;
  if (!MissingAPI(kPaperFormatAPI, COUNT(kPaperFormatAPI)).count) [formats addObject:@"paper"];
  if (!MissingAPI(kInlineDrawingFormatAPI, COUNT(kInlineDrawingFormatAPI)).count) [formats addObject:@"drawing"];
  return formats;
}

static NSDictionary *PaperWriteFeatureReport(BOOL contextOK, NSString *contextReason) {
  NSMutableArray *missing = [MissingForPaperWrite() mutableCopy];
  NSArray *formats = AvailablePaperFormats();
  if (!formats.count && gFrameworkLoaded) {
    [missing addObjectsFromArray:MissingAPI(kPaperFormatAPI, COUNT(kPaperFormatAPI))];
    [missing addObjectsFromArray:MissingAPI(kInlineDrawingFormatAPI, COUNT(kInlineDrawingFormatAPI))];
  }
  if (missing.count)
    return @{@"available" : @NO, @"reason" : @"private_api_unavailable", @"missing" : missing, @"formats" : formats};
  if (!contextOK)
    return @{
      @"available" : @NO,
      @"reason" : contextReason ?: @"store_unavailable",
      @"missing" : @[],
      @"formats" : formats
    };
  return @{@"available" : @YES, @"reason" : [NSNull null], @"missing" : @[], @"formats" : formats};
}

static BOOL IsSafePathComponent(NSString *value) {
  if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 128) return NO;
  NSCharacterSet *allowed = [NSCharacterSet
      characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."];
  if ([value rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
  return ![value isEqualToString:@"."] && ![value isEqualToString:@".."];
}

static NSString *gSandboxRoot = nil;

static NSURL *SandboxedAccountDirectory(id self, SEL _cmd) {
  NSString *account = nil;
  @try {
    account = [self valueForKey:@"identifier"];
  } @catch (NSException *e) {
    account = nil;
  }
  // Called from inside NotesShared, so this cannot throw a HelperError. An
  // unsafe identifier maps to a directory that cannot collide with a real
  // account, which makes the caller fail rather than escape the sandbox.
  NSString *component = IsSafePathComponent(account) ? account : @"invalid-account";
  NSString *suffix = @"";
  for (size_t i = 0; i < COUNT(kAccountDirectories); i++)
    if (sel_isEqual(_cmd, sel_registerName(kAccountDirectories[i].sel))) suffix = @(kAccountDirectories[i].suffix);
  NSString *path = [[[gSandboxRoot stringByAppendingPathComponent:@"Accounts"] stringByAppendingPathComponent:component]
      stringByAppendingPathComponent:suffix];
  [NSFileManager.defaultManager createDirectoryAtPath:path
                          withIntermediateDirectories:YES
                                           attributes:@{NSFilePosixPermissions : @0700}
                                                error:NULL];
  return [NSURL fileURLWithPath:path isDirectory:YES];
}

// Points every ICAccount directory at `root` for the rest of this process.
// Resolves every method before replacing the first: a partial redirect could
// leave one path pointing into the live Notes container.
static void InstallAccountSandbox(NSString *root) {
  if (gSandboxRoot) {
    if (![gSandboxRoot isEqualToString:root])
      Fail(@"internal_error", @"The account sandbox is already installed elsewhere", @{@"committed" : @NO});
    return;
  }
  Class account = objc_getClass("ICAccount");
  Method methods[COUNT(kAccountDirectories)];
  for (size_t i = 0; i < COUNT(kAccountDirectories); i++) {
    methods[i] = account ? class_getInstanceMethod(account, sel_registerName(kAccountDirectories[i].sel)) : NULL;
    if (!methods[i])
      Fail(@"private_api_unavailable", @"An ICAccount directory method is missing; refusing to run unsandboxed",
           @{@"missing" : @[ @(kAccountDirectories[i].sel) ], @"committed" : @NO});
  }
  gSandboxRoot = [root copy];
  for (size_t i = 0; i < COUNT(kAccountDirectories); i++)
    method_setImplementation(methods[i], (IMP)SandboxedAccountDirectory);
}

// A private 0700 temporary directory, removed by the caller.
static NSString *MakePrivateTempDir(NSString *prefix) {
  NSString *template =
      [NSTemporaryDirectory() stringByAppendingPathComponent:[prefix stringByAppendingString:@".XXXXXX"]];
  char *buffer = strdup(template.fileSystemRepresentation);
  char *made = mkdtemp(buffer);
  NSString *path =
      made ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:made length:strlen(made)] : nil;
  free(buffer);
  if (!path) Fail(@"internal_error", @"Could not create a private temporary directory", nil);
  chmod(path.fileSystemRepresentation, 0700);
  return path;
}

// Size and modification time of every regular file in a bundle, refusing
// links and anything that is not a regular file or directory.
static NSDictionary *BundleSignature(NSString *bundle) {
  NSMutableDictionary *signature = [NSMutableDictionary dictionary];
  long long total = 0;
  NSDirectoryEnumerator *walker = [NSFileManager.defaultManager enumeratorAtPath:bundle];
  for (NSString *relative in walker) {
    NSDictionary *attrs = walker.fileAttributes;
    NSString *type = attrs.fileType;
    if ([type isEqualToString:NSFileTypeDirectory]) continue;
    if (![type isEqualToString:NSFileTypeRegular])
      Fail(@"unsupported_attachment", @"The Paper bundle contains a link or special file", nil);
    total += (long long)attrs.fileSize;
    if (signature.count >= MAX_PAPER_BUNDLE_FILES || total > MAX_PAPER_BUNDLE_BYTES)
      Fail(@"unsupported_attachment", @"The Paper bundle exceeds the writer's size limits", nil);
    signature[relative] =
        [NSString stringWithFormat:@"%llu:%.6f", attrs.fileSize, attrs.fileModificationDate.timeIntervalSince1970];
  }
  return signature;
}

// Copies one Paper bundle from the store's container into the sandbox. The
// bundle directory must sit exactly at Accounts/<account>/Paper/Bundles/ under
// the store's directory with no link on the way, and must be unchanged across
// the copy (Notes may be writing it); a moving bundle is retried, then refused.
static void SnapshotPaperBundle(NSString *storePath, NSString *account, NSString *attachment, NSString *sandbox) {
  if (!IsSafePathComponent(account) || !IsSafePathComponent(attachment))
    Fail(@"unsupported_attachment", @"The attachment's account or identifier is not a safe path component", nil);
  NSString *relative = [NSString stringWithFormat:@"Accounts/%@/Paper/Bundles/%@.bundle", account, attachment];
  NSString *containerDir = [[storePath stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
  NSString *source = [containerDir stringByAppendingPathComponent:relative];
  if (![[source stringByResolvingSymlinksInPath] isEqualToString:source])
    Fail(@"unsupported_attachment", @"The Paper bundle path contains a link", nil);
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:source isDirectory:&isDir] || !isDir)
    Fail(@"bundle_unavailable", @"The new Paper bundle is not where NotesShared keeps it", nil);
  NSString *destination = [sandbox stringByAppendingPathComponent:relative];
  [NSFileManager.defaultManager createDirectoryAtPath:[destination stringByDeletingLastPathComponent]
                          withIntermediateDirectories:YES
                                           attributes:@{NSFilePosixPermissions : @0700}
                                                error:NULL];
  for (int attempt = 0; attempt < 3; attempt++) {
    NSDictionary *before = BundleSignature(source);
    [NSFileManager.defaultManager removeItemAtPath:destination error:NULL];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:&error])
      Fail(@"bundle_unavailable", @"Could not copy the Paper bundle", @{@"detail" : OrNull(error.localizedDescription)});
    if ([before isEqualToDictionary:BundleSignature(source)]) return;
    usleep(200000);
  }
  Fail(@"store_busy", @"The Paper bundle kept changing while it was copied", nil);
}

static BOOL IsPaperAttachment(NSManagedObject *attachment) {
  NSString *uti = [attachment valueForKey:@"typeUTI"];
  return [uti isKindOfClass:[NSString class]] && [uti isEqualToString:kPaperUTI] &&
         ((BOOL(*)(id, SEL, id))objc_msgSend)(objc_getClass("ICAttachment"), sel_registerName("typeUTIIsSystemPaper:"),
                                              uti);
}

static BOOL IsInlineDrawingAttachment(NSManagedObject *attachment) {
  NSString *uti = [attachment valueForKey:@"typeUTI"];
  return [uti isKindOfClass:[NSString class]] &&
         ([uti isEqualToString:kInlineDrawingUTI] || [uti isEqualToString:kLegacyDrawingUTI]);
}

// A classic drawing keeps its PKDrawing in the attachment's mergeable data in
// the store; its inline drawing model deserializes it.
static PKDrawing *InlineDrawingForAttachment(NSManagedObject *attachment) {
  SEL drawingSel = sel_registerName("newDrawingFromMergeableData");
  id model = [attachment respondsToSelector:sel_registerName("inlineDrawingModel")]
                 ? Send(attachment, "inlineDrawingModel")
                 : nil;
  if (!model || ![model respondsToSelector:drawingSel])
    Fail(@"private_api_unavailable", @"The inline drawing model cannot deserialize its drawing",
         @{@"missing" : @[ @"-[ICAttachmentInlineDrawingModel newDrawingFromMergeableData]" ]});
  id drawing = ((id(*)(id, SEL))objc_msgSend)(model, drawingSel);
  return [drawing isKindOfClass:[PKDrawing class]] ? drawing : nil;
}

static NSArray<PKDrawing *> *DrawingsForAttachment(NSManagedObject *attachment) {
  if (IsInlineDrawingAttachment(attachment)) {
    PKDrawing *drawing = InlineDrawingForAttachment(attachment);
    return drawing ? @[ drawing ] : @[];
  }
  if (!IsPaperAttachment(attachment)) return @[];
  id value = ((id(*)(id, SEL, id))objc_msgSend)(objc_getClass("ICSystemPaperDrawingsHelper"),
                                                sel_registerName("drawingsForAttachment:"), attachment);
  if ([value isKindOfClass:[PKDrawing class]]) return @[ value ];
  if (![value isKindOfClass:[NSArray class]]) return @[];
  NSMutableArray *drawings = [NSMutableArray array];
  for (id item in value)
    if ([item isKindOfClass:[PKDrawing class]]) [drawings addObject:item];
  return drawings;
}

static double Round4(double value) { return round(value * 10000.0) / 10000.0; }

static NSArray *RectArray(CGRect rect) {
  if (CGRectIsNull(rect) || CGRectIsInfinite(rect)) return @[ @0, @0, @0, @0 ];
  return @[ @(Round4(rect.origin.x)), @(Round4(rect.origin.y)), @(Round4(rect.size.width)), @(Round4(rect.size.height)) ];
}

static BOOL IsJSONNumber(id value) {
  return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
         isfinite([value doubleValue]);
}

static double NumberIn(id value, double lo, double hi, NSString *what) {
  if (!IsJSONNumber(value) || [value doubleValue] < lo || [value doubleValue] > hi)
    Fail(@"invalid_request", [NSString stringWithFormat:@"%@ must be a finite number from %g to %g", what, lo, hi],
         @{@"committed" : @NO});
  return [value doubleValue];
}

static PKStrokePoint *AuthorPoint(CGPoint location, NSUInteger index, double width) {
  return [[PKStrokePoint alloc] initWithLocation:location
                                      timeOffset:0.01 * (double)index
                                            size:CGSizeMake(width, width)
                                         opacity:1
                                           force:1
                                         azimuth:0
                                        altitude:M_PI_2];
}

// Validates the normalized drawing and builds the PKDrawing. Every stroke is
// {ink, color: [r,g,b,a] 0..1, width, points: [[x,y] or [x,y,width], ...]}.
// Nothing is inferred: a missing or malformed field is an error. Runs before
// the store is opened, so every refusal here has committed: false.
static PKDrawing *DrawingFromSpec(id spec, NSUInteger *pointsOut, NSMutableSet *inksOut) {
  NSDictionary *notCommitted = @{@"committed" : @NO};
  if (![spec isKindOfClass:[NSDictionary class]]) Fail(@"invalid_request", @"`drawing` must be an object", notCommitted);
  for (NSString *key in spec)
    if (![key isEqualToString:@"strokes"])
      Fail(@"invalid_request", [NSString stringWithFormat:@"Unknown drawing field `%@`", key], notCommitted);
  NSArray *strokes = spec[@"strokes"];
  if (![strokes isKindOfClass:[NSArray class]] || strokes.count == 0 || strokes.count > MAX_AUTHOR_STROKES)
    Fail(@"invalid_request", @"`drawing.strokes` must hold 1 to 4096 strokes", notCommitted);
  NSMutableArray<PKStroke *> *pkStrokes = [NSMutableArray array];
  NSUInteger totalPoints = 0;
  NSDate *created = [NSDate date];
  for (id stroke in strokes) {
    if (![stroke isKindOfClass:[NSDictionary class]])
      Fail(@"invalid_request", @"Each stroke must be an object", notCommitted);
    for (NSString *key in stroke)
      if (![@[ @"ink", @"color", @"width", @"points" ] containsObject:key])
        Fail(@"invalid_request", [NSString stringWithFormat:@"Unknown stroke field `%@`", key], notCommitted);
    NSString *ink = stroke[@"ink"];
    BOOL knownInk = NO;
    for (size_t i = 0; i < COUNT(kAuthorInks); i++)
      if ([ink isKindOfClass:[NSString class]] && [ink isEqualToString:@(kAuthorInks[i])]) knownInk = YES;
    if (!knownInk) Fail(@"invalid_request", @"Stroke `ink` is not a supported ink name", notCommitted);
    NSArray *color = stroke[@"color"];
    if (![color isKindOfClass:[NSArray class]] || color.count != 4)
      Fail(@"invalid_request", @"Stroke `color` must be [r, g, b, a] from 0 to 1", notCommitted);
    double rgba[4];
    for (int i = 0; i < 4; i++) rgba[i] = NumberIn(color[i], 0, 1, @"A color channel");
    double width = NumberIn(stroke[@"width"], 0.01, MAX_AUTHOR_WIDTH, @"Stroke `width`");
    NSArray *points = stroke[@"points"];
    if (![points isKindOfClass:[NSArray class]] || points.count == 0)
      Fail(@"invalid_request", @"Stroke `points` must be a non-empty array", notCommitted);
    totalPoints += points.count;
    if (totalPoints > MAX_AUTHOR_POINTS)
      Fail(@"invalid_request", @"The drawing has more than 100000 points", notCommitted);
    NSMutableArray<PKStrokePoint *> *pkPoints = [NSMutableArray arrayWithCapacity:points.count + 1];
    for (id point in points) {
      if (![point isKindOfClass:[NSArray class]] || ([point count] != 2 && [point count] != 3))
        Fail(@"invalid_request", @"Each point must be [x, y] or [x, y, width]", notCommitted);
      double x = NumberIn(point[0], -MAX_AUTHOR_COORDINATE, MAX_AUTHOR_COORDINATE, @"A point coordinate");
      double y = NumberIn(point[1], -MAX_AUTHOR_COORDINATE, MAX_AUTHOR_COORDINATE, @"A point coordinate");
      double w = [point count] == 3 ? NumberIn(point[2], 0.01, MAX_AUTHOR_WIDTH, @"A point width") : width;
      [pkPoints addObject:AuthorPoint(CGPointMake(x, y), pkPoints.count, w)];
    }
    // A single point becomes a dot: PencilKit needs two samples to draw it.
    if (pkPoints.count == 1) [pkPoints addObject:AuthorPoint(pkPoints[0].location, 1, pkPoints[0].size.width)];
    NSColor *nsColor = [NSColor colorWithSRGBRed:rgba[0] green:rgba[1] blue:rgba[2] alpha:rgba[3]];
    PKInk *pkInk = [[PKInk alloc] initWithInkType:[@"com.apple.ink." stringByAppendingString:ink] color:nsColor];
    PKStrokePath *path = [[PKStrokePath alloc] initWithControlPoints:pkPoints creationDate:created];
    [pkStrokes addObject:[[PKStroke alloc] initWithInk:pkInk
                                            strokePath:path
                                             transform:CGAffineTransformIdentity
                                                  mask:nil]];
    [inksOut addObject:ink];
  }
  PKDrawing *drawing = [[PKDrawing alloc] initWithStrokes:pkStrokes];
  if (drawing.strokes.count != pkStrokes.count)
    Fail(@"invalid_request", @"PencilKit did not accept every stroke", notCommitted);
  // What Notes stores is the serialized drawing: every ink must survive it.
  PKDrawing *roundTrip = [[PKDrawing alloc] initWithData:drawing.dataRepresentation error:NULL];
  if (roundTrip.strokes.count != pkStrokes.count)
    Fail(@"invalid_request", @"The drawing did not survive PencilKit serialization", notCommitted);
  for (NSUInteger i = 0; i < pkStrokes.count; i++)
    if (![roundTrip.strokes[i].ink.inkType isEqualToString:pkStrokes[i].ink.inkType])
      Fail(@"invalid_request",
           [NSString stringWithFormat:@"PencilKit on this macOS stores the %@ ink as %@", pkStrokes[i].ink.inkType,
                                      roundTrip.strokes[i].ink.inkType],
           notCommitted);
  NSUInteger built = 0;
  for (PKStroke *s in drawing.strokes) built += s.path.count;
  *pointsOut = built;
  return drawing;
}

static NSUInteger PointTotal(NSArray<PKDrawing *> *drawings, NSUInteger *strokesOut) {
  NSUInteger points = 0, strokes = 0;
  for (PKDrawing *d in drawings)
    for (PKStroke *s in d.strokes) {
      strokes++;
      points += s.path.count;
    }
  *strokesOut = strokes;
  return points;
}

// Older Notes clients read these flags to know a drawing uses newer inks.
static void SetInkFlags(id attachment, NSSet *inks) {
  id model =
      [attachment respondsToSelector:sel_registerName("paperBundleModel")] ? Send(attachment, "paperBundleModel") : nil;
  if (!model) return;
  void (^flag)(const char *) = ^(const char *sel) {
    if ([model respondsToSelector:sel_registerName(sel)])
      ((void (*)(id, SEL, BOOL))objc_msgSend)(model, sel_registerName(sel), YES);
  };
  if ([inks containsObject:@"fountainpen"]) flag("setPaperHasNewInks2022:");
  if ([inks containsObject:@"watercolor"] || [inks containsObject:@"crayon"]) flag("setPaperHasNewInks2023:");
}

// Best effort: Notes regenerates previews itself, so a failure here is only
// reported, never fatal.
static BOOL UpdatePreview(id attachment, PKDrawing *drawing) {
  SEL sel = sel_registerName(
      "updateAttachmentPreviewImageWithImageData:size:scale:appearanceType:scaleWhenDrawing:metadata:"
      "sendNotification:");
  if (![attachment respondsToSelector:sel]) return NO;
  CGRect bounds = CGRectInset(drawing.bounds, -4, -4);
  if (CGRectIsEmpty(bounds) || bounds.size.width > 8192 || bounds.size.height > 8192) return NO;
  NSImage *image = [drawing imageFromRect:bounds scale:2.0];
  CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
  if (!cg) return NO;
  NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:cg] representationUsingType:NSBitmapImageFileTypePNG
                                                                             properties:@{}];
  if (!png.length) return NO;
  @try {
    id preview = ((id(*)(id, SEL, id, CGSize, double, unsigned long long, BOOL, id, BOOL))objc_msgSend)(
        attachment, sel, png, bounds.size, 2.0, 0ULL, YES, nil, NO);
    if (preview && [preview respondsToSelector:sel_registerName("updateChangeCountWithReason:")])
      ((void (*)(id, SEL, id))objc_msgSend)(preview, sel_registerName("updateChangeCountWithReason:"),
                                            kPaperChangeReason);
    return preview != nil;
  } @catch (NSException *e) {
    return NO;
  }
}

static NSRange AttachmentRange(id note, id attachment) {
  return ((NSRange(*)(id, SEL, id))objc_msgSend)(note, sel_registerName("rangeForAttachment:"), attachment);
}

// Appends the attachment's U+FFFC glyph as the note's last paragraph. A new
// attachment is invisible in Notes until its glyph is in the note text.
// Returns the UTF-16 length inserted (0 when NotesShared already placed it).
static NSUInteger PlaceGlyph(id note, id attachment) {
  NSRange existing = AttachmentRange(note, attachment);
  if (existing.location != NSNotFound && existing.length) return 0;
  id ms = Send(note, "mergeableString");
  NSAttributedString *text = ms ? Send(ms, "attributedString") : nil;
  if (![text isKindOfClass:[NSAttributedString class]])
    Fail(@"unsupported_note", @"The note body could not be loaded as a mergeable string", @{@"committed" : @NO});
  id tt = [objc_getClass("ICTTAttachment") new];
  ((void (*)(id, SEL, id))objc_msgSend)(tt, sel_registerName("setAttachmentIdentifier:"),
                                        [attachment valueForKey:@"identifier"]);
  ((void (*)(id, SEL, id))objc_msgSend)(tt, sel_registerName("setAttachmentUTI:"), [attachment valueForKey:@"typeUTI"]);
  NSMutableAttributedString *insertion = [NSMutableAttributedString new];
  NSAttributedString *separator = SeparatorFor(text);
  if (separator) [insertion appendAttributedString:separator];
  [insertion appendAttributedString:[[NSAttributedString alloc] initWithString:@"￼"
                                                                    attributes:@{@"NSAttachment" : tt}]];
  NSUInteger at = text.length;
  SendVoid(ms, "beginEditing");
  ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertAttributedString:atIndex:"), insertion,
                                                    at);
  SendVoid(ms, "endEditing");
  ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
      note, sel_registerName("edited:range:changeInLength:"), NSTextStorageEditedCharacters,
      NSMakeRange(at, insertion.length), (NSInteger)insertion.length);
  return insertion.length;
}

// Decode the persisted drawing for verification. A live Paper bundle is read
// from a private copy; on a copy store the sandbox already points beside it.
static NSArray<PKDrawing *> *VerifiedDrawings(NSManagedObject *attachment, StoreLocation store, NSString *accountId) {
  if (!IsPaperAttachment(attachment) || store.isCopy) return DrawingsForAttachment(attachment);
  NSString *sandbox = MakePrivateTempDir(@"apple-notes-paper-verify");
  @try {
    SnapshotPaperBundle(store.path, accountId, [attachment valueForKey:@"identifier"], sandbox);
    InstallAccountSandbox(sandbox);
    return DrawingsForAttachment(attachment);
  } @finally {
    [NSFileManager.defaultManager removeItemAtPath:sandbox error:NULL];
  }
}

static NSDictionary *HandleAddPaper(NSDictionary *request) {
  NSDictionary *notCommitted = @{@"committed" : @NO};
  NSString *identifier = RequireIdentifier(request);
  NSString *ifRevision = RequireString(request, @"ifRevision");
  id dryValue = request[@"dryRun"];
  if (dryValue && CFGetTypeID((__bridge CFTypeRef)dryValue) != CFBooleanGetTypeID())
    Fail(@"invalid_request", @"`dryRun` must be a boolean", notCommitted);
  BOOL dryRun = [dryValue boolValue];
  NSString *format = request[@"format"] ?: @"auto";
  if (![format isKindOfClass:[NSString class]] || ![@[ @"auto", @"paper", @"drawing" ] containsObject:format])
    Fail(@"invalid_request", @"`format` must be auto, paper, or drawing", notCommitted);
  LoadFramework();
  NSArray *missing = MissingForPaperWrite();
  if (missing.count)
    Fail(@"private_api_unavailable", @"Required NotesShared or PencilKit API is not available on this macOS",
         @{@"missing" : missing, @"committed" : @NO});
  NSArray *formats = AvailablePaperFormats();
  NSString *chosen = [format isEqualToString:@"auto"] ? formats.firstObject : format;
  if (!chosen || ![formats containsObject:chosen])
    Fail(@"private_api_unavailable", @"That attachment format cannot be created on this macOS",
         @{@"availableFormats" : formats, @"committed" : @NO});

  NSUInteger inputPoints = 0;
  NSMutableSet *inks = [NSMutableSet set];
  PKDrawing *drawing = DrawingFromSpec(request[@"drawing"], &inputPoints, inks);

  StoreLocation store = ResolveStore();
  // On a copy store every file NotesShared writes (bundle, previews) goes
  // beside the copy, never into the live container.
  if (store.isCopy) InstallAccountSandbox([store.path stringByDeletingLastPathComponent]);
  // A dry run opens read-only. A write opens read-write, which OpenContext
  // allows on the live store only with APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1.
  NSManagedObjectContext *context = OpenContext(store, dryRun);
  NSManagedObject *note = FetchNote(context, identifier);
  RequireAppendableNote(note);
  NSString *revisionBefore = RevisionToken(note);
  if (![revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : revisionBefore});
  id account = [note valueForKey:@"account"];
  NSString *accountId = account ? [account valueForKey:@"identifier"] : nil;
  NSDictionary *plan = @{
    @"format" : chosen,
    @"availableFormats" : formats,
    @"strokeCount" : @(drawing.strokes.count),
    @"pointCount" : @(inputPoints),
    @"inks" : [[inks allObjects] sortedArrayUsingSelector:@selector(compare:)],
    @"bounds" : RectArray(drawing.bounds),
    @"revisionBefore" : revisionBefore,
    @"storeKind" : store.isCopy ? @"copy" : @"live",
  };
  if (dryRun) {
    NSMutableDictionary *out = [plan mutableCopy];
    out[@"status"] = @"planned";
    out[@"committed"] = @NO;
    return out;
  }

  id attachment = nil;
  NSString *bundlePath = nil;
  BOOL previewUpdated = NO;
  NSUInteger glyphLength = 0;
  @try {
    SendVoid(note, "beginEditing");
    if ([chosen isEqualToString:@"paper"]) {
      attachment = ((id(*)(id, SEL, id, id))objc_msgSend)(
          objc_getClass("ICPaperAttachmentCreationHelper"),
          sel_registerName("createSystemPaperAttachmentWithPKDrawing:inNote:"), drawing, note);
      NSURL *url = attachment ? Send(attachment, "paperBundleURL") : nil;
      bundlePath = [url isKindOfClass:[NSURL class]] ? url.path : nil;
      SetInkFlags(attachment, inks);
    } else {
      attachment =
          ((id(*)(id, SEL, BOOL))objc_msgSend)(note, sel_registerName("addInlineDrawingAttachmentWithAnalytics:"), NO);
      if (attachment)
        ((void (*)(id, SEL, id))objc_msgSend)(attachment, sel_registerName("setMergeableData:"),
                                              drawing.dataRepresentation);
    }
    if (!attachment) Fail(@"save_failed", @"NotesShared did not create the attachment", notCommitted);
    glyphLength = PlaceGlyph(note, attachment);
    SendVoid(note, "endEditing");
    previewUpdated = UpdatePreview(attachment, drawing);
    ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(note, sel_registerName("regenerateTitle:snippet:"), YES, YES);
    if (!SendBool(note, "saveNoteData"))
      Fail(@"save_failed", @"NotesShared did not serialize the edited body", notCommitted);
    [note setValue:[NSDate date] forKey:@"modificationDate"];
    // Bumps both cloud states so Notes treats the note and the new attachment
    // as needing upload.
    ((void (*)(id, SEL, id))objc_msgSend)(attachment, sel_registerName("updateChangeCountWithReason:"),
                                          kPaperChangeReason);
    ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("updateChangeCountWithReason:"), kPaperChangeReason);
    NSError *saveError = nil;
    if (![context save:&saveError]) {
      [context rollback];
      BOOL conflict =
          saveError.code == NSManagedObjectMergeError || saveError.code == NSPersistentStoreSaveConflictsError;
      Fail(conflict ? @"revision_conflict" : @"save_failed",
           conflict ? @"Notes changed the note during the write; nothing was saved"
                    : @"The Core Data save failed; nothing was saved",
           @{@"committed" : @NO, @"detail" : OrNull(saveError.localizedDescription)});
    }
  } @catch (HelperError *e) {
    // Nothing reached the store: remove the bundle NotesShared already wrote,
    // and only when it sits exactly where a Paper bundle belongs.
    if ([e.userInfo[@"committed"] isEqual:@NO] && bundlePath && [bundlePath hasSuffix:@".bundle"] &&
        [[bundlePath stringByDeletingLastPathComponent] hasSuffix:@"/Paper/Bundles"])
      [NSFileManager.defaultManager removeItemAtPath:bundlePath error:NULL];
    @throw;
  }

  // Fresh read-back through a brand-new read-only coordinator: the note owns
  // the attachment, its glyph is in the saved text, and the drawing decodes
  // to the same number of strokes and points.
  NSString *attachmentId = [attachment valueForKey:@"identifier"];
  NSString *typeUTI = [attachment valueForKey:@"typeUTI"];
  NSDictionary *after = nil;
  NSUInteger decodedStrokes = 0, decodedPoints = 0;
  NSString *verifyDetail = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *reread = FetchNote(fresh, identifier);
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"ICAttachment"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", attachmentId];
    NSManagedObject *freshAttachment = [[fresh executeFetchRequest:fetch error:NULL] firstObject];
    if (!freshAttachment || [freshAttachment valueForKey:@"note"] != reread)
      verifyDetail = @"The new attachment is not attached to the note after saving";
    else if (AttachmentRange(reread, freshAttachment).location == NSNotFound)
      verifyDetail = @"The attachment glyph is not in the saved note text";
    else {
      decodedPoints = PointTotal(VerifiedDrawings(freshAttachment, store, accountId), &decodedStrokes);
      if (decodedStrokes != drawing.strokes.count || decodedPoints != inputPoints)
        verifyDetail = [NSString
            stringWithFormat:@"Decoded %lu strokes / %lu points, expected %lu / %lu", (unsigned long)decodedStrokes,
                             (unsigned long)decodedPoints, (unsigned long)drawing.strokes.count,
                             (unsigned long)inputPoints];
    }
    after = NoteState(reread);
  } @catch (HelperError *e) {
    verifyDetail = e.reason;
  }
  if (verifyDetail)
    Fail(@"verification_failed", verifyDetail,
         @{@"committed" : @YES, @"attachmentIdentifier" : OrNull(attachmentId), @"revisionBefore" : revisionBefore});

  BOOL hostRunning = NotesAppRunning();
  NSMutableDictionary *out = [plan mutableCopy];
  [out addEntriesFromDictionary:@{
    @"status" : @"created",
    @"committed" : @YES,
    @"verified" : @YES,
    @"identifier" : identifier,
    @"attachmentIdentifier" : attachmentId,
    @"typeUTI" : OrNull(typeUTI),
    @"decodedStrokeCount" : @(decodedStrokes),
    @"decodedPointCount" : @(decodedPoints),
    @"glyphInserted" : @((BOOL)(glyphLength > 0)),
    @"previewUpdated" : @(previewUpdated),
    @"revisionAfter" : after[@"revision"],
    @"modificationDate" : after[@"modificationDate"],
    @"cloudSync" : after[@"cloudSync"],
    // The writer never uploads; see HandleAppendPlainText.
    @"pushScheduled" : @NO,
    @"syncHostRunning" : @(hostRunning),
    @"pushState" : hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch",
  }];
  return out;
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
