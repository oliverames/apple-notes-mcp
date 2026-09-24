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

// Structured compose: paragraph styles, checklist todos, and inline runs.
// Paragraph-style accessors are inherited by the mutable subclass, which
// instancesRespondToSelector: sees.
static const APIRequirement kComposeAPI[] = {
    {"ICTTMutableParagraphStyle", "setStyle:", NO},
    {"ICTTMutableParagraphStyle", "setIndent:", NO},
    {"ICTTMutableParagraphStyle", "setBlockQuoteLevel:", NO},
    {"ICTTMutableParagraphStyle", "setTodo:", NO},
    {"ICTTParagraphStyle", "style", NO},
    {"ICTTParagraphStyle", "indent", NO},
    {"ICTTParagraphStyle", "blockQuoteLevel", NO},
    {"ICTTParagraphStyle", "todo", NO},
    {"ICTTTodo", "initWithIdentifier:done:", NO},
    {"ICTTTodo", "done", NO},
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

static NSArray<NSString *> *MissingModelProperties(void) {
  Class container = objc_getClass("ICPersistentContainer");
  SEL modelSel = sel_registerName("managedObjectModel");
  if (!container || ![container respondsToSelector:modelSel]) return @[ @"managed object model" ];
  NSManagedObjectModel *model = ((id(*)(id, SEL))objc_msgSend)(container, modelSel);
  if (![model isKindOfClass:[NSManagedObjectModel class]]) return @[ @"managed object model" ];
  NSMutableArray *missing = [NSMutableArray array];
  for (size_t i = 0; i < COUNT(kModelProperties); i++) {
    NSEntityDescription *entity = model.entitiesByName[@(kModelProperties[i].entity)];
    if (!entity) {
      [missing addObject:[NSString stringWithFormat:@"entity %s", kModelProperties[i].entity]];
      continue;
    }
    for (NSString *name in [@(kModelProperties[i].properties) componentsSeparatedByString:@","])
      if (!entity.propertiesByName[name])
        [missing addObject:[NSString stringWithFormat:@"%s.%@", kModelProperties[i].entity, name]];
  }
  return missing;
}

// Features after FeatureAppend need the append API plus their own table,
// matched with `==` in MissingForFeature.
typedef NS_ENUM(NSInteger, Feature) { FeatureModel, FeatureRead, FeatureAppend, FeatureCompose };

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
  if (feature == FeatureCompose)
    [missing addObjectsFromArray:MissingAPI(kComposeAPI, COUNT(kComposeAPI))];
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
static NSDictionary *HandleComposeNote(NSDictionary *request);

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
    {"compose_note",
     "identifier,mode,paragraphs,ifRevision,dryRun,requireNonSystemPaper,insertBeforeHeading",
     HandleComposeNote},
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
      @"composeNote" : FeatureReport(FeatureCompose, contextOK, contextReason),
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

#pragma mark - Structured compose

// Notes stores paragraph and inline formatting as attributes on the
// mergeable string: TTStyle holds an ICTTParagraphStyle (style number,
// indent, block-quote level, checklist todo); TTHints is a bold/italic
// bitmask; TTUnderline and TTStrikethrough are flags; TTEmphasis is the named
// highlight (1-5); TTColor is a text color; NSLink is a hyperlink.
static NSString *const kStyleKey = @"TTStyle";
static NSString *const kHintsKey = @"TTHints";
static NSString *const kUnderlineKey = @"TTUnderline";
static NSString *const kStrikethroughKey = @"TTStrikethrough";
static NSString *const kEmphasisKey = @"TTEmphasis";
static NSString *const kColorKey = @"TTColor";

#define MAX_COMPOSE_PARAGRAPHS 2000
#define MAX_COMPOSE_RUNS 20000
#define MAX_COMPOSE_UTF16 200000
#define MAX_INDENT 8
#define STYLE_HEADING 1

typedef struct {
  const char *name;
  unsigned int value;
  BOOL indentable;
} StyleSpec;

// The only paragraph styles compose writes. Title (0) is never written: a
// note's title is its first paragraph, which compose does not replace.
static const StyleSpec kStyles[] = {
    {"heading", 1, NO},   {"subheading", 2, NO}, {"body", 3, YES},      {"monospaced", 4, NO},
    {"bulleted", 100, YES}, {"dashed", 101, YES},  {"numbered", 102, YES}, {"checklist", 103, YES},
};

static const char *kHighlights[] = {"purple", "pink", "orange", "mint", "blue"};  // TTEmphasis 1-5

static const StyleSpec *StyleNamed(NSString *name) {
  for (size_t i = 0; i < COUNT(kStyles); i++)
    if ([name isEqualToString:@(kStyles[i].name)]) return &kStyles[i];
  return NULL;
}

static NSString *StyleName(unsigned int value) {
  if (value == 0) return @"title";
  for (size_t i = 0; i < COUNT(kStyles); i++)
    if (kStyles[i].value == value) return @(kStyles[i].name);
  return [NSString stringWithFormat:@"style-%u", value];
}

static BOOL IsJSONBool(id value) {
  return [value isKindOfClass:[NSNumber class]] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static void RequireOnlyKeys(NSDictionary *object, NSString *allowedCSV, NSString *label) {
  NSSet *allowed = [NSSet setWithArray:[allowedCSV componentsSeparatedByString:@","]];
  for (NSString *key in object)
    if (![allowed containsObject:key])
      Fail(@"invalid_request", [NSString stringWithFormat:@"Unknown %@ field `%@`", label, key], nil);
}

static BOOL OptionalBool(NSDictionary *object, NSString *key, NSString *label) {
  id value = object[key];
  if (!value) return NO;
  if (!IsJSONBool(value))
    Fail(@"invalid_request", [NSString stringWithFormat:@"%@ `%@` must be a boolean", label, key], nil);
  return [value boolValue];
}

static NSUInteger OptionalCount(NSDictionary *object, NSString *key, NSUInteger min, NSUInteger max,
                                NSUInteger fallback, NSString *label) {
  id value = object[key];
  if (!value) return fallback;
  double number = [value isKindOfClass:[NSNumber class]] && !IsJSONBool(value) ? [value doubleValue] : -1;
  if (number != floor(number) || number < min || number > max)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"%@ `%@` must be an integer from %lu to %lu", label, key,
                                    (unsigned long)min, (unsigned long)max],
         nil);
  return (NSUInteger)number;
}

// Run text is one line of one paragraph: printable characters and tabs only.
static void ValidateRunText(NSString *text) {
  NSMutableCharacterSet *forbidden = [NSMutableCharacterSet controlCharacterSet];
  [forbidden removeCharactersInString:@"\t"];
  [forbidden addCharactersInString:@"\uFFFC\u2028\u2029"];
  if ([text rangeOfCharacterFromSet:forbidden].location != NSNotFound)
    Fail(@"invalid_request",
         @"Run `text` may contain only printable characters and tabs (no newlines, attachment "
         @"glyphs, or other control characters); each paragraph is one line",
         nil);
}

static NSURL *ValidatedLink(NSString *value) {
  NSURL *url = [NSURL URLWithString:value];
  NSString *scheme = url.scheme.lowercaseString;
  NSSet *allowed = [NSSet setWithArray:@[ @"http", @"https", @"mailto", @"tel", @"notes", @"applenotes" ]];
  if (!url || value.length > 4096 || ![allowed containsObject:scheme])
    Fail(@"invalid_request",
         @"Run `link` must be an absolute http, https, mailto, tel, notes, or applenotes URL", nil);
  return url;
}

static id ColorFromHex(NSString *hex) {
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$"
                                                                      options:0
                                                                        error:nil];
  if (![hex isKindOfClass:[NSString class]] ||
      [re numberOfMatchesInString:hex options:0 range:NSMakeRange(0, hex.length)] != 1)
    Fail(@"invalid_request", @"Run `color` must be #RRGGBB", nil);
  unsigned int rgb = 0;
  [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&rgb];
  NSColor *color = [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                                       green:((rgb >> 8) & 0xFF) / 255.0
                                        blue:(rgb & 0xFF) / 255.0
                                       alpha:1.0];
  return (__bridge id)color.CGColor;
}

static NSDictionary *RunAttributes(NSDictionary *run) {
  NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
  unsigned int hints = (OptionalBool(run, @"bold", @"Run") ? 1 : 0) |
                       (OptionalBool(run, @"italic", @"Run") ? 2 : 0);
  if (hints) attrs[kHintsKey] = @(hints);
  if (OptionalBool(run, @"underline", @"Run")) attrs[kUnderlineKey] = @1;
  if (OptionalBool(run, @"strikethrough", @"Run")) attrs[kStrikethroughKey] = @1;
  id link = run[@"link"];
  if (link) {
    if (![link isKindOfClass:[NSString class]]) Fail(@"invalid_request", @"Run `link` must be a string", nil);
    attrs[NSLinkAttributeName] = ValidatedLink(link);
  }
  id highlight = run[@"highlight"];
  if (highlight) {
    NSUInteger code = 0;
    for (size_t i = 0; i < COUNT(kHighlights); i++)
      if ([highlight isKindOfClass:[NSString class]] && [highlight isEqualToString:@(kHighlights[i])])
        code = i + 1;
    if (!code)
      Fail(@"invalid_request", @"Run `highlight` must be purple, pink, orange, mint, or blue", nil);
    attrs[kEmphasisKey] = @(code);
  }
  if (run[@"color"]) attrs[kColorKey] = ColorFromHex(run[@"color"]);
  return attrs;
}

static id NewParagraphStyle(const StyleSpec *spec, NSUInteger indent, BOOL blockQuote, id checked) {
  id style = [[objc_getClass("ICTTMutableParagraphStyle") alloc] init];
  if (!style) Fail(@"private_api_unavailable", @"Could not create a paragraph style", nil);
  ((void (*)(id, SEL, unsigned int))objc_msgSend)(style, sel_registerName("setStyle:"), spec->value);
  if (indent)
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setIndent:"), indent);
  if (blockQuote)
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setBlockQuoteLevel:"), 1);
  if (checked) {
    id todo = ((id(*)(id, SEL, id, BOOL))objc_msgSend)([objc_getClass("ICTTTodo") alloc],
                                                        sel_registerName("initWithIdentifier:done:"),
                                                        [NSUUID UUID], [checked boolValue]);
    if (!todo) Fail(@"private_api_unavailable", @"Could not create a checklist item", nil);
    ((void (*)(id, SEL, id))objc_msgSend)(style, sel_registerName("setTodo:"), todo);
  }
  return style;
}

// One composed unit: paragraphs joined by "\n". Every paragraph's TTStyle
// covers its text AND its own terminating newline, which is where Notes keeps
// a paragraph's style; the last paragraph's terminator is supplied by the
// placement (or is the end of the note).
typedef struct {
  NSMutableAttributedString *text;
  NSMutableArray<NSValue *> *ranges;  // content range of each paragraph within `text`
  NSMutableArray<NSDictionary *> *styles;  // validated paragraph-style parameters
} ComposedUnit;

// Validates the whole request and builds the text with its inline runs. Pure
// Foundation: nothing here needs NotesShared, so a malformed request fails the
// same way on every macOS. ApplyParagraphStyles adds the private styles.
static ComposedUnit BuildUnit(id paragraphsValue) {
  if (![paragraphsValue isKindOfClass:[NSArray class]] || [paragraphsValue count] == 0)
    Fail(@"invalid_request", @"`paragraphs` must be a non-empty array", nil);
  NSArray *paragraphs = paragraphsValue;
  if (paragraphs.count > MAX_COMPOSE_PARAGRAPHS)
    Fail(@"invalid_request", @"`paragraphs` exceeds 2000 entries", nil);
  ComposedUnit unit = {[NSMutableAttributedString new], [NSMutableArray array], [NSMutableArray array]};
  NSUInteger runCount = 0;
  for (NSUInteger index = 0; index < paragraphs.count; index++) {
    id value = paragraphs[index];
    if (![value isKindOfClass:[NSDictionary class]])
      Fail(@"invalid_request", @"Each paragraph must be an object", nil);
    NSDictionary *paragraph = value;
    RequireOnlyKeys(paragraph, @"style,indent,blockQuote,checked,runs", @"paragraph");
    id styleName = paragraph[@"style"];
    const StyleSpec *spec = [styleName isKindOfClass:[NSString class]] ? StyleNamed(styleName) : NULL;
    if (!spec)
      Fail(@"invalid_request",
           @"Paragraph `style` must be heading, subheading, body, monospaced, bulleted, dashed, "
           @"numbered, or checklist",
           nil);
    NSUInteger indent = OptionalCount(paragraph, @"indent", 0, MAX_INDENT, 0, @"Paragraph");
    if (indent && !spec->indentable)
      Fail(@"invalid_request", @"Only body, list, and checklist paragraphs take `indent`", nil);
    BOOL blockQuote = OptionalBool(paragraph, @"blockQuote", @"Paragraph");
    id checked = paragraph[@"checked"];
    BOOL isChecklist = spec->value == 103;
    if (isChecklist ? !IsJSONBool(checked) : checked != nil)
      Fail(@"invalid_request", @"`checked` is a required boolean on checklist paragraphs and invalid elsewhere",
           nil);
    // An empty `runs` array is a blank line. The unit's last paragraph must
    // have text: with no terminator of its own, its style needs a character.
    id runs = paragraph[@"runs"];
    if (![runs isKindOfClass:[NSArray class]] || ([runs count] == 0 && index + 1 == paragraphs.count))
      Fail(@"invalid_request", @"Paragraph `runs` must be an array, non-empty on the last paragraph", nil);
    runCount += [runs count];
    if (runCount > MAX_COMPOSE_RUNS) Fail(@"invalid_request", @"Too many runs (max 20000)", nil);

    if (unit.text.length) [unit.text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    NSUInteger start = unit.text.length;
    for (id runValue in runs) {
      if (![runValue isKindOfClass:[NSDictionary class]]) Fail(@"invalid_request", @"Each run must be an object", nil);
      NSDictionary *run = runValue;
      RequireOnlyKeys(run, @"text,bold,italic,underline,strikethrough,link,highlight,color", @"run");
      NSString *text = run[@"text"];
      if (![text isKindOfClass:[NSString class]] || text.length == 0)
        Fail(@"invalid_request", @"Run `text` must be a non-empty string", nil);
      ValidateRunText(text);
      [unit.text appendAttributedString:[[NSAttributedString alloc] initWithString:text
                                                                       attributes:RunAttributes(run)]];
      if (unit.text.length > MAX_COMPOSE_UTF16)
        Fail(@"invalid_request", @"Composed text exceeds 200000 UTF-16 code units", nil);
    }
    [unit.ranges addObject:[NSValue valueWithRange:NSMakeRange(start, unit.text.length - start)]];
    [unit.styles addObject:@{
      @"spec" : [NSValue valueWithPointer:spec],
      @"indent" : @(indent),
      @"blockQuote" : @(blockQuote),
      @"checked" : isChecklist ? checked : [NSNull null],
    }];
  }
  return unit;
}

static void ApplyParagraphStyles(ComposedUnit unit) {
  for (NSUInteger i = 0; i < unit.ranges.count; i++) {
    NSDictionary *p = unit.styles[i];
    id style = NewParagraphStyle([p[@"spec"] pointerValue], [p[@"indent"] unsignedIntegerValue],
                                 [p[@"blockQuote"] boolValue], p[@"checked"] == [NSNull null] ? nil : p[@"checked"]);
    NSRange range = unit.ranges[i].rangeValue;
    if (i + 1 < unit.ranges.count) range.length += 1;  // own terminator
    [unit.text addAttribute:kStyleKey value:style range:range];
  }
}

#pragma mark Read-back signatures

static NSString *ColorHex(id value) {
  NSColor *color = nil;
  if (CFGetTypeID((__bridge CFTypeRef)value) == CGColorGetTypeID())
    color = [NSColor colorWithCGColor:(__bridge CGColorRef)value];
  else if ([value isKindOfClass:[NSColor class]])
    color = value;
  NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!srgb) return [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
  return [NSString stringWithFormat:@"#%02lX%02lX%02lX", lround(srgb.redComponent * 255),
                                    lround(srgb.greenComponent * 255), lround(srgb.blueComponent * 255)];
}

static NSDictionary *RunSignature(NSDictionary *attrs) {
  NSMutableDictionary *sig = [NSMutableDictionary dictionary];
  unsigned int hints = [attrs[kHintsKey] unsignedIntValue];
  if (hints & 1) sig[@"bold"] = @YES;
  if (hints & 2) sig[@"italic"] = @YES;
  if ([attrs[kUnderlineKey] boolValue]) sig[@"underline"] = @YES;
  if ([attrs[kStrikethroughKey] boolValue]) sig[@"strikethrough"] = @YES;
  id link = attrs[NSLinkAttributeName];
  if (link) sig[@"link"] = [link isKindOfClass:[NSURL class]] ? [link absoluteString] : [link description];
  NSUInteger emphasis = [attrs[kEmphasisKey] unsignedIntegerValue];
  if (emphasis >= 1 && emphasis <= COUNT(kHighlights)) sig[@"highlight"] = @(kHighlights[emphasis - 1]);
  else if (emphasis) sig[@"highlight"] = @(emphasis);
  if (attrs[kColorKey]) sig[@"color"] = ColorHex(attrs[kColorKey]);
  return sig;
}

static NSDictionary *StyleSignature(id style) {
  if (!style) return @{@"style" : @"none"};
  unsigned int value = ((unsigned int (*)(id, SEL))objc_msgSend)(style, sel_registerName("style"));
  NSUInteger indent = ((NSUInteger(*)(id, SEL))objc_msgSend)(style, sel_registerName("indent"));
  NSUInteger quote = ((NSUInteger(*)(id, SEL))objc_msgSend)(style, sel_registerName("blockQuoteLevel"));
  id todo = Send(style, "todo");
  NSMutableDictionary *sig = [@{
    @"style" : StyleName(value),
    @"indent" : @(indent),
    @"blockQuote" : @((BOOL)(quote > 0)),
  } mutableCopy];
  if (todo) sig[@"checked"] = @(SendBool(todo, "done"));
  return sig;
}

// What a paragraph looks like to Notes: its paragraph style (read at its
// first character and, when it has one, at its terminator) and its inline
// runs as {length, attributes}, adjacent equal runs merged.
static NSDictionary *ParagraphSignature(NSAttributedString *string, NSRange content, BOOL hasTerminator) {
  NSMutableDictionary *sig = [StyleSignature([string attribute:kStyleKey
                                                       atIndex:content.location
                                                effectiveRange:NULL]) mutableCopy];
  if (hasTerminator)
    sig[@"terminator"] = StyleSignature([string attribute:kStyleKey
                                                  atIndex:NSMaxRange(content)
                                           effectiveRange:NULL]);
  NSMutableArray *runs = [NSMutableArray array];
  [string enumerateAttributesInRange:content
                             options:0
                          usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                            (void)stop;
                            NSDictionary *run = RunSignature(attrs);
                            NSMutableDictionary *last = runs.lastObject;
                            if (last && [last[@"attributes"] isEqual:run])
                              last[@"length"] = @([last[@"length"] unsignedIntegerValue] + range.length);
                            else
                              [runs addObject:[@{@"length" : @(range.length), @"attributes" : run} mutableCopy]];
                          }];
  sig[@"runs"] = runs;
  sig[@"lengthUTF16"] = @(content.length);
  return sig;
}

static NSArray *UnitSignatures(NSAttributedString *string, NSUInteger offset, NSArray<NSValue *> *ranges,
                               BOOL lastHasTerminator) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < ranges.count; i++) {
    NSRange range = ranges[i].rangeValue;
    range.location += offset;
    [out addObject:ParagraphSignature(string, range, i + 1 < ranges.count || lastHasTerminator)];
  }
  return out;
}

#pragma mark Placement

typedef struct {
  NSUInteger index;          // insertion point in the existing body
  NSAttributedString *prefix;  // closes the paragraph before the unit, or nil
  BOOL trailingTerminator;   // the unit needs its own closing newline
  NSUInteger headingIndex;   // for insertBeforeHeading: start of the matched heading
} Placement;

static NSUInteger StyleValueAt(NSAttributedString *string, NSUInteger index) {
  id style = [string attribute:kStyleKey atIndex:index effectiveRange:NULL];
  if (!style || ![style respondsToSelector:sel_registerName("style")]) return 3;
  return ((unsigned int (*)(id, SEL))objc_msgSend)(style, sel_registerName("style"));
}

// A newline carrying the paragraph style found at `index`, which becomes that
// paragraph's terminator.
static NSAttributedString *TerminatorFor(NSAttributedString *string, NSUInteger index) {
  id style = [string attribute:kStyleKey atIndex:index effectiveRange:NULL];
  return [[NSAttributedString alloc] initWithString:@"\n" attributes:style ? @{kStyleKey : style} : @{}];
}

static Placement ResolvePlacement(NSAttributedString *existing, NSString *mode, NSDictionary *beforeHeading) {
  NSString *body = existing.string;
  Placement p = {body.length, nil, NO, NSNotFound};
  if (beforeHeading) {
    NSString *text = beforeHeading[@"text"];
    NSUInteger occurrence = OptionalCount(beforeHeading, @"occurrence", 1, 100000, 1, @"insertBeforeHeading");
    NSUInteger expected = OptionalCount(beforeHeading, @"expectedCount", 1, 100000, 1, @"insertBeforeHeading");
    NSMutableArray<NSNumber *> *matches = [NSMutableArray array];
    [body enumerateSubstringsInRange:NSMakeRange(0, body.length)
                             options:NSStringEnumerationByParagraphs
                          usingBlock:^(NSString *line, NSRange range, NSRange enclosing, BOOL *stop) {
                            (void)enclosing;
                            (void)stop;
                            if (range.length && [line isEqualToString:text] &&
                                StyleValueAt(existing, range.location) == STYLE_HEADING)
                              [matches addObject:@(range.location)];
                          }];
    if (matches.count != expected || occurrence > matches.count)
      Fail(@"selector_conflict",
           [NSString stringWithFormat:@"Found %lu Heading paragraphs equal to the text; expected %lu",
                                      (unsigned long)matches.count, (unsigned long)expected],
           @{@"committed" : @NO, @"matchCount" : @(matches.count)});
    NSUInteger at = matches[occurrence - 1].unsignedIntegerValue;
    if (at == 0)
      Fail(@"selector_conflict", @"Cannot insert above the note's first paragraph (its title)",
           @{@"committed" : @NO});
    p.index = at;
    p.headingIndex = at;
    p.trailingTerminator = YES;
    return p;
  }
  if ([mode isEqualToString:@"prepend"]) {
    NSRange newline = [body rangeOfString:@"\n"];
    if (newline.location != NSNotFound) {
      p.index = newline.location + 1;
      p.trailingTerminator = p.index < body.length;
      return p;
    }
  }
  // Append, or prepend to a title-only note: close the last paragraph first.
  if (body.length && ![body hasSuffix:@"\n"]) p.prefix = TerminatorFor(existing, body.length - 1);
  return p;
}

static NSMutableAttributedString *Insertion(ComposedUnit unit, Placement p) {
  NSMutableAttributedString *insertion = [NSMutableAttributedString new];
  if (p.prefix) [insertion appendAttributedString:p.prefix];
  [insertion appendAttributedString:unit.text];
  if (p.trailingTerminator) [insertion appendAttributedString:TerminatorFor(unit.text, unit.text.length - 1)];
  return insertion;
}

static void RequireNonSystemPaper(NSManagedObject *note) {
  if (!note.entity.propertiesByName[@"isSystemPaper"])
    Fail(@"unsupported_note", @"Cannot determine whether this note is a Quick Note on this macOS",
         @{@"committed" : @NO});
  if ([[note valueForKey:@"isSystemPaper"] boolValue])
    Fail(@"unsupported_note", @"The note is a Quick Note and requireNonSystemPaper is set",
         @{@"committed" : @NO});
}

static NSArray *ReadBackSummary(NSArray *signatures) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *sig in signatures) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"style", @"indent", @"blockQuote", @"checked", @"lengthUTF16" ])
      if (sig[key]) entry[key] = sig[key];
    NSMutableArray *runs = [NSMutableArray array];
    for (NSDictionary *run in sig[@"runs"])
      [runs addObject:@{@"length" : run[@"length"], @"attributes" : run[@"attributes"]}];
    entry[@"runs"] = runs;
    [out addObject:entry];
  }
  return out;
}

// Every failure raised before the save carries committed: NO, so the client
// never reports a refused compose as indeterminate. Failures from the save on
// set committed themselves and pass through unchanged.
static NSDictionary *HandleComposeNote(NSDictionary *request) {
  @try {
    NSString *identifier = RequireIdentifier(request);
    NSString *mode = RequireString(request, @"mode");
    if (![mode isEqualToString:@"append"] && ![mode isEqualToString:@"prepend"])
      Fail(@"invalid_request", @"`mode` must be append or prepend", nil);
    BOOL dryRun = OptionalBool(request, @"dryRun", @"Request");
    BOOL requireNonSystemPaper = OptionalBool(request, @"requireNonSystemPaper", @"Request");
    NSString *ifRevision = nil;
    if (dryRun) {
      if (request[@"ifRevision"]) Fail(@"invalid_request", @"`dryRun` does not take `ifRevision`", nil);
    } else {
      ifRevision = RequireString(request, @"ifRevision");
    }
    NSDictionary *beforeHeading = request[@"insertBeforeHeading"];
    if (beforeHeading) {
      if (![beforeHeading isKindOfClass:[NSDictionary class]])
        Fail(@"invalid_request", @"`insertBeforeHeading` must be an object", nil);
      if (![mode isEqualToString:@"append"])
        Fail(@"invalid_request", @"`insertBeforeHeading` is valid only in append mode", nil);
      RequireOnlyKeys(beforeHeading, @"text,occurrence,expectedCount", @"insertBeforeHeading");
      NSString *text = RequireString(beforeHeading, @"text");
      if ([text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
        Fail(@"invalid_request", @"`insertBeforeHeading.text` must be one line", nil);
      OptionalCount(beforeHeading, @"occurrence", 1, 100000, 1, @"insertBeforeHeading");
      OptionalCount(beforeHeading, @"expectedCount", 1, 100000, 1, @"insertBeforeHeading");
    }
    ComposedUnit unit = BuildUnit(request[@"paragraphs"]);
    RequireFeature(FeatureCompose);
    ApplyParagraphStyles(unit);

    StoreLocation store = ResolveStore();
    NSManagedObjectContext *context = OpenContext(store, dryRun);
    NSManagedObject *note = FetchNote(context, identifier);
    RequireAppendableNote(note);
    if (requireNonSystemPaper) RequireNonSystemPaper(note);

    NSString *revisionBefore = RevisionToken(note);
    if (!dryRun && ![revisionBefore isEqualToString:ifRevision])
      Fail(@"revision_conflict", @"The note changed since ifRevision was read",
           @{@"committed" : @NO, @"currentRevision" : revisionBefore});

    id ms = Send(note, "mergeableString");
    NSAttributedString *existing = ms ? Send(ms, "attributedString") : nil;
    if (![existing isKindOfClass:[NSAttributedString class]])
      Fail(@"unsupported_note", @"The note body could not be loaded as a mergeable string", nil);
    existing = [existing copy];
    Placement placement = ResolvePlacement(existing, mode, beforeHeading);
    NSMutableAttributedString *insertion = Insertion(unit, placement);
    NSUInteger unitOffset = placement.prefix ? placement.prefix.length : 0;
    NSArray *expected = UnitSignatures(insertion, unitOffset, unit.ranges, placement.trailingTerminator);

    NSMutableDictionary *result = [@{
      @"identifier" : identifier,
      @"mode" : mode,
      @"paragraphs" : @(unit.ranges.count),
      @"insertedUTF16" : @(insertion.length),
      @"insertAt" : @(placement.index),
      // UTF-16 offset of the first composed paragraph in the new body (after
      // any separator), so a caller can locate the unit in an independent read.
      @"unitStart" : @(placement.index + unitOffset),
      @"objectURI" : note.objectID.URIRepresentation.absoluteString,
      @"revisionBefore" : revisionBefore,
      @"requiredNonSystemPaper" : @(requireNonSystemPaper),
      @"storeKind" : store.isCopy ? @"copy" : @"live",
    } mutableCopy];
    if (beforeHeading) result[@"insertBeforeHeading"] = beforeHeading;
    if (dryRun) {
      [result addEntriesFromDictionary:@{
        @"status" : @"planned",
        @"dryRun" : @YES,
        @"committed" : @NO,
        @"plan" : ReadBackSummary(expected),
      }];
      return result;
    }

    SendVoid(ms, "beginEditing");
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertAttributedString:atIndex:"),
                                                      insertion, placement.index);
    SendVoid(ms, "endEditing");
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"),
        NSTextStorageEditedCharacters | NSTextStorageEditedAttributes,
        NSMakeRange(placement.index, insertion.length), (NSInteger)insertion.length);
    ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(note, sel_registerName("regenerateTitle:snippet:"), YES, YES);
    if (!SendBool(note, "saveNoteData"))
      Fail(@"save_failed", @"NotesShared did not serialize the edited body", @{@"committed" : @NO});
    [note setValue:[NSDate date] forKey:@"modificationDate"];
    ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("updateChangeCountWithReason:"),
                                          @"apple-notes-mcp compose_note");

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

    // Fresh read-back through a new coordinator: the full text must equal the
    // old body with the insertion spliced in, and every composed paragraph must
    // carry the expected style, checklist state, and inline runs.
    NSMutableString *expectedText = [existing.string mutableCopy];
    [expectedText insertString:insertion.string atIndex:placement.index];
    NSDictionary *after = nil;
    NSArray *persisted = nil;
    NSString *verifyDetail = nil;
    BOOL placementVerified = !beforeHeading;
    @try {
      NSManagedObjectContext *fresh = OpenContext(store, YES);
      NSManagedObject *reread = FetchNote(fresh, identifier);
      NSAttributedString *body = Send(Send(reread, "mergeableString"), "attributedString");
      after = NoteState(reread);
      if (![body isKindOfClass:[NSAttributedString class]] || ![body.string isEqualToString:expectedText]) {
        verifyDetail = @"The persisted body does not equal the previous body with the composed text inserted";
      } else {
        persisted = UnitSignatures(body, placement.index + unitOffset, unit.ranges, placement.trailingTerminator);
        if (![persisted isEqualToArray:expected])
          verifyDetail = @"A composed paragraph's persisted style, checklist state, or runs differ from the request";
        if (beforeHeading) {
          NSUInteger headingAt = placement.index + insertion.length;
          NSString *line = nil;
          if (headingAt < body.length) {
            NSRange range = [body.string paragraphRangeForRange:NSMakeRange(headingAt, 0)];
            line = [[body.string substringWithRange:range]
                stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
          }
          placementVerified = line && StyleValueAt(body, headingAt) == STYLE_HEADING &&
                              [line isEqualToString:beforeHeading[@"text"]];
          if (!placementVerified) verifyDetail = @"The heading no longer follows the composed text";
        }
      }
    } @catch (HelperError *e) {
      verifyDetail = e.reason;
    }
    if (verifyDetail) {
      NSMutableDictionary *extra = [@{@"committed" : @YES, @"indeterminate" : @YES, @"revisionBefore" : revisionBefore}
          mutableCopy];
      if (persisted) {
        extra[@"expected"] = ReadBackSummary(expected);
        extra[@"persisted"] = ReadBackSummary(persisted);
      }
      Fail(@"verification_failed", verifyDetail, extra);
    }

    BOOL hostRunning = NotesAppRunning();
    [result addEntriesFromDictionary:@{
      @"status" : @"updated",
      @"committed" : @YES,
      @"verified" : @YES,
      @"placementVerified" : @(placementVerified),
      @"revisionAfter" : after[@"revision"],
      @"modificationDate" : after[@"modificationDate"],
      @"title" : after[@"title"],
      @"cloudSync" : after[@"cloudSync"],
      @"readBack" : ReadBackSummary(persisted),
      @"pushScheduled" : @NO,
      @"syncHostRunning" : @(hostRunning),
      @"pushState" : hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch",
    }];
    return result;
  } @catch (HelperError *e) {
    if (e.userInfo[@"committed"]) @throw;
    NSMutableDictionary *info = [e.userInfo mutableCopy];
    info[@"committed"] = @NO;
    @throw [HelperError exceptionWithName:e.name reason:e.reason userInfo:info];
  }
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
