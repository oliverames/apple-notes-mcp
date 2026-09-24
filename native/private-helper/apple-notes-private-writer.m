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

static const ModelRequirement kLinkCardModel[] = {
    {"ICAttachment", "identifier,typeUTI,urlString,note,cloudState"},
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

// URL link cards add an ICAttachment and its attachment glyph. They need the
// append editing surface above plus these, and the ICAttachment model
// properties in kLinkCardModel below.
static const APIRequirement kLinkCardAPI[] = {
    {"ICNote", "addURLAttachmentWithURL:", NO},
    {"ICNote", "rangeForAttachment:", NO},
    {"ICAttachment", "updateChangeCountWithReason:", NO},
    {"ICTTAttachment", "setAttachmentIdentifier:", NO},
    {"ICTTAttachment", "setAttachmentUTI:", NO},
    {"ICTTAttachment", "attachmentIdentifier", NO},
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

static NSArray<NSString *> *MissingModelProperties(const ModelRequirement *list, size_t count) {
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

// Each feature up to FeatureAppend includes everything before it. Features
// after FeatureAppend add their own requirement table on top of FeatureAppend.
typedef NS_ENUM(NSInteger, Feature) { FeatureModel, FeatureRead, FeatureAppend, FeatureLinkCard };

static NSArray<NSString *> *MissingForFeature(Feature feature) {
  LoadFramework();
  if (!gFrameworkLoaded) return @[ @"NotesShared.framework" ];
  NSMutableArray *missing = [NSMutableArray array];
  [missing addObjectsFromArray:MissingAPI(kModelAPI, COUNT(kModelAPI))];
  if (missing.count) return missing;
  if (feature >= FeatureRead) {
    [missing addObjectsFromArray:MissingModelProperties(kModelProperties, COUNT(kModelProperties))];
    [missing addObjectsFromArray:MissingAPI(kReadAPI, COUNT(kReadAPI))];
  }
  if (feature >= FeatureAppend)
    [missing addObjectsFromArray:MissingAPI(kAppendAPI, COUNT(kAppendAPI))];
  if (feature == FeatureLinkCard) {
    [missing addObjectsFromArray:MissingAPI(kLinkCardAPI, COUNT(kLinkCardAPI))];
    [missing addObjectsFromArray:MissingModelProperties(kLinkCardModel, COUNT(kLinkCardModel))];
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
static NSDictionary *HandleAddURLCard(NSDictionary *request);

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
    {"add_url_card", "identifier,url,afterParagraph,ifRevision,dryRun", HandleAddURLCard},
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
      @"linkCard" : FeatureReport(FeatureLinkCard, contextOK, contextReason),
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

#pragma mark - Shared write plumbing

// Saves an edited note with the same optimistic-locking rules as the append
// path: a concurrent save by Notes becomes revision_conflict, anything else
// save_failed, and in both cases nothing is written.
static void SaveOrFail(NSManagedObjectContext *context) {
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

// The sync fields every write result carries. The writer never uploads.
static NSDictionary *SyncFields(NSDictionary *after, StoreLocation store) {
  BOOL hostRunning = NotesAppRunning();
  return @{
    @"modificationDate" : after[@"modificationDate"],
    @"cloudSync" : after[@"cloudSync"],
    @"pushScheduled" : @NO,
    @"syncHostRunning" : @(hostRunning),
    @"pushState" : hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch",
    @"storeKind" : store.isCopy ? @"copy" : @"live",
  };
}

static NSAttributedString *LoadBody(NSManagedObject *note, id *mergeableOut) {
  id ms = Send(note, "mergeableString");
  NSAttributedString *body = ms ? Send(ms, "attributedString") : nil;
  if (![body isKindOfClass:[NSAttributedString class]])
    Fail(@"unsupported_note", @"The note body could not be loaded as a mergeable string", nil);
  if (mergeableOut) *mergeableOut = ms;
  return body;
}

static BOOL IsJSONBool(id value) {
  return [value isKindOfClass:[NSNumber class]] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

#pragma mark - URL link card

#define MAX_URL_UTF16 2048
#define MAX_ANCHOR_UTF16 2000
static const unichar kAttachmentGlyph = 0xFFFC;
static NSString *const kURLCardUTI = @"public.url";

// Only absolute http(s) URLs with a host become cards. Everything else (file,
// data, javascript, notes deep links) is refused.
static NSURL *CardURL(NSString *value) {
  if (value.length > MAX_URL_UTF16)
    Fail(@"invalid_request", @"`url` exceeds 2048 UTF-16 code units", nil);
  if ([value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
      [value rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound)
    Fail(@"invalid_request", @"`url` must not contain whitespace or control characters", nil);
  NSURLComponents *parts = [NSURLComponents componentsWithString:value];
  NSString *scheme = parts.scheme.lowercaseString;
  if (!parts.URL || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ||
      !parts.host.length)
    Fail(@"invalid_request", @"`url` must be an absolute http or https URL with a host", nil);
  return parts.URL;
}

// Where the card goes: at the end of one paragraph's text, so it becomes the
// next paragraph. With no anchor that is the note's last paragraph. Returns
// the insertion index and fills `styleSource` with the index whose paragraph
// style the separating newline copies (NSNotFound for none) and `found` with
// how many paragraphs matched the anchor.
static NSUInteger CardInsertionIndex(NSString *text, NSString *anchor, NSUInteger *styleSource,
                                     NSUInteger *found) {
  *styleSource = NSNotFound;
  if (!anchor) {
    *found = 1;
    // A body that already ends in a newline gets the card as its own last
    // paragraph without a separator.
    if (text.length == 0 || [text hasSuffix:@"\n"]) return text.length;
    *styleSource = text.length - 1;
    return text.length;
  }
  NSUInteger start = 0, hits = 0, end = NSNotFound;
  while (start <= text.length) {
    NSRange newline = [text rangeOfString:@"\n"
                                  options:NSLiteralSearch
                                    range:NSMakeRange(start, text.length - start)];
    NSUInteger lineEnd = newline.location == NSNotFound ? text.length : newline.location;
    if ([[text substringWithRange:NSMakeRange(start, lineEnd - start)] isEqualToString:anchor]) {
      hits++;
      end = lineEnd;
    }
    if (newline.location == NSNotFound) break;
    start = lineEnd + 1;
  }
  *found = hits;
  if (hits != 1) return NSNotFound;
  *styleSource = end > 0 && [text characterAtIndex:end - 1] != '\n' ? end - 1 : NSNotFound;
  return end;
}

// The inserted text: an optional newline that carries the anchor paragraph's
// style, then the card glyph. A Notes-made card is one U+FFFC whose only
// attribute is the NSAttachment (an ICTTAttachment naming the ICAttachment);
// its paragraph is body text.
static NSAttributedString *CardInsertion(NSAttributedString *body, NSUInteger styleSource,
                                         BOOL separator, id ttAttachment) {
  NSMutableAttributedString *insertion = [NSMutableAttributedString new];
  if (separator) {
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (styleSource != NSNotFound) {
      id style = [body attribute:@"TTStyle" atIndex:styleSource effectiveRange:NULL];
      if ([NSStringFromClass([style class]) containsString:@"ParagraphStyle"]) attrs[@"TTStyle"] = style;
    }
    [insertion appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                      attributes:attrs]];
  }
  NSString *glyph = [NSString stringWithCharacters:&kAttachmentGlyph length:1];
  [insertion appendAttributedString:[[NSAttributedString alloc]
                                        initWithString:glyph
                                            attributes:@{NSAttachmentAttributeName : ttAttachment}]];
  return insertion;
}

static NSManagedObject *FetchAttachment(NSManagedObjectContext *context, NSString *identifier) {
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICAttachment"];
  request.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", identifier];
  request.fetchLimit = 2;
  NSArray *rows = [context executeFetchRequest:request error:nil];
  return rows.count == 1 ? rows.firstObject : nil;
}

static NSDictionary *HandleAddURLCard(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  NSURL *url = CardURL(RequireString(request, @"url"));
  NSString *anchor = nil;
  if (request[@"afterParagraph"]) {
    anchor = RequireString(request, @"afterParagraph");
    if (anchor.length > MAX_ANCHOR_UTF16 || [anchor containsString:@"\n"])
      Fail(@"invalid_request", @"`afterParagraph` must be one paragraph of at most 2000 UTF-16 units",
           nil);
  }
  id dryRunValue = request[@"dryRun"];
  if (dryRunValue && !IsJSONBool(dryRunValue))
    Fail(@"invalid_request", @"`dryRun` must be true or false", nil);
  BOOL dryRun = [dryRunValue boolValue];
  NSString *ifRevision = nil;
  if (!dryRun || request[@"ifRevision"]) ifRevision = RequireString(request, @"ifRevision");
  RequireFeature(dryRun ? FeatureRead : FeatureLinkCard);

  // A dry run opens the store read-only and can never write.
  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, dryRun);
  NSManagedObject *note = FetchNote(context, identifier);
  RequireAppendableNote(note);
  NSString *revisionBefore = RevisionToken(note);
  if (ifRevision && ![revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : revisionBefore});

  id ms = nil;
  NSAttributedString *body = LoadBody(note, &ms);
  NSUInteger styleSource = NSNotFound, found = 0;
  NSUInteger at = CardInsertionIndex(body.string, anchor, &styleSource, &found);
  if (at == NSNotFound)
    Fail(@"match_count_mismatch",
         [NSString stringWithFormat:@"`afterParagraph` matches %lu paragraphs, not exactly one",
                                    (unsigned long)found],
         @{@"committed" : @NO, @"found" : @(found), @"revision" : revisionBefore});
  BOOL separator = anchor ? YES : (body.length > 0 && ![body.string hasSuffix:@"\n"]);
  NSUInteger glyphIndex = at + (separator ? 1 : 0);

  NSMutableDictionary *result = [@{
    @"identifier" : identifier,
    @"url" : url.absoluteString,
    @"placement" : anchor ? @"afterParagraph" : @"end",
    @"insertedAtUTF16" : @(at),
    @"glyphIndexUTF16" : @(glyphIndex),
    @"separatorInserted" : @(separator),
    @"revisionBefore" : revisionBefore,
  } mutableCopy];
  if (dryRun) {
    [result addEntriesFromDictionary:@{
      @"status" : @"planned",
      @"committed" : @NO,
      @"dryRun" : @YES,
      @"revisionAfter" : revisionBefore,
    }];
    [result addEntriesFromDictionary:SyncFields(NoteState(note), store)];
    return result;
  }

  // The attachment row. NotesShared creates it with the URL and the
  // public.url type; the card's title and preview image are left for Notes to
  // fetch, so the writer makes no network request.
  id attachment =
      ((id(*)(id, SEL, id))objc_msgSend)(note, sel_registerName("addURLAttachmentWithURL:"), url);
  NSString *attachmentID = [attachment isKindOfClass:[NSManagedObject class]]
                               ? [attachment valueForKey:@"identifier"]
                               : nil;
  NSString *uti = attachmentID ? [attachment valueForKey:@"typeUTI"] : nil;
  if (!attachmentID.length || ![uti isEqualToString:kURLCardUTI]) {
    [context rollback];
    Fail(@"private_api_unavailable", @"NotesShared did not create a public.url attachment",
         @{@"committed" : @NO, @"typeUTI" : OrNull(uti)});
  }
  NSRange placed = ((NSRange(*)(id, SEL, id))objc_msgSend)(
      note, sel_registerName("rangeForAttachment:"), attachment);
  if (placed.location != NSNotFound && placed.length > 0) {
    [context rollback];
    Fail(@"private_api_unavailable", @"NotesShared placed the attachment glyph itself; refusing to guess",
         @{@"committed" : @NO});
  }

  id tt = [objc_getClass("ICTTAttachment") new];
  ((void (*)(id, SEL, id))objc_msgSend)(tt, sel_registerName("setAttachmentIdentifier:"), attachmentID);
  ((void (*)(id, SEL, id))objc_msgSend)(tt, sel_registerName("setAttachmentUTI:"), kURLCardUTI);
  NSAttributedString *insertion = CardInsertion(body, styleSource, separator, tt);
  NSString *before = [body.string copy];

  SendVoid(ms, "beginEditing");
  ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
      ms, sel_registerName("insertAttributedString:atIndex:"), insertion, at);
  SendVoid(ms, "endEditing");
  ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
      note, sel_registerName("edited:range:changeInLength:"), NSTextStorageEditedCharacters,
      NSMakeRange(at, insertion.length), (NSInteger)insertion.length);
  ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(note, sel_registerName("regenerateTitle:snippet:"), YES,
                                                YES);
  if (!SendBool(note, "saveNoteData")) {
    [context rollback];
    Fail(@"save_failed", @"NotesShared did not serialize the edited body", @{@"committed" : @NO});
  }
  [note setValue:[NSDate date] forKey:@"modificationDate"];
  ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("updateChangeCountWithReason:"),
                                        @"apple-notes-mcp add_url_card");
  // The attachment is its own cloud object; without its own bump it would not
  // be eligible for upload even when the note is.
  ((void (*)(id, SEL, id))objc_msgSend)(attachment, sel_registerName("updateChangeCountWithReason:"),
                                        @"apple-notes-mcp add_url_card");
  SaveOrFail(context);

  // Fresh read-back: the text is the old text plus the insertion at the
  // expected index, the glyph there names the new attachment, no other glyph
  // does, and the attachment row is a public.url card for this URL on this
  // note.
  NSDictionary *after = nil;
  NSString *verifyDetail = nil;
  NSMutableDictionary *stored = [NSMutableDictionary dictionaryWithObject:attachmentID
                                                                   forKey:@"attachmentIdentifier"];
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *reread = FetchNote(fresh, identifier);
    NSAttributedString *persisted = LoadBody(reread, NULL);
    NSMutableString *expected = [before mutableCopy];
    [expected insertString:insertion.string atIndex:at];
    __block NSUInteger glyphsForAttachment = 0;
    __block NSUInteger glyphAt = NSNotFound;
    [persisted enumerateAttribute:NSAttachmentAttributeName
                          inRange:NSMakeRange(0, persisted.length)
                          options:0
                       usingBlock:^(id value, NSRange run, BOOL *stop) {
                         (void)stop;
                         if (!value || ![value respondsToSelector:sel_registerName("attachmentIdentifier")])
                           return;
                         if ([Send(value, "attachmentIdentifier") isEqual:attachmentID]) {
                           glyphsForAttachment += run.length;
                           glyphAt = run.location;
                         }
                       }];
    NSManagedObject *row = FetchAttachment(fresh, attachmentID);
    stored[@"typeUTI"] = OrNull(row ? [row valueForKey:@"typeUTI"] : nil);
    stored[@"urlString"] = OrNull(row ? [row valueForKey:@"urlString"] : nil);
    stored[@"glyphIndexUTF16"] = glyphAt == NSNotFound ? [NSNull null] : @(glyphAt);
    if (row) stored[@"cloudSync"] = CloudSyncState(row);
    if (![persisted.string isEqualToString:expected])
      verifyDetail = @"The persisted text is not the previous text plus the card glyph";
    else if (glyphsForAttachment != 1 || glyphAt != glyphIndex)
      verifyDetail = @"The card glyph is not present exactly once at the expected position";
    else if (!row || ![[row valueForKey:@"typeUTI"] isEqual:kURLCardUTI])
      verifyDetail = @"The attachment row is missing or is not a public.url attachment";
    else if (![[row valueForKey:@"note"] isEqual:reread])
      verifyDetail = @"The attachment row does not belong to this note";
    else if (![[row valueForKey:@"urlString"] isEqual:url.absoluteString])
      verifyDetail = @"The attachment row does not carry the requested URL";
    after = NoteState(reread);
  } @catch (HelperError *e) {
    verifyDetail = e.reason;
  }
  if (verifyDetail || !after)
    Fail(@"verification_failed", verifyDetail ?: @"Read-back failed",
         @{@"committed" : @YES, @"revisionBefore" : revisionBefore, @"attachment" : stored});

  [result addEntriesFromDictionary:@{
    @"status" : @"updated",
    @"committed" : @YES,
    @"verified" : @YES,
    @"dryRun" : @NO,
    @"attachment" : stored,
    @"previewFetched" : @NO,
    @"revisionAfter" : after[@"revision"],
  }];
  [result addEntriesFromDictionary:SyncFields(after, store)];
  return result;
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
