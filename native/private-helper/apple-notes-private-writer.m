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

// Paragraph identifiers: the UUID on a paragraph style (attribute key
// TTStyle), set through the mergeable string so the change merges like any
// other attribute edit.
static const APIRequirement kParagraphIdAPI[] = {
    {"ICTTParagraphStyle", "uuid", NO},
    {"ICTTParagraphStyle", "setUuid:", NO},
    {"ICTTParagraphStyle", "style", NO},
    {"ICTTParagraphStyle", "defaultParagraphStyle", YES},
    {"ICTTMergeableAttributedString", "setAttributes:range:", NO},
    {"ICTTMergeableString", "beginEditing", NO},
    {"ICTTMergeableString", "endEditing", NO},
    {"ICNote", "edited:range:changeInLength:", NO},
    {"ICNote", "saveNoteData", NO},
    {"ICNote", "updateChangeCountWithReason:", NO},
};

// Native section-link chips (macOS 27): NotesShared builds the paragraph-link
// inline attachment; the writer inserts its glyph through the mergeable string.
static const APIRequirement kSectionLinkAPI[] = {
    {"ICInlineAttachment",
     "newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:fromNote:"
     "parentAttachment:",
     YES},
    {"ICInlineAttachment", "isParagraphLinkAttachment", NO},
    {"ICInlineAttachment", "markForDeletion", NO},
    {"ICInlineAttachment", "updateChangeCountWithReason:", NO},
    {"ICNote", "addInlineAttachmentsObject:", NO},
    {"ICNote", "regenerateTitle:snippet:", NO},
    {"ICTTAttachment", "setAttachmentIdentifier:", NO},
    {"ICTTAttachment", "setAttachmentUTI:", NO},
    {"ICTTAttachment", "attachmentIdentifier", NO},
    {"ICTTMergeableString", "insertAttributedString:atIndex:", NO},
    {"ICTTMergeableString", "replaceCharactersInRange:withAttributedString:", NO},
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

static const ModelRequirement kSectionLinkModelProperties[] = {
    {"ICNote", "inlineAttachments"},
    {"ICInlineAttachment", "identifier,tokenContentIdentifier,typeUTI,note,markedForDeletion"},
};

typedef NS_ENUM(NSInteger, Feature) {
  FeatureModel,
  FeatureRead,
  FeatureAppend,
  FeatureParagraphIds,
  FeatureSectionLinks,
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
  if (feature == FeatureParagraphIds || feature == FeatureSectionLinks)
    [missing addObjectsFromArray:MissingAPI(kParagraphIdAPI, COUNT(kParagraphIdAPI))];
  if (feature == FeatureSectionLinks) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27)
      [missing addObject:@"macOS 27 or later"];
    [missing addObjectsFromArray:MissingAPI(kSectionLinkAPI, COUNT(kSectionLinkAPI))];
    [missing addObjectsFromArray:MissingModelPropertiesIn(kSectionLinkModelProperties,
                                                          COUNT(kSectionLinkModelProperties))];
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
static NSDictionary *HandleSetParagraphId(NSDictionary *request);
static NSDictionary *HandleAddSectionLink(NSDictionary *request);

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
    {"set_paragraph_id", "identifier,blockIndex,expectedText,paragraphId,ifRevision",
     HandleSetParagraphId},
    {"add_section_link", "identifier,target,blockIndex,expectedText,paragraphId,heading,position,clearExistingSectionLinks,ifRevision,ifTargetRevision", HandleAddSectionLink},
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
      @"setParagraphId" : FeatureReport(FeatureParagraphIds, contextOK, contextReason),
      @"addSectionLink" : FeatureReport(FeatureSectionLinks, contextOK, contextReason),
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

// The note body as an attributed string, copied so later edits to the
// mergeable string cannot change it.
static NSAttributedString *LoadBody(NSManagedObject *note) {
  id ms = Send(note, "mergeableString");
  NSAttributedString *body = ms ? Send(ms, "attributedString") : nil;
  if (![body isKindOfClass:[NSAttributedString class]])
    Fail(@"unsupported_note", @"The note body could not be loaded as a mergeable string", nil);
  return [body copy];
}

// One Core Data save with the context's NSErrorMergePolicy. A failure rolls
// back and reports committed: false.
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

// Serializes the edited body and marks the note for upload. Must run before
// SaveOrFail.
static void FinishNoteEdit(NSManagedObject *note, NSString *reason, NSDate *now) {
  if (!SendBool(note, "saveNoteData"))
    Fail(@"save_failed", @"NotesShared did not serialize the edited body", @{@"committed" : @NO});
  [note setValue:now forKey:@"modificationDate"];
  ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("updateChangeCountWithReason:"), reason);
}

// The sync fields every write result carries. The writer never uploads; see
// TECHNICAL_NOTES.
static NSDictionary *SyncFields(NSDictionary *after, StoreLocation store) {
  BOOL hostRunning = NotesAppRunning();
  return @{
    @"cloudSync" : after[@"cloudSync"],
    @"pushScheduled" : @NO,
    @"syncHostRunning" : @(hostRunning),
    @"pushState" : hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch",
    @"storeKind" : store.isCopy ? @"copy" : @"live",
  };
}

#pragma mark - Paragraph identifiers

// Every Notes paragraph style (ICTTParagraphStyle, attribute key TTStyle) can
// carry a UUID, and Notes opens applenotes://showNote?identifier=<note>&
// paragraphID=<uuid> at the paragraph carrying it. Notes copies the UUID when
// a paragraph is split, so body paragraphs often share one. The read-only
// list-note-paragraphs tool (src/utils/noteParagraphs.ts) classifies each
// block's UUID as unique, shared or missing; these functions apply the same
// rules to the live attributed string so a write can mint a UUID of its own
// for one block:
//   - blocks split on "\n" only; a trailing newline adds no empty block;
//   - a block owns its text plus its terminating newline;
//   - its UUID is the one on its first character (the newline when empty);
//   - that UUID is unique when no character of another block carries it.

static NSString *const kParagraphStyleKey = @"TTStyle";
#define EDITED_ATTRIBUTES 1  // NSTextStorageEditedAttributes

static NSUUID *StyleUUID(id style) {
  if (!style || ![style respondsToSelector:sel_registerName("uuid")]) return nil;
  id uuid = Send(style, "uuid");
  return [uuid isKindOfClass:[NSUUID class]] ? uuid : nil;
}

// The paragraph style value (0 title, 1 heading, 2 subheading, 3 body, ...).
// A run without a paragraph style renders as body text, so it counts as 3.
static NSInteger StyleValue(id style) {
  if (!style || ![style respondsToSelector:sel_registerName("style")]) return 3;
  return (NSInteger)((unsigned int (*)(id, SEL))objc_msgSend)(style, sel_registerName("style"));
}

// Text used to compare a caller's expectedText: attachment glyphs removed,
// surrounding whitespace trimmed.
static NSString *ComparableText(NSString *text) {
  NSString *stripped = [text stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
  return [stripped stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Blocks in upstream's order and with upstream's ranges, each with its first
// UUID, every UUID any of its characters carries (NSNull for none), and its
// paragraph style value.
static NSArray<NSDictionary *> *NoteBlocks(NSAttributedString *body) {
  NSMutableArray *blocks = [NSMutableArray array];
  NSString *text = body.string;
  NSUInteger length = text.length;
  NSUInteger start = 0;
  while (start < length) {
    NSRange newline = [text rangeOfString:@"\n" options:NSLiteralSearch
                                    range:NSMakeRange(start, length - start)];
    NSUInteger end = newline.location == NSNotFound ? length : newline.location;
    NSRange owned = NSMakeRange(start, MIN(end + 1, length) - start);
    NSMutableSet *uuids = [NSMutableSet set];
    [body enumerateAttribute:kParagraphStyleKey
                     inRange:owned
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
                    (void)range;
                    (void)stop;
                    [uuids addObject:StyleUUID(value) ?: (id)[NSNull null]];
                  }];
    id style = [body attribute:kParagraphStyleKey atIndex:start effectiveRange:NULL];
    NSMutableDictionary *block = [@{
      @"index" : @(blocks.count),
      @"text" : [text substringWithRange:NSMakeRange(start, end - start)],
      @"owned" : [NSValue valueWithRange:owned],
      @"style" : @(StyleValue(style)),
      @"uuids" : uuids,
    } mutableCopy];
    NSUUID *first = StyleUUID(style);
    if (first) block[@"uuid"] = first;
    [blocks addObject:block];
    start = end + 1;
  }
  return blocks;
}

// For each UUID, the indexes of the blocks that carry it anywhere.
static NSDictionary<NSUUID *, NSIndexSet *> *BlocksByUUID(NSArray<NSDictionary *> *blocks) {
  NSMutableDictionary *owners = [NSMutableDictionary dictionary];
  for (NSDictionary *block in blocks)
    for (id uuid in block[@"uuids"]) {
      if (![uuid isKindOfClass:[NSUUID class]]) continue;
      NSMutableIndexSet *set = owners[uuid] ?: [NSMutableIndexSet indexSet];
      [set addIndex:[block[@"index"] unsignedIntegerValue]];
      owners[uuid] = set;
    }
  return owners;
}

// "unique", "shared" or "missing", as list-note-paragraphs reports it.
static NSString *ParagraphIdStatus(NSDictionary *block, NSDictionary *owners) {
  NSUUID *uuid = block[@"uuid"];
  if (!uuid) return @"missing";
  return [owners[uuid] count] == 1 ? @"unique" : @"shared";
}

static NSString *ParagraphLink(NSString *noteIdentifier, NSUUID *uuid) {
  return [NSString stringWithFormat:@"applenotes://showNote?identifier=%@&paragraphID=%@",
                                    noteIdentifier.uppercaseString, uuid.UUIDString];
}

// Gives every run of `owned` a copy of its own paragraph style carrying
// `uuid`. -[ICTTMergeableAttributedString setAttributes:range:] replaces a
// run's whole dictionary, so each run keeps its other attributes (links,
// fonts, attachments) and only TTStyle changes.
static void AssignParagraphUUID(id ms, NSAttributedString *body, NSRange owned, NSUUID *uuid) {
  NSMutableArray *updates = [NSMutableArray array];
  [body enumerateAttributesInRange:owned
                           options:0
                        usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                          (void)stop;
                          id style = attrs[kParagraphStyleKey]
                                         ?: Send(objc_getClass("ICTTParagraphStyle"),
                                                 "defaultParagraphStyle");
                          id copy = [style mutableCopy];
                          ((void (*)(id, SEL, id))objc_msgSend)(copy, sel_registerName("setUuid:"),
                                                                uuid);
                          NSMutableDictionary *merged = [attrs mutableCopy];
                          merged[kParagraphStyleKey] = copy;
                          [updates addObject:@[ merged, [NSValue valueWithRange:range] ]];
                        }];
  SendVoid(ms, "beginEditing");
  for (NSArray *update in updates)
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                                                   update[0], [update[1] rangeValue]);
  SendVoid(ms, "endEditing");
}

// True when, at every index of `range`, every attribute other than TTStyle is
// equal in both strings and the paragraph style value is unchanged.
static BOOL SameAttributesExceptParagraphUUID(NSAttributedString *a, NSAttributedString *b,
                                              NSRange range) {
  if (NSMaxRange(range) > a.length || NSMaxRange(range) > b.length) return NO;
  for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
    NSMutableDictionary *left = [[a attributesAtIndex:i effectiveRange:NULL] mutableCopy];
    NSMutableDictionary *right = [[b attributesAtIndex:i effectiveRange:NULL] mutableCopy];
    if (StyleValue(left[kParagraphStyleKey]) != StyleValue(right[kParagraphStyleKey])) return NO;
    [left removeObjectForKey:kParagraphStyleKey];
    [right removeObjectForKey:kParagraphStyleKey];
    if (![left isEqualToDictionary:right]) return NO;
  }
  return YES;
}

// Every block other than `except` keeps its text and first UUID.
static BOOL OtherBlocksUnchanged(NSArray *before, NSArray *after, NSSet<NSNumber *> *except) {
  if (before.count != after.count) return NO;
  for (NSUInteger i = 0; i < before.count; i++) {
    if ([except containsObject:@(i)]) continue;
    NSDictionary *x = before[i], *y = after[i];
    if (![x[@"text"] isEqualToString:y[@"text"]]) return NO;
    if (!(x[@"uuid"] == y[@"uuid"] || [x[@"uuid"] isEqual:y[@"uuid"]])) return NO;
  }
  return YES;
}

static NSUInteger RequireBlockIndex(NSDictionary *request) {
  id value = request[@"blockIndex"];
  // NSJSONSerialization decodes true/false as the CFBoolean singletons.
  if (![value isKindOfClass:[NSNumber class]] || value == (id)kCFBooleanTrue ||
      value == (id)kCFBooleanFalse || [value doubleValue] < 0 ||
      [value doubleValue] != floor([value doubleValue]) || [value doubleValue] > 1e9)
    Fail(@"invalid_request", @"`blockIndex` must be a non-negative integer", nil);
  return [value unsignedIntegerValue];
}

static NSUUID *OptionalParagraphId(NSDictionary *request) {
  if (!request[@"paragraphId"]) return nil;
  NSString *text = RequireString(request, @"paragraphId");
  if (!IsUUID(text)) Fail(@"invalid_request", @"`paragraphId` must be a UUID", nil);
  return [[NSUUID alloc] initWithUUIDString:text];
}

// The block at `index`, refused unless it is a non-empty paragraph whose text
// still equals `expectedText` (attachment glyphs and outer whitespace aside).
static NSDictionary *ExpectedBlock(NSArray *blocks, NSUInteger index, NSString *expectedText) {
  if (index >= blocks.count)
    Fail(@"paragraph_changed", @"No block has that blockIndex any more", @{@"committed" : @NO});
  NSDictionary *block = blocks[index];
  NSString *text = ComparableText(block[@"text"]);
  if (!text.length)
    Fail(@"invalid_request", @"That block is an empty paragraph; choose one list-note-paragraphs lists",
         @{@"committed" : @NO});
  if (![text isEqualToString:ComparableText(expectedText)])
    Fail(@"paragraph_changed", @"The block at that index no longer has the expected text",
         @{@"committed" : @NO});
  return block;
}

static NSDictionary *HandleSetParagraphId(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  NSString *ifRevision = RequireString(request, @"ifRevision");
  NSString *expectedText = RequireString(request, @"expectedText");
  NSUInteger index = RequireBlockIndex(request);
  NSUUID *requested = OptionalParagraphId(request);
  RequireFeature(FeatureParagraphIds);

  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, NO);
  NSManagedObject *note = FetchNote(context, identifier);
  RequireAppendableNote(note);
  NSString *revisionBefore = RevisionToken(note);
  if (![revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : revisionBefore});

  NSAttributedString *body = LoadBody(note);
  NSArray *blocks = NoteBlocks(body);
  NSDictionary *owners = BlocksByUUID(blocks);
  NSDictionary *target = ExpectedBlock(blocks, index, expectedText);
  NSString *noteIdentifier = [note valueForKey:@"identifier"];
  NSUUID *previous = target[@"uuid"];
  NSString *previousStatus = ParagraphIdStatus(target, owners);
  NSMutableDictionary *result = [@{
    @"identifier" : noteIdentifier,
    @"blockIndex" : @(index),
    @"text" : target[@"text"],
    @"styleType" : target[@"style"],
    @"previousParagraphId" : previous ? previous.UUIDString : [NSNull null],
    @"previousParagraphIdStatus" : previousStatus,
    @"revisionBefore" : revisionBefore,
  } mutableCopy];

  if ([previousStatus isEqualToString:@"unique"] && (!requested || [requested isEqual:previous])) {
    [result addEntriesFromDictionary:@{
      @"status" : @"unchanged",
      @"changed" : @NO,
      @"committed" : @NO,
      @"paragraphId" : previous.UUIDString,
      @"url" : ParagraphLink(noteIdentifier, previous),
      @"revisionAfter" : revisionBefore,
    }];
    return result;
  }
  if (requested && owners[requested])
    Fail(@"invalid_request", @"`paragraphId` is already used by a paragraph of this note",
         @{@"committed" : @NO});
  NSUUID *uuid = requested ?: [NSUUID UUID];
  NSRange owned = [target[@"owned"] rangeValue];

  id ms = Send(note, "mergeableString");
  AssignParagraphUUID(ms, body, owned, uuid);
  ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
      note, sel_registerName("edited:range:changeInLength:"), EDITED_ATTRIBUTES, owned, 0);
  FinishNoteEdit(note, @"apple-notes-mcp set_paragraph_id", [NSDate date]);
  SaveOrFail(context);

  // Fresh read-back: same text, the block carries the new UUID on every
  // character and no other block carries it, nothing but TTStyle's UUID
  // changed in the block, and every other block kept its first UUID.
  NSString *verifyDetail = nil;
  NSDictionary *after = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *reread = FetchNote(fresh, identifier);
    NSAttributedString *persisted = LoadBody(reread);
    NSArray *blocksAfter = NoteBlocks(persisted);
    NSDictionary *ownersAfter = BlocksByUUID(blocksAfter);
    NSDictionary *block = index < blocksAfter.count ? blocksAfter[index] : nil;
    if (![persisted.string isEqualToString:body.string])
      verifyDetail = @"The note text changed";
    else if (![block[@"uuid"] isEqual:uuid] || [block[@"uuids"] count] != 1 ||
             ![ParagraphIdStatus(block, ownersAfter) isEqualToString:@"unique"])
      verifyDetail = @"The paragraph does not carry the new identifier uniquely";
    else if (!SameAttributesExceptParagraphUUID(body, persisted, owned))
      verifyDetail = @"Attributes other than the paragraph identifier changed";
    else if (!OtherBlocksUnchanged(blocks, blocksAfter, [NSSet setWithObject:@(index)]))
      verifyDetail = @"Another paragraph changed";
    else
      after = NoteState(reread);
  } @catch (HelperError *e) {
    verifyDetail = e.reason;
  }
  if (verifyDetail)
    Fail(@"verification_failed", verifyDetail, @{@"committed" : @YES, @"revisionBefore" : revisionBefore});
  [result addEntriesFromDictionary:@{
    @"status" : @"updated",
    @"changed" : @YES,
    @"committed" : @YES,
    @"verified" : @YES,
    @"paragraphId" : uuid.UUIDString,
    @"url" : ParagraphLink(noteIdentifier, uuid),
    @"revisionAfter" : after[@"revision"],
    @"modificationDate" : after[@"modificationDate"],
  }];
  [result addEntriesFromDictionary:SyncFields(after, store)];
  return result;
}

#pragma mark - Section-link chips (macOS 27)

// A section link is the chip Notes pastes for "Copy Link to Section": an
// inline attachment (ICInlineAttachment, type
// com.apple.notes.inlinetextattachment.link) whose token is an
// applenotes://showNote?identifier=<note>&paragraphID=<uuid> link, shown in
// the body as one U+FFFC glyph. NotesShared builds the attachment through
// +newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:
// fromNote:parentAttachment:, which exists from macOS 27. The target
// paragraph must carry a unique paragraph UUID (upstream's rules, see
// "Paragraph identifiers"); the writer mints one when it does not.

static NSString *const kAttachmentKey = @"NSAttachment";

static BOOL SectionLinkOSSupported(void) {
  return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

static NSString *OptionalString(NSDictionary *request, NSString *key) {
  return request[key] ? RequireString(request, key) : nil;
}

static BOOL OptionalBool(NSDictionary *request, NSString *key) {
  id value = request[key];
  if (!value) return NO;
  // NSJSONSerialization decodes true/false as the CFBoolean singletons.
  if (value != (id)kCFBooleanTrue && value != (id)kCFBooleanFalse)
    Fail(@"invalid_request", [NSString stringWithFormat:@"`%@` must be true or false", key], nil);
  return [value boolValue];
}

static NSString *GlyphAttachmentIdentifier(id value) {
  if (!value || ![value respondsToSelector:sel_registerName("attachmentIdentifier")]) return nil;
  id named = Send(value, "attachmentIdentifier");
  return [named isKindOfClass:[NSString class]] ? named : nil;
}

static NSManagedObject *InlineAttachmentNamed(NSManagedObject *note, NSString *identifier) {
  if (!identifier) return nil;
  for (NSManagedObject *inlineAttachment in [note valueForKey:@"inlineAttachments"])
    if ([[inlineAttachment valueForKey:@"identifier"] caseInsensitiveCompare:identifier] ==
        NSOrderedSame)
      return inlineAttachment;
  return nil;
}

static BOOL IsSectionLinkAttachment(id inlineAttachment) {
  return inlineAttachment && ![[inlineAttachment valueForKey:@"markedForDeletion"] boolValue] &&
         SendBool(inlineAttachment, "isParagraphLinkAttachment");
}

// Number of U+FFFC glyphs in the body that name this attachment.
static NSUInteger GlyphCount(NSAttributedString *body, NSString *attachmentIdentifier) {
  __block NSUInteger count = 0;
  if (!body.length) return 0;
  [body enumerateAttribute:kAttachmentKey
                   inRange:NSMakeRange(0, body.length)
                   options:0
                usingBlock:^(id value, NSRange range, BOOL *stop) {
                  (void)stop;
                  NSString *named = GlyphAttachmentIdentifier(value);
                  if (!named || [named caseInsensitiveCompare:attachmentIdentifier] != NSOrderedSame)
                    return;
                  for (NSUInteger i = range.location; i < NSMaxRange(range); i++)
                    if ([body.string characterAtIndex:i] == 0xFFFC) count++;
                }];
  return count;
}

// Glyphs whose inline attachment is a section link, each widened to its whole
// line when it is alone on that line. Note-link chips share the UTI but are
// not paragraph links, so they are never included.
static NSArray<NSDictionary *> *SectionLinkGlyphs(NSAttributedString *body, NSManagedObject *note) {
  NSMutableArray *found = [NSMutableArray array];
  if (!body.length) return found;
  NSString *text = body.string;
  [body enumerateAttribute:kAttachmentKey
                   inRange:NSMakeRange(0, body.length)
                   options:0
                usingBlock:^(id value, NSRange range, BOOL *stop) {
                  (void)stop;
                  NSManagedObject *inlineAttachment =
                      InlineAttachmentNamed(note, GlyphAttachmentIdentifier(value));
                  if (!IsSectionLinkAttachment(inlineAttachment)) return;
                  NSRange remove = range;
                  BOOL startsLine =
                      range.location == 0 || [text characterAtIndex:range.location - 1] == '\n';
                  BOOL endsLine = NSMaxRange(range) == text.length ||
                                  [text characterAtIndex:NSMaxRange(range)] == '\n';
                  if (startsLine && endsLine) {
                    if (NSMaxRange(range) < text.length) {
                      remove.length += 1;
                    } else if (range.location > 0) {
                      remove.location -= 1;
                      remove.length += 1;
                    }
                  }
                  [found addObject:@{
                    @"range" : [NSValue valueWithRange:remove],
                    @"attachment" : inlineAttachment,
                  }];
                }];
  return found;
}

// Index just after the title line and any section chips that directly follow
// it, one per line.
static NSUInteger IndexAfterTitleAndSectionChips(NSAttributedString *body, NSManagedObject *note) {
  NSString *text = body.string;
  NSRange newline = [text rangeOfString:@"\n"];
  NSUInteger index = newline.location == NSNotFound ? text.length : NSMaxRange(newline);
  while (index < text.length && [text characterAtIndex:index] == 0xFFFC) {
    id value = [body attribute:kAttachmentKey atIndex:index effectiveRange:NULL];
    if (!IsSectionLinkAttachment(InlineAttachmentNamed(note, GlyphAttachmentIdentifier(value))))
      break;
    index += 1;
    if (index < text.length && [text characterAtIndex:index] == '\n') index += 1;
  }
  return index;
}

// The target block: by blockIndex (+ expectedText), by a paragraphId that
// is unique in the note, by heading text (title, heading or subheading;
// exact after trimming, case-insensitive), or the first heading or
// subheading.
static NSDictionary *ChooseSectionBlock(NSArray *blocks, NSDictionary *owners,
                                        NSDictionary *request) {
  NSString *paragraphId = OptionalString(request, @"paragraphId");
  NSString *heading = OptionalString(request, @"heading");
  BOOL byIndex = request[@"blockIndex"] != nil;
  if ((paragraphId != nil) + (heading != nil) + byIndex > 1)
    Fail(@"invalid_request", @"Pass at most one of blockIndex, paragraphId, heading", nil);
  if (byIndex) {
    NSString *expectedText = RequireString(request, @"expectedText");
    return ExpectedBlock(blocks, RequireBlockIndex(request), expectedText);
  }
  if (request[@"expectedText"])
    Fail(@"invalid_request", @"`expectedText` goes with blockIndex", nil);
  if (paragraphId) {
    if (!IsUUID(paragraphId)) Fail(@"invalid_request", @"`paragraphId` must be a UUID", nil);
    NSUUID *wanted = [[NSUUID alloc] initWithUUIDString:paragraphId];
    NSIndexSet *holders = owners[wanted];
    if (!holders.count) Fail(@"not_found", @"No paragraph of the target note has that paragraphId", nil);
    NSDictionary *block = blocks[holders.firstIndex];
    if (holders.count > 1 || ![block[@"uuid"] isEqual:wanted])
      Fail(@"ambiguous_paragraph",
           @"That paragraphId is not unique to one paragraph; select the paragraph by blockIndex "
           @"or heading and the writer mints one",
           nil);
    return block;
  }
  NSString *wantedHeading = heading ? ComparableText(heading) : nil;
  NSMutableArray *matches = [NSMutableArray array];
  for (NSDictionary *block in blocks) {
    NSInteger style = [block[@"style"] integerValue];
    NSString *text = ComparableText(block[@"text"]);
    if (!text.length) continue;
    if (!wantedHeading) {
      if (style == 1 || style == 2) return block;
    } else if (style <= 2 && [text caseInsensitiveCompare:wantedHeading] == NSOrderedSame) {
      [matches addObject:block];
    }
  }
  if (!wantedHeading) Fail(@"not_found", @"The target note has no heading or subheading", nil);
  if (!matches.count) Fail(@"not_found", @"No heading of the target note has that text", nil);
  if (matches.count > 1)
    Fail(@"ambiguous_paragraph", @"More than one heading of the target note has that text", nil);
  return matches.firstObject;
}

// The single block whose first UUID is `uuid`, when no other block carries it.
static NSDictionary *UniqueBlockWithUUID(NSArray *blocks, NSUUID *uuid) {
  NSDictionary *owners = BlocksByUUID(blocks);
  NSIndexSet *holders = owners[uuid];
  if (holders.count != 1) return nil;
  NSDictionary *block = blocks[holders.firstIndex];
  return [block[@"uuid"] isEqual:uuid] ? block : nil;
}

static NSDictionary *HandleAddSectionLink(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  NSString *targetIdentifier = OptionalString(request, @"target") ?: identifier;
  if (!IsUUID(targetIdentifier)) Fail(@"invalid_request", @"`target` must be a Notes UUID", nil);
  BOOL selfLink = [targetIdentifier caseInsensitiveCompare:identifier] == NSOrderedSame;
  NSString *ifRevision = RequireString(request, @"ifRevision");
  NSString *ifTargetRevision = OptionalString(request, @"ifTargetRevision");
  if (selfLink && ifTargetRevision)
    Fail(@"invalid_request", @"`ifTargetRevision` is only for a link to another note", nil);
  if (!selfLink && !ifTargetRevision)
    Fail(@"invalid_request", @"`ifTargetRevision` is required for a link to another note", nil);
  NSString *position = OptionalString(request, @"position") ?: @"end";
  if (![position isEqualToString:@"end"] && ![position isEqualToString:@"belowTitle"])
    Fail(@"invalid_request", @"`position` must be end or belowTitle", nil);
  BOOL clearExisting = OptionalBool(request, @"clearExistingSectionLinks");
  if (!SectionLinkOSSupported())
    Fail(@"private_api_unavailable", @"Native section-link chips need macOS 27 or later",
         @{@"committed" : @NO});
  RequireFeature(FeatureSectionLinks);

  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, NO);
  NSManagedObject *source = FetchNote(context, identifier);
  RequireAppendableNote(source);
  NSManagedObject *target = selfLink ? source : FetchNote(context, targetIdentifier);
  RequireAppendableNote(target);
  NSString *sourceRevision = RevisionToken(source);
  if (![sourceRevision isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : sourceRevision});
  NSString *targetRevision = selfLink ? sourceRevision : RevisionToken(target);
  if (!selfLink && ![targetRevision isEqualToString:ifTargetRevision])
    Fail(@"revision_conflict", @"The target note changed since ifTargetRevision was read",
         @{@"committed" : @NO, @"currentTargetRevision" : targetRevision});
  NSString *canonicalTarget = [target valueForKey:@"identifier"];

  // 1. The target paragraph, with a unique UUID (minted when needed).
  NSAttributedString *targetBody = LoadBody(target);
  NSArray *targetBlocks = NoteBlocks(targetBody);
  NSDictionary *owners = BlocksByUUID(targetBlocks);
  NSDictionary *block = ChooseSectionBlock(targetBlocks, owners, request);
  NSString *previousStatus = ParagraphIdStatus(block, owners);
  BOOL minted = ![previousStatus isEqualToString:@"unique"];
  NSUUID *uuid = minted ? [NSUUID UUID] : block[@"uuid"];
  NSRange targetRange = [block[@"owned"] rangeValue];
  NSString *sectionName = ComparableText(block[@"text"]);
  id targetMs = Send(target, "mergeableString");
  if (minted) {
    AssignParagraphUUID(targetMs, targetBody, targetRange, uuid);
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        target, sel_registerName("edited:range:changeInLength:"), EDITED_ATTRIBUTES, targetRange, 0);
  }

  // 2. The inline attachment, built by NotesShared.
  NSString *inlineId = [NSUUID UUID].UUIDString;
  id inlineAttachment = ((id(*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(
      objc_getClass("ICInlineAttachment"),
      sel_registerName("newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:"
                       "fromNote:parentAttachment:"),
      inlineId, target, sectionName, uuid, source, nil);
  if (!IsSectionLinkAttachment(inlineAttachment)) {
    [context rollback];
    Fail(@"save_failed", @"NotesShared did not create a paragraph-link attachment; nothing was saved",
         @{@"committed" : @NO});
  }
  if (![[inlineAttachment valueForKey:@"note"] isEqual:source])
    ((void (*)(id, SEL, id))objc_msgSend)(source, sel_registerName("addInlineAttachmentsObject:"),
                                          inlineAttachment);
  NSString *token = [inlineAttachment valueForKey:@"tokenContentIdentifier"];
  NSString *typeUTI = [inlineAttachment valueForKey:@"typeUTI"];

  // 3. The source body: optionally drop existing section chips, then insert
  //    the new glyph at the end or below the title. Loaded after step 1, so a
  //    link within the note sees the minted identifier.
  id sourceMs = Send(source, "mergeableString");
  NSAttributedString *sourceBefore = LoadBody(source);
  NSMutableAttributedString *expected = [sourceBefore mutableCopy];
  NSArray *cleared = clearExisting ? SectionLinkGlyphs(sourceBefore, source) : @[];
  SendVoid(sourceMs, "beginEditing");
  for (NSDictionary *entry in cleared.reverseObjectEnumerator) {
    NSRange range = [entry[@"range"] rangeValue];
    ((void (*)(id, SEL, NSRange, id))objc_msgSend)(
        sourceMs, sel_registerName("replaceCharactersInRange:withAttributedString:"), range,
        [[NSAttributedString alloc] initWithString:@""]);
    [expected deleteCharactersInRange:range];
  }
  for (NSDictionary *entry in cleared) SendVoid(entry[@"attachment"], "markForDeletion");

  id glyphAttachment = [[objc_getClass("ICTTAttachment") alloc] init];
  ((void (*)(id, SEL, id))objc_msgSend)(glyphAttachment, sel_registerName("setAttachmentIdentifier:"),
                                        inlineId);
  ((void (*)(id, SEL, id))objc_msgSend)(glyphAttachment, sel_registerName("setAttachmentUTI:"),
                                        typeUTI);
  id bodyStyle = [Send(objc_getClass("ICTTParagraphStyle"), "defaultParagraphStyle") mutableCopy];
  NSDictionary *bodyAttrs = @{kParagraphStyleKey : bodyStyle};
  NSMutableDictionary *glyphAttrs = [bodyAttrs mutableCopy];
  glyphAttrs[kAttachmentKey] = glyphAttachment;
  NSAttributedString *glyph = [[NSAttributedString alloc] initWithString:@"\uFFFC"
                                                              attributes:glyphAttrs];
  NSMutableAttributedString *insertion = [NSMutableAttributedString new];
  NSUInteger at;
  if ([position isEqualToString:@"belowTitle"]) {
    at = IndexAfterTitleAndSectionChips(expected, source);
    if (at == expected.length && expected.length && ![expected.string hasSuffix:@"\n"])
      [insertion appendAttributedString:
                     [[NSAttributedString alloc]
                         initWithString:@"\n"
                             attributes:[expected attributesAtIndex:expected.length - 1
                                                     effectiveRange:NULL]]];
    [insertion appendAttributedString:glyph];
    [insertion appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                      attributes:bodyAttrs]];
  } else {
    at = expected.length;
    if (expected.length && ![expected.string hasSuffix:@"\n"]) {
      // The separator ends the old last paragraph, so it keeps that style.
      id lastStyle = [expected attribute:kParagraphStyleKey
                                 atIndex:expected.length - 1
                          effectiveRange:NULL];
      [insertion
          appendAttributedString:[[NSAttributedString alloc]
                                     initWithString:@"\n"
                                         attributes:lastStyle ? @{kParagraphStyleKey : lastStyle}
                                                              : @{}]];
    }
    [insertion appendAttributedString:glyph];
  }
  ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
      sourceMs, sel_registerName("insertAttributedString:atIndex:"), insertion, at);
  [expected insertAttributedString:insertion atIndex:at];
  SendVoid(sourceMs, "endEditing");
  NSInteger delta = (NSInteger)expected.length - (NSInteger)sourceBefore.length;
  ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
      source, sel_registerName("edited:range:changeInLength:"),
      EDITED_ATTRIBUTES | NSTextStorageEditedCharacters, NSMakeRange(0, expected.length), delta);
  ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(source, sel_registerName("regenerateTitle:snippet:"),
                                                YES, YES);

  // 4. Serialize, mark for upload, and save once.
  NSDate *now = [NSDate date];
  @try {
    FinishNoteEdit(source, @"apple-notes-mcp add_section_link", now);
    if (!selfLink && minted) FinishNoteEdit(target, @"apple-notes-mcp add_section_link", now);
  } @catch (HelperError *e) {
    [context rollback];
    @throw;
  }
  ((void (*)(id, SEL, id))objc_msgSend)(
      inlineAttachment, sel_registerName("updateChangeCountWithReason:"),
      @"apple-notes-mcp add_section_link");
  SaveOrFail(context);

  // 5. Fresh read-back of both notes and the attachment.
  NSString *link = ParagraphLink(canonicalTarget, uuid);
  NSString *verifyDetail = nil;
  NSDictionary *sourceAfter = nil;
  NSDictionary *targetAfter = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *freshSource = FetchNote(fresh, identifier);
    NSManagedObject *freshTarget = selfLink ? freshSource : FetchNote(fresh, targetIdentifier);
    NSAttributedString *sourceText = LoadBody(freshSource);
    NSAttributedString *targetText = selfLink ? sourceText : LoadBody(freshTarget);
    NSArray *targetBlocksAfter = NoteBlocks(targetText);
    NSDictionary *blockAfter = UniqueBlockWithUUID(targetBlocksAfter, uuid);
    NSManagedObject *inlineAfter = InlineAttachmentNamed(freshSource, inlineId);
    NSString *tokenAfter = [inlineAfter valueForKey:@"tokenContentIdentifier"];
    BOOL clearedGone = YES;
    for (NSDictionary *entry in cleared) {
      NSManagedObject *old =
          InlineAttachmentNamed(freshSource, [entry[@"attachment"] valueForKey:@"identifier"]);
      if (old && ![[old valueForKey:@"markedForDeletion"] boolValue]) clearedGone = NO;
    }
    if (![sourceText.string isEqualToString:expected.string])
      verifyDetail = @"The source note text is not the planned text";
    else if (GlyphCount(sourceText, inlineId) != 1)
      verifyDetail = @"The section-link glyph is not present exactly once";
    else if (!IsSectionLinkAttachment(inlineAfter))
      verifyDetail = @"The section-link attachment was not persisted";
    else if (![tokenAfter isKindOfClass:[NSString class]] ||
             [tokenAfter rangeOfString:uuid.UUIDString options:NSCaseInsensitiveSearch].location ==
                 NSNotFound ||
             [tokenAfter rangeOfString:canonicalTarget options:NSCaseInsensitiveSearch].location ==
                 NSNotFound)
      verifyDetail = @"The section link does not point at the target paragraph";
    else if (!blockAfter || ![ComparableText(blockAfter[@"text"]) isEqualToString:sectionName])
      verifyDetail = @"The target paragraph does not carry the link's identifier uniquely";
    else if (!selfLink && ![targetText.string isEqualToString:targetBody.string])
      verifyDetail = @"The target note text changed";
    else if (!selfLink && minted &&
             !OtherBlocksUnchanged(targetBlocks, targetBlocksAfter,
                                   [NSSet setWithObject:block[@"index"]]))
      verifyDetail = @"Another paragraph of the target note changed";
    else if (!clearedGone)
      verifyDetail = @"A cleared section link is still active";
    else {
      sourceAfter = NoteState(freshSource);
      targetAfter = selfLink ? sourceAfter : NoteState(freshTarget);
    }
  } @catch (HelperError *e) {
    verifyDetail = e.reason;
  }
  if (verifyDetail)
    Fail(@"verification_failed", verifyDetail,
         @{@"committed" : @YES, @"revisionBefore" : sourceRevision});
  NSMutableDictionary *result = [@{
    @"status" : @"updated",
    @"committed" : @YES,
    @"verified" : @YES,
    @"identifier" : [source valueForKey:@"identifier"],
    @"target" : canonicalTarget,
    @"selfLink" : @(selfLink),
    @"section" : sectionName,
    @"targetStyleType" : block[@"style"],
    @"paragraphId" : uuid.UUIDString,
    @"previousParagraphIdStatus" : previousStatus,
    @"paragraphIdMinted" : @(minted),
    @"url" : link,
    @"token" : OrNull(token),
    @"inlineAttachmentIdentifier" : inlineId,
    @"position" : position,
    @"clearedSectionLinks" : @(cleared.count),
    @"revisionBefore" : sourceRevision,
    @"revisionAfter" : sourceAfter[@"revision"],
    @"modificationDate" : sourceAfter[@"modificationDate"],
  } mutableCopy];
  [result addEntriesFromDictionary:SyncFields(sourceAfter, store)];
  if (!selfLink) {
    result[@"targetRevisionBefore"] = targetRevision;
    result[@"targetRevisionAfter"] = targetAfter[@"revision"];
    result[@"targetCloudSync"] = targetAfter[@"cloudSync"];
  }
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
