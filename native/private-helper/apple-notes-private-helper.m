// apple-notes-private-helper: opt-in native helper for apple-notes-mcp.
//
// Speaks one JSON object in on stdin and one JSON object out on stdout. It
// loads Apple's private NotesShared framework at runtime, opens the Notes
// Core Data store through NotesShared's own managed object model and store
// options, and performs only the whitelisted actions in kActions below.
//
// This is UNSUPPORTED PRIVATE API. Every class and selector is resolved at
// runtime and checked before use; a missing one fails closed with
// `private_api_unavailable` instead of crashing. The helper never issues SQL,
// never spawns a shell, and never dispatches a caller-supplied selector.
//
// Build (src/services/privateHelperBuild.ts; `apple-notes-mcp setup --native-helper`):
//   xcrun clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreData \
//     -framework AppKit -framework PencilKit -DHELPER_SOURCE_SHA256='"<sha256 of this file>"' \
//     -o apple-notes-private-helper apple-notes-private-helper.m
//
// Adding an action: write a `static NSDictionary *HandleX(NSDictionary *)`,
// list the NotesShared selectors it needs in an APIRequirement table (so
// `probe` can report it), and add one row to kActions with its name and
// allowed request keys. The dispatcher rejects any other key.

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

static NSString *const kFrameworkPath =
    @"/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared";
static NSString *const kTransactionAuthor = @"apple-notes-mcp-private-helper";
static NSString *const kChangeReason = @"apple-notes-mcp append_plain_text";
static NSString *const kEnableEnv = @"APPLE_NOTES_MCP_ENABLE_PRIVATE";
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

#pragma mark - Paper drawings

// Paper (com.apple.paper) keeps its drawing in a Coherence bundle on disk,
// `Accounts/<account>/Paper/Bundles/<attachment>.bundle`, not in the store.
// Public PaperKit cannot open that bundle. NotesShared's
// ICSystemPaperDrawingsHelper can: it returns the attachment's strokes as
// public PKDrawing objects, whose ink, color, width and points are then read
// through PencilKit's public API. Nothing here parses bundle bytes, and no
// geometry is ever synthesized: every number comes from a PKStroke.
//
// Reads never touch the live bundle. The helper copies the one bundle into a
// private temporary directory and redirects every ICAccount directory method
// to that copy for the life of the process, so whatever NotesShared or
// Coherence opens, creates or checkpoints is the throwaway copy.

#define MAX_PAPER_STROKES 4096
#define DEFAULT_PAPER_POINTS 20000
#define MAX_PAPER_POINTS 40000
#define MAX_PAPER_BUNDLE_FILES 2048
#define MAX_PAPER_BUNDLE_BYTES (512LL * 1024 * 1024)

static NSString *const kPaperUTI = @"com.apple.paper";

static const APIRequirement kPaperReadAPI[] = {
    {"ICSystemPaperDrawingsHelper", "drawingsForAttachment:", YES},
    {"ICAttachment", "typeUTIIsSystemPaper:", YES},
    {"ICAccount", "accountFilesDirectoryURL", NO},
    {"ICAccount", "accountFilesDirectoryURLInApplicationDataContainer", NO},
    {"ICAccount", "systemPaperDirectoryURL", NO},
    {"ICAccount", "systemPaperBundlesDirectoryURL", NO},
    {"ICAccount", "systemPaperTemporaryDirectoryURL", NO},
    {"ICAccount", "fallbackImageDirectoryURL", NO},
    {"ICAccount", "fallbackPDFDirectoryURL", NO},
    {"ICAccount", "previewImageDirectoryURL", NO},
    {"ICAccount", "mediaDirectoryURL", NO},
    {"ICAccount", "exportableMediaDirectoryURL", NO},
    {"ICAccount", "temporaryDirectoryURL", NO},
    {"PKDrawing", "strokes", NO},
    {"PKStroke", "ink", NO},
    {"PKStroke", "path", NO},
    {"PKStrokePath", "pointAtIndex:", NO},
};

static const ModelRequirement kPaperModelProperties[] = {
    {"ICAttachment",
     "identifier,typeUTI,note,account,markedForDeletion,isPasswordProtected,"
     "needsInitialFetchFromCloud"},
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

static NSArray<NSString *> *MissingForPaperRead(void) {
  NSMutableArray *missing = [MissingForFeature(FeatureRead) mutableCopy];
  if (!gFrameworkLoaded) return missing;
  [missing addObjectsFromArray:MissingAPI(kPaperReadAPI, COUNT(kPaperReadAPI))];
  [missing addObjectsFromArray:MissingModelPropertiesIn(kPaperModelProperties,
                                                        COUNT(kPaperModelProperties))];
  return missing;
}

static NSDictionary *PaperFeatureReport(BOOL contextOK, NSString *contextReason) {
  NSArray *missing = MissingForPaperRead();
  if (missing.count)
    return @{@"available" : @NO, @"reason" : @"private_api_unavailable", @"missing" : missing};
  if (!contextOK)
    return @{@"available" : @NO, @"reason" : contextReason ?: @"store_unavailable", @"missing" : @[]};
  return @{@"available" : @YES, @"reason" : [NSNull null], @"missing" : @[]};
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
  // unsafe identifier maps to a directory that cannot exist, which makes the
  // caller fail rather than escape the sandbox.
  NSString *component = IsSafePathComponent(account) ? account : @"invalid-account";
  NSString *suffix = @"";
  for (size_t i = 0; i < COUNT(kAccountDirectories); i++)
    if (sel_isEqual(_cmd, sel_registerName(kAccountDirectories[i].sel)))
      suffix = @(kAccountDirectories[i].suffix);
  NSString *path = [[[gSandboxRoot stringByAppendingPathComponent:@"Accounts"]
      stringByAppendingPathComponent:component] stringByAppendingPathComponent:suffix];
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
      Fail(@"internal_error", @"The account sandbox is already installed elsewhere", nil);
    return;
  }
  Class account = objc_getClass("ICAccount");
  Method methods[COUNT(kAccountDirectories)];
  for (size_t i = 0; i < COUNT(kAccountDirectories); i++) {
    methods[i] = account ? class_getInstanceMethod(account, sel_registerName(kAccountDirectories[i].sel))
                         : NULL;
    if (!methods[i])
      Fail(@"private_api_unavailable", @"An ICAccount directory method is missing; refusing to run unsandboxed",
           @{@"missing" : @[ @(kAccountDirectories[i].sel) ]});
  }
  gSandboxRoot = [root copy];
  for (size_t i = 0; i < COUNT(kAccountDirectories); i++)
    method_setImplementation(methods[i], (IMP)SandboxedAccountDirectory);
}

// A private 0700 temporary directory, removed by the caller.
static NSString *MakePrivateTempDir(NSString *prefix) {
  NSString *template = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[prefix stringByAppendingString:@".XXXXXX"]];
  char *buffer = strdup(template.fileSystemRepresentation);
  char *made = mkdtemp(buffer);
  NSString *path = made ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:made
                                                                                    length:strlen(made)]
                        : nil;
  free(buffer);
  if (!path) Fail(@"internal_error", @"Could not create a private temporary directory", nil);
  chmod(path.fileSystemRepresentation, 0700);
  return path;
}

// size and modification time of every regular file in a bundle, refusing
// links and anything that is not a regular file or directory.
static NSDictionary *BundleSignature(NSString *bundle, long long *totalBytes) {
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
      Fail(@"unsupported_attachment", @"The Paper bundle exceeds the helper's size limits", nil);
    signature[relative] = [NSString
        stringWithFormat:@"%llu:%.6f", attrs.fileSize, attrs.fileModificationDate.timeIntervalSince1970];
  }
  if (totalBytes) *totalBytes = total;
  return signature;
}

// Copies one Paper bundle from the store's container into the sandbox. The
// bundle directory must sit exactly at Accounts/<account>/Paper/Bundles/ under
// the store's directory with no link on the way, and must be unchanged across
// the copy (Notes may be writing it); a moving bundle is retried, then refused.
static NSDictionary *SnapshotPaperBundle(NSString *storePath, NSString *account, NSString *attachment,
                                         NSString *sandbox) {
  if (!IsSafePathComponent(account) || !IsSafePathComponent(attachment))
    Fail(@"unsupported_attachment", @"The attachment's account or identifier is not a safe path component",
         nil);
  NSString *relative = [NSString stringWithFormat:@"Accounts/%@/Paper/Bundles/%@.bundle", account, attachment];
  NSString *containerDir = [[storePath stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
  NSString *source = [containerDir stringByAppendingPathComponent:relative];
  if (![[source stringByResolvingSymlinksInPath] isEqualToString:source])
    Fail(@"unsupported_attachment", @"The Paper bundle path contains a link", nil);
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:source isDirectory:&isDir] || !isDir)
    Fail(@"bundle_unavailable",
         @"The Paper bundle is not on this Mac (it may not have downloaded from iCloud yet)", nil);
  NSString *destination = [sandbox stringByAppendingPathComponent:relative];
  [NSFileManager.defaultManager createDirectoryAtPath:[destination stringByDeletingLastPathComponent]
                          withIntermediateDirectories:YES
                                           attributes:@{NSFilePosixPermissions : @0700}
                                                error:NULL];
  for (int attempt = 0; attempt < 3; attempt++) {
    long long bytes = 0;
    NSDictionary *before = BundleSignature(source, &bytes);
    [NSFileManager.defaultManager removeItemAtPath:destination error:NULL];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:&error])
      Fail(@"bundle_unavailable", @"Could not copy the Paper bundle",
           @{@"detail" : OrNull(error.localizedDescription)});
    NSDictionary *after = BundleSignature(source, NULL);
    if ([before isEqualToDictionary:after])
      return @{@"files" : @(before.count), @"bytes" : @(bytes)};
    usleep(200000);
  }
  Fail(@"store_busy", @"The Paper bundle kept changing while it was copied; try again", nil);
  return nil;
}

static NSManagedObject *FetchPaperAttachment(NSManagedObjectContext *context, NSDictionary *request) {
  id attachmentId = request[@"attachmentIdentifier"];
  id noteId = request[@"identifier"];
  if ((attachmentId && noteId) || (!attachmentId && !noteId))
    Fail(@"invalid_request", @"Pass exactly one of `identifier` (note) or `attachmentIdentifier`", nil);
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"ICAttachment"];
  if (attachmentId) {
    if (!IsUUID(attachmentId)) Fail(@"invalid_request", @"`attachmentIdentifier` must be a UUID", nil);
    fetch.predicate = [NSPredicate predicateWithFormat:@"identifier ==[c] %@", attachmentId];
  } else {
    if (!IsUUID(noteId)) Fail(@"invalid_request", @"`identifier` must be a Notes UUID", nil);
    fetch.predicate = [NSPredicate
        predicateWithFormat:@"note.identifier ==[c] %@ AND typeUTI == %@ AND markedForDeletion != YES", noteId,
                            kPaperUTI];
  }
  fetch.fetchLimit = 64;
  NSError *error = nil;
  NSArray *rows = [context executeFetchRequest:fetch error:&error];
  if (!rows)
    Fail(@"store_unavailable", @"Attachment fetch failed", @{@"detail" : OrNull(error.localizedDescription)});
  if (rows.count == 0)
    Fail(@"not_found", attachmentId ? @"No attachment has that identifier" : @"That note has no Paper drawing",
         nil);
  if (rows.count > 1) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSManagedObject *row in rows) [ids addObject:OrNull([row valueForKey:@"identifier"])];
    Fail(attachmentId ? @"unsupported_attachment" : @"ambiguous_attachment",
         attachmentId ? @"More than one attachment row has that identifier"
                      : @"The note has more than one Paper drawing; pass attachmentIdentifier",
         @{@"attachmentIdentifiers" : ids});
  }
  return rows.firstObject;
}

static void RequireReadablePaper(NSManagedObject *attachment) {
  NSString *uti = [attachment valueForKey:@"typeUTI"];
  BOOL isPaper = [uti isKindOfClass:[NSString class]] &&
                 ((BOOL(*)(id, SEL, id))objc_msgSend)(objc_getClass("ICAttachment"),
                                                      sel_registerName("typeUTIIsSystemPaper:"), uti) &&
                 [uti isEqualToString:kPaperUTI];
  if (!isPaper)
    Fail(@"unsupported_attachment", @"The attachment is not a Paper drawing (com.apple.paper)",
         @{@"typeUTI" : OrNull(uti)});
  NSManagedObject *note = [attachment valueForKey:@"note"];
  if ([[attachment valueForKey:@"isPasswordProtected"] boolValue] ||
      (note && SendBool(note, "isPasswordProtected")))
    Fail(@"unsupported_note", @"Drawings in locked notes are encrypted and are not supported", nil);
  if ([[attachment valueForKey:@"markedForDeletion"] boolValue])
    Fail(@"unsupported_attachment", @"The attachment is deleted", nil);
  if ([[attachment valueForKey:@"needsInitialFetchFromCloud"] boolValue])
    Fail(@"bundle_unavailable", @"The drawing has not finished downloading from iCloud", nil);
}

static double Round4(double value) { return round(value * 10000.0) / 10000.0; }

static BOOL AllFinite(const double *values, size_t count) {
  for (size_t i = 0; i < count; i++)
    if (!isfinite(values[i])) return NO;
  return YES;
}

static NSArray *RectArray(CGRect rect) {
  return @[ @(Round4(rect.origin.x)), @(Round4(rect.origin.y)), @(Round4(rect.size.width)),
            @(Round4(rect.size.height)) ];
}

// Short ink name: "com.apple.ink.pen" -> "pen". Unknown ink identifiers pass
// through unchanged in `inkIdentifier`.
static NSString *InkName(NSString *inkType) {
  NSString *prefix = @"com.apple.ink.";
  return [inkType hasPrefix:prefix] ? [inkType substringFromIndex:prefix.length] : inkType;
}

// One stroke as JSON. Points are compact arrays in the order of the
// response's `pointFields`; `budget` is the number of points still allowed.
static NSDictionary *StrokeJSON(PKStroke *stroke, BOOL includePoints, NSUInteger *budget,
                                NSMutableArray *warnings) {
  PKInk *ink = stroke.ink;
  NSString *inkType = ink.inkType ?: @"";
  NSColor *color = [ink.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  id colorJSON = [NSNull null];
  if (color) {
    double c[4] = {color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent};
    if (AllFinite(c, 4)) colorJSON = @[ @(Round4(c[0])), @(Round4(c[1])), @(Round4(c[2])), @(Round4(c[3])) ];
  }
  if (colorJSON == [NSNull null]) [warnings addObject:@"A stroke color could not be converted to sRGB"];
  CGAffineTransform t = stroke.transform;
  double tv[6] = {t.a, t.b, t.c, t.d, t.tx, t.ty};
  PKStrokePath *path = stroke.path;
  NSUInteger count = path.count;
  double widthSum = 0;
  NSMutableArray *points = [NSMutableArray array];
  BOOL emit = includePoints && count <= *budget;
  for (NSUInteger i = 0; i < count; i++) {
    PKStrokePoint *p = [path pointAtIndex:i];
    double v[9] = {p.location.x, p.location.y, p.size.width, p.size.height, p.opacity,
                   p.force,      p.azimuth,    p.altitude,   p.timeOffset};
    if (!AllFinite(v, 9)) {
      [warnings addObject:@"A stroke with a non-finite point was skipped"];
      return nil;
    }
    widthSum += v[2];
    if (emit) {
      NSMutableArray *row = [NSMutableArray arrayWithCapacity:9];
      for (int k = 0; k < 9; k++) [row addObject:@(Round4(v[k]))];
      [points addObject:row];
    }
  }
  // Once one stroke's points do not fit, no later stroke gets any: the strokes
  // that carry points are always a prefix of the drawing's stroke order.
  *budget = emit ? *budget - count : 0;
  NSMutableDictionary *out = [@{
    @"ink" : InkName(inkType),
    @"inkIdentifier" : inkType,
    @"color" : colorJSON,
    @"width" : @(Round4(count ? widthSum / count : 0)),
    @"transform" : AllFinite(tv, 6) ? @[ @(tv[0]), @(tv[1]), @(tv[2]), @(tv[3]), @(Round4(tv[4])), @(Round4(tv[5])) ]
                                    : [NSNull null],
    @"pointCount" : @(count),
    @"renderBounds" : RectArray(stroke.renderBounds),
    @"masked" : @((BOOL)(stroke.mask != nil)),
  } mutableCopy];
  if (emit)
    out[@"points"] = points;
  else if (includePoints)
    out[@"pointsOmitted"] = @YES;
  return out;
}

static NSArray<PKDrawing *> *DrawingsForAttachment(NSManagedObject *attachment) {
  id value = ((id(*)(id, SEL, id))objc_msgSend)(objc_getClass("ICSystemPaperDrawingsHelper"),
                                                sel_registerName("drawingsForAttachment:"), attachment);
  if ([value isKindOfClass:[PKDrawing class]]) return @[ value ];
  if (![value isKindOfClass:[NSArray class]]) return @[];
  NSMutableArray *drawings = [NSMutableArray array];
  for (id item in value)
    if ([item isKindOfClass:[PKDrawing class]]) [drawings addObject:item];
  return drawings;
}

static NSDictionary *HandleReadPaper(NSDictionary *request) {
  id includeValue = request[@"includePoints"];
  if (includeValue && ![includeValue isKindOfClass:[NSNumber class]])
    Fail(@"invalid_request", @"`includePoints` must be a boolean", nil);
  BOOL includePoints = includeValue ? [includeValue boolValue] : YES;
  id maxValue = request[@"maxPoints"];
  if (maxValue && (![maxValue isKindOfClass:[NSNumber class]] || [maxValue integerValue] < 1 ||
                   [maxValue integerValue] > MAX_PAPER_POINTS))
    Fail(@"invalid_request", @"`maxPoints` must be an integer from 1 to 40000", nil);
  NSUInteger budget = maxValue ? (NSUInteger)[maxValue integerValue] : DEFAULT_PAPER_POINTS;
  NSArray *missing = MissingForPaperRead();
  if (missing.count)
    Fail(@"private_api_unavailable", @"Required NotesShared or PencilKit API is not available on this macOS",
         @{@"missing" : missing});

  StoreLocation store = ResolveStore();
  NSString *sandbox = MakePrivateTempDir(@"apple-notes-paper");
  @try {
    InstallAccountSandbox(sandbox);
    NSManagedObjectContext *context = OpenContext(store, YES);
    NSManagedObject *attachment = FetchPaperAttachment(context, request);
    RequireReadablePaper(attachment);
    NSManagedObject *note = [attachment valueForKey:@"note"];
    id account = (note ? [note valueForKey:@"account"] : nil) ?: [attachment valueForKey:@"account"];
    NSString *accountId = account ? [account valueForKey:@"identifier"] : nil;
    NSString *attachmentId = [attachment valueForKey:@"identifier"];
    NSDictionary *snapshot = SnapshotPaperBundle(store.path, accountId, attachmentId, sandbox);

    NSArray<PKDrawing *> *drawings = DrawingsForAttachment(attachment);
    NSMutableArray *strokes = [NSMutableArray array];
    NSMutableArray *warnings = [NSMutableArray array];
    NSMutableSet *inks = [NSMutableSet set];
    NSUInteger totalPoints = 0, strokeTotal = 0;
    CGRect bounds = CGRectNull;
    BOOL truncated = NO;
    for (PKDrawing *drawing in drawings) {
      if (!CGRectIsEmpty(drawing.bounds)) bounds = CGRectUnion(bounds, drawing.bounds);
      for (PKStroke *stroke in drawing.strokes) {
        strokeTotal++;
        if (strokes.count >= MAX_PAPER_STROKES) {
          truncated = YES;
          continue;
        }
        NSDictionary *json = StrokeJSON(stroke, includePoints, &budget, warnings);
        if (!json) continue;
        if (json[@"pointsOmitted"]) truncated = YES;
        totalPoints += [json[@"pointCount"] unsignedIntegerValue];
        [inks addObject:json[@"ink"]];
        [strokes addObject:json];
      }
    }
    return @{
      @"status" : @"ok",
      @"storeKind" : store.isCopy ? @"copy" : @"live",
      @"attachmentIdentifier" : attachmentId,
      @"noteIdentifier" : OrNull(note ? [note valueForKey:@"identifier"] : nil),
      @"typeUTI" : [attachment valueForKey:@"typeUTI"],
      @"decodePath" : @"NotesShared.ICSystemPaperDrawingsHelper",
      @"vectorDecode" : strokes.count ? @"strokes" : @"empty",
      @"drawingCount" : @(drawings.count),
      @"strokeCount" : @(strokeTotal),
      @"returnedStrokeCount" : @(strokes.count),
      @"pointCount" : @(totalPoints),
      @"bounds" : CGRectIsNull(bounds) ? [NSNull null] : RectArray(bounds),
      @"inks" : [[inks allObjects] sortedArrayUsingSelector:@selector(compare:)],
      @"pointFields" : @[ @"x", @"y", @"width", @"height", @"opacity", @"force", @"azimuth", @"altitude",
                          @"timeOffset" ],
      @"strokes" : strokes,
      // Typed shapes live only in the Coherence model, which no stable entry
      // point exposes to an out-of-process reader. They are reported as not
      // exposed rather than approximated from the rendered image.
      @"shapes" : @[],
      @"shapeDecode" : @{@"available" : @NO, @"reason" : @"not_exposed"},
      @"truncated" : @(truncated),
      @"warnings" : warnings,
      @"snapshot" : snapshot,
    };
  } @finally {
    [NSFileManager.defaultManager removeItemAtPath:sandbox error:NULL];
  }
}

#pragma mark - Actions

static NSDictionary *HandleHello(NSDictionary *request);
static NSDictionary *HandleProbe(NSDictionary *request);
static NSDictionary *HandleReadNoteState(NSDictionary *request);
static NSDictionary *HandleAppendPlainText(NSDictionary *request);
static NSDictionary *HandleReadPaper(NSDictionary *request);

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
    {"read_paper", "identifier,attachmentIdentifier,includePoints,maxPoints", HandleReadPaper},
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
      @"readPaper" : PaperFeatureReport(contextOK, contextReason),
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
