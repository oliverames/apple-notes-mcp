// Fixed public read-only production comparator control. No writer import,
// action dispatch, saves, user input, or native value/snapshot output. Fresh
// in-memory objects use only source-established production construction APIs.
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreData/CoreData.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include "../../native/private-helper/content-preservation.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
extern const int SANDBOX_CHECK_NO_REPORT;
extern int sandbox_check(pid_t, const char *, int, ...);

__attribute__((used, section("__TEXT,__info_plist"))) static const char info[] =
"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
"<key>CFBundleIdentifier</key><string>io.github.apple-notes-mcp.private-writer</string>"
"<key>CFBundleName</key><string>synthetic-native-content-control</string></dict></plist>";

static NSString *const PublicPayloadSHA256 = @"ac93f271962eddbc6511ce12064ae1ac423e91546c8eff356a9ecddc765fa0d1";
static NSString *const PublicText = @"PUBLIC SYNTHETIC WRITER FIXTURE\n"
    "All contents and identifiers in this note are generated.\n"
    "This note contains no user data or device identifiers.\n"
    "For use in isolated fixture validation.\n";

static const char *DiagnosticStage = "input";

static NSNumber *Flag(BOOL value) { return value ? @YES : @NO; }
static NSMutableDictionary *EmptyObservations(void) {
  return [@{ @"firstPayloadMatchesBeforeProjection": NSNull.null, @"secondPayloadMatchesBeforeProjection": NSNull.null,
      @"firstPayloadMatchesAfterProjection": NSNull.null, @"secondPayloadMatchesAfterProjection": NSNull.null,
      @"firstContextHasChangesBeforeProjection": NSNull.null, @"secondContextHasChangesBeforeProjection": NSNull.null,
      @"firstContextHasChangesAfterProjection": NSNull.null, @"secondContextHasChangesAfterProjection": NSNull.null } mutableCopy];
}

static void Require(BOOL condition) {
  if (!condition) @throw [NSException exceptionWithName:@"DiagnosticBoundary" reason:nil userInfo:nil];
}
static BOOL Denied(const char *operation, int filter, const char *value) {
  return sandbox_check(getpid(), operation, filter | SANDBOX_CHECK_NO_REPORT, value) == 1;
}
static NSString *Digest(NSData *data) {
  unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
  NSMutableString *result = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(bytes); i++) [result appendFormat:@"%02x", bytes[i]];
  return result;
}
static NSData *SingleLinkFile(NSString *path) {
  int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
  Require(fd >= 0);
  struct stat st;
  BOOL valid = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1 && st.st_size > 0 && st.st_size <= 16 * 1024 * 1024;
  if (!valid) { close(fd); Require(NO); }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t count = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
    if (count <= 0) { close(fd); Require(NO); }
    offset += (NSUInteger)count;
  }
  close(fd);
  return [data copy];
}
static NSString *Metadata(const char *value) {
  Require(value != NULL && strlen(value) <= 8192);
  NSString *text = [NSString stringWithUTF8String:value];
  Require(text.length > 0 && [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound);
  return text;
}
static BOOL SubclassOf(Class cls, Class parent) {
  for (NSUInteger depth = 0; cls && depth < 32; depth++, cls = class_getSuperclass(cls))
    if (cls == parent) return YES;
  return NO;
}
// These are solely the fixed construction APIs already used by the production
// reader/writer. Inspect the runtime ABI before invoking any of them.
static id FixedObjectGetter(id receiver, const char *selector) {
  Class cls = object_getClass(receiver);
  Method method = class_getInstanceMethod(cls, sel_registerName(selector));
  Require(method != NULL && method_getNumberOfArguments(method) == 2);
  char *returnType = method_copyReturnType(method);
  BOOL objectReturn = returnType && strcmp(returnType, "@") == 0;
  free(returnType);
  Require(objectReturn);
  char *selfType = method_copyArgumentType(method, 0), *selectorType = method_copyArgumentType(method, 1);
  BOOL argumentsMatch = selfType && (strcmp(selfType, "@") == 0 || strcmp(selfType, "#") == 0) &&
      selectorType && strcmp(selectorType, ":") == 0;
  free(selfType); free(selectorType);
  Require(argumentsMatch);
  return ((id (*)(id, SEL))objc_msgSend)(receiver, sel_registerName(selector));
}

// Dynamic construction has no private getter invocation except documented
// NSObject allocation/init/copy and the production reader's fixed projections.
static void TypedMethod(id receiver, const char *selector, const char *result, NSArray<NSString *> *arguments) {
  Method method = class_getInstanceMethod(object_getClass(receiver), sel_registerName(selector));
  Require(method != NULL && method_getNumberOfArguments(method) == arguments.count + 2);
  char *returnType = method_copyReturnType(method);
  Require(returnType != NULL && strcmp(returnType, result) == 0);
  free(returnType);
  char *selfType = method_copyArgumentType(method, 0), *selType = method_copyArgumentType(method, 1);
  Require(selfType && (strcmp(selfType, "@") == 0 || strcmp(selfType, "#") == 0) && selType && strcmp(selType, ":") == 0);
  free(selfType); free(selType);
  for (NSUInteger i = 0; i < arguments.count; i++) {
    char *type = method_copyArgumentType(method, (unsigned int)i + 2);
    Require(type && strcmp(type, [arguments[i] UTF8String]) == 0);
    free(type);
  }
}
static void FixedObjectSetter(id receiver, const char *selector, id value) {
  TypedMethod(receiver, selector, "v", @[ @"@" ]);
  ((void (*)(id, SEL, id))objc_msgSend)(receiver, sel_registerName(selector), value);
}
static void FixedUIntSetter(id receiver, const char *selector, unsigned int value) {
  TypedMethod(receiver, selector, "v", @[ @(@encode(unsigned int)) ]);
  ((void (*)(id, SEL, unsigned int))objc_msgSend)(receiver, sel_registerName(selector), value);
}
static void FixedNSUIntegerSetter(id receiver, const char *selector, NSUInteger value) {
  TypedMethod(receiver, selector, "v", @[ @(@encode(NSUInteger)) ]);
  ((void (*)(id, SEL, NSUInteger))objc_msgSend)(receiver, sel_registerName(selector), value);
}
static void FixedNativeClass(Class cls) {
  Require(cls != Nil);
  Class valueClass = cls;
  for (; cls != NSObject.class; cls = class_getSuperclass(cls)) {
    NSDictionary *layout = cls ? ANMObservedNativeLayout(NSStringFromClass(cls)) : nil;
    Require(layout && ANMContentObservedClassMatches(cls, valueClass, layout, NULL));
  }
}
static id FixedNew(const char *name) {
  Class cls = objc_getClass(name);
  FixedNativeClass(cls);
  id allocated = FixedObjectGetter((id)cls, "alloc");
  Require(allocated && object_getClass(allocated) == cls);
  id value = FixedObjectGetter(allocated, "init");
  Require(value && object_getClass(value) == cls && ANMContentLayoutMatches(value, NULL));
  return value;
}
static id FixedTodo(BOOL done) {
  Class cls = objc_getClass("ICTTTodo");
  FixedNativeClass(cls);
  id allocated = FixedObjectGetter((id)cls, "alloc");
  Require(allocated && object_getClass(allocated) == cls);
  TypedMethod(allocated, "initWithIdentifier:done:", "@", @[ @"@", @(@encode(BOOL)) ]);
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:@"77777777-7777-4777-8777-777777777777"];
  id value = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(allocated, sel_registerName("initWithIdentifier:done:"), uuid, done);
  Require(value && object_getClass(value) == cls && ANMContentLayoutMatches(value, NULL));
  return value;
}
static NSDictionary *Snapshot(NSAttributedString *body) {
  NSDictionary *snapshot = ANMContentSnapshot(body, NSMakeRange(0, body.length), NULL);
  Require(snapshot != nil);
  return snapshot;
}
static NSString *const ConstructedPublicText = @"PUBLIC NATIVE REPRESENTATION CONTROL\nChecklist generated\nAttachment \uFFFC\n";
static id ConstructedStyle(void) {
  id style = FixedNew("ICTTMutableParagraphStyle");
  FixedUIntSetter(style, "setStyle:", 103);
  FixedNSUIntegerSetter(style, "setIndent:", 3);
  FixedNSUIntegerSetter(style, "setBlockQuoteLevel:", 1);
  FixedObjectSetter(style, "setUuid:", [[NSUUID alloc] initWithUUIDString:@"66666666-6666-4666-8666-666666666666"]);
  FixedObjectSetter(style, "setTodo:", FixedTodo(YES));
  return style;
}
static id ConstructedGlyph(void) {
  id glyph = FixedNew("ICTTAttachment");
  FixedObjectSetter(glyph, "setAttachmentIdentifier:", @"88888888-8888-4888-8888-888888888888");
  FixedObjectSetter(glyph, "setAttachmentUTI:", @"public.data");
  return glyph;
}
static NSAttributedString *ConstructedBody(id style, id glyph) {
  NSMutableAttributedString *body = [[NSMutableAttributedString alloc] initWithString:ConstructedPublicText
      attributes:@{ @"TTStyle": style, @"TTHints": @3, @"NSLink": [NSURL URLWithString:@"https://example.test/public-fixture"] }];
  NSRange at = [ConstructedPublicText rangeOfString:@"\uFFFC"];
  Require(at.length == 1);
  [body addAttribute:@"NSAttachment" value:glyph range:at];
  return body;
}
static NSDictionary *ConstructedControls(NSMutableArray *checks) {
  DiagnosticStage = "fixed-native-memory-construction";
  id style = ConstructedStyle(), glyph = ConstructedGlyph();
  NSAttributedString *body = ConstructedBody(style, glyph);
  Require([body.string isEqual:ConstructedPublicText]);
  NSDictionary *frozen = Snapshot(body);
  Require(ANMContentMatches(frozen, body, NULL));
  // Expected identity/type values come from the public construction constants,
  // not from a captured native object or an edited store baseline.
  BOOL done = YES;
  id expectedTodo = @[ @"todo", @{ @"uuid": @[ @"uuid", @"77777777-7777-4777-8777-777777777777" ],
      @"done": @[ @"stored-scalar", @(@encode(BOOL)), [NSData dataWithBytes:&done length:sizeof(done)] ] } ];
  Require([ANMContentValue(FixedTodo(YES), NULL) isEqual:expectedTodo]);
  Require([ANMContentValue(glyph, NULL) isEqual:@[ @"attachment", @"88888888-8888-4888-8888-888888888888", @"public.data" ]]);
  [checks addObject:@"native-mutable-todo-glyph-accepted"];
  DiagnosticStage = "independent-native-memory-reconstruction";
  NSAttributedString *independent = ConstructedBody(ConstructedStyle(), ConstructedGlyph());
  Require(ANMContentMatches(frozen, independent, NULL));
  [checks addObject:@"independent-native-memory-values-stable"];
  DiagnosticStage = "native-immutable-copy-normalization";
  id copied = FixedObjectGetter(style, "copy");
  Require(copied && [NSStringFromClass(object_getClass(copied)) isEqual:@"ICTTParagraphStyle"]);
  NSAttributedString *normalized = ConstructedBody(copied, ConstructedGlyph());
  Require(ANMContentMatches(frozen, normalized, NULL));
  [checks addObject:@"native-mutable-to-immutable-copy-preserves-stored-state"];
  DiagnosticStage = "native-deep-snapshot-mutation-controls";
  FixedNSUIntegerSetter(style, "setIndent:", 4);
  Require(!ANMContentMatches(frozen, body, NULL));
  FixedNSUIntegerSetter(style, "setIndent:", 3);
  Require(ANMContentMatches(frozen, body, NULL));
  FixedObjectSetter(style, "setTodo:", FixedTodo(NO));
  Require(!ANMContentMatches(frozen, body, NULL));
  FixedObjectSetter(style, "setTodo:", FixedTodo(YES));
  Require(ANMContentMatches(frozen, body, NULL));
  FixedObjectSetter(glyph, "setAttachmentIdentifier:", @"99999999-9999-4999-8999-999999999999");
  Require(!ANMContentMatches(frozen, body, NULL));
  FixedObjectSetter(glyph, "setAttachmentIdentifier:", @"88888888-8888-4888-8888-888888888888");
  Require(ANMContentMatches(frozen, body, NULL));
  [checks addObject:@"native-stored-field-todo-glyph-mutation-detected"];
  Require([body.string isEqual:ConstructedPublicText]);
  return @{ @"constructedBodyUTF16": @(body.length), @"constructedBodyUTF8Sha256": Digest([body.string dataUsingEncoding:NSUTF8StringEncoding]) };
}
static NSManagedObjectContext *ReadOnlyContext(NSManagedObjectModel *model, NSDictionary *standard, NSString *storePath) {
  NSMutableDictionary *options = [standard mutableCopy];
  options[NSReadOnlyPersistentStoreOption] = @YES;
  options[NSMigratePersistentStoresAutomaticallyOption] = @NO;
  options[NSInferMappingModelAutomaticallyOption] = @NO;
  options[NSSQLitePragmasOption] = @{ @"journal_mode": @"DELETE" };
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  Require([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
      URL:[NSURL fileURLWithPath:storePath] options:options error:NULL] != nil);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  context.undoManager = nil;
  return context;
}
static NSManagedObject *FixedNote(NSManagedObjectContext *context) {
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
  request.fetchLimit = 2;
  request.returnsObjectsAsFaults = NO;
  NSArray *notes = [context executeFetchRequest:request error:NULL];
  Require(notes.count == 1);
  NSManagedObject *note = notes.firstObject;
  Require([[note valueForKey:@"identifier"] isEqual:@"33333333-3333-4333-8333-333333333333"]);
  NSData *body = [[note valueForKey:@"noteData"] valueForKey:@"data"];
  DiagnosticStage = "fixed-public-body-hash";
  Require([body isKindOfClass:NSData.class] && [Digest(body) isEqual:PublicPayloadSHA256]);
  return note;
}
static void CloseContext(NSManagedObjectContext *context) {
  [context reset];
  NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
  NSArray *stores = [coordinator.persistentStores copy];
  for (NSPersistentStore *store in stores) Require([coordinator removePersistentStore:store error:NULL]);
}
static NSString *FixtureRootName(NSString *path) {
  NSString *parent = [path stringByDeletingLastPathComponent];
  if (![@[ @"/tmp", @"/private/tmp" ] containsObject:parent]) return nil;
  NSString *name = path.lastPathComponent;
  NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:
      @"^apple-notes-synthetic-fixture-[A-Za-z0-9]+$" options:0 error:NULL];
  return [pattern numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] == 1 ? name : nil;
}
static BOOL EquivalentFixtureRoots(NSString *supplied, NSString *resolved) {
  NSString *name = FixtureRootName(supplied);
  return name && [name isEqual:FixtureRootName(resolved)];
}
static NSDictionary *Control(NSString *root, NSMutableArray *checks, NSMutableDictionary *observations) {
  // Policy checks inspect denial only and never open real home/preferences.
  const char *home = getenv("HOME"), *fixed = getenv("CFFIXED_USER_HOME"), *tmp = getenv("TMPDIR");
  Require(home && fixed && tmp && strcmp(home, fixed) != 0);
  DiagnosticStage = "root-containment";
  Require(FixtureRootName(root) != nil);
  char resolvedRoot[PATH_MAX];
  Require(realpath(root.fileSystemRepresentation, resolvedRoot) != NULL &&
      EquivalentFixtureRoots(root, Metadata(resolvedRoot)));
  struct stat rootStat;
  Require(lstat(root.fileSystemRepresentation, &rootStat) == 0 && S_ISDIR(rootStat.st_mode) &&
      rootStat.st_uid == getuid() && (rootStat.st_mode & 0777) == 0700);
  Require([@(fixed) isEqual:[root stringByAppendingPathComponent:@"isolated-user"]] &&
      [@(tmp) isEqual:[root stringByAppendingPathComponent:@"tmp"]]);
  DiagnosticStage = "sandbox-policy";
  NSString *sentinel = [@(home) stringByAppendingPathComponent:@"Library/Preferences/io.github.apple-notes-mcp.private-writer.plist"];
  Require(Denied("file-read-data", 1, sentinel.UTF8String) && Denied("file-write-data", 1, sentinel.UTF8String) &&
      Denied("file-read-data", 1, "/Library/Preferences/.GlobalPreferences.plist") &&
      Denied("file-write-data", 1, "/Library/Preferences/.GlobalPreferences.plist") &&
      Denied("mach-lookup", 2, "com.apple.cfprefsd.agent") && Denied("mach-lookup", 2, "com.apple.cfprefsd.daemon") &&
      Denied("network-outbound", 0, NULL));
  Require([[NSHomeDirectory() stringByStandardizingPath] isEqual:[@(fixed) stringByStandardizingPath]] &&
      [NSBundle.mainBundle.bundleIdentifier isEqual:@"io.github.apple-notes-mcp.private-writer"]);
  Require(objc_getClass("ICNote") == Nil);
  DiagnosticStage = "public-payload-file";
  NSData *payload = SingleLinkFile([root stringByAppendingPathComponent:@"generated-baseline.gz"]);
  Require([Digest(payload) isEqual:PublicPayloadSHA256]);
  NSString *storePath = [root stringByAppendingPathComponent:@"NoteStore.sqlite"];
  (void)SingleLinkFile(storePath);
  // Verify generic persisted fixed seed before any private framework loads.
  DiagnosticStage = "generic-model-open";
  NSManagedObjectModel *genericModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:
      [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/NotesShared.framework/Resources/NoteData.mom"]];
  Require(genericModel != nil);
  for (NSEntityDescription *entity in genericModel.entities) entity.managedObjectClassName = @"NSManagedObject";
  NSManagedObjectContext *generic = ReadOnlyContext(genericModel, @{}, storePath);
  DiagnosticStage = "generic-public-seed";
  (void)FixedNote(generic);
  CloseContext(generic);
  DiagnosticStage = "framework-load";
  Require(dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW | RTLD_LOCAL) != NULL);
  // Independent new-memory controls run before any native store projection.
  // A later payload bookkeeping failure cannot hide their completed result.
  NSDictionary *constructedLedger = ConstructedControls(checks);
  Class container = objc_getClass("ICPersistentContainer");
  Require(container != Nil);
  DiagnosticStage = "container-model-abi";
  NSManagedObjectModel *model = FixedObjectGetter((id)container, "managedObjectModel");
  NSDictionary *standard = FixedObjectGetter((id)container, "standardStoreOptions");
  Require([model isKindOfClass:NSManagedObjectModel.class] && [standard isKindOfClass:NSDictionary.class]);
  DiagnosticStage = "native-read-only-open";
  NSManagedObjectContext *first = ReadOnlyContext(model, standard, storePath);
  NSManagedObjectContext *second = ReadOnlyContext(model, standard, storePath);
  Require(first != second && first.persistentStoreCoordinator != second.persistentStoreCoordinator);
  DiagnosticStage = "fixed-seed-native-body";
  NSManagedObject *firstNote = FixedNote(first), *secondNote = FixedNote(second);
  Require(firstNote != secondNote && SubclassOf(object_getClass(firstNote), objc_getClass("ICNote")) &&
      SubclassOf(object_getClass(secondNote), objc_getClass("ICNote")));
  // Each FixedNote has already independently type-checked and matched the
  // stored gzip bytes against the public literal hash before projection.
  observations[@"firstPayloadMatchesBeforeProjection"] = @YES;
  observations[@"secondPayloadMatchesBeforeProjection"] = @YES;
  DiagnosticStage = "read-only-context-before-projection";
  observations[@"firstContextHasChangesBeforeProjection"] = Flag(first.hasChanges);
  observations[@"secondContextHasChangesBeforeProjection"] = Flag(second.hasChanges);
  id firstMergeable = FixedObjectGetter(firstNote, "mergeableString"), secondMergeable = FixedObjectGetter(secondNote, "mergeableString");
  Require(firstMergeable && secondMergeable && firstMergeable != secondMergeable);
  NSAttributedString *firstBody = FixedObjectGetter(firstMergeable, "attributedString"), *secondBody = FixedObjectGetter(secondMergeable, "attributedString");
  Require([firstBody isKindOfClass:NSAttributedString.class] && [secondBody isKindOfClass:NSAttributedString.class] &&
      [firstBody.string isEqual:PublicText] && [secondBody.string isEqual:PublicText]);
  DiagnosticStage = "fixed-seed-native-comparator";
  NSDictionary *frozen = Snapshot(firstBody);
  Require(ANMContentMatches(frozen, firstBody, NULL));
  [checks addObject:@"native-fixed-seed-accepted"];
  DiagnosticStage = "fixed-seed-repeated-projection";
  NSAttributedString *repeated = FixedObjectGetter(firstMergeable, "attributedString");
  Require([repeated.string isEqual:PublicText] && ANMContentMatches(frozen, repeated, NULL));
  [checks addObject:@"native-fixed-seed-repeated-projection-stable"];
  DiagnosticStage = "fixed-seed-independent-context";
  Require(ANMContentMatches(frozen, secondBody, NULL));
  [checks addObject:@"native-fixed-seed-independent-context-stable"];
  DiagnosticStage = "read-only-context-after-projection";
  observations[@"firstContextHasChangesAfterProjection"] = Flag(first.hasChanges);
  observations[@"secondContextHasChangesAfterProjection"] = Flag(second.hasChanges);
  // A read-only persistent store plus the outer exact byte/tree ledger is the
  // durability boundary. Context dirtiness is reported separately; no cause
  // or harmlessness is inferred from its value.
  DiagnosticStage = "read-only-first-payload-recheck";
  NSData *firstBytes = [[firstNote valueForKey:@"noteData"] valueForKey:@"data"];
  Require([firstBytes isKindOfClass:NSData.class]);
  observations[@"firstPayloadMatchesAfterProjection"] = Flag([Digest(firstBytes) isEqual:PublicPayloadSHA256]);
  Require([observations[@"firstPayloadMatchesAfterProjection"] isEqual:@YES]);
  DiagnosticStage = "read-only-second-payload-recheck";
  NSData *secondBytes = [[secondNote valueForKey:@"noteData"] valueForKey:@"data"];
  Require([secondBytes isKindOfClass:NSData.class]);
  observations[@"secondPayloadMatchesAfterProjection"] = Flag([Digest(secondBytes) isEqual:PublicPayloadSHA256]);
  Require([observations[@"secondPayloadMatchesAfterProjection"] isEqual:@YES]);
  [checks addObject:@"native-fixed-seed-public-body-ledgers-unchanged"];
  NSString *firstBodyHash = Digest([firstBody.string dataUsingEncoding:NSUTF8StringEncoding]);
  NSString *secondBodyHash = Digest([secondBody.string dataUsingEncoding:NSUTF8StringEncoding]);
  NSString *persistedPayloadHash = Digest(firstBytes);
  CloseContext(first); CloseContext(second);
  return @{ @"schemaVersion": @2, @"kind": @"fixed-public-native-comparator-control", @"completed": @YES,
      @"syntheticOnly": @YES, @"fixedPublicBodyVerified": @YES, @"readOnlyStore": @YES,
      @"storedAttributeFieldsRead": @YES, @"snapshotValuesEmitted": @NO, @"nativeAttributeGettersInvoked": @NO,
      @"nativeObjectsConstructedInMemory": @YES, @"storeSavesInvoked": @NO, @"writerInvoked": @NO,
      @"archiveCompletenessClaimed": @NO, @"persistenceClaimed": @NO,
      @"seedBodyUTF16": @184, @"seedPayloadSha256": persistedPayloadHash,
      @"firstSeedBodyUTF8Sha256": firstBodyHash, @"secondSeedBodyUTF8Sha256": secondBodyHash,
      @"constructedBodyUTF16": constructedLedger[@"constructedBodyUTF16"], @"constructedBodyUTF8Sha256": constructedLedger[@"constructedBodyUTF8Sha256"],
      @"observations": [observations copy], @"checks": [checks copy] };
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2) return 2;
    NSMutableArray *checks = [NSMutableArray array];
    NSMutableDictionary *observations = EmptyObservations();
    @try {
      NSDictionary *report = Control(@(argv[1]), checks, observations);
      NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
      Require(json != nil);
      fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
      return 0;
    } @catch (NSException *error) {
      (void)error;
      // Never output native reason, userInfo, body, snapshot, getter values or
      // object descriptions. The fixed stage/check code envelope is bounded.
      NSDictionary *failure = @{ @"schemaVersion": @2, @"kind": @"fixed-public-native-comparator-control", @"completed": @NO,
          @"code": @"control_boundary_or_api_unavailable", @"stage": @(DiagnosticStage), @"observations": [observations copy], @"checks": [checks copy] };
      NSData *json = [NSJSONSerialization dataWithJSONObject:failure options:NSJSONWritingSortedKeys error:NULL];
      if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); }
      return 1;
    }
  }
}
