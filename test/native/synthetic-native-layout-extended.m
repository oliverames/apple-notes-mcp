// Extended metadata-only diagnostic for a fixed public generated fixture. No writer
// import, action dispatch, saves, attribute getter invocation, or value output.
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreData/CoreData.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
"<key>CFBundleName</key><string>synthetic-native-layout</string></dict></plist>";

static NSString *const PublicPayloadSHA256 = @"ac93f271962eddbc6511ce12064ae1ac423e91546c8eff356a9ecddc765fa0d1";
static NSString *const PublicText = @"PUBLIC SYNTHETIC WRITER FIXTURE\n"
    "All contents and identifiers in this note are generated.\n"
    "This note contains no user data or device identifiers.\n"
    "For use in isolated fixture validation.\n";

static const char *DiagnosticStage = "input";

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
static void SortRecords(NSMutableArray *records, NSString *key) {
  [records sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[key] compare:b[key] options:NSLiteralSearch];
  }];
}
static NSDictionary *MethodMetadata(Class cls, SEL selector) {
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) return @{ @"selector": Metadata(sel_getName(selector)), @"present": @NO };
  char *returnType = method_copyReturnType(method);
  NSString *resultType = Metadata(returnType);
  free(returnType);
  unsigned int count = method_getNumberOfArguments(method);
  Require(count <= 32);
  NSMutableArray *arguments = [NSMutableArray array];
  for (unsigned int i = 0; i < count; i++) {
    char *type = method_copyArgumentType(method, i);
    [arguments addObject:Metadata(type)];
    free(type);
  }
  return @{ @"selector": Metadata(sel_getName(selector)), @"present": @YES,
      @"encoding": Metadata(method_getTypeEncoding(method)), @"returnType": resultType, @"argumentTypes": arguments };
}
static NSDictionary *DeclaredClassMetadata(Class cls) {
  unsigned int count = 0;
  Ivar *ivars = class_copyIvarList(cls, &count);
  Require(count <= 1024);
  NSMutableArray *stored = [NSMutableArray array];
  for (unsigned int i = 0; i < count; i++) {
    [stored addObject:@{ @"name": Metadata(ivar_getName(ivars[i])), @"encoding": Metadata(ivar_getTypeEncoding(ivars[i])),
        @"offset": @(ivar_getOffset(ivars[i])) }];
  }
  free(ivars);
  SortRecords(stored, @"name");
  objc_property_t *properties = class_copyPropertyList(cls, &count);
  Require(count <= 1024);
  NSMutableArray *declared = [NSMutableArray array];
  for (unsigned int i = 0; i < count; i++) {
    char *customGetter = property_copyAttributeValue(properties[i], "G");
    const char *getter = customGetter ?: property_getName(properties[i]);
    [declared addObject:@{ @"name": Metadata(property_getName(properties[i])),
        @"attributes": Metadata(property_getAttributes(properties[i])),
        @"getter": MethodMetadata(cls, sel_registerName(getter)) }];
    free(customGetter);
  }
  free(properties);
  SortRecords(declared, @"name");
  Method *methods = class_copyMethodList(cls, &count);
  Require(count <= 2048);
  NSMutableArray *zeroArgumentMethods = [NSMutableArray array];
  for (unsigned int i = 0; i < count; i++)
    if (method_getNumberOfArguments(methods[i]) == 2)
      [zeroArgumentMethods addObject:MethodMetadata(cls, method_getName(methods[i]))];
  free(methods);
  SortRecords(zeroArgumentMethods, @"selector");
  Class parent = class_getSuperclass(cls);
  return @{ @"name": Metadata(class_getName(cls)), @"superclass": parent ? Metadata(class_getName(parent)) : (id)NSNull.null,
      @"instanceSize": @(class_getInstanceSize(cls)), @"ivars": stored, @"properties": declared,
      @"zeroArgumentMethods": zeroArgumentMethods };
}
static NSArray *ClassChain(Class cls) {
  NSMutableArray *chain = [NSMutableArray array];
  for (NSUInteger depth = 0; cls && depth < 32; depth++, cls = class_getSuperclass(cls)) {
    [chain addObject:DeclaredClassMetadata(cls)];
    if (cls == NSObject.class) return chain;
  }
  Require(cls == Nil);
  return chain;
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
static NSDictionary *Diagnose(NSString *root) {
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
  Class container = objc_getClass("ICPersistentContainer");
  Require(container != Nil);
  DiagnosticStage = "container-model-abi";
  NSManagedObjectModel *model = FixedObjectGetter((id)container, "managedObjectModel");
  NSDictionary *standard = FixedObjectGetter((id)container, "standardStoreOptions");
  Require([model isKindOfClass:NSManagedObjectModel.class] && [standard isKindOfClass:NSDictionary.class]);
  DiagnosticStage = "native-read-only-open";
  NSManagedObjectContext *context = ReadOnlyContext(model, standard, storePath);
  DiagnosticStage = "native-public-seed";
  NSManagedObject *note = FixedNote(context);
  Require(SubclassOf(object_getClass(note), objc_getClass("ICNote")));
  DiagnosticStage = "mergeable-string-abi";
  id mergeable = FixedObjectGetter(note, "mergeableString");
  Require(mergeable != nil);
  DiagnosticStage = "attributed-string-abi";
  NSAttributedString *body = FixedObjectGetter(mergeable, "attributedString");
  DiagnosticStage = "public-body-text";
  Require([body isKindOfClass:NSAttributedString.class] && [body.string isEqual:PublicText]);
  DiagnosticStage = "attribute-schema-metadata";
  NSSet *supported = [NSSet setWithArray:@[ @"TTStyle", @"TTHints", @"TTUnderline", @"TTStrikethrough",
      @"TTEmphasis", @"TTColor", @"TTTimestamp", @"TTFont", @"NSFont", @"NSLink", @"NSAttachment" ]];
  NSMutableDictionary *keyClasses = [NSMutableDictionary dictionary];
  NSMutableDictionary *observedClasses = [NSMutableDictionary dictionary];
  NSMutableArray *nestedNativeFontClasses = [NSMutableArray array];
  NSMutableArray *fixedClasses = [NSMutableArray array];
  for (NSString *fixedName in @[ @"ICTTTodo", @"ICTTMutableParagraphStyle", @"ICTable", @"ICTTMergeableString", @"ICTTMergeableAttributedString", @"ICTTAttachment" ]) {
    Class fixedClass = NSClassFromString(fixedName);
    [fixedClasses addObject:@{ @"name": fixedName, @"present": @(fixedClass != Nil) }];
    if (fixedClass) observedClasses[fixedName] = ClassChain(fixedClass);
  }
  __block NSUInteger runs = 0;
  [body enumerateAttributesInRange:NSMakeRange(0, body.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
    (void)range; (void)stop;
    Require(++runs <= 128 && attrs.count <= 64);
    for (id key in attrs) {
      Require(SubclassOf(object_getClass(key), NSString.class));
      NSString *name = Metadata([key UTF8String]);
      Require(name.length <= 128);
      id value = attrs[key];
      Class cls = object_getClass(value);
      Require(cls != Nil);
      NSString *className = Metadata(class_getName(cls));
      NSMutableSet *classes = keyClasses[name];
      if (!classes) keyClasses[name] = classes = [NSMutableSet set];
      [classes addObject:className];
      if (!observedClasses[className]) observedClasses[className] = ClassChain(cls);
      if ([className isEqual:@"ICTTFont"]) {
        // Read only the object reference after exact known class/storage checks.
        // Never invoke nativeFont (which could initialize or normalize it),
        // describe/archive the object, or traverse any nested field values.
        Require(class_getSuperclass(cls) == NSObject.class && class_getInstanceSize(cls) == 40);
        Ivar field = class_getInstanceVariable(cls, "_nativeFont");
        Require(field != NULL && strcmp(ivar_getTypeEncoding(field), "@") == 0 && ivar_getOffset(field) == 32);
        id nested = object_getIvar(value, field);
        Class nestedClass = nested ? object_getClass(nested) : Nil;
        NSString *nestedName = nestedClass ? Metadata(class_getName(nestedClass)) : nil;
        NSDictionary *observation = @{ @"ownerClass": @"ICTTFont", @"storedField": @"_nativeFont",
            @"nil": @(nested == nil), @"valueClass": nestedName ?: (id)NSNull.null };
        if (![nestedNativeFontClasses containsObject:observation]) [nestedNativeFontClasses addObject:observation];
        if (nestedClass && !observedClasses[nestedName]) observedClasses[nestedName] = ClassChain(nestedClass);
      }
    }
  }];
  Require(keyClasses.count <= 64 && observedClasses.count <= 64);
  NSMutableArray *attributes = [NSMutableArray array];
  for (NSString *key in [[keyClasses allKeys] sortedArrayUsingSelector:@selector(compare:)])
    [attributes addObject:@{ @"key": key, @"supportedKey": @([supported containsObject:key]),
        @"valueClasses": [[keyClasses[key] allObjects] sortedArrayUsingSelector:@selector(compare:)] }];
  NSMutableArray *classes = [NSMutableArray array];
  for (NSString *name in [[observedClasses allKeys] sortedArrayUsingSelector:@selector(compare:)])
    [classes addObject:@{ @"name": name, @"chain": observedClasses[name] }];
  NSDictionary *result = @{ @"schemaVersion": @2, @"kind": @"fixed-public-native-layout-metadata", @"syntheticOnly": @YES,
      @"fixedPublicBodyVerified": @YES, @"readOnlyStore": @YES, @"scalarAttributeFieldValuesRead": @NO, @"nestedStoredReferenceClassOnly": @YES,
      @"nativeAttributeGettersInvoked": @NO, @"preservationPinsChanged": @NO,
      @"bodyUTF16": @(body.length), @"attributeRuns": @(runs), @"attributes": attributes, @"classes": classes,
      @"tableCellCoverage": @"unavailable:no-table-in-fixed-seed", @"nestedValueCoverage": @"class-only:nativeFont-no-values", @"fixedClassMetadata": fixedClasses,
      @"nestedNativeFontClasses": nestedNativeFontClasses };
  DiagnosticStage = "close-read-only-context";
  CloseContext(context);
  return result;
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2) return 2;
    @try {
      NSDictionary *report = Diagnose(@(argv[1]));
      NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
      Require(json != nil);
      fwrite(json.bytes, 1, json.length, stdout);
      fputc('\n', stdout);
      return 0;
    } @catch (NSException *error) {
      (void)error;
      // Never print exception reason/userInfo: private object descriptions or
      // native values could be embedded in either. A failure remains private.
      fprintf(stdout, "{\"kind\":\"fixed-public-native-layout-metadata\",\"completed\":false,\"code\":\"diagnostic_boundary_or_api_unavailable\",\"stage\":\"%s\"}\n", DiagnosticStage);
      return 1;
    }
  }
}
