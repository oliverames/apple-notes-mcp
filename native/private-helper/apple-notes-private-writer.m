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

// A write handler sets gWriteRequest before it can save; the save sets
// gSaveAttempted just before -save: and gSaveSucceeded after it returns YES.
// main() uses them so an error raised before the save reports committed:
// false, and an exception after a successful save still reports committed:
// true, instead of both reading as indeterminate.
static BOOL gWriteRequest = NO;
static BOOL gSaveAttempted = NO;
static BOOL gSaveSucceeded = NO;

static const ModelRequirement kModelProperties[] = {
    {"ICNote",
     "identifier,title,modificationDate,creationDate,folder,account,noteData,cloudState,"
     "isPasswordProtected,markedForDeletion,needsInitialFetchFromCloud"},
    {"ICNoteData", "data"},
    {"ICCloudState", "currentLocalVersion,latestVersionSyncedToCloud"},
    {"ICFolder", "identifier,markedForDeletion,cloudState"},
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

// In-place edits (plan_edit, edit_note) also use everything in kAppendAPI.
static const APIRequirement kEditAPI[] = {
    {"ICTTMergeableString", "replaceCharactersInRange:withAttributedString:", NO},
    {"ICTTParagraphStyle", "style", NO},
    {"ICTTMutableParagraphStyle", "setStyle:", NO},
    {"ICTTMutableParagraphStyle", "setTodo:", NO},
    {"ICTTTodo", "initWithIdentifier:done:", NO},
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

// Compose dividers and tables: new attachment objects plus their glyphs.
static const APIRequirement kComposeObjectAPI[] = {
    {"ICTTAttachment", "setAttachmentIdentifier:", NO},
    {"ICTTAttachment", "setAttachmentUTI:", NO},
    {"ICTTAttachment", "attachmentIdentifier", NO},
    {"ICTTAttachment", "attachmentUTI", NO},
    {"ICInlineAttachment", "newDividerLineAttachmentWithIdentifier:note:parentAttachment:", YES},
    {"ICTable", "registerWithICCRCoder", YES},
    {"ICNote", "addTableAttachment", NO},
    {"ICAttachment", "tableModel", NO},
    {"ICAttachment", "saveMergeableDataIfNeeded", NO},
    {"ICAttachment", "updateChangeCountWithReason:", NO},
    {"ICAttachmentTableModel", "table", NO},
    {"ICAttachmentTableModel", "writeMergeableData", NO},
    {"ICAttachmentTableModel", "regenerateTextContentInNote", NO},
    {"ICTable", "setAttributedString:columnIndex:rowIndex:", NO},
    {"ICTable", "stringForColumnIndex:rowIndex:", NO},
    {"ICTable", "insertRowAtIndex:", NO},
    {"ICTable", "insertColumnAtIndex:", NO},
    {"ICTable", "removeRowAtIndex:", NO},
    {"ICTable", "removeColumnAtIndex:", NO},
    {"ICTable", "rowCount", NO},
    {"ICTable", "columnCount", NO},
};

// Checklist toggling rewrites the paragraph style of one existing checklist
// item. It needs the append editing surface above plus these.
static const APIRequirement kChecklistAPI[] = {
    {"ICTTParagraphStyle", "style", NO},
    {"ICTTParagraphStyle", "todo", NO},
    {"ICTTParagraphStyle", "mutableCopyWithZone:", NO},
    {"ICTTParagraphStyle", "setTodo:", NO},
    {"ICTTTodo", "uuid", NO},
    {"ICTTTodo", "done", NO},
    {"ICTTTodo", "initWithIdentifier:done:", NO},
    {"ICTTMergeableAttributedString", "setAttributes:range:", NO},
};

// Highlighting rewrites the TTEmphasis attribute of exact text ranges. It
// needs the append editing surface above plus this.
static const APIRequirement kHighlightAPI[] = {
    {"ICTTMergeableAttributedString", "setAttributes:range:", NO},
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
typedef NS_ENUM(NSInteger, Feature) {
  FeatureModel,
  FeatureRead,
  FeatureAppend,
  FeatureEdit,
  FeatureCompose,
  FeatureChecklist,
  FeatureHighlight,
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
  if (feature >= FeatureAppend)
    [missing addObjectsFromArray:MissingAPI(kAppendAPI, COUNT(kAppendAPI))];
  if (feature == FeatureEdit) [missing addObjectsFromArray:MissingAPI(kEditAPI, COUNT(kEditAPI))];
  if (feature == FeatureCompose)
    [missing addObjectsFromArray:MissingAPI(kComposeAPI, COUNT(kComposeAPI))];
  if (feature == FeatureChecklist)
    [missing addObjectsFromArray:MissingAPI(kChecklistAPI, COUNT(kChecklistAPI))];
  if (feature == FeatureHighlight)
    [missing addObjectsFromArray:MissingAPI(kHighlightAPI, COUNT(kHighlightAPI))];
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
  if (![NSProcessInfo.processInfo.environment[kEnableEnv] isEqualToString:@"1"])
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
static NSDictionary *HandlePlanEdit(NSDictionary *request);
static NSDictionary *HandleEditNote(NSDictionary *request);
static NSDictionary *HandleComposeNote(NSDictionary *request);
static NSDictionary *HandleReadChecklist(NSDictionary *request);
static NSDictionary *HandleSetChecklistItem(NSDictionary *request);
static NSDictionary *HandleSetHighlight(NSDictionary *request);

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
    {"plan_edit", "identifier,requireNonSystemPaper,operations", HandlePlanEdit},
    {"edit_note", "identifier,ifRevision,requireNonSystemPaper,operations", HandleEditNote},
    {"compose_note",
     "identifier,mode,paragraphs,ifRevision,dryRun,requireNonSystemPaper,insertBeforeHeading",
     HandleComposeNote},
    {"read_checklist", "identifier", HandleReadChecklist},
    {"set_checklist_item", "identifier,todoIdentifier,done,ifRevision", HandleSetChecklistItem},
    {"set_highlight", "identifier,scope,match,expectedCount,color,ifRevision,dryRun", HandleSetHighlight},
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

// Dividers and tables in compose: the compose feature plus the object API.
static NSDictionary *ObjectsReport(BOOL contextOK, NSString *contextReason) {
  NSDictionary *compose = FeatureReport(FeatureCompose, contextOK, contextReason);
  if (![compose[@"available"] boolValue]) return compose;
  NSArray *missing = MissingAPI(kComposeObjectAPI, COUNT(kComposeObjectAPI));
  if (missing.count)
    return @{@"available" : @NO, @"reason" : @"private_api_unavailable", @"missing" : missing};
  return compose;
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
      @"planEdit" : FeatureReport(FeatureEdit, contextOK, contextReason),
      @"editNote" : FeatureReport(FeatureEdit, contextOK, contextReason),
      @"composeNote" : FeatureReport(FeatureCompose, contextOK, contextReason),
      @"composeObjects" : ObjectsReport(contextOK, contextReason),
      @"checklistToggle" : FeatureReport(FeatureChecklist, contextOK, contextReason),
      @"highlight" : FeatureReport(FeatureHighlight, contextOK, contextReason),
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

// Characters no written text may contain. Only category Cc (C0 and C1
// controls) is forbidden: controlCharacterSet also covers Cf, which would
// refuse ZWJ emoji, ZWNJ, soft hyphens, BOMs and bidi marks that appear in
// ordinary text. Tab is always allowed and \n only where the caller says;
// the attachment glyph and the Unicode line and paragraph separators never
// are. The client's checks in src/services/privateWriter.ts match this set.
static NSCharacterSet *ForbiddenTextCharacters(BOOL allowNewline) {
  NSMutableCharacterSet *forbidden = [NSMutableCharacterSet new];
  [forbidden addCharactersInRange:NSMakeRange(0x00, 0x20)];
  [forbidden addCharactersInRange:NSMakeRange(0x7F, 0x21)];
  [forbidden removeCharactersInString:allowNewline ? @"\n\t" : @"\t"];
  [forbidden addCharactersInString:@"\uFFFC\u2028\u2029"];
  return forbidden;
}

static void ValidateAppendText(NSString *text) {
  if (text.length > MAX_APPEND_UTF16)
    Fail(@"invalid_request", @"`text` exceeds 50000 UTF-16 code units", nil);
  if ([text rangeOfCharacterFromSet:ForbiddenTextCharacters(YES)].location != NSNotFound)
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
  gWriteRequest = YES;
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
  gSaveAttempted = YES;
  if (![context save:&saveError]) {
    [context rollback];
    BOOL conflict = saveError.code == NSManagedObjectMergeError ||
                    saveError.code == NSPersistentStoreSaveConflictsError;
    Fail(conflict ? @"revision_conflict" : @"save_failed",
         conflict ? @"Notes changed the note during the write; nothing was saved"
                  : @"The Core Data save failed; nothing was saved",
         @{@"committed" : @NO, @"detail" : OrNull(saveError.localizedDescription)});
  }
  gSaveSucceeded = YES;

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
  } @catch (NSException *e) {
    // Any failure here happens after a successful save: report it as a
    // committed write that could not be verified, never as uncommitted.
    verifyDetail = e.reason ?: e.name;
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
// save_failed, and in both cases nothing is written. The save is bracketed
// with gSaveAttempted / gSaveSucceeded like the append path's, so main() can
// tell a failure before, during, and after it apart.
static void SaveOrFail(NSManagedObjectContext *context) {
  NSError *saveError = nil;
  gSaveAttempted = YES;
  if ([context save:&saveError]) {
    gSaveSucceeded = YES;
    return;
  }
  [context rollback];
  BOOL conflict = saveError.code == NSManagedObjectMergeError ||
                  saveError.code == NSPersistentStoreSaveConflictsError;
  Fail(conflict ? @"revision_conflict" : @"save_failed",
       conflict ? @"Notes changed the note during the write; nothing was saved"
                : @"The Core Data save failed; nothing was saved",
       @{@"committed" : @NO, @"detail" : OrNull(saveError.localizedDescription)});
}

// Serializes an attribute-only edit of `range` and marks the note for upload.
static void FinishAttributeEdit(NSManagedObject *note, NSRange range, NSString *reason) {
  ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
      note, sel_registerName("edited:range:changeInLength:"), NSTextStorageEditedAttributes, range, 0);
  if (!SendBool(note, "saveNoteData"))
    Fail(@"save_failed", @"NotesShared did not serialize the edited body", @{@"committed" : @NO});
  [note setValue:[NSDate date] forKey:@"modificationDate"];
  ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("updateChangeCountWithReason:"), reason);
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

// Applies `extra` on top of every existing attribute run in `range`.
// ICTTMergeableAttributedString's setAttributes:range: replaces a run's whole
// dictionary, so each run's own attributes (links, fonts, timestamps,
// attachments) are carried over explicitly. Callers bracket one or more calls
// with the mergeable string's beginEditing/endEditing.
static void MergeAttributes(id mergeable, NSAttributedString *snapshot, NSRange range,
                            NSDictionary *extra, NSArray<NSString *> *remove) {
  NSMutableArray *updates = [NSMutableArray array];
  [snapshot enumerateAttributesInRange:range
                               options:0
                            usingBlock:^(NSDictionary *attrs, NSRange run, BOOL *stop) {
                              (void)stop;
                              NSMutableDictionary *merged = [attrs mutableCopy];
                              if (remove) [merged removeObjectsForKeys:remove];
                              if (extra) [merged addEntriesFromDictionary:extra];
                              [updates addObject:@[ merged, [NSValue valueWithRange:run] ]];
                            }];
  for (NSArray *update in updates)
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mergeable, sel_registerName("setAttributes:range:"),
                                                   update[0], [update[1] rangeValue]);
}

static NSAttributedString *LoadBody(NSManagedObject *note, id *mergeableOut) {
  id ms = Send(note, "mergeableString");
  NSAttributedString *body = ms ? Send(ms, "attributedString") : nil;
  if (![body isKindOfClass:[NSAttributedString class]])
    Fail(@"unsupported_note", @"The note body could not be loaded as a mergeable string", nil);
  if (mergeableOut) *mergeableOut = ms;
  return body;
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

static NSString *StyleName(unsigned int value);

static const StyleSpec *StyleNamed(NSString *name) {
  for (size_t i = 0; i < COUNT(kStyles); i++)
    if ([name isEqualToString:@(kStyles[i].name)]) return &kStyles[i];
  return NULL;
}

static BOOL IsJSONBool(id value) {
  return [value isKindOfClass:[NSNumber class]] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

#pragma mark - In-place edit

// plan_edit (read) and edit_note (write) resolve literal operations against
// ONE snapshot of the note's native attributed string, turn each into a
// (range, replacement) target, refuse overlapping targets, and apply them
// through the CRDT in descending order so no target shifts another. Nothing
// outside the targets is rewritten: untouched characters keep their CRDT
// identity, paragraph styles, checklist state, inline formatting, and
// attachment glyphs.
//
// - plan_edit opens the store read-only, rehearses the native edit in memory
//   (then rolls it back), and returns the plan plus `revisionBefore`.
// - edit_note requires `ifRevision`, which must equal the current revision.
//   Sending the same operations with the plan's revisionBefore reproduces
//   exactly the planned targets.
// - Matching is literal, case-sensitive, and confined to one paragraph. No
//   selector, replacement, or block text may contain a line break or the
//   attachment glyph U+FFFC. A target range may contain an attachment glyph
//   only when an explicit attachment selector named that one attachment, and
//   then only that attachment's glyph, so every other attachment, table, and
//   inline object is never inside an edited range.
// - Before saving, only the note, its note data, its cloud state, and the row
//   of an attachment the plan removes from the body may be dirty; anything
//   else rolls back (unexpected_side_effect).
// - After saving, a brand-new read-only Core Data stack re-reads the note and
//   proves that the text equals the plan, that every character outside the
//   edited ranges has the same attribute runs it had before (paragraph style,
//   checklist state, fonts, inline formatting, attachment references), that
//   the attachment glyph sequence is the planned one, and that every
//   attachment row other than one the plan removed is still the note's and
//   has the same stored values.
//
// Line-break trimming is the trim_blank_lines operation (PlanTrim): it
// returns whole empty paragraphs, each removed with its own newline, as
// ordinary deletion targets, so the checks above apply unchanged.
//
// Extension points. Selectors resolve through ResolveSelector(), keyed by
// `kind` (`text`, `style`, `blank`, `attachment`), so a later kind is one
// more branch that returns ranges. A target may contain an attachment glyph
// only when its selector kind says so (TargetMayTouchAttachment), and
// verification compares the persisted glyph sequence with the planned text
// rather than with the old one.

#define MAX_EDIT_OPERATIONS 64
#define MAX_EDIT_TARGETS 1000
#define MAX_EDIT_TEXT_UTF16 10000
#define MAX_EDIT_BLOCKS 200
#define MAX_EDIT_RUNS 200

static NSString *const kTimestampKey = @"TTTimestamp";
static NSString *const kAttachmentKey = @"NSAttachment";
static NSString *const kEditChangeReason = @"apple-notes-mcp edit_note";

static const unsigned int kStyleTitle = 0;
static const unsigned int kStyleBody = 3;
static const unsigned int kStyleChecklist = 103;

// Native ICTTParagraphStyle.style values by public name.
static NSDictionary<NSString *, NSNumber *> *StyleValues(void) {
  return @{
    @"title" : @0,
    @"heading" : @1,
    @"subheading" : @2,
    @"body" : @3,
    @"monospaced" : @4,
    @"bulleted" : @100,
    @"dashed" : @101,
    @"numbered" : @102,
    @"checklist" : @103,
  };
}

static NSString *StyleName(unsigned int value) {
  NSDictionary *values = StyleValues();
  for (NSString *name in values)
    if ([values[name] unsignedIntValue] == value) return name;
  return [NSString stringWithFormat:@"style_%u", value];
}

@interface EditParagraph : NSObject
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSRange content;  // text without the terminator
@property(nonatomic) NSRange full;     // text plus its "\n", when it has one
@property(nonatomic) BOOL terminated;
@end
@implementation EditParagraph
@end

// Paragraphs are split on "\n" only, which is how Notes stores them. A body
// that ends in "\n" has no trailing empty paragraph.
static NSArray<EditParagraph *> *Paragraphs(NSString *text) {
  NSMutableArray *out = [NSMutableArray array];
  NSUInteger start = 0, length = text.length;
  do {
    NSRange nl = [text rangeOfString:@"\n"
                             options:NSLiteralSearch
                               range:NSMakeRange(start, length - start)];
    EditParagraph *p = [EditParagraph new];
    p.index = out.count;
    if (nl.location == NSNotFound) {
      p.content = NSMakeRange(start, length - start);
      p.full = p.content;
      p.terminated = NO;
      [out addObject:p];
      break;
    }
    p.content = NSMakeRange(start, nl.location - start);
    p.full = NSMakeRange(start, nl.location + 1 - start);
    p.terminated = YES;
    [out addObject:p];
    start = nl.location + 1;
  } while (start < length);
  return out;
}

static unsigned int StyleValueOf(id paragraphStyle) {
  if (!paragraphStyle || ![paragraphStyle respondsToSelector:sel_registerName("style")]) return kStyleBody;
  return ((unsigned int (*)(id, SEL))objc_msgSend)(paragraphStyle, sel_registerName("style"));
}

static id ParagraphStyleAt(NSAttributedString *text, EditParagraph *p) {
  if (!p.full.length) return nil;
  return [text attribute:kStyleKey atIndex:p.full.location effectiveRange:NULL];
}

// Canonical, pointer-free text for an attribute value so two reads of the
// same stored run compare equal. Unknown classes use their description with
// memory addresses removed; a class whose description is unstable makes
// verification fail closed, never pass.
static NSString *CanonicalValue(id value) {
  if ([value isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"n:%@", value];
  if ([value isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"s:%@", value];
  if ([value isKindOfClass:[NSURL class]])
    return [NSString stringWithFormat:@"u:%@", [value absoluteString]];
  static NSRegularExpression *pointer;
  if (!pointer)
    pointer = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-fA-F]+" options:0 error:nil];
  NSString *d = [value description] ?: @"";
  d = [pointer stringByReplacingMatchesInString:d options:0 range:NSMakeRange(0, d.length) withTemplate:@""];
  return [NSString stringWithFormat:@"%@:%@", NSStringFromClass([value class]), d];
}

static NSString *CanonicalAttributes(NSDictionary *attributes, BOOL ignoreTimestamp) {
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *key in [attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (ignoreTimestamp && [key isEqualToString:kTimestampKey]) continue;
    [parts addObject:[NSString stringWithFormat:@"%@=%@", key, CanonicalValue(attributes[key])]];
  }
  return [parts componentsJoinedByString:@"\x1f"];
}

// Runs of equal canonical attributes over `range`, as [relativeStart, length,
// canonical] triples, merged so that storage-level run splits do not matter.
static NSArray *CanonicalRuns(NSAttributedString *text, NSRange range, BOOL ignoreTimestamp) {
  NSMutableArray *runs = [NSMutableArray array];
  if (!range.length) return runs;
  [text enumerateAttributesInRange:range
                           options:0
                        usingBlock:^(NSDictionary *attrs, NSRange r, BOOL *stop) {
                          (void)stop;
                          NSString *canonical = CanonicalAttributes(attrs, ignoreTimestamp);
                          NSMutableArray *last = runs.lastObject;
                          if (last && [last[2] isEqualToString:canonical]) {
                            last[1] = @([last[1] unsignedIntegerValue] + r.length);
                          } else {
                            [runs addObject:[@[ @(r.location - range.location), @(r.length), canonical ]
                                                mutableCopy]];
                          }
                        }];
  return runs;
}

static NSArray<NSString *> *AttachmentGlyphs(NSAttributedString *text) {
  NSMutableArray *glyphs = [NSMutableArray array];
  if (!text.length) return glyphs;
  [text enumerateAttribute:kAttachmentKey
                   inRange:NSMakeRange(0, text.length)
                   options:0
                usingBlock:^(id value, NSRange range, BOOL *stop) {
                  (void)stop;
                  if (!value) return;
                  // Adjacent glyphs for the same attachment form one attribute
                  // run; list each character so a duplicate glyph is counted
                  // and a removed one fails the sequence check.
                  NSString *canonical = CanonicalValue(value);
                  for (NSUInteger i = 0; i < range.length; i++) [glyphs addObject:canonical];
                }];
  return glyphs;
}

// The note's attachment rows (ICAttachment, not inline objects such as
// hashtags or note links), keyed by lowercased identifier. A row without an
// identifier is keyed by its object URI so it still takes part in the checks.
static NSDictionary<NSString *, NSManagedObject *> *AttachmentRows(NSManagedObject *note) {
  if (![note.entity.propertiesByName objectForKey:@"attachments"]) return @{};
  NSMutableDictionary *rows = [NSMutableDictionary dictionary];
  for (NSManagedObject *attachment in [note valueForKey:@"attachments"]) {
    id identifier = [attachment valueForKey:@"identifier"];
    NSString *key = [identifier isKindOfClass:[NSString class]]
                        ? [identifier lowercaseString]
                        : attachment.objectID.URIRepresentation.absoluteString;
    rows[key] = attachment;
  }
  return rows;
}

// A pointer-free digest of one attachment row's stored values. Data values
// are hashed; transient and transformed attributes (CloudKit system fields,
// wall-clock values) are skipped because their decoded objects have no stable
// canonical form. The note relationship is included, so a row that moved to
// another note does not match.
static NSString *AttachmentRowDigest(NSManagedObject *row) {
  NSMutableArray *parts = [NSMutableArray array];
  NSDictionary *attributes = row.entity.attributesByName;
  for (NSString *name in [attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attribute = attributes[name];
    if (attribute.isTransient || attribute.valueTransformerName ||
        attribute.attributeType == NSTransformableAttributeType)
      continue;
    id value = [row valueForKey:name];
    NSString *canonical;
    if (!value)
      canonical = @"nil";
    else if ([value isKindOfClass:[NSData class]])
      canonical = [@"d:" stringByAppendingString:SHA256Hex(value)];
    else
      canonical = CanonicalValue(value);
    [parts addObject:[NSString stringWithFormat:@"%@=%@", name, canonical]];
  }
  id owner = row.entity.relationshipsByName[@"note"] ? [row valueForKey:@"note"] : nil;
  id ownerIdentifier = owner ? ([owner valueForKey:@"identifier"] ?: @"?") : @"nil";
  [parts addObject:[NSString stringWithFormat:@"note=%@", ownerIdentifier]];
  return SHA256Hex([[parts componentsJoinedByString:@"\x1f"] dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSDictionary<NSString *, NSString *> *AttachmentRowDigests(
    NSDictionary<NSString *, NSManagedObject *> *rows) {
  NSMutableDictionary *digests = [NSMutableDictionary dictionary];
  for (NSString *key in rows) digests[key] = AttachmentRowDigest(rows[key]);
  return digests;
}

// One entry per attachment glyph (U+FFFC carrying an attachment attribute)
// in body order: its location and the attachment's identifier and type as
// the native string records them.
static NSArray<NSDictionary *> *AttachmentGlyphEntries(NSAttributedString *text) {
  NSMutableArray *entries = [NSMutableArray array];
  NSString *string = text.string;
  SEL identifierSel = sel_registerName("attachmentIdentifier");
  SEL utiSel = sel_registerName("attachmentUTI");
  for (NSUInteger i = 0; i < string.length; i++) {
    if ([string characterAtIndex:i] != 0xFFFC) continue;
    id value = [text attribute:kAttachmentKey atIndex:i effectiveRange:NULL];
    if (!value) continue;
    id identifier = [value respondsToSelector:identifierSel] ? Send(value, "attachmentIdentifier") : nil;
    id uti = [value respondsToSelector:utiSel] ? Send(value, "attachmentUTI") : nil;
    [entries addObject:@{
      @"location" : @(i),
      @"identifier" : [identifier isKindOfClass:[NSString class]] ? identifier : @"",
      @"uti" : [uti isKindOfClass:[NSString class]] ? uti : [NSNull null],
    }];
  }
  return entries;
}

#pragma mark Request parsing

static void RejectUnknownKeys(NSDictionary *object, NSArray *allowed, NSString *what) {
  NSSet *set = [NSSet setWithArray:allowed];
  for (NSString *key in object)
    if (![set containsObject:key])
      Fail(@"invalid_request", [NSString stringWithFormat:@"Unknown field `%@` in %@", key, what], nil);
}

static BOOL OptionalBool(NSDictionary *object, NSString *key, BOOL fallback) {
  id value = object[key];
  if (!value) return fallback;
  if (!IsJSONBool(value))
    Fail(@"invalid_request", [NSString stringWithFormat:@"`%@` must be a boolean", key], nil);
  return [value boolValue];
}

static NSUInteger OptionalCount(NSDictionary *object, NSString *key, NSUInteger fallback, NSUInteger max) {
  id value = object[key];
  if (!value) return fallback;
  if (![value isKindOfClass:[NSNumber class]] || IsJSONBool(value) ||
      [value doubleValue] != (double)[value longLongValue] || [value longLongValue] < 1 ||
      [value longLongValue] > (long long)max)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"`%@` must be an integer from 1 to %lu", key, (unsigned long)max],
         nil);
  return (NSUInteger)[value longLongValue];
}

static NSDictionary *RequireObject(NSDictionary *object, NSString *key) {
  id value = object[key];
  if (![value isKindOfClass:[NSDictionary class]])
    Fail(@"invalid_request", [NSString stringWithFormat:@"`%@` must be an object", key], nil);
  return value;
}

static NSString *OptionalEnum(NSDictionary *object, NSString *key, NSArray *allowed, NSString *fallback) {
  id value = object[key];
  if (!value) return fallback;
  if (![value isKindOfClass:[NSString class]] || ![allowed containsObject:value])
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"`%@` must be one of %@", key, [allowed componentsJoinedByString:@", "]],
         nil);
  return value;
}

// Text that must stay inside one paragraph: no line or paragraph breaks, no
// attachment glyph, no control characters other than tab.
static NSString *EditText(id value, NSString *what, BOOL allowEmpty) {
  if (![value isKindOfClass:[NSString class]])
    Fail(@"invalid_request", [NSString stringWithFormat:@"%@ must be a string", what], nil);
  NSString *text = value;
  if (!allowEmpty && !text.length)
    Fail(@"invalid_request", [NSString stringWithFormat:@"%@ must not be empty", what], nil);
  if (text.length > MAX_EDIT_TEXT_UTF16)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"%@ exceeds %d UTF-16 code units", what, MAX_EDIT_TEXT_UTF16], nil);
  if ([text rangeOfCharacterFromSet:ForbiddenTextCharacters(NO)].location != NSNotFound)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"%@ must stay inside one paragraph: no line breaks, attachment "
                                    @"glyphs, or control characters",
                                    what],
         nil);
  return text;
}

static NSNumber *StyleFromName(id value, NSString *what) {
  NSNumber *style = [value isKindOfClass:[NSString class]] ? StyleValues()[value] : nil;
  if (!style)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"%@ must be one of %@", what,
                                    [[StyleValues().allKeys sortedArrayUsingSelector:@selector(compare:)]
                                        componentsJoinedByString:@", "]],
         nil);
  return style;
}

static NSArray *EditOperations(NSDictionary *request) {
  NSArray *operations = request[@"operations"];
  if (![operations isKindOfClass:[NSArray class]] || !operations.count ||
      operations.count > MAX_EDIT_OPERATIONS)
    Fail(@"invalid_request", @"`operations` must be an array of 1 to 64 operations", nil);
  for (id operation in operations)
    if (![operation isKindOfClass:[NSDictionary class]])
      Fail(@"invalid_request", @"Every operation must be an object", nil);
  return operations;
}

#pragma mark Replacement construction

static NSMutableDictionary *InlineBase(NSDictionary *attributes) {
  NSMutableDictionary *base = [attributes mutableCopy] ?: [NSMutableDictionary dictionary];
  [base removeObjectsForKeys:@[ kHintsKey, kUnderlineKey, kStrikethroughKey, kTimestampKey, kAttachmentKey ]];
  return base;
}

// `runs` replacement: each run is plain text plus explicit inline flags laid
// over `base` (the paragraph style and font of the replaced range).
static NSAttributedString *AttributedRuns(id value, NSDictionary *base, NSString *what) {
  if (![value isKindOfClass:[NSArray class]] || ![value count] || [value count] > MAX_EDIT_RUNS)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"%@ must be an array of 1 to %d runs", what, MAX_EDIT_RUNS], nil);
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  for (id run in value) {
    if (![run isKindOfClass:[NSDictionary class]])
      Fail(@"invalid_request", [NSString stringWithFormat:@"%@ entries must be objects", what], nil);
    RejectUnknownKeys(run, @[ @"text", @"bold", @"italic", @"underline", @"strikethrough" ], what);
    NSString *text = EditText(run[@"text"], [what stringByAppendingString:@" text"], NO);
    NSMutableDictionary *attrs = [base mutableCopy];
    NSUInteger hints =
        (OptionalBool(run, @"bold", NO) ? 1 : 0) | (OptionalBool(run, @"italic", NO) ? 2 : 0);
    if (hints) attrs[kHintsKey] = @(hints);
    if (OptionalBool(run, @"underline", NO)) attrs[kUnderlineKey] = @1;
    if (OptionalBool(run, @"strikethrough", NO)) attrs[kStrikethroughKey] = @1;
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
  }
  if (out.length > MAX_EDIT_TEXT_UTF16)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"%@ exceed %d UTF-16 code units", what, MAX_EDIT_TEXT_UTF16], nil);
  return out;
}

static id NewParagraphStyle(unsigned int value, BOOL checked) {
  id style = [[objc_getClass("ICTTMutableParagraphStyle") alloc] init];
  if (!style) Fail(@"private_api_unavailable", @"Could not create a native paragraph style", nil);
  ((void (*)(id, SEL, unsigned int))objc_msgSend)(style, sel_registerName("setStyle:"), value);
  if (value == kStyleChecklist) {
    id todo = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(
        [objc_getClass("ICTTTodo") alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], checked);
    if (!todo) Fail(@"private_api_unavailable", @"Could not create a native checklist item", nil);
    ((void (*)(id, SEL, id))objc_msgSend)(style, sel_registerName("setTodo:"), todo);
  }
  return [style copy];
}

// Whole paragraphs for an insert. Each block gets a fresh native paragraph
// style (and, for checklist rows, a fresh todo with the requested state).
// With `separatorAttributes`, the blocks follow a newline that terminates the
// anchor paragraph and carries the anchor's own paragraph style; the last
// block then has no terminator, matching a note that did not end in "\n".
static NSAttributedString *AttributedBlocks(id value, NSDictionary *separatorAttributes, NSString *what) {
  if (![value isKindOfClass:[NSArray class]] || ![value count] || [value count] > MAX_EDIT_BLOCKS)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"%@ must be an array of 1 to %d blocks", what, MAX_EDIT_BLOCKS], nil);
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  if (separatorAttributes)
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                                                                attributes:separatorAttributes]];
  NSUInteger count = [value count], i = 0;
  for (id block in value) {
    if (![block isKindOfClass:[NSDictionary class]])
      Fail(@"invalid_request", [NSString stringWithFormat:@"%@ entries must be objects", what], nil);
    RejectUnknownKeys(block, @[ @"type", @"text", @"runs", @"checked" ], what);
    NSNumber *style = StyleFromName(block[@"type"], @"block type");
    if (style.unsignedIntValue == kStyleTitle)
      Fail(@"title_invariant", @"Inserted blocks cannot be titles; use set_title", @{@"committed" : @NO});
    if (block[@"checked"] && style.unsignedIntValue != kStyleChecklist)
      Fail(@"invalid_request", @"`checked` is only valid on checklist blocks", nil);
    id paragraphStyle = NewParagraphStyle(style.unsignedIntValue, OptionalBool(block, @"checked", NO));
    NSDictionary *base = @{kStyleKey : paragraphStyle};
    if ((block[@"text"] != nil) == (block[@"runs"] != nil))
      Fail(@"invalid_request", @"Each block needs exactly one of `text` or `runs`", nil);
    NSAttributedString *content =
        block[@"runs"]
            ? AttributedRuns(block[@"runs"], base, @"block runs")
            : [[NSAttributedString alloc]
                  initWithString:EditText(block[@"text"], @"block text", style.unsignedIntValue == kStyleBody)
                      attributes:base];
    [out appendAttributedString:content];
    BOOL last = ++i == count;
    if (!(separatorAttributes && last))
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:base]];
  }
  return out;
}

#pragma mark Selectors

static NSArray<EditParagraph *> *ScopeParagraphs(NSArray<EditParagraph *> *paragraphs, NSString *scope) {
  if ([scope isEqualToString:@"all"]) return paragraphs;
  if ([scope isEqualToString:@"title"]) return paragraphs.count ? @[ paragraphs.firstObject ] : @[];
  return paragraphs.count > 1 ? [paragraphs subarrayWithRange:NSMakeRange(1, paragraphs.count - 1)] : @[];
}

// A text selector resolves to ranges inside single paragraphs. `substring`
// finds every non-overlapping literal occurrence; `equals` matches a
// paragraph whose entire text is the literal.
static NSArray<NSDictionary *> *ResolveText(NSDictionary *selector, NSString *match,
                                            NSAttributedString *snapshot,
                                            NSArray<EditParagraph *> *paragraphs, NSString *defaultScope) {
  NSString *literal = EditText(selector[@"text"], @"selector text", NO);
  NSString *scope = OptionalEnum(selector, @"scope", @[ @"body", @"title", @"all" ], defaultScope);
  NSString *text = snapshot.string;
  NSMutableArray *hits = [NSMutableArray array];
  for (EditParagraph *p in ScopeParagraphs(paragraphs, scope)) {
    if ([match isEqualToString:@"equals"]) {
      if ([[text substringWithRange:p.content] isEqualToString:literal])
        [hits addObject:@{@"range" : [NSValue valueWithRange:p.content], @"paragraph" : p}];
      continue;
    }
    NSUInteger cursor = p.content.location, end = NSMaxRange(p.content);
    while (cursor < end) {
      NSRange found = [text rangeOfString:literal
                                  options:NSLiteralSearch
                                    range:NSMakeRange(cursor, end - cursor)];
      if (found.location == NSNotFound) break;
      [hits addObject:@{@"range" : [NSValue valueWithRange:found], @"paragraph" : p}];
      cursor = NSMaxRange(found);
    }
  }
  return hits;
}

static NSArray<NSDictionary *> *ResolveStyle(NSDictionary *selector, NSAttributedString *snapshot,
                                             NSArray<EditParagraph *> *paragraphs, BOOL blankOnly) {
  unsigned int wanted = StyleFromName(selector[@"style"], @"selector style").unsignedIntValue;
  NSMutableArray *hits = [NSMutableArray array];
  for (EditParagraph *p in paragraphs) {
    if (StyleValueOf(ParagraphStyleAt(snapshot, p)) != wanted) continue;
    if (blankOnly) {
      NSString *content = [snapshot.string substringWithRange:p.content];
      if ([content rangeOfString:@"\uFFFC"].location != NSNotFound) continue;
      if ([content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) continue;
    }
    [hits addObject:@{@"range" : [NSValue valueWithRange:p.content], @"paragraph" : p}];
  }
  return hits;
}

static const APIRequirement kAttachmentSelectorAPI[] = {
    {"ICTTAttachment", "attachmentIdentifier", NO},
    {"ICTTAttachment", "attachmentUTI", NO},
};

static EditParagraph *ParagraphAt(NSArray<EditParagraph *> *paragraphs, NSUInteger location) {
  for (EditParagraph *p in paragraphs)
    if (location >= p.full.location && location < NSMaxRange(p.full)) return p;
  return nil;
}

// An attachment selector names one of the note's attachment rows by
// `identifier` (its Notes UUID), `id` (its x-coredata ICAttachment URI, as
// list-attachments and get-note-structure return it), or `ordinal` (1-based
// position among the body's attachment glyphs that belong to the note's
// attachment rows; inline objects such as hashtags and note links are not
// counted and cannot be selected). Per role:
//   replace  `position` self (default) targets the glyph itself, so the
//            replacement text takes its place (empty text removes it);
//            before/after target the empty range next to the glyph, so the
//            replacement text is inserted inline beside it.
//   delete   the paragraph holding the glyph, which must hold nothing else
//            but whitespace.
//   anchor   the paragraph holding the glyph.
// Each hit carries `glyph` (the one glyph location its target may contain)
// and `attachment` (what the plan reports about it).
static NSArray<NSDictionary *> *ResolveAttachment(NSDictionary *selector, NSString *role,
                                                  NSAttributedString *snapshot,
                                                  NSArray<EditParagraph *> *paragraphs,
                                                  NSDictionary<NSString *, NSManagedObject *> *rows) {
  NSMutableArray *keys = [@[ @"kind", @"identifier", @"id", @"ordinal", @"occurrence" ] mutableCopy];
  BOOL replace = [role isEqualToString:@"replace"];
  if (replace) [keys addObject:@"position"];
  RejectUnknownKeys(selector, keys, @"attachment selector");
  NSUInteger given =
      (selector[@"identifier"] ? 1 : 0) + (selector[@"id"] ? 1 : 0) + (selector[@"ordinal"] ? 1 : 0);
  if (given != 1)
    Fail(@"invalid_request",
         @"An attachment selector needs exactly one of `identifier`, `id`, or `ordinal`", nil);
  NSArray *missing = MissingAPI(kAttachmentSelectorAPI, COUNT(kAttachmentSelectorAPI));
  if (missing.count)
    Fail(@"private_api_unavailable", @"Attachment selectors need NotesShared's attachment accessors",
         @{@"missing" : missing});
  NSString *position = replace ? OptionalEnum(selector, @"position", @[ @"self", @"before", @"after" ], @"self")
                               : @"self";

  NSString *wanted = nil;
  if (selector[@"identifier"]) {
    if (!IsUUID(selector[@"identifier"]))
      Fail(@"invalid_request", @"attachment selector `identifier` must be a Notes UUID", nil);
    wanted = [selector[@"identifier"] lowercaseString];
  } else if (selector[@"id"]) {
    id uri = selector[@"id"];
    if (![uri isKindOfClass:[NSString class]] || ![uri hasPrefix:@"x-coredata://"] ||
        [uri rangeOfString:@"/ICAttachment/p"].location == NSNotFound)
      Fail(@"invalid_request", @"attachment selector `id` must be an x-coredata ICAttachment id", nil);
    wanted = @"";  // an id that names none of this note's rows matches nothing
    for (NSString *key in rows)
      if ([rows[key].objectID.URIRepresentation.absoluteString caseInsensitiveCompare:uri] == NSOrderedSame)
        wanted = key;
  }
  NSUInteger ordinal = OptionalCount(selector, @"ordinal", 0, MAX_EDIT_TARGETS);

  NSMutableArray *hits = [NSMutableArray array];
  NSUInteger seen = 0;
  for (NSDictionary *entry in AttachmentGlyphEntries(snapshot)) {
    NSString *key = [entry[@"identifier"] lowercaseString];
    if (!rows[key]) continue;  // inline objects are never selectable
    seen++;
    if (ordinal ? seen != ordinal : ![key isEqualToString:wanted]) continue;
    NSUInteger glyph = [entry[@"location"] unsignedIntegerValue];
    EditParagraph *p = ParagraphAt(paragraphs, glyph);
    if (!p) continue;
    NSRange range;
    if (replace) {
      range = [position isEqualToString:@"before"] ? NSMakeRange(glyph, 0)
              : [position isEqualToString:@"after"] ? NSMakeRange(glyph + 1, 0)
                                                    : NSMakeRange(glyph, 1);
    } else {
      range = p.content;
    }
    if ([role isEqualToString:@"delete"]) {
      NSMutableString *rest = [[snapshot.string substringWithRange:p.content] mutableCopy];
      [rest deleteCharactersInRange:NSMakeRange(glyph - p.content.location, 1)];
      if ([rest rangeOfString:@"￼"].location != NSNotFound ||
          [rest stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length)
        Fail(@"unsupported_selection",
             @"The attachment's paragraph holds other text or objects; remove just the attachment with "
             @"replace (position self, empty text) instead",
             @{@"committed" : @NO});
    }
    [hits addObject:@{
      @"range" : [NSValue valueWithRange:range],
      @"paragraph" : p,
      @"glyph" : @(glyph),
      @"position" : position,
      @"attachment" : @{
        @"identifier" : [rows[key] valueForKey:@"identifier"] ?: entry[@"identifier"],
        @"uti" : entry[@"uti"],
        @"ordinal" : @(seen),
      },
    }];
  }
  return hits;
}

// One entry point for every selector kind an operation role accepts. Roles:
// "replace" (text, substring or equals; or one attachment), "delete" (text
// equals, blank styled rows, or an attachment's own paragraph), "anchor"
// (text equals, style, or an attachment's paragraph). A new kind is one more
// branch here plus its entry in the role's allowed list.
static NSArray<NSDictionary *> *ResolveSelector(NSDictionary *selector, NSString *role,
                                                NSAttributedString *snapshot,
                                                NSArray<EditParagraph *> *paragraphs,
                                                NSDictionary<NSString *, NSManagedObject *> *rows,
                                                NSString **kindOut) {
  NSArray *kinds = [role isEqualToString:@"replace"]  ? @[ @"text", @"attachment" ]
                   : [role isEqualToString:@"delete"] ? @[ @"text", @"blank", @"attachment" ]
                                                      : @[ @"text", @"style", @"attachment" ];
  NSString *kind = OptionalEnum(selector, @"kind", kinds, @"text");
  if (kindOut) *kindOut = kind;
  if ([kind isEqualToString:@"attachment"]) return ResolveAttachment(selector, role, snapshot, paragraphs, rows);
  if ([kind isEqualToString:@"text"]) {
    if ([role isEqualToString:@"replace"]) {
      RejectUnknownKeys(selector, @[ @"kind", @"text", @"scope", @"match", @"occurrence" ], @"text selector");
      NSString *match = OptionalEnum(selector, @"match", @[ @"substring", @"equals" ], @"substring");
      return ResolveText(selector, match, snapshot, paragraphs, @"body");
    }
    RejectUnknownKeys(selector, @[ @"kind", @"text", @"scope", @"occurrence" ], @"text selector");
    return ResolveText(selector, @"equals", snapshot, paragraphs,
                       [role isEqualToString:@"anchor"] ? @"all" : @"body");
  }
  if ([kind isEqualToString:@"blank"]) {
    RejectUnknownKeys(selector, @[ @"kind", @"style", @"occurrence" ], @"blank selector");
    // Blank body paragraphs are ordinary spacing, and the title is never
    // deleted, so a blank selector names a list, checklist, or heading row.
    unsigned int blankStyle = StyleFromName(selector[@"style"], @"selector style").unsignedIntValue;
    if (blankStyle == kStyleTitle || blankStyle == kStyleBody)
      Fail(@"invalid_request", @"A blank selector needs a style other than title or body", nil);
    return ResolveStyle(selector, snapshot, paragraphs, YES);
  }
  RejectUnknownKeys(selector, @[ @"kind", @"style", @"occurrence" ], @"style anchor");
  return ResolveStyle(selector, snapshot, paragraphs, NO);
}

// Whether a target resolved by this selector kind may contain an attachment
// glyph. Only an explicit attachment selector may, and then only the glyph
// of the attachment it named (RequireNoAttachmentGlyph checks the location).
static BOOL TargetMayTouchAttachment(NSString *kind) {
  return [kind isEqualToString:@"attachment"];
}

// Applies expectedCount (must equal the full match count) and occurrence
// (1-based; picks one match without changing what must exist).
static NSArray<NSDictionary *> *CountAndPick(NSArray<NSDictionary *> *hits, NSDictionary *operation,
                                             NSDictionary *selector, NSUInteger index) {
  NSUInteger expected = OptionalCount(operation, @"expectedCount", 1, MAX_EDIT_TARGETS);
  NSUInteger occurrence = OptionalCount(selector, @"occurrence", 0, MAX_EDIT_TARGETS);
  if (hits.count != expected)
    Fail(@"match_count_mismatch",
         [NSString stringWithFormat:@"Operation %lu matched %lu time(s); expectedCount is %lu",
                                    (unsigned long)index, (unsigned long)hits.count, (unsigned long)expected],
         @{@"committed" : @NO, @"operationIndex" : @(index), @"matchedCount" : @(hits.count)});
  if (occurrence > hits.count)
    Fail(@"invalid_request",
         [NSString stringWithFormat:@"Operation %lu occurrence exceeds its matches", (unsigned long)index], nil);
  return occurrence ? @[ hits[occurrence - 1] ] : hits;
}

#pragma mark Planning

static NSMutableDictionary *Target(NSRange range, NSAttributedString *replacement, NSUInteger operation,
                                   EditParagraph *paragraph) {
  return [@{
    @"range" : [NSValue valueWithRange:range],
    @"replacement" : replacement,
    @"operation" : @(operation),
    @"paragraph" : @(paragraph.index),
  } mutableCopy];
}

// Refuses a target range that contains an attachment glyph, except the one
// glyph (`allowedGlyph`) an attachment selector named. Every other glyph,
// including a second attachment in the same paragraph, is refused.
static void RequireNoAttachmentGlyph(NSAttributedString *snapshot, NSRange range, NSUInteger index,
                                     NSString *kind, NSUInteger allowedGlyph) {
  if (!TargetMayTouchAttachment(kind)) allowedGlyph = NSNotFound;
  NSString *text = snapshot.string;
  NSUInteger cursor = range.location, end = NSMaxRange(range);
  while (cursor < end) {
    NSRange found = [text rangeOfString:@"\uFFFC"
                                options:NSLiteralSearch
                                  range:NSMakeRange(cursor, end - cursor)];
    if (found.location == NSNotFound) return;
    if (found.location != allowedGlyph)
      Fail(@"unsupported_selection",
           [NSString stringWithFormat:@"Operation %lu would touch an attachment, table, or inline object it "
                                      @"did not select; those are never edited",
                                      (unsigned long)index],
           @{@"committed" : @NO, @"operationIndex" : @(index)});
    cursor = NSMaxRange(found);
  }
}

static NSUInteger HitGlyph(NSDictionary *hit) {
  return hit[@"glyph"] ? [hit[@"glyph"] unsignedIntegerValue] : NSNotFound;
}

// Plain replacement text inherits the replaced range's attributes, which is
// only meaningful when that range is uniformly formatted. `attributesAt`
// overrides where those attributes are read (an attachment glyph, for text
// inserted beside it); NSNotFound keeps the default.
static NSAttributedString *ReplacementFor(NSDictionary *replacement, NSAttributedString *snapshot,
                                          NSRange range, EditParagraph *paragraph, NSUInteger index,
                                          BOOL allowEmpty, NSUInteger attributesAt) {
  RejectUnknownKeys(replacement, @[ @"text", @"runs" ], @"replacement");
  if ((replacement[@"text"] != nil) == (replacement[@"runs"] != nil))
    Fail(@"invalid_request", @"replacement needs exactly one of `text` or `runs`", nil);
  NSUInteger at = attributesAt != NSNotFound ? attributesAt
                  : range.length             ? range.location
                                             : paragraph.full.location;
  NSDictionary *attributes = at < snapshot.length ? [snapshot attributesAtIndex:at effectiveRange:NULL] : @{};
  if (replacement[@"runs"])
    return AttributedRuns(replacement[@"runs"], InlineBase(attributes), @"replacement runs");
  NSString *text = EditText(replacement[@"text"], @"replacement text", allowEmpty);
  if (range.length && CanonicalRuns(snapshot, range, YES).count > 1)
    Fail(@"mixed_formatting",
         [NSString stringWithFormat:@"Operation %lu matches text with mixed formatting; pass "
                                    @"replacement.runs to say how the new text is formatted",
                                    (unsigned long)index],
         @{@"committed" : @NO, @"operationIndex" : @(index)});
  NSMutableDictionary *inherited = [attributes mutableCopy];
  [inherited removeObjectsForKeys:@[ kTimestampKey, kAttachmentKey ]];
  return [[NSAttributedString alloc] initWithString:text attributes:inherited];
}

#pragma mark Line-break trimming

#define MAX_TRIM_KEEP 10

// A paragraph trim_blank_lines may remove: not the title, no attachment or
// inline object, nothing but whitespace, and a text style (title, heading,
// subheading, or body). Empty list and checklist rows are visible bullets
// (delete them with a blank selector), and empty monospaced lines belong to
// code blocks, so neither is trimmed.
static BOOL IsTrimmableBlank(NSAttributedString *snapshot, EditParagraph *p) {
  if (p.index == 0) return NO;
  NSString *content = [snapshot.string substringWithRange:p.content];
  if ([content rangeOfString:@"\uFFFC"].location != NSNotFound) return NO;
  if ([content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) return NO;
  unsigned int style = StyleValueOf(ParagraphStyleAt(snapshot, p));
  return style == kStyleTitle || style == 1 || style == 2 || style == kStyleBody;
}

// Maximal runs of consecutive trimmable paragraphs, as arrays of paragraphs.
static NSArray<NSArray<EditParagraph *> *> *BlankRuns(NSAttributedString *snapshot,
                                                     NSArray<EditParagraph *> *paragraphs) {
  NSMutableArray *runs = [NSMutableArray array];
  NSMutableArray *current = nil;
  for (EditParagraph *p in paragraphs) {
    if (IsTrimmableBlank(snapshot, p)) {
      if (!current) current = [NSMutableArray array];
      [current addObject:p];
    } else if (current) {
      [runs addObject:current];
      current = nil;
    }
  }
  if (current) [runs addObject:current];
  return runs;
}

// The run of trimmable paragraphs directly before (or after) the anchor
// paragraph, stopping at the first paragraph that is not trimmable.
static NSArray<EditParagraph *> *AdjacentBlankRun(NSAttributedString *snapshot,
                                                  NSArray<EditParagraph *> *paragraphs, EditParagraph *anchor,
                                                  BOOL before) {
  NSMutableArray *run = [NSMutableArray array];
  if (before) {
    for (NSInteger i = (NSInteger)anchor.index - 1; i >= 0 && IsTrimmableBlank(snapshot, paragraphs[i]); i--)
      [run insertObject:paragraphs[i] atIndex:0];
  } else {
    for (NSUInteger i = anchor.index + 1; i < paragraphs.count && IsTrimmableBlank(snapshot, paragraphs[i]); i++)
      [run addObject:paragraphs[i]];
  }
  return run;
}

// trim_blank_lines removes redundant empty paragraphs, each with its own
// terminating newline, so every non-empty paragraph keeps its characters,
// its terminator, and its paragraph style. mode:
//   runs    in every run of blank paragraphs, keep the first `keep`
//           (default 1) and remove the rest;
//   end     the run that ends the note: keep the first `keep` (default 0);
//   around  the runs directly before and/or after (`side`, default both) the
//           one paragraph `anchor` names: keep the first `keep` (default 0).
// Returns the paragraphs to remove, in document order.
static NSArray<EditParagraph *> *PlanTrim(NSDictionary *operation, NSUInteger index, NSAttributedString *snapshot,
                                          NSArray<EditParagraph *> *paragraphs,
                                          NSDictionary<NSString *, NSManagedObject *> *rows,
                                          NSMutableDictionary *summary) {
  NSString *mode = OptionalEnum(operation, @"mode", @[ @"runs", @"end", @"around" ], nil);
  if (!mode) Fail(@"invalid_request", @"trim_blank_lines needs `mode`", nil);
  BOOL around = [mode isEqualToString:@"around"];
  RejectUnknownKeys(operation,
                    around ? @[ @"op", @"id", @"mode", @"keep", @"anchor", @"side", @"expectedCount" ]
                           : @[ @"op", @"id", @"mode", @"keep", @"expectedCount" ],
                    @"trim_blank_lines operation");
  NSUInteger keep = [mode isEqualToString:@"runs"] ? 1 : 0;
  if (operation[@"keep"]) {
    id value = operation[@"keep"];
    if (![value isKindOfClass:[NSNumber class]] || IsJSONBool(value) ||
        [value doubleValue] != (double)[value longLongValue] || [value longLongValue] < 0 ||
        [value longLongValue] > MAX_TRIM_KEEP)
      Fail(@"invalid_request",
           [NSString stringWithFormat:@"`keep` must be an integer from 0 to %d", MAX_TRIM_KEEP], nil);
    keep = (NSUInteger)[value longLongValue];
  }
  summary[@"mode"] = mode;
  summary[@"keep"] = @(keep);

  NSMutableArray<NSArray<EditParagraph *> *> *runs = [NSMutableArray array];
  if ([mode isEqualToString:@"runs"]) {
    [runs addObjectsFromArray:BlankRuns(snapshot, paragraphs)];
  } else if ([mode isEqualToString:@"end"]) {
    NSArray *last = BlankRuns(snapshot, paragraphs).lastObject;
    if (last && [last lastObject] == paragraphs.lastObject) [runs addObject:last];
  } else {
    NSDictionary *anchor = RequireObject(operation, @"anchor");
    NSString *side = OptionalEnum(operation, @"side", @[ @"before", @"after", @"both" ], @"both");
    NSString *kind = nil;
    NSArray *hits = ResolveSelector(anchor, @"anchor", snapshot, paragraphs, rows, &kind);
    NSUInteger occurrence = OptionalCount(anchor, @"occurrence", 0, MAX_EDIT_TARGETS);
    if (occurrence ? occurrence > hits.count : hits.count != 1)
      Fail(@"match_count_mismatch",
           [NSString stringWithFormat:@"Operation %lu anchor matched %lu paragraph(s); it must name exactly one "
                                      @"(use occurrence)",
                                      (unsigned long)index, (unsigned long)hits.count],
           @{@"committed" : @NO, @"operationIndex" : @(index), @"matchedCount" : @(hits.count)});
    EditParagraph *anchorParagraph = hits[occurrence ? occurrence - 1 : 0][@"paragraph"];
    if (![side isEqualToString:@"after"])
      [runs addObject:AdjacentBlankRun(snapshot, paragraphs, anchorParagraph, YES)];
    if (![side isEqualToString:@"before"])
      [runs addObject:AdjacentBlankRun(snapshot, paragraphs, anchorParagraph, NO)];
    summary[@"anchorKind"] = kind;
    summary[@"anchorParagraphIndex"] = @(anchorParagraph.index);
    summary[@"side"] = side;
  }

  NSMutableArray *removed = [NSMutableArray array];
  NSUInteger blankParagraphs = 0;
  for (NSArray<EditParagraph *> *run in runs) {
    blankParagraphs += run.count;
    if (run.count > keep)
      [removed addObjectsFromArray:[run subarrayWithRange:NSMakeRange(keep, run.count - keep)]];
  }
  summary[@"blankRuns"] = @(runs.count);
  summary[@"blankParagraphs"] = @(blankParagraphs);
  if (operation[@"expectedCount"]) {
    NSUInteger expected = OptionalCount(operation, @"expectedCount", 1, MAX_EDIT_TARGETS);
    if (removed.count != expected)
      Fail(@"match_count_mismatch",
           [NSString stringWithFormat:@"Operation %lu would remove %lu empty paragraph(s); expectedCount is %lu",
                                      (unsigned long)index, (unsigned long)removed.count,
                                      (unsigned long)expected],
           @{@"committed" : @NO, @"operationIndex" : @(index), @"matchedCount" : @(removed.count)});
  }
  return removed;
}

static NSDictionary *PlanOperation(NSDictionary *operation, NSUInteger index, NSAttributedString *snapshot,
                                   NSArray<EditParagraph *> *paragraphs,
                                   NSDictionary<NSString *, NSManagedObject *> *rows, NSMutableArray *targets) {
  NSString *op = OptionalEnum(
      operation, @"op",
      @[ @"replace", @"delete_paragraph", @"insert_after", @"insert_before", @"set_title", @"trim_blank_lines" ],
      nil);
  if (!op) Fail(@"invalid_request", @"Every operation needs `op`", nil);
  NSMutableDictionary *summary = [@{@"index" : @(index), @"op" : op} mutableCopy];
  if (operation[@"id"]) {
    id opId = operation[@"id"];
    if (![opId isKindOfClass:[NSString class]] || ![opId length] || [opId length] > 128)
      Fail(@"invalid_request", @"operation `id` must be a string of 1 to 128 characters", nil);
    summary[@"id"] = opId;
  }
  NSMutableArray *created = [NSMutableArray array];
  NSString *kind = nil;

  if ([op isEqualToString:@"set_title"]) {
    RejectUnknownKeys(operation, @[ @"op", @"id", @"replacement" ], @"set_title operation");
    EditParagraph *title = paragraphs.firstObject;
    NSDictionary *replacement = RequireObject(operation, @"replacement");
    RequireNoAttachmentGlyph(snapshot, title.content, index, @"title", NSNotFound);
    NSAttributedString *text =
        ReplacementFor(replacement, snapshot, title.content, title, index, NO, NSNotFound);
    [created addObject:Target(title.content, text, index, title)];
  } else if ([op isEqualToString:@"replace"]) {
    RejectUnknownKeys(operation, @[ @"op", @"id", @"selector", @"replacement", @"expectedCount" ],
                      @"replace operation");
    NSDictionary *selector = RequireObject(operation, @"selector");
    NSDictionary *replacement = RequireObject(operation, @"replacement");
    NSArray *hits = ResolveSelector(selector, @"replace", snapshot, paragraphs, rows, &kind);
    for (NSDictionary *hit in CountAndPick(hits, operation, selector, index)) {
      NSRange range = [hit[@"range"] rangeValue];
      EditParagraph *p = hit[@"paragraph"];
      NSUInteger glyph = HitGlyph(hit);
      RequireNoAttachmentGlyph(snapshot, range, index, kind, glyph);
      // Text beside an attachment must not be empty: an empty insertion is
      // no edit at all. Replacing the glyph itself may be empty (removal).
      BOOL allowEmpty = range.length > 0;
      NSMutableDictionary *target =
          Target(range, ReplacementFor(replacement, snapshot, range, p, index, allowEmpty, glyph), index, p);
      if (hit[@"attachment"]) target[@"attachment"] = hit[@"attachment"];
      [created addObject:target];
    }
    summary[@"selectorKind"] = kind;
    if ([kind isEqualToString:@"text"]) summary[@"match"] = selector[@"match"] ?: @"substring";
    if ([kind isEqualToString:@"attachment"]) summary[@"position"] = selector[@"position"] ?: @"self";
  } else if ([op isEqualToString:@"delete_paragraph"]) {
    RejectUnknownKeys(operation, @[ @"op", @"id", @"selector", @"expectedCount" ],
                      @"delete_paragraph operation");
    NSDictionary *selector = RequireObject(operation, @"selector");
    NSArray *hits = ResolveSelector(selector, @"delete", snapshot, paragraphs, rows, &kind);
    for (NSDictionary *hit in CountAndPick(hits, operation, selector, index)) {
      EditParagraph *p = hit[@"paragraph"];
      if (p.index == 0)
        Fail(@"title_invariant", @"The title paragraph cannot be deleted", @{@"committed" : @NO});
      NSRange range = p.full;
      if (!p.terminated) {
        // The last paragraph has no terminator: remove the newline before it
        // instead, which leaves the previous paragraph as the last one.
        EditParagraph *previous = paragraphs[p.index - 1];
        range = NSMakeRange(NSMaxRange(previous.content),
                            NSMaxRange(p.content) - NSMaxRange(previous.content));
      }
      RequireNoAttachmentGlyph(snapshot, range, index, kind, HitGlyph(hit));
      NSMutableDictionary *target = Target(range, [NSAttributedString new], index, p);
      if (hit[@"attachment"]) target[@"attachment"] = hit[@"attachment"];
      [created addObject:target];
    }
    summary[@"selectorKind"] = kind;
  } else if ([op isEqualToString:@"trim_blank_lines"]) {
    for (EditParagraph *p in PlanTrim(operation, index, snapshot, paragraphs, rows, summary)) {
      // Each paragraph goes with its own terminator; an unterminated last
      // paragraph (whitespace only) goes alone and leaves the previous
      // terminator in place, so no other paragraph loses its newline.
      RequireNoAttachmentGlyph(snapshot, p.full, index, @"trim", NSNotFound);
      NSMutableDictionary *target = Target(p.full, [NSAttributedString new], index, p);
      target[@"blankUTF16"] = @(p.content.length);
      [created addObject:target];
    }
  } else {
    BOOL after = [op isEqualToString:@"insert_after"];
    RejectUnknownKeys(operation, @[ @"op", @"id", @"anchor", @"blocks", @"expectedCount" ], @"insert operation");
    NSDictionary *anchor = RequireObject(operation, @"anchor");
    NSArray *hits = ResolveSelector(anchor, @"anchor", snapshot, paragraphs, rows, &kind);
    for (NSDictionary *hit in CountAndPick(hits, operation, anchor, index)) {
      EditParagraph *p = hit[@"paragraph"];
      NSAttributedString *blocks;
      NSUInteger at;
      if (!after) {
        if (p.index == 0)
          Fail(@"title_invariant", @"Nothing can be inserted before the title paragraph", @{@"committed" : @NO});
        at = p.full.location;
        blocks = AttributedBlocks(operation[@"blocks"], nil, @"blocks");
      } else if (p.terminated) {
        at = NSMaxRange(p.full);
        blocks = AttributedBlocks(operation[@"blocks"], nil, @"blocks");
      } else {
        // Anchor is the unterminated last paragraph: the inserted newline
        // becomes its terminator, so it carries the anchor's paragraph style.
        at = NSMaxRange(p.content);
        NSDictionary *anchorAttributes =
            p.content.length ? [snapshot attributesAtIndex:NSMaxRange(p.content) - 1 effectiveRange:NULL] : @{};
        NSMutableDictionary *separator = [NSMutableDictionary dictionary];
        if (anchorAttributes[kStyleKey]) separator[kStyleKey] = anchorAttributes[kStyleKey];
        blocks = AttributedBlocks(operation[@"blocks"], separator, @"blocks");
      }
      NSMutableDictionary *target = Target(NSMakeRange(at, 0), blocks, index, p);
      if (hit[@"attachment"]) target[@"attachment"] = hit[@"attachment"];
      [created addObject:target];
    }
    summary[@"anchorKind"] = kind;
  }
  if (targets.count + created.count > MAX_EDIT_TARGETS)
    Fail(@"invalid_request", @"The edit plan exceeds 1000 targets", nil);
  NSMutableArray *described = [NSMutableArray array];
  for (NSDictionary *t in created) {
    NSRange r = [t[@"range"] rangeValue];
    EditParagraph *p = paragraphs[[t[@"paragraph"] unsignedIntegerValue]];
    NSMutableDictionary *description = [@{
      @"paragraphIndex" : t[@"paragraph"],
      @"paragraphStyle" : StyleName(StyleValueOf(ParagraphStyleAt(snapshot, p))),
      @"location" : @(r.location),
      @"length" : @(r.length),
      @"newLength" : @([t[@"replacement"] length]),
    } mutableCopy];
    if (t[@"attachment"]) description[@"attachment"] = t[@"attachment"];
    // For a trimmed paragraph: how many whitespace characters it held.
    if (t[@"blankUTF16"]) description[@"blankUTF16"] = t[@"blankUTF16"];
    [described addObject:description];
  }
  [targets addObjectsFromArray:created];
  summary[@"matchedCount"] = @(created.count);
  summary[@"targets"] = described;
  return summary;
}

// Two targets conflict when their ranges overlap, when an insertion point
// sits on or inside another target's range, or when two insertions share a
// point (their relative order would be ambiguous).
static void RejectOverlaps(NSArray<NSDictionary *> *targets) {
  for (NSUInteger i = 0; i < targets.count; i++) {
    NSRange a = [targets[i][@"range"] rangeValue];
    for (NSUInteger j = i + 1; j < targets.count; j++) {
      NSRange b = [targets[j][@"range"] rangeValue];
      BOOL conflict;
      if (a.length && b.length)
        conflict = NSIntersectionRange(a, b).length > 0;
      else if (!a.length && !b.length)
        conflict = a.location == b.location;
      else {
        NSRange range = a.length ? a : b;
        NSUInteger point = a.length ? b.location : a.location;
        conflict = point >= range.location && point <= NSMaxRange(range);
      }
      if (conflict)
        Fail(@"conflicting_operations",
             [NSString stringWithFormat:@"Operations %@ and %@ touch the same text", targets[i][@"operation"],
                                        targets[j][@"operation"]],
             @{@"committed" : @NO});
    }
  }
}

static NSArray<NSDictionary *> *Descending(NSArray<NSDictionary *> *targets) {
  return [targets sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
    NSUInteger a = [x[@"range"] rangeValue].location, b = [y[@"range"] rangeValue].location;
    return a == b ? NSOrderedSame : (a > b ? NSOrderedAscending : NSOrderedDescending);
  }];
}

// Maps the unchanged stretches of the old text to their place in the new
// text, and records where each replacement landed.
static void Segments(NSArray<NSDictionary *> *targets, NSUInteger oldLength, NSMutableArray *unchanged,
                     NSMutableArray *replaced) {
  NSArray *ascending = [Descending(targets) reverseObjectEnumerator].allObjects;
  NSUInteger oldCursor = 0, newCursor = 0;
  for (NSDictionary *t in ascending) {
    NSRange r = [t[@"range"] rangeValue];
    NSUInteger keep = r.location - oldCursor;
    if (keep)
      [unchanged addObject:@[
        [NSValue valueWithRange:NSMakeRange(oldCursor, keep)], [NSValue valueWithRange:NSMakeRange(newCursor, keep)]
      ]];
    newCursor += keep;
    NSUInteger length = [t[@"replacement"] length];
    [replaced addObject:@[ [NSValue valueWithRange:NSMakeRange(newCursor, length)], t[@"replacement"] ]];
    newCursor += length;
    oldCursor = NSMaxRange(r);
  }
  if (oldCursor < oldLength)
    [unchanged addObject:@[
      [NSValue valueWithRange:NSMakeRange(oldCursor, oldLength - oldCursor)],
      [NSValue valueWithRange:NSMakeRange(newCursor, oldLength - oldCursor)]
    ]];
}

static NSString *PlanDigest(NSString *identifier, NSArray *operations) {
  NSData *ops = [NSJSONSerialization dataWithJSONObject:operations options:NSJSONWritingSortedKeys error:nil];
  NSMutableData *data = [[identifier dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [data appendData:ops ?: [NSData data]];
  return [@"p1:" stringByAppendingString:SHA256Hex(data)];
}

@interface EditPlan : NSObject
@property(nonatomic, strong) NSManagedObject *note;
@property(nonatomic, strong) id mergeable;
@property(nonatomic, copy) NSAttributedString *snapshot;
@property(nonatomic, copy) NSAttributedString *expected;
@property(nonatomic, copy) NSArray *targets;
@property(nonatomic, strong) NSMutableArray *unchanged;
@property(nonatomic, strong) NSMutableArray *replaced;
@property(nonatomic) BOOL titleChanged;
@property(nonatomic) BOOL wouldChange;
@property(nonatomic, copy) NSString *revisionBefore;
@property(nonatomic, strong) NSMutableDictionary *response;
// The note's attachment rows by lowercased identifier, and the keys of those
// whose glyph the plan removes from the body.
@property(nonatomic, copy) NSDictionary<NSString *, NSManagedObject *> *attachmentRows;
@property(nonatomic, copy) NSArray<NSString *> *removedAttachments;
@end
@implementation EditPlan
@end

static BOOL IsSystemPaper(NSManagedObject *note, BOOL *known) {
  if (note.entity.attributesByName[@"isSystemPaper"]) {
    *known = YES;
    return [[note valueForKey:@"isSystemPaper"] boolValue];
  }
  if ([note respondsToSelector:sel_registerName("isSystemPaper")]) {
    *known = YES;
    return SendBool(note, "isSystemPaper");
  }
  *known = NO;
  return NO;
}

// Fetches the note in `context`, checks it is editable and (when
// `ifRevision` is given) unchanged, and resolves every operation against one
// snapshot. Shared by plan_edit and edit_note so both compute the same plan.
static EditPlan *PlanEdit(NSManagedObjectContext *context, StoreLocation store, NSString *identifier,
                          NSArray *operations, BOOL requireNonSystemPaper, NSString *ifRevision) {
  EditPlan *plan = [EditPlan new];
  NSManagedObject *note = FetchNote(context, identifier);
  RequireAppendableNote(note);
  if (requireNonSystemPaper) {
    BOOL known = NO;
    BOOL systemPaper = IsSystemPaper(note, &known);
    if (!known || systemPaper)
      Fail(@"unsupported_note",
           known ? @"The note is a Quick Note" : @"Cannot tell whether the note is a Quick Note",
           @{@"committed" : @NO});
  }
  plan.note = note;
  plan.revisionBefore = RevisionToken(note);
  if (ifRevision && ![plan.revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : plan.revisionBefore});

  id ms = nil;
  NSAttributedString *snapshot = [LoadBody(note, &ms) copy];
  plan.mergeable = ms;
  plan.snapshot = snapshot;
  plan.attachmentRows = AttachmentRows(note);
  NSArray<EditParagraph *> *paragraphs = Paragraphs(snapshot.string);

  NSMutableArray *targets = [NSMutableArray array];
  NSMutableArray *summaries = [NSMutableArray array];
  NSMutableSet *ids = [NSMutableSet set];
  for (NSUInteger i = 0; i < operations.count; i++) {
    NSDictionary *summary = PlanOperation(operations[i], i, snapshot, paragraphs, plan.attachmentRows, targets);
    if (summary[@"id"]) {
      if ([ids containsObject:summary[@"id"]]) Fail(@"invalid_request", @"Operation ids must be unique", nil);
      [ids addObject:summary[@"id"]];
    }
    [summaries addObject:summary];
  }
  RejectOverlaps(targets);
  plan.targets = targets;

  NSMutableAttributedString *expected = [snapshot mutableCopy];
  for (NSDictionary *t in Descending(targets))
    [expected replaceCharactersInRange:[t[@"range"] rangeValue] withAttributedString:t[@"replacement"]];
  plan.expected = expected;
  NSArray<EditParagraph *> *expectedParagraphs = Paragraphs(expected.string);
  NSString *expectedTitle = [expected.string substringWithRange:expectedParagraphs.firstObject.content];
  if (![expectedTitle stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length)
    Fail(@"title_invariant", @"The edit would leave the note without a title", @{@"committed" : @NO});
  plan.titleChanged =
      ![expectedTitle isEqualToString:[snapshot.string substringWithRange:paragraphs.firstObject.content]];
  // Attachments whose glyph is in the snapshot but not in the planned text.
  // Only an attachment selector can put a glyph inside a target, so these are
  // exactly the attachments the request named for replacement or deletion.
  NSMutableSet *kept = [NSMutableSet set];
  for (NSDictionary *entry in AttachmentGlyphEntries(expected))
    [kept addObject:[entry[@"identifier"] lowercaseString]];
  NSMutableArray *removed = [NSMutableArray array];
  NSMutableArray *removedReport = [NSMutableArray array];
  for (NSDictionary *entry in AttachmentGlyphEntries(snapshot)) {
    NSString *key = [entry[@"identifier"] lowercaseString];
    if ([kept containsObject:key] || [removed containsObject:key]) continue;
    [removed addObject:key];
    [removedReport addObject:entry[@"identifier"]];
  }
  plan.removedAttachments = removed;
  plan.unchanged = [NSMutableArray array];
  plan.replaced = [NSMutableArray array];
  Segments(targets, snapshot.length, plan.unchanged, plan.replaced);
  plan.wouldChange = ![expected.string isEqualToString:snapshot.string] ||
                     ![CanonicalRuns(expected, NSMakeRange(0, expected.length), YES)
                         isEqual:CanonicalRuns(snapshot, NSMakeRange(0, snapshot.length), YES)];
  NSUInteger unchangedUTF16 = 0;
  for (NSArray *segment in plan.unchanged) unchangedUTF16 += [segment[0] rangeValue].length;

  plan.response = [@{
    @"identifier" : identifier,
    @"revisionBefore" : plan.revisionBefore,
    @"planDigest" : PlanDigest(identifier, operations),
    @"operationCount" : @(operations.count),
    @"targetCount" : @(targets.count),
    @"operations" : summaries,
    @"lengthBefore" : @(snapshot.length),
    @"lengthAfter" : @(expected.length),
    @"unchangedUTF16" : @(unchangedUTF16),
    @"wouldChange" : @(plan.wouldChange),
    @"titleChanged" : @(plan.titleChanged),
    @"attachmentGlyphs" : @(AttachmentGlyphs(snapshot).count),
    @"attachmentGlyphsAfter" : @(AttachmentGlyphs(expected).count),
    @"removedAttachments" : removedReport,
    @"storeKind" : store.isCopy ? @"copy" : @"live",
  } mutableCopy];
  return plan;
}

// The proof that nothing else moved: same text as the plan, same attribute
// runs outside the edits, the requested formatting inside them (ignoring the
// per-edit timestamps Notes may stamp on new text), and the planned
// attachment glyph sequence.
static NSString *VerifyAgainstPlan(NSAttributedString *persisted, EditPlan *plan) {
  if (![persisted.string isEqualToString:plan.expected.string])
    return @"The persisted text does not equal the planned text";
  for (NSArray *segment in plan.unchanged) {
    NSRange oldRange = [segment[0] rangeValue], newRange = [segment[1] rangeValue];
    if (![CanonicalRuns(plan.snapshot, oldRange, NO) isEqual:CanonicalRuns(persisted, newRange, NO)])
      return [NSString stringWithFormat:@"Formatting changed outside the edited ranges (at %lu)",
                                        (unsigned long)newRange.location];
  }
  for (NSArray *segment in plan.replaced) {
    NSRange newRange = [segment[0] rangeValue];
    NSAttributedString *replacement = segment[1];
    if (![CanonicalRuns(replacement, NSMakeRange(0, replacement.length), YES)
            isEqual:CanonicalRuns(persisted, newRange, YES)])
      return [NSString stringWithFormat:@"The inserted text does not carry the planned formatting (at %lu)",
                                        (unsigned long)newRange.location];
  }
  if (![AttachmentGlyphs(persisted) isEqual:AttachmentGlyphs(plan.expected)])
    return @"The attachment glyph sequence changed";
  return nil;
}

// Every attachment row the note had, other than one whose glyph the plan
// removed, must still be the note's with the same stored values, and no row
// may appear. A removed attachment's row may be gone or changed.
static NSString *VerifyAttachmentRows(NSDictionary<NSString *, NSString *> *before,
                                      NSDictionary<NSString *, NSString *> *after, EditPlan *plan) {
  NSSet *removed = [NSSet setWithArray:plan.removedAttachments];
  for (NSString *key in before) {
    if ([removed containsObject:key]) continue;
    if (!after[key]) return @"An attachment the edit did not target is no longer in the note";
    if (![after[key] isEqualToString:before[key]])
      return @"An attachment the edit did not target changed its stored values";
  }
  for (NSString *key in after)
    if (!before[key]) return @"A new attachment row appeared in the note";
  return nil;
}

// Performs the planned edit on the note in `context` without saving, then
// refuses (after rolling back) if the native string did not take the plan or
// if any object other than the note, its body data, and its cloud state
// became dirty. plan_edit calls this on its read-only context with
// persist = NO, so the plan proves the same side-effect check the apply makes.
static void ApplyInContext(NSManagedObjectContext *context, EditPlan *plan, BOOL persist) {
  NSManagedObject *note = plan.note;
  id ms = plan.mergeable;
  // Edit through the CRDT, last target first, so earlier ranges stay valid.
  SendVoid(ms, "beginEditing");
  for (NSDictionary *t in Descending(plan.targets)) {
    NSRange range = [t[@"range"] rangeValue];
    NSAttributedString *replacement = t[@"replacement"];
    ((void (*)(id, SEL, NSRange, id))objc_msgSend)(
        ms, sel_registerName("replaceCharactersInRange:withAttributedString:"), range, replacement);
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"),
        NSTextStorageEditedCharacters | NSTextStorageEditedAttributes,
        NSMakeRange(range.location, replacement.length), (NSInteger)replacement.length - (NSInteger)range.length);
  }
  SendVoid(ms, "endEditing");

  NSAttributedString *inMemory = Send(ms, "attributedString");
  if (![inMemory.string isEqualToString:plan.expected.string]) {
    [context rollback];
    Fail(@"edit_failed", @"The native string did not take the planned edit; nothing was saved",
         @{@"committed" : @NO});
  }
  // Regenerate the title only when its text changed.
  ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(note, sel_registerName("regenerateTitle:snippet:"),
                                                plan.titleChanged, YES);
  if (persist) {
    if (!SendBool(note, "saveNoteData")) {
      [context rollback];
      Fail(@"save_failed", @"NotesShared did not serialize the edited body", @{@"committed" : @NO});
    }
    [note setValue:[NSDate date] forKey:@"modificationDate"];
    ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("updateChangeCountWithReason:"),
                                          kEditChangeReason);
  }

  // Only the note, its body data, its cloud state, and the row of an
  // attachment the plan removes from the body may change. Notes can re-derive
  // a note's title from one of its attachments when the body is edited; that
  // re-points another attachment row, so it is refused here too. A removed
  // attachment's row may be updated (for example marked for deletion) but
  // never deleted outright; its changed keys are reported.
  NSMutableSet *allowed = [NSMutableSet setWithObject:note];
  id noteData = Send(note, "noteData");
  id cloudState = Send(note, "cloudState");
  if (noteData) [allowed addObject:noteData];
  if (cloudState) [allowed addObject:cloudState];
  NSMutableDictionary *removedRowChanges = [NSMutableDictionary dictionary];
  for (NSString *key in plan.removedAttachments) {
    NSManagedObject *row = plan.attachmentRows[key];
    if (!row) continue;
    [allowed addObject:row];
    if (row.hasChanges)
      removedRowChanges[[row valueForKey:@"identifier"] ?: key] =
          [row.changedValues.allKeys sortedArrayUsingSelector:@selector(compare:)];
  }
  plan.response[@"removedAttachmentRowChanges"] = removedRowChanges;
  NSMutableArray *unexpected = [NSMutableArray array];
  for (NSManagedObject *object in context.insertedObjects)
    [unexpected addObject:[@"inserted " stringByAppendingString:object.entity.name ?: @"?"]];
  for (NSManagedObject *object in context.deletedObjects)
    [unexpected addObject:[@"deleted " stringByAppendingString:object.entity.name ?: @"?"]];
  for (NSManagedObject *object in context.updatedObjects)
    if (![allowed containsObject:object])
      [unexpected
          addObject:[NSString stringWithFormat:@"updated %@ (%@)", object.entity.name ?: @"?",
                                               [[object.changedValues.allKeys
                                                   sortedArrayUsingSelector:@selector(compare:)]
                                                   componentsJoinedByString:@","]]];
  if (unexpected.count) {
    [context rollback];
    Fail(@"unexpected_side_effect",
         @"Editing this note would also change other objects (for example, Notes re-deriving the title "
         @"from an attachment); nothing was saved. Edit this note in Notes.app.",
         @{@"committed" : @NO, @"objects" : unexpected});
  }
}

static NSDictionary *HandlePlanEdit(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  NSArray *operations = EditOperations(request);
  BOOL requireNonSystemPaper = OptionalBool(request, @"requireNonSystemPaper", NO);
  RequireFeature(FeatureEdit);
  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, YES);
  EditPlan *plan = PlanEdit(context, store, identifier, operations, requireNonSystemPaper, nil);
  // Rehearse the native edit in the read-only context, then discard it.
  if (plan.wouldChange) {
    ApplyInContext(context, plan, NO);
    [context rollback];
  }
  NSMutableDictionary *response = plan.response;
  response[@"status"] = @"planned";
  response[@"dryRun"] = @YES;
  response[@"committed"] = @NO;
  return response;
}

static NSDictionary *HandleEditNote(NSDictionary *request) {
  gWriteRequest = YES;
  NSString *identifier = RequireIdentifier(request);
  NSString *ifRevision = RequireString(request, @"ifRevision");
  NSArray *operations = EditOperations(request);
  BOOL requireNonSystemPaper = OptionalBool(request, @"requireNonSystemPaper", NO);
  RequireFeature(FeatureEdit);

  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, NO);
  EditPlan *plan = PlanEdit(context, store, identifier, operations, requireNonSystemPaper, ifRevision);
  NSMutableDictionary *response = plan.response;
  response[@"dryRun"] = @NO;
  if (!plan.wouldChange) {
    response[@"status"] = @"unchanged";
    response[@"committed"] = @NO;
    response[@"revisionAfter"] = plan.revisionBefore;
    return response;
  }

  NSDictionary *attachmentsBefore = AttachmentRowDigests(plan.attachmentRows);
  ApplyInContext(context, plan, YES);
  SaveOrFail(context);

  // Fresh read-back through a new coordinator opened read-only.
  NSString *verifyError = nil;
  NSDictionary *after = nil;
  NSUInteger attachmentRows = 0;
  NSMutableArray *removedReport = [NSMutableArray array];
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *reread = FetchNote(fresh, identifier);
    NSAttributedString *persisted = LoadBody(reread, NULL);
    verifyError = VerifyAgainstPlan(persisted, plan);
    NSDictionary<NSString *, NSManagedObject *> *rowsAfter = AttachmentRows(reread);
    attachmentRows = rowsAfter.count;
    if (!verifyError)
      verifyError = VerifyAttachmentRows(attachmentsBefore, AttachmentRowDigests(rowsAfter), plan);
    for (NSString *key in plan.removedAttachments) {
      NSManagedObject *row = rowsAfter[key];
      [removedReport addObject:@{
        @"identifier" : [plan.attachmentRows[key] valueForKey:@"identifier"] ?: key,
        @"rowStillInNote" : @((BOOL)(row != nil)),
        @"markedForDeletion" : row ? @([[row valueForKey:@"markedForDeletion"] boolValue]) : [NSNull null],
      }];
    }
    after = NoteState(reread);
  } @catch (NSException *e) {
    // After a successful save: a committed write that could not be verified.
    verifyError = e.reason ?: e.name;
  }
  if (verifyError)
    Fail(@"verification_failed", verifyError, @{@"committed" : @YES, @"revisionBefore" : plan.revisionBefore});
  NSUInteger otherRows = 0;
  for (NSString *key in attachmentsBefore)
    if (![plan.removedAttachments containsObject:key]) otherRows++;

  response[@"status"] = @"updated";
  response[@"committed"] = @YES;
  response[@"verified"] = @YES;
  response[@"revisionAfter"] = after[@"revision"];
  response[@"title"] = after[@"title"];
  // What the read-back proved, in counts only.
  response[@"preservation"] = @{
    @"unchangedUTF16" : response[@"unchangedUTF16"],
    @"formattingOutsideEditsVerified" : @YES,
    @"attachmentGlyphs" : @(AttachmentGlyphs(plan.expected).count),
    @"attachmentGlyphSequenceVerified" : @YES,
    @"attachmentRows" : @(attachmentRows),
    @"attachmentRowsVerified" : @YES,
    // Rows other than a removed attachment's, proven present with the same
    // stored values; and what became of each removed attachment's row.
    @"otherAttachmentRowsUnchanged" : @(otherRows),
    @"removedAttachments" : removedReport,
  };
  [response addEntriesFromDictionary:SyncFields(after, store)];
  return response;
}

static void RequireOnlyKeys(NSDictionary *object, NSString *allowedCSV, NSString *label) {
  NSSet *allowed = [NSSet setWithArray:[allowedCSV componentsSeparatedByString:@","]];
  for (NSString *key in object)
    if (![allowed containsObject:key])
      Fail(@"invalid_request", [NSString stringWithFormat:@"Unknown %@ field `%@`", label, key], nil);
}

static BOOL ComposeBool(NSDictionary *object, NSString *key, NSString *label) {
  id value = object[key];
  if (!value) return NO;
  if (!IsJSONBool(value))
    Fail(@"invalid_request", [NSString stringWithFormat:@"%@ `%@` must be a boolean", label, key], nil);
  return [value boolValue];
}

static NSUInteger ComposeCount(NSDictionary *object, NSString *key, NSUInteger min, NSUInteger max,
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
  if ([text rangeOfCharacterFromSet:ForbiddenTextCharacters(NO)].location != NSNotFound)
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
  unsigned int hints = (ComposeBool(run, @"bold", @"Run") ? 1 : 0) |
                       (ComposeBool(run, @"italic", @"Run") ? 2 : 0);
  if (hints) attrs[kHintsKey] = @(hints);
  if (ComposeBool(run, @"underline", @"Run")) attrs[kUnderlineKey] = @1;
  if (ComposeBool(run, @"strikethrough", @"Run")) attrs[kStrikethroughKey] = @1;
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

static id ComposeParagraphStyle(const StyleSpec *spec, NSUInteger indent, BOOL blockQuote, id checked) {
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

#define MAX_TABLE_ROWS 1000
#define MAX_TABLE_COLUMNS 100
#define MAX_TABLE_CELLS 10000

// A divider or table paragraph: one attachment glyph on its own line.
// Table rows must be rectangular arrays of one-line strings (empty allowed).
static NSDictionary *ValidateObjectParagraph(NSDictionary *paragraph, NSString *kind) {
  if ([kind isEqualToString:@"divider"]) {
    RequireOnlyKeys(paragraph, @"kind", @"divider paragraph");
    return @{@"kind" : kind};
  }
  RequireOnlyKeys(paragraph, @"kind,rows", @"table paragraph");
  id rows = paragraph[@"rows"];
  if (![rows isKindOfClass:[NSArray class]] || [rows count] == 0 || [rows count] > MAX_TABLE_ROWS)
    Fail(@"invalid_request", @"Table `rows` must be an array of 1 to 1000 rows", nil);
  NSUInteger columns = 0;
  for (id row in rows) {
    if (![row isKindOfClass:[NSArray class]] || [row count] == 0 || [row count] > MAX_TABLE_COLUMNS)
      Fail(@"invalid_request", @"Each table row must be an array of 1 to 100 cells", nil);
    if (!columns) columns = [row count];
    if ([row count] != columns) Fail(@"invalid_request", @"Table rows must all have the same number of cells", nil);
    for (id cell in row) {
      if (![cell isKindOfClass:[NSString class]]) Fail(@"invalid_request", @"Table cells must be strings", nil);
      if ([cell length]) ValidateRunText(cell);
    }
  }
  if ([rows count] * columns > MAX_TABLE_CELLS)
    Fail(@"invalid_request", @"A table may have at most 10000 cells", nil);
  return @{@"kind" : kind, @"rows" : rows};
}

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
    id kind = paragraph[@"kind"] ?: @"text";
    if ([kind isEqual:@"divider"] || [kind isEqual:@"table"]) {
      NSDictionary *object = ValidateObjectParagraph(paragraph, kind);
      if (unit.text.length) [unit.text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
      [unit.ranges addObject:[NSValue valueWithRange:NSMakeRange(unit.text.length, 1)]];
      // A placeholder glyph; MaterializeObjects gives it a real attachment.
      [unit.text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\uFFFC"]];
      [unit.styles addObject:object];
      continue;
    }
    if (![kind isEqual:@"text"])
      Fail(@"invalid_request", @"Paragraph `kind` must be text, divider, or table", nil);
    RequireOnlyKeys(paragraph, @"kind,style,indent,blockQuote,checked,runs", @"paragraph");
    id styleName = paragraph[@"style"];
    const StyleSpec *spec = [styleName isKindOfClass:[NSString class]] ? StyleNamed(styleName) : NULL;
    if (!spec)
      Fail(@"invalid_request",
           @"Paragraph `style` must be heading, subheading, body, monospaced, bulleted, dashed, "
           @"numbered, or checklist",
           nil);
    NSUInteger indent = ComposeCount(paragraph, @"indent", 0, MAX_INDENT, 0, @"Paragraph");
    if (indent && !spec->indentable)
      Fail(@"invalid_request", @"Only body, list, and checklist paragraphs take `indent`", nil);
    BOOL blockQuote = ComposeBool(paragraph, @"blockQuote", @"Paragraph");
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
    // An attachment glyph sits in a plain body paragraph, as Notes writes it.
    id style = p[@"kind"] ? ComposeParagraphStyle(StyleNamed(@"body"), 0, NO, nil)
                          : ComposeParagraphStyle([p[@"spec"] pointerValue], [p[@"indent"] unsignedIntegerValue],
                                              [p[@"blockQuote"] boolValue],
                                              p[@"checked"] == [NSNull null] ? nil : p[@"checked"]);
    NSRange range = unit.ranges[i].rangeValue;
    if (i + 1 < unit.ranges.count) range.length += 1;  // own terminator
    [unit.text addAttribute:kStyleKey value:style range:range];
  }
}

// The attachment glyph Notes uses for block objects: U+FFFC carrying an
// ICTTAttachment that names the attachment's identifier and type.
static void AttachGlyph(NSMutableAttributedString *text, NSRange glyph, id attachment) {
  id tt = [[objc_getClass("ICTTAttachment") alloc] init];
  ((void (*)(id, SEL, id))objc_msgSend)(tt, sel_registerName("setAttachmentIdentifier:"),
                                        [attachment valueForKey:@"identifier"]);
  ((void (*)(id, SEL, id))objc_msgSend)(tt, sel_registerName("setAttachmentUTI:"), Send(attachment, "typeUTI"));
  [text addAttribute:@"NSAttachment" value:tt range:glyph];
}

static id NewTable(NSManagedObject *note, NSArray<NSArray<NSString *> *> *rows) {
  // Notes.app registers the table CRDT type at launch; without it the
  // serialized table has no root type and renders empty.
  SendVoid(objc_getClass("ICTable"), "registerWithICCRCoder");
  id attachment = Send(note, "addTableAttachment");
  id table = Send(Send(attachment, "tableModel"), "table");
  if (!table) Fail(@"materialization_failed", @"NotesShared did not create a table", @{@"committed" : @NO});
  NSUInteger wantRows = rows.count, wantColumns = rows.firstObject.count;
  NSUInteger (*count)(id, SEL) = (NSUInteger(*)(id, SEL))objc_msgSend;
  while (count(table, sel_registerName("rowCount")) < wantRows)
    ((id(*)(id, SEL, NSUInteger))objc_msgSend)(table, sel_registerName("insertRowAtIndex:"),
                                               count(table, sel_registerName("rowCount")));
  while (count(table, sel_registerName("rowCount")) > wantRows)
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(table, sel_registerName("removeRowAtIndex:"),
                                                  count(table, sel_registerName("rowCount")) - 1);
  while (count(table, sel_registerName("columnCount")) < wantColumns)
    ((id(*)(id, SEL, NSUInteger))objc_msgSend)(table, sel_registerName("insertColumnAtIndex:"),
                                               count(table, sel_registerName("columnCount")));
  while (count(table, sel_registerName("columnCount")) > wantColumns)
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(table, sel_registerName("removeColumnAtIndex:"),
                                                  count(table, sel_registerName("columnCount")) - 1);
  // Every cell is written, empty ones too, so no default content survives.
  for (NSUInteger r = 0; r < wantRows; r++)
    for (NSUInteger c = 0; c < wantColumns; c++)
      ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(
          table, sel_registerName("setAttributedString:columnIndex:rowIndex:"),
          [[NSAttributedString alloc] initWithString:rows[r][c]], c, r);
  id model = Send(attachment, "tableModel");
  SendVoid(model, "writeMergeableData");
  SendVoid(model, "regenerateTextContentInNote");
  SendVoid(attachment, "saveMergeableDataIfNeeded");
  return attachment;
}

static id NewDivider(NSManagedObject *note) {
  return ((id(*)(id, SEL, id, id, id))objc_msgSend)(
      objc_getClass("ICInlineAttachment"),
      sel_registerName("newDividerLineAttachmentWithIdentifier:note:parentAttachment:"), NSUUID.UUID.UUIDString, note,
      nil);
}

static BOOL UnitHasObjects(ComposedUnit unit) {
  for (NSDictionary *p in unit.styles)
    if (p[@"kind"]) return YES;
  return NO;
}

// Creates each divider and table on the note and points its placeholder glyph
// at it. Runs only on apply, after the revision check; nothing is saved here,
// so a failure leaves the store untouched (the context is discarded).
static NSArray<NSDictionary *> *MaterializeObjects(ComposedUnit unit, NSManagedObject *note) {
  NSMutableArray *created = [NSMutableArray array];
  for (NSUInteger i = 0; i < unit.styles.count; i++) {
    NSDictionary *p = unit.styles[i];
    if (!p[@"kind"]) continue;
    NSUInteger lengthBefore = [BodyText(Send(note, "mergeableString")) length];
    id attachment = nil;
    @try {
      attachment = [p[@"kind"] isEqual:@"table"] ? NewTable(note, p[@"rows"]) : NewDivider(note);
    } @catch (HelperError *e) {
      @throw;
    } @catch (NSException *e) {
      Fail(@"materialization_failed", [NSString stringWithFormat:@"Could not create a %@: %@", p[@"kind"], e.reason],
           @{@"committed" : @NO});
    }
    if (!attachment || ![[attachment valueForKey:@"identifier"] isKindOfClass:[NSString class]])
      Fail(@"materialization_failed", [NSString stringWithFormat:@"NotesShared did not create a %@", p[@"kind"]],
           @{@"committed" : @NO});
    // The factories must not place glyphs themselves; the unit places them.
    if ([BodyText(Send(note, "mergeableString")) length] != lengthBefore)
      Fail(@"materialization_failed", @"Creating the object changed the note text", @{@"committed" : @NO});
    ((void (*)(id, SEL, id))objc_msgSend)(attachment, sel_registerName("updateChangeCountWithReason:"),
                                          @"apple-notes-mcp compose_note");
    AttachGlyph(unit.text, unit.ranges[i].rangeValue, attachment);
    [created addObject:@{
      @"kind" : p[@"kind"],
      @"identifier" : [attachment valueForKey:@"identifier"],
      @"uti" : OrNull(Send(attachment, "typeUTI")),
    }];
  }
  return created;
}

// Fresh-context proof that each created object exists, belongs to the note,
// and, for tables, holds exactly the requested cells.
static NSString *VerifyObjects(NSManagedObjectContext *fresh, ComposedUnit unit, NSArray *created,
                               NSString *noteIdentifier) {
  NSUInteger next = 0;
  for (NSDictionary *p in unit.styles) {
    if (!p[@"kind"]) continue;
    NSDictionary *object = created[next++];
    NSString *entity = [p[@"kind"] isEqual:@"table"] ? @"ICAttachment" : @"ICInlineAttachment";
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity];
    request.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", object[@"identifier"]];
    NSArray *rows = [fresh executeFetchRequest:request error:nil];
    if (rows.count != 1) return [NSString stringWithFormat:@"The %@ was not persisted", p[@"kind"]];
    id note = [rows.firstObject valueForKey:@"note"];
    if (![[note valueForKey:@"identifier"] isEqual:noteIdentifier])
      return [NSString stringWithFormat:@"The %@ does not belong to the note", p[@"kind"]];
    if (![p[@"kind"] isEqual:@"table"]) continue;
    SendVoid(objc_getClass("ICTable"), "registerWithICCRCoder");
    id table = Send(Send(rows.firstObject, "tableModel"), "table");
    NSArray<NSArray<NSString *> *> *want = p[@"rows"];
    NSUInteger (*count)(id, SEL) = (NSUInteger(*)(id, SEL))objc_msgSend;
    if (!table || count(table, sel_registerName("rowCount")) != want.count ||
        count(table, sel_registerName("columnCount")) != want.firstObject.count)
      return @"The persisted table does not have the requested shape";
    for (NSUInteger r = 0; r < want.count; r++)
      for (NSUInteger c = 0; c < want[r].count; c++) {
        id cell = ((id(*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(
            table, sel_registerName("stringForColumnIndex:rowIndex:"), c, r);
        NSString *text = [cell isKindOfClass:[NSAttributedString class]] ? [cell string] : cell;
        if (![(text ?: @"") isEqualToString:want[r][c]])
          return @"A persisted table cell differs from the request";
      }
  }
  return nil;
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
  id attachment = attrs[@"NSAttachment"];
  if (attachment) {
    BOOL known = [attachment respondsToSelector:sel_registerName("attachmentUTI")] &&
                 [attachment respondsToSelector:sel_registerName("attachmentIdentifier")];
    sig[@"attachment"] = known ? @{
      @"uti" : OrNull(Send(attachment, "attachmentUTI")),
      @"identifier" : OrNull(Send(attachment, "attachmentIdentifier")),
    }
                               : @{@"class" : NSStringFromClass([attachment class])};
  }
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
    NSUInteger occurrence = ComposeCount(beforeHeading, @"occurrence", 1, 100000, 1, @"insertBeforeHeading");
    NSUInteger expected = ComposeCount(beforeHeading, @"expectedCount", 1, 100000, 1, @"insertBeforeHeading");
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

// Every failure raised before the save reports committed: NO (main() sees
// gWriteRequest without gSaveAttempted), so the client never reports a
// refused compose as indeterminate. Failures from the save on set committed
// themselves.
static NSDictionary *HandleComposeNote(NSDictionary *request) {
  gWriteRequest = YES;
  NSString *identifier = RequireIdentifier(request);
  NSString *mode = RequireString(request, @"mode");
  if (![mode isEqualToString:@"append"] && ![mode isEqualToString:@"prepend"])
    Fail(@"invalid_request", @"`mode` must be append or prepend", nil);
  BOOL dryRun = ComposeBool(request, @"dryRun", @"Request");
  BOOL requireNonSystemPaper = ComposeBool(request, @"requireNonSystemPaper", @"Request");
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
    ComposeCount(beforeHeading, @"occurrence", 1, 100000, 1, @"insertBeforeHeading");
    ComposeCount(beforeHeading, @"expectedCount", 1, 100000, 1, @"insertBeforeHeading");
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
  BOOL hasObjects = UnitHasObjects(unit);
  if (hasObjects) {
    NSArray *missing = MissingAPI(kComposeObjectAPI, COUNT(kComposeObjectAPI));
    if (missing.count)
      Fail(@"private_api_unavailable", @"Dividers and tables need NotesShared API missing on this macOS",
           @{@"missing" : missing, @"committed" : @NO});
    if ([note respondsToSelector:sel_registerName("canAddAttachment")] && !SendBool(note, "canAddAttachment"))
      Fail(@"unsupported_note", @"Notes does not allow attachments in this note", @{@"committed" : @NO});
  }
  // Objects are created only on apply, after the revision check.
  NSArray *created = (!dryRun && hasObjects) ? MaterializeObjects(unit, note) : @[];
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

  SaveOrFail(context);

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
      else if (hasObjects)
        verifyDetail = VerifyObjects(fresh, unit, created, identifier);
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
  } @catch (NSException *e) {
    // After a successful save: a committed write that could not be verified.
    verifyDetail = e.reason ?: e.name;
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
    @"objects" : created,
    @"pushScheduled" : @NO,
    @"syncHostRunning" : @(hostRunning),
    @"pushState" : hostRunning ? @"awaiting_notes_app" : @"queued_for_next_launch",
  }];
  return result;
}

#pragma mark - Checklist items


// Checklist identities are the 16 raw bytes of the item's ICTTTodo UUID.
// get-native-objects reports them as 32 lowercase hex digits; the canonical
// dashed UUID spelling is accepted too.
static NSUUID *ParseTodoIdentifier(NSString *value) {
  NSString *hex = [[value stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
  if (hex.length != 32 ||
      [hex rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]
                                       invertedSet]]
              .location != NSNotFound)
    return nil;
  if ([value containsString:@"-"] && !IsUUID(value)) return nil;
  NSString *dashed =
      [NSString stringWithFormat:@"%@-%@-%@-%@-%@", [hex substringWithRange:NSMakeRange(0, 8)],
                                 [hex substringWithRange:NSMakeRange(8, 4)],
                                 [hex substringWithRange:NSMakeRange(12, 4)],
                                 [hex substringWithRange:NSMakeRange(16, 4)],
                                 [hex substringWithRange:NSMakeRange(20, 12)]];
  return [[NSUUID alloc] initWithUUIDString:dashed];
}

static NSString *TodoHex(NSUUID *uuid) {
  uuid_t bytes;
  [uuid getUUIDBytes:bytes];
  NSMutableString *hex = [NSMutableString stringWithCapacity:32];
  for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", bytes[i]];
  return hex;
}

static NSRange LineAt(NSString *text, NSUInteger index) {
  NSUInteger start = index, end = index;
  while (start > 0 && [text characterAtIndex:start - 1] != '\n') start--;
  while (end < text.length && [text characterAtIndex:end] != '\n') end++;
  return NSMakeRange(start, end - start);
}

static BOOL OnlyNewlines(NSString *text, NSRange range) {
  for (NSUInteger i = range.location; i < NSMaxRange(range); i++)
    if ([text characterAtIndex:i] != '\n') return NO;
  return YES;
}

// Notes stores a checklist item's ICTTTodo (identity and done bit) in the
// TTStyle of the item's characters. Style runs are NOT aligned to lines:
// Notes and the Shortcuts append path can store the newline that ends the
// previous line inside the next item's run. So an item is never inferred from
// line boundaries. It is the exact set of characters whose style carries its
// todo UUID; edits touch only those characters. Its `text` is the line holding
// its first non-newline character, and its `done` comes from that character.
// One entry per todo UUID, in body order. `contiguous` is NO when the UUID
// appears in more than one place; `consistent` is NO when its runs disagree
// on the done bit.
static NSArray<NSDictionary *> *ChecklistItems(NSAttributedString *body) {
  NSString *text = body.string;
  NSMutableArray<NSString *> *order = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSMutableDictionary *> *byHex = [NSMutableDictionary dictionary];
  [body enumerateAttribute:kStyleKey
                   inRange:NSMakeRange(0, body.length)
                   options:0
                usingBlock:^(id style, NSRange run, BOOL *stop) {
                  (void)stop;
                  if (![NSStringFromClass([style class]) containsString:@"ParagraphStyle"]) return;
                  unsigned int value =
                      ((unsigned int (*)(id, SEL))objc_msgSend)(style, sel_registerName("style"));
                  id todo = value == kStyleChecklist ? Send(style, "todo") : nil;
                  NSUUID *uuid = todo ? Send(todo, "uuid") : nil;
                  if (![uuid isKindOfClass:[NSUUID class]]) return;
                  NSString *hex = TodoHex(uuid);
                  NSMutableDictionary *entry = byHex[hex];
                  if (!entry) {
                    entry = [@{@"uuid" : uuid,
                               @"runs" : [NSMutableArray array],
                               @"doneValues" : [NSMutableSet set]} mutableCopy];
                    byHex[hex] = entry;
                    [order addObject:hex];
                  }
                  BOOL done = SendBool(todo, "done");
                  [entry[@"runs"] addObject:@[ [NSValue valueWithRange:run], style ]];
                  [entry[@"doneValues"] addObject:@(done)];
                  if (!entry[@"fallbackDone"]) entry[@"fallbackDone"] = @(done);
                  if (!entry[@"done"] && !OnlyNewlines(text, run)) entry[@"done"] = @(done);
                }];
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *hex in order) {
    NSDictionary *entry = byHex[hex];
    NSArray *runs = entry[@"runs"];
    NSRange first = [runs.firstObject[0] rangeValue], last = [runs.lastObject[0] rangeValue];
    NSRange span = NSMakeRange(first.location, NSMaxRange(last) - first.location);
    NSUInteger covered = 0;
    for (NSArray *run in runs) covered += [run[0] rangeValue].length;
    NSUInteger anchor = span.location;
    while (anchor < NSMaxRange(span) && [text characterAtIndex:anchor] == '\n') anchor++;
    if (anchor == NSMaxRange(span)) anchor = span.location;
    NSRange line = LineAt(text, anchor);
    [items addObject:@{
      @"todoIdentifier" : hex,
      @"uuid" : [entry[@"uuid"] UUIDString],
      @"index" : @(items.count),
      @"done" : entry[@"done"] ?: entry[@"fallbackDone"],
      @"consistent" : @((BOOL)([entry[@"doneValues"] count] == 1)),
      @"contiguous" : @((BOOL)(covered == span.length)),
      @"text" : [text substringWithRange:line],
      @"line" : [NSValue valueWithRange:line],
      @"span" : [NSValue valueWithRange:span],
      @"runs" : runs,
    }];
  }
  return items;
}

// JSON-safe copy of an item (drops the range and style objects).
static NSDictionary *PublicItem(NSDictionary *item) {
  NSRange line = [item[@"line"] rangeValue], span = [item[@"span"] rangeValue];
  return @{
    @"todoIdentifier" : item[@"todoIdentifier"],
    @"uuid" : item[@"uuid"],
    @"index" : item[@"index"],
    @"done" : item[@"done"],
    @"text" : item[@"text"],
    @"lineStart" : @(line.location),
    @"lineLengthUTF16" : @(line.length),
    @"styledStart" : @(span.location),
    @"styledLengthUTF16" : @(span.length),
    @"contiguous" : item[@"contiguous"],
    @"consistent" : item[@"consistent"],
  };
}

static NSDictionary *ItemWithTodo(NSArray<NSDictionary *> *items, NSString *hex) {
  for (NSDictionary *item in items)
    if ([item[@"todoIdentifier"] isEqualToString:hex]) return item;
  return nil;
}

static NSDictionary *HandleReadChecklist(NSDictionary *request) {
  NSString *identifier = RequireIdentifier(request);
  RequireFeature(FeatureChecklist);
  NSManagedObjectContext *context = OpenContext(ResolveStore(), YES);
  NSManagedObject *note = FetchNote(context, identifier);
  if (SendBool(note, "isPasswordProtected"))
    Fail(@"unsupported_note", @"Locked notes are not supported", nil);
  NSArray *items = ChecklistItems(LoadBody(note, NULL));
  NSMutableArray *out = [NSMutableArray array];
  NSUInteger checked = 0;
  for (NSDictionary *item in items) {
    [out addObject:PublicItem(item)];
    if ([item[@"done"] boolValue]) checked++;
  }
  return @{
    @"status" : @"ok",
    @"identifier" : identifier,
    @"revision" : RevisionToken(note),
    @"items" : out,
    @"total" : @(items.count),
    @"checked" : @(checked),
    @"syncHostRunning" : @(NotesAppRunning()),
  };
}

static NSDictionary *HandleSetChecklistItem(NSDictionary *request) {
  gWriteRequest = YES;
  NSString *identifier = RequireIdentifier(request);
  NSString *todoValue = RequireString(request, @"todoIdentifier");
  NSUUID *todoUUID = ParseTodoIdentifier(todoValue);
  if (!todoUUID) Fail(@"invalid_request", @"`todoIdentifier` must be 32 hex digits or a UUID", nil);
  NSString *todoHex = TodoHex(todoUUID);
  id doneValue = request[@"done"];
  if (!IsJSONBool(doneValue)) Fail(@"invalid_request", @"`done` must be true or false", nil);
  BOOL done = [doneValue boolValue];
  NSString *ifRevision = RequireString(request, @"ifRevision");
  RequireFeature(FeatureChecklist);

  StoreLocation store = ResolveStore();
  NSManagedObjectContext *context = OpenContext(store, NO);
  NSManagedObject *note = FetchNote(context, identifier);
  RequireAppendableNote(note);

  NSString *revisionBefore = RevisionToken(note);
  if (![revisionBefore isEqualToString:ifRevision])
    Fail(@"revision_conflict", @"The note changed since ifRevision was read",
         @{@"committed" : @NO, @"currentRevision" : revisionBefore});

  id ms = nil;
  NSAttributedString *body = LoadBody(note, &ms);
  if (![ms respondsToSelector:sel_registerName("setAttributes:range:")])
    Fail(@"private_api_unavailable", @"The note body does not support attribute edits",
         @{@"committed" : @NO, @"missing" : @[ @"-[mergeable string setAttributes:range:]" ]});
  NSArray *items = ChecklistItems(body);
  NSDictionary *item = ItemWithTodo(items, todoHex);
  if (!item)
    Fail(@"not_found", @"No checklist item in this note has that todoIdentifier", @{@"committed" : @NO});
  if (![item[@"contiguous"] boolValue])
    Fail(@"ambiguous_target", @"That todoIdentifier appears in more than one place in the note",
         @{@"committed" : @NO});
  BOOL previousDone = [item[@"done"] boolValue];

  NSMutableDictionary *result = [@{
    @"identifier" : identifier,
    @"todoIdentifier" : todoHex,
    @"index" : item[@"index"],
    @"done" : @(done),
    @"previousDone" : @(previousDone),
    @"revisionBefore" : revisionBefore,
  } mutableCopy];

  // Already in the requested state on every run: an idempotent no-op that
  // writes nothing.
  if (previousDone == done && [item[@"consistent"] boolValue]) {
    [result addEntriesFromDictionary:@{
      @"status" : @"unchanged",
      @"committed" : @NO,
      @"verified" : @YES,
      @"persistedDone" : @(previousDone),
      @"revisionAfter" : revisionBefore,
    }];
    [result addEntriesFromDictionary:SyncFields(NoteState(note), store)];
    return result;
  }

  // Each run keeps its own paragraph style (indent, alignment, paragraph
  // identity) and gets a todo with the item's identity and the new done bit.
  Class todoClass = objc_getClass("ICTTTodo");
  id todo = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(
      [todoClass alloc], sel_registerName("initWithIdentifier:done:"), todoUUID, done);
  if (!todo) Fail(@"private_api_unavailable", @"Could not build the checklist todo", @{@"committed" : @NO});
  NSMutableArray *edits = [NSMutableArray array];
  for (NSArray *run in item[@"runs"]) {
    id style = [run[1] mutableCopy];
    if (!style)
      Fail(@"private_api_unavailable", @"Could not copy the checklist paragraph style",
           @{@"committed" : @NO});
    ((void (*)(id, SEL, id))objc_msgSend)(style, sel_registerName("setTodo:"), todo);
    [edits addObject:@[ run[0], style ]];
  }

  NSRange span = [item[@"span"] rangeValue];
  NSString *before = [body.string copy];
  SendVoid(ms, "beginEditing");
  for (NSArray *edit in edits)
    MergeAttributes(ms, body, [edit[0] rangeValue], @{kStyleKey : edit[1]}, nil);
  SendVoid(ms, "endEditing");
  FinishAttributeEdit(note, span, @"apple-notes-mcp set_checklist_item");
  SaveOrFail(context);

  // Fresh read-back through a new coordinator: the text is unchanged, the item
  // covers the same characters with the requested done bit everywhere, and
  // every other item kept its identity, position, and state.
  NSDictionary *after = nil;
  NSNumber *persistedDone = nil;
  NSString *verifyDetail = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *reread = FetchNote(fresh, identifier);
    NSAttributedString *persisted = LoadBody(reread, NULL);
    NSArray *freshItems = ChecklistItems(persisted);
    NSDictionary *freshItem = ItemWithTodo(freshItems, todoHex);
    persistedDone = freshItem[@"done"];
    BOOL othersKept = freshItems.count == items.count;
    for (NSUInteger i = 0; othersKept && i < items.count; i++) {
      NSDictionary *a = items[i], *b = freshItems[i];
      othersKept = [a[@"todoIdentifier"] isEqualToString:b[@"todoIdentifier"]] &&
                   NSEqualRanges([a[@"span"] rangeValue], [b[@"span"] rangeValue]) &&
                   ([a[@"todoIdentifier"] isEqualToString:todoHex] || [a[@"done"] isEqual:b[@"done"]]);
    }
    if (![persisted.string isEqualToString:before])
      verifyDetail = @"The persisted note text changed";
    else if (!freshItem || !NSEqualRanges([freshItem[@"span"] rangeValue], span))
      verifyDetail = @"The checklist item no longer covers the same characters";
    else if (![freshItem[@"consistent"] boolValue] || [persistedDone boolValue] != done)
      verifyDetail = @"The persisted done state is not the requested one";
    else if (!othersKept)
      verifyDetail = @"Another checklist item changed";
    after = NoteState(reread);
  } @catch (NSException *e) {
    // After a successful save: a committed write that could not be verified.
    verifyDetail = e.reason ?: e.name;
  }
  if (verifyDetail || !after)
    Fail(@"verification_failed", verifyDetail ?: @"Read-back failed",
         @{@"committed" : @YES,
           @"revisionBefore" : revisionBefore,
           @"persistedDone" : OrNull(persistedDone)});

  [result addEntriesFromDictionary:@{
    @"status" : @"updated",
    @"committed" : @YES,
    @"verified" : @YES,
    @"persistedDone" : persistedDone,
    @"revisionAfter" : after[@"revision"],
  }];
  [result addEntriesFromDictionary:SyncFields(after, store)];
  return result;
}

#pragma mark - Highlight

// Notes' highlight is the `TTEmphasis` attribute (an NSNumber) on the
// highlighted characters, serialized as AttributeRun field 14. Values follow
// Notes' color order: 1 purple, 2 pink, 3 orange, 4 mint, 5 blue.
#define MAX_MATCH_UTF16 1000
#define MAX_HIGHLIGHT_RANGES 100

static NSNumber *EmphasisForColor(NSString *color) {
  NSDictionary *codes = @{@"purple" : @1, @"pink" : @2, @"orange" : @3, @"mint" : @4, @"blue" : @5};
  return codes[color];
}

static NSString *ColorForEmphasis(id value) {
  if (![value isKindOfClass:[NSNumber class]]) return nil;
  NSArray *names = @[ @"purple", @"pink", @"orange", @"mint", @"blue" ];
  NSInteger code = [value integerValue];
  return code >= 1 && code <= 5 ? names[code - 1]
                                : [NSString stringWithFormat:@"unknown-%ld", (long)code];
}

static void ValidateMatchText(NSString *match) {
  if (match.length > MAX_MATCH_UTF16)
    Fail(@"invalid_request", @"`match` exceeds 1000 UTF-16 code units", nil);
  if ([match rangeOfCharacterFromSet:ForbiddenTextCharacters(NO)].location != NSNotFound)
    Fail(@"invalid_request",
         @"`match` must be text within one paragraph (no newlines, attachment glyphs, or control "
         @"characters)",
         nil);
}

// Every non-overlapping, case-sensitive, literal occurrence of `match`.
static NSArray<NSValue *> *Occurrences(NSString *text, NSString *match) {
  NSMutableArray *found = [NSMutableArray array];
  NSRange search = NSMakeRange(0, text.length);
  while (search.length >= match.length) {
    NSRange hit = [text rangeOfString:match options:NSLiteralSearch range:search];
    if (hit.location == NSNotFound) break;
    [found addObject:[NSValue valueWithRange:hit]];
    NSUInteger next = NSMaxRange(hit);
    search = NSMakeRange(next, text.length - next);
  }
  return found;
}

// The stored emphasis runs inside `range`: [{start, lengthUTF16, color|null}].
static NSArray *EmphasisRuns(NSAttributedString *body, NSRange range) {
  NSMutableArray *runs = [NSMutableArray array];
  [body enumerateAttribute:kEmphasisKey
                   inRange:range
                   options:0
                usingBlock:^(id value, NSRange run, BOOL *stop) {
                  (void)stop;
                  [runs addObject:@{
                    @"start" : @(run.location),
                    @"lengthUTF16" : @(run.length),
                    @"color" : OrNull(ColorForEmphasis(value)),
                  }];
                }];
  return runs;
}

static BOOL RangeHasEmphasis(NSAttributedString *body, NSRange range, NSNumber *code) {
  __block BOOL all = YES;
  [body enumerateAttribute:kEmphasisKey
                   inRange:range
                   options:0
                usingBlock:^(id value, NSRange run, BOOL *stop) {
                  (void)run;
                  if (!(code ? [value isEqual:code] : value == nil)) {
                    all = NO;
                    *stop = YES;
                  }
                }];
  return all;
}

// Emphasis over the whole body as comparable (start, length, value) triples.
static NSArray *EmphasisMap(NSAttributedString *body) {
  NSMutableArray *map = [NSMutableArray array];
  [body enumerateAttribute:kEmphasisKey
                   inRange:NSMakeRange(0, body.length)
                   options:0
                usingBlock:^(id value, NSRange run, BOOL *stop) {
                  (void)stop;
                  [map addObject:@[ @(run.location), @(run.length), value ?: [NSNull null] ]];
                }];
  return map;
}

// The note's derived "has a highlight" flag (ZHASEMPHASIS), when this macOS
// models it. nil when the entity has no such property.
static NSNumber *HasEmphasisFlag(NSManagedObject *note) {
  if (!note.entity.propertiesByName[@"hasEmphasis"]) return nil;
  return @([[note valueForKey:@"hasEmphasis"] boolValue]);
}

// A highlight request names a scope and the ranges it covers. The only scope
// is "text": every exact occurrence of `match`, which must occur exactly
// `expectedCount` times. Everything after target selection (plan, no-op
// check, edit, whole-note verification) works on any list of ranges, so a
// later scope such as the whole note only adds a branch here and in
// HighlightTargets.
typedef struct {
  NSString *scope;
  NSString *match;
  NSUInteger expectedCount;
} HighlightTarget;

static HighlightTarget ParseHighlightTarget(NSDictionary *request) {
  id scope = request[@"scope"] ?: @"text";
  if (![scope isEqual:@"text"]) Fail(@"invalid_request", @"`scope` must be \"text\"", nil);
  NSString *match = RequireString(request, @"match");
  ValidateMatchText(match);
  id expected = request[@"expectedCount"] ?: @1;
  if (![expected isKindOfClass:[NSNumber class]] || IsJSONBool(expected) ||
      [expected doubleValue] != (double)[expected integerValue] || [expected integerValue] < 1 ||
      [expected integerValue] > MAX_HIGHLIGHT_RANGES)
    Fail(@"invalid_request", @"`expectedCount` must be an integer from 1 to 100", nil);
  return (HighlightTarget){scope, match, [expected unsignedIntegerValue]};
}

static NSArray<NSValue *> *HighlightTargets(HighlightTarget target, NSString *text,
                                            NSString *revision) {
  NSArray<NSValue *> *ranges = Occurrences(text, target.match);
  if (ranges.count != target.expectedCount)
    Fail(@"match_count_mismatch",
         [NSString stringWithFormat:@"`match` occurs %lu times, not the expected %lu",
                                    (unsigned long)ranges.count, (unsigned long)target.expectedCount],
         @{@"committed" : @NO, @"found" : @(ranges.count), @"revision" : revision});
  return ranges;
}

static NSDictionary *HandleSetHighlight(NSDictionary *request) {
  gWriteRequest = YES;
  NSString *identifier = RequireIdentifier(request);
  HighlightTarget target = ParseHighlightTarget(request);
  NSString *color = RequireString(request, @"color");
  NSNumber *code = nil;
  if (![color isEqualToString:@"none"]) {
    code = EmphasisForColor(color);
    if (!code) Fail(@"invalid_request", @"`color` must be purple, pink, orange, mint, blue, or none", nil);
  }
  id dryRunValue = request[@"dryRun"];
  if (dryRunValue && !IsJSONBool(dryRunValue))
    Fail(@"invalid_request", @"`dryRun` must be true or false", nil);
  BOOL dryRun = [dryRunValue boolValue];
  NSString *ifRevision = nil;
  if (!dryRun || request[@"ifRevision"]) ifRevision = RequireString(request, @"ifRevision");
  RequireFeature(dryRun ? FeatureRead : FeatureHighlight);

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
  NSArray<NSValue *> *ranges = HighlightTargets(target, body.string, revisionBefore);

  NSMutableArray *plan = [NSMutableArray array];
  BOOL changes = NO;
  for (NSValue *value in ranges) {
    NSRange range = value.rangeValue;
    BOOL satisfied = RangeHasEmphasis(body, range, code);
    if (!satisfied) changes = YES;
    [plan addObject:@{
      @"start" : @(range.location),
      @"lengthUTF16" : @(range.length),
      @"currentRuns" : EmphasisRuns(body, range),
      @"changes" : @((BOOL)!satisfied),
    }];
  }
  NSMutableDictionary *result = [@{
    @"identifier" : identifier,
    @"scope" : target.scope,
    @"color" : color,
    @"rangeCount" : @(ranges.count),
    @"revisionBefore" : revisionBefore,
  } mutableCopy];

  if (dryRun || !changes) {
    [result addEntriesFromDictionary:@{
      @"status" : dryRun ? @"planned" : @"unchanged",
      @"committed" : @NO,
      @"dryRun" : @(dryRun),
      @"wouldChange" : @(changes),
      @"plan" : plan,
      @"revisionAfter" : revisionBefore,
      @"hasEmphasis" : OrNull(HasEmphasisFlag(note)),
    }];
    if (!dryRun) result[@"verified"] = @YES;
    [result addEntriesFromDictionary:SyncFields(NoteState(note), store)];
    return result;
  }

  if (![ms respondsToSelector:sel_registerName("setAttributes:range:")])
    Fail(@"private_api_unavailable", @"The note body does not support attribute edits",
         @{@"committed" : @NO, @"missing" : @[ @"-[mergeable string setAttributes:range:]" ]});

  // The expected result, computed on a detached copy, is what the fresh
  // read-back must match everywhere, not only inside the targeted ranges.
  NSMutableAttributedString *expected = [body mutableCopy];
  NSRange edited = [ranges.firstObject rangeValue];
  SendVoid(ms, "beginEditing");
  for (NSValue *value in ranges) {
    NSRange range = value.rangeValue;
    MergeAttributes(ms, body, range, code ? @{kEmphasisKey : code} : nil,
                    code ? nil : @[ kEmphasisKey ]);
    if (code)
      [expected addAttribute:kEmphasisKey value:code range:range];
    else
      [expected removeAttribute:kEmphasisKey range:range];
    edited = NSUnionRange(edited, range);
  }
  SendVoid(ms, "endEditing");
  FinishAttributeEdit(note, edited, @"apple-notes-mcp set_highlight");
  NSArray *expectedMap = EmphasisMap(expected);
  // saveNoteData refreshes the derived hasEmphasis flag from the body
  // (observed on a store copy, macOS 27.2); the read-back checks it.
  BOOL anyEmphasis = NO;
  for (NSArray *run in expectedMap)
    if (![run[2] isKindOfClass:[NSNull class]]) anyEmphasis = YES;
  NSNumber *expectedFlag = HasEmphasisFlag(note) ? @(anyEmphasis) : nil;
  SaveOrFail(context);

  NSDictionary *after = nil;
  NSMutableArray *stored = [NSMutableArray array];
  NSNumber *persistedFlag = nil;
  NSString *verifyDetail = nil;
  @try {
    NSManagedObjectContext *fresh = OpenContext(store, YES);
    NSManagedObject *reread = FetchNote(fresh, identifier);
    NSAttributedString *persisted = LoadBody(reread, NULL);
    persistedFlag = HasEmphasisFlag(reread);
    if (![persisted.string isEqualToString:body.string])
      verifyDetail = @"The persisted note text changed";
    else if (![EmphasisMap(persisted) isEqualToArray:expectedMap])
      verifyDetail = @"The persisted highlight runs differ from the requested change";
    else if (expectedFlag && ![persistedFlag isEqual:expectedFlag])
      verifyDetail = @"The note's hasEmphasis flag does not match its stored highlights";
    else
      for (NSValue *value in ranges)
        [stored addObject:@{
          @"start" : @(value.rangeValue.location),
          @"lengthUTF16" : @(value.rangeValue.length),
          @"storedRuns" : EmphasisRuns(persisted, value.rangeValue),
        }];
    after = NoteState(reread);
  } @catch (NSException *e) {
    // After a successful save: a committed write that could not be verified.
    verifyDetail = e.reason ?: e.name;
  }
  if (verifyDetail || !after)
    Fail(@"verification_failed", verifyDetail ?: @"Read-back failed",
         @{@"committed" : @YES, @"revisionBefore" : revisionBefore});

  [result addEntriesFromDictionary:@{
    @"status" : @"updated",
    @"committed" : @YES,
    @"verified" : @YES,
    @"dryRun" : @NO,
    @"ranges" : stored,
    @"revisionAfter" : after[@"revision"],
    @"hasEmphasis" : OrNull(persistedFlag),
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
      NSMutableDictionary *out = [e.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
      if (gWriteRequest && !gSaveAttempted && !out[@"committed"]) out[@"committed"] = @NO;
      out[@"status"] = @"error";
      out[@"message"] = e.reason ?: @"error";
      EmitAndExit(out, 1);
    } @catch (NSException *e) {
      NSMutableDictionary *out = [@{
        @"status" : @"error",
        @"code" : @"internal_error",
        @"message" : [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""],
      } mutableCopy];
      // Before the save nothing was written; after a successful save the
      // write is committed even though the rest of the handler failed.
      // Between the two (the save itself threw) the outcome stays unknown.
      if (gWriteRequest && !gSaveAttempted) out[@"committed"] = @NO;
      if (gSaveSucceeded) {
        out[@"code"] = @"verification_failed";
        out[@"committed"] = @YES;
      }
      EmitAndExit(out, 1);
    }
  }
  return 1;
}
