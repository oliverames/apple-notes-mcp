// Original generic in-memory Core Data model. No Notes store/model or NotesShared.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
static void *ForbiddenFrameworkLoad(const char *path, int flags) {
  (void)path; (void)flags;
  @throw [NSException exceptionWithName:@"fixture_framework_load" reason:@"Dynamic framework loads are forbidden" userInfo:nil];
}
#define dlopen ForbiddenFrameworkLoad
#define main private_writer_main
#include "../../native/private-helper/apple-notes-private-writer.m"
#undef main
#undef dlopen

static NSString *const SOURCE = @"D629A948-0C61-43BA-8FDE-04CD6DED38C7";
static NSString *const TARGET = @"1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F";
static void Assert(BOOL condition, NSString *message) {
  if (!condition) @throw [NSException exceptionWithName:@"fixture_assertion" reason:message userInfo:nil];
}
static NSAttributeDescription *Attribute(NSString *name, NSAttributeType type) {
  NSAttributeDescription *a = [NSAttributeDescription new];
  a.name = name; a.attributeType = type; a.optional = YES;
  return a;
}
static NSRelationshipDescription *Relationship(NSString *name, NSEntityDescription *entity) {
  NSRelationshipDescription *r = [NSRelationshipDescription new];
  r.name = name; r.destinationEntity = entity; r.optional = YES; r.maxCount = 1;
  return r;
}
static NSManagedObjectContext *Peer(NSManagedObjectContext *context) {
  NSManagedObjectContext *peer = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  peer.persistentStoreCoordinator = context.persistentStoreCoordinator;
  peer.mergePolicy = NSErrorMergePolicy;
  peer.userInfo[@"writerStoreIsCopy"] = @YES;
  return peer;
}
static NSManagedObject *Insert(NSManagedObjectContext *c, NSString *entity, NSString *identifier) {
  NSManagedObject *o = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:c];
  [o setValue:identifier forKey:@"identifier"];
  return o;
}
static NSString *URI(NSManagedObject *o) { return o.objectID.URIRepresentation.absoluteString; }

static NSDictionary *Fixture(BOOL unique) {
  gScopeRequest = nil; gTargetScopeRequest = nil; gScopeEnforced = NO;
  gScopeSubject = ScopeSubjectNote;
  gWriteRequest = YES; gSaveAttempted = NO; gSaveSucceeded = NO; gEarlySaves = 0;
  NSEntityDescription *folder = [NSEntityDescription new];
  folder.name = @"ICFolder"; folder.managedObjectClassName = @"NSManagedObject";
  folder.properties = @[ Attribute(@"identifier", NSStringAttributeType),
    Attribute(@"markedForDeletion", NSBooleanAttributeType), Relationship(@"parent", folder) ];
  NSEntityDescription *note = [NSEntityDescription new];
  note.name = @"ICNote"; note.managedObjectClassName = @"NSManagedObject";
  NSEntityDescription *noteData = [NSEntityDescription new];
  noteData.name = @"ICNoteData"; noteData.managedObjectClassName = @"NSManagedObject";
  noteData.properties = @[ Attribute(@"data", NSBinaryDataAttributeType) ];
  note.properties = @[ Attribute(@"identifier", NSStringAttributeType), Attribute(@"text", NSStringAttributeType),
    Attribute(@"paragraphId", NSStringAttributeType), Attribute(@"modificationDate", NSDateAttributeType),
    Attribute(@"markedForDeletion", NSBooleanAttributeType), Attribute(@"isPasswordProtected", NSBooleanAttributeType),
    Relationship(@"noteData", noteData), Relationship(@"folder", folder) ];
  NSEntityDescription *inlineRow = [NSEntityDescription new];
  inlineRow.name = @"ICInlineAttachment"; inlineRow.managedObjectClassName = @"NSManagedObject";
  inlineRow.properties = @[ Attribute(@"identifier", NSStringAttributeType), Relationship(@"note", note) ];
  NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[ folder, note, noteData, inlineRow ];
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  Assert([coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error] != nil,
         error.description);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator; context.mergePolicy = NSErrorMergePolicy;
  context.userInfo[@"writerStoreIsCopy"] = @YES;
  NSManagedObject *allowed = Insert(context, @"ICFolder", @"allowed");
  NSManagedObject *forbidden = Insert(context, @"ICFolder", @"forbidden");
  NSManagedObject *sourceHome = Insert(context, @"ICFolder", @"source-home");
  NSManagedObject *targetHome = Insert(context, @"ICFolder", @"target-home");
  [sourceHome setValue:allowed forKey:@"parent"]; [targetHome setValue:allowed forKey:@"parent"];
  NSManagedObject *source = Insert(context, @"ICNote", SOURCE);
  NSManagedObject *target = Insert(context, @"ICNote", TARGET);
  [source setValue:sourceHome forKey:@"folder"]; [target setValue:targetHome forKey:@"folder"];
  [source setValue:@"source baseline" forKey:@"text"]; [target setValue:@"target baseline" forKey:@"text"];
  for (NSManagedObject *subject in @[ source, target ]) {
    NSManagedObject *body = [NSEntityDescription insertNewObjectForEntityForName:@"ICNoteData" inManagedObjectContext:context];
    [body setValue:[[subject valueForKey:@"text"] dataUsingEncoding:NSUTF8StringEncoding] forKey:@"data"];
    [subject setValue:body forKey:@"noteData"]; [subject setValue:@NO forKey:@"isPasswordProtected"];
  }
  if (unique) [target setValue:@"unique-baseline" forKey:@"paragraphId"];
  Assert([context save:&error], error.description);
  return @{ @"context" : context, @"source" : source, @"target" : target,
    @"allowed" : allowed, @"forbidden" : forbidden, @"sourceHome" : sourceHome, @"targetHome" : targetHome,
    @"unique" : @(unique) };
}
static NSDictionary *Request(NSDictionary *f, BOOL receiver, NSDictionary *targetScope) {
  NSMutableDictionary *r = [@{ @"action" : @"add_section_link", @"identifier" : SOURCE, @"target" : TARGET } mutableCopy];
  if (receiver) r[@"ifAncestorFolderId"] = URI(f[@"allowed"]);
  if (targetScope) r[@"targetScope"] = targetScope;
  return r;
}
static void Reparent(NSDictionary *f, NSString *row, NSString *parent) {
  NSManagedObjectContext *context = f[@"context"];
  NSManagedObjectContext *peer = Peer(context);
  NSManagedObject *folder = [peer existingObjectWithID:[f[row] objectID] error:NULL];
  NSManagedObject *destination = [peer existingObjectWithID:[f[parent] objectID] error:NULL];
  [folder setValue:destination forKey:@"parent"];
  Assert([peer save:NULL], @"Peer reparent save");
}
static void AssertUnchanged(NSDictionary *f) {
  Assert(![f[@"context"] hasChanges], @"Refusal left pending note or inline-row changes");
  NSManagedObjectContext *fresh = Peer(f[@"context"]);
  NSManagedObject *source = FetchNote(fresh, SOURCE), *target = FetchNote(fresh, TARGET);
  Assert([[source valueForKey:@"text"] isEqual:@"source baseline"], @"Receiver was persisted on refusal");
  Assert([[target valueForKey:@"text"] isEqual:@"target baseline"], @"Target body was persisted on refusal");
  Assert([NoteBodyData(source) isEqual:[@"source baseline" dataUsingEncoding:NSUTF8StringEncoding]], @"Receiver body bytes changed on refusal");
  Assert([NoteBodyData(target) isEqual:[@"target baseline" dataUsingEncoding:NSUTF8StringEncoding]], @"Target body bytes changed on refusal");
  NSString *expected = [f[@"unique"] boolValue] ? @"unique-baseline" : nil;
  Assert([[target valueForKey:@"paragraphId"] isEqual:expected] || (![target valueForKey:@"paragraphId"] && !expected),
         @"Target paragraph identifier changed on refusal");
  Assert([fresh countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"ICInlineAttachment"] error:NULL] == 0,
         @"Inline attachment persisted on refusal");
  Assert(!gSaveAttempted && !gSaveSucceeded && !gEarlySaves, @"Refusal reached a save");
}
static void Refuses(void (^fn)(void), NSString *code, NSString *reason) {
  BOOL refused = NO;
  @try { fn(); } @catch (HelperError *error) {
    Assert([error.userInfo[@"code"] isEqual:code], [NSString stringWithFormat:@"Expected %@, got %@", code, error.userInfo]);
    if (reason) Assert([error.userInfo[@"scopeReason"] isEqual:reason], @"Wrong scope reason");
    Assert([error.userInfo[@"committed"] isEqual:@NO], @"Refusal must be uncommitted");
    refused = YES;
  }
  Assert(refused, @"Expected scope refusal");
}
static void MutateAndSave(NSDictionary *f) {
  NSManagedObjectContext *context = f[@"context"];
  NSManagedObject *source = f[@"source"], *target = f[@"target"];
  [source setValue:@"source with chip" forKey:@"text"];
  NSMutableArray *changed = [NSMutableArray arrayWithObject:source];
  if (![f[@"unique"] boolValue]) { [target setValue:@"minted" forKey:@"paragraphId"]; [changed addObject:target]; }
  NSManagedObject *inlineRow = Insert(context, @"ICInlineAttachment", @"new-chip");
  [inlineRow setValue:source forKey:@"note"]; [changed addObject:inlineRow];
  RequireExpectedChanges(context, changed, [NSSet set]);
  SaveOrFail(context);
}

static NSArray *Run(void) {
  NSMutableArray *passed = [NSMutableArray array];
  Assert(!gFrameworkLoaded, @"NotesShared must remain unloaded");
  NSDictionary *policyFixture = Fixture(YES);
  NSDictionary *sourcePolicy = @{ @"ifFolderId" : URI(policyFixture[@"sourceHome"]),
    @"forbiddenAncestorFolderIds" : @[ URI(policyFixture[@"forbidden"]), URI(policyFixture[@"targetHome"]) ] };
  NSMutableDictionary *policyRequest = [sourcePolicy mutableCopy];
  policyRequest[@"action"] = @"add_section_link"; policyRequest[@"identifier"] = SOURCE;
  policyRequest[@"target"] = [SOURCE lowercaseString];
  NSString *original = URI(policyFixture[@"sourceHome"]);
  NSRange keySlash = [original rangeOfString:@"/p" options:NSBackwardsSearch];
  NSString *equivalent = [NSString stringWithFormat:@"%@/p0%@", [original substringToIndex:keySlash.location],
    [original substringFromIndex:keySlash.location + 2]];
  policyRequest[@"targetScope"] = @{ @"ifFolderId" : equivalent,
    @"forbiddenAncestorFolderIds" : @[ URI(policyFixture[@"targetHome"]), URI(policyFixture[@"forbidden"]), URI(policyFixture[@"targetHome"]) ] };
  ConfigureScopeGuard(policyRequest, ScopeSubjectNote);
  Assert(gScopeRequest && !gTargetScopeRequest, @"Equivalent self-link policies need one subject");
  CheckSectionLinkScopeBeforeMutation(policyFixture[@"context"]);
  policyRequest[@"targetScope"] = @{ @"ifFolderId" : URI(policyFixture[@"targetHome"]) };
  Refuses(^{ ConfigureScopeGuard(policyRequest, ScopeSubjectNote); }, @"invalid_request", nil);
  policyRequest[@"targetScope"] = @{};
  Refuses(^{ ConfigureScopeGuard(policyRequest, ScopeSubjectNote); }, @"invalid_request", nil);
  ConfigureScopeGuard(@{ @"action" : @"add_section_link", @"identifier" : SOURCE,
      @"targetScope" : @{ @"ifFolderId" : URI(policyFixture[@"sourceHome"]) } }, ScopeSubjectNote);
  CheckSectionLinkScopeBeforeMutation(policyFixture[@"context"]);
  Assert(gScopeRequest && !gTargetScopeRequest, @"Target-only self-link policy must guard that note");
  AssertUnchanged(policyFixture); [passed addObject:@"self-link policies are explicit and equivalent"];
  policyRequest[@"target"] = TARGET;
  for (id empty in @[ @{}, @{ @"forbiddenAncestorFolderIds" : @[] } ]) {
    policyRequest[@"targetScope"] = empty;
    Refuses(^{ ConfigureScopeGuard(policyRequest, ScopeSubjectNote); }, @"invalid_request", nil);
  }
  [policyRequest removeObjectForKey:@"targetScope"];
  Refuses(^{ ConfigureScopeGuard(policyRequest, ScopeSubjectNote); }, @"invalid_request", nil);
  AssertUnchanged(policyFixture); [passed addObject:@"receiver guards never infer a target policy"];
  for (NSNumber *unique in @[ @NO, @YES ]) {
    NSDictionary *f = Fixture(unique.boolValue);
    Reparent(f, @"targetHome", @"forbidden");
    NSDictionary *scope = @{ @"ifAncestorFolderId" : URI(f[@"allowed"]) };
    ConfigureScopeGuard(Request(f, YES, scope), ScopeSubjectNote);
    Refuses(^{ CheckSectionLinkScopeBeforeMutation(f[@"context"]); }, @"scope_conflict", @"not_inside_expected_ancestor");
    AssertUnchanged(f);
    [passed addObject:unique.boolValue ? @"unique target outside ancestor refuses before mutation" : @"unminted target outside ancestor refuses before mutation"];

    f = Fixture(unique.boolValue);
    scope = @{ @"forbiddenAncestorFolderIds" : @[ URI(f[@"forbidden"]) ] };
    ConfigureScopeGuard(Request(f, YES, scope), ScopeSubjectNote);
    CheckSectionLinkScopeBeforeMutation(f[@"context"]);
    NSString *targetRevision = RevisionToken(f[@"target"]);
    Reparent(f, @"targetHome", @"forbidden");
    Assert([RevisionToken(FetchNote(Peer(f[@"context"]), TARGET)) isEqual:targetRevision], @"Ancestor drift must leave target r1 unchanged");
    Assert([[f[@"targetHome"] valueForKey:@"parent"] isEqual:f[@"allowed"]], @"Writing context must retain cached old ancestor");
    Refuses(^{ MutateAndSave(f); }, @"scope_conflict", @"inside_forbidden_folder");
    AssertUnchanged(f);
    [passed addObject:unique.boolValue ? @"unique target reparent drift rolls back both notes and chip" : @"minted target reparent drift rolls back both notes and chip"];
  }

  NSDictionary *f = Fixture(YES);
  NSDictionary *scope = @{ @"ifFolderId" : URI(f[@"sourceHome"]) };
  ConfigureScopeGuard(Request(f, NO, scope), ScopeSubjectNote);
  Assert(!gScopeRequest && gTargetScopeRequest, @"Target-only policy cannot depend on receiver guard");
  Refuses(^{ MutateAndSave(f); }, @"scope_conflict", @"not_in_expected_folder");
  AssertUnchanged(f); [passed addObject:@"target-only exact-folder guard refuses atomically"];

  f = Fixture(YES);
  scope = @{ @"ifFolderId" : URI(f[@"targetHome"]) };
  ConfigureScopeGuard(Request(f, NO, scope), ScopeSubjectNote);
  CheckSectionLinkScopeBeforeMutation(f[@"context"]);
  NSManagedObjectContext *peer = Peer(f[@"context"]);
  NSManagedObject *moved = FetchNote(peer, TARGET);
  [moved setValue:[peer existingObjectWithID:[f[@"forbidden"] objectID] error:NULL] forKey:@"folder"];
  Assert([peer save:NULL], @"Peer direct target move");
  Assert([[f[@"target"] valueForKey:@"folder"] isEqual:f[@"targetHome"]], @"Target's direct folder must still be cached");
  Refuses(^{ MutateAndSave(f); }, @"scope_conflict", @"not_in_expected_folder");
  AssertUnchanged(f); [passed addObject:@"unchanged unique target direct-folder drift is reread"];

  for (NSString *kind in @[ @"missing", @"deleted", @"cycle" ]) {
    f = Fixture(NO);
    NSMutableDictionary *targetScope = [@{ @"ifAncestorFolderId" : URI(f[@"allowed"]) } mutableCopy];
    if ([kind isEqual:@"missing"]) {
      NSString *existing = URI(f[@"allowed"]);
      NSRange slash = [existing rangeOfString:@"/" options:NSBackwardsSearch];
      targetScope[@"ifAncestorFolderId"] = [[existing substringToIndex:slash.location] stringByAppendingString:@"/p999999"];
    }
    else if ([kind isEqual:@"deleted"]) {
      peer = Peer(f[@"context"]);
      [[peer existingObjectWithID:[f[@"allowed"] objectID] error:NULL] setValue:@YES forKey:@"markedForDeletion"];
      Assert([peer save:NULL], @"Peer ancestor delete");
    } else {
      Reparent(f, @"allowed", @"targetHome");
    }
    ConfigureScopeGuard(Request(f, NO, targetScope), ScopeSubjectNote);
    Refuses(^{ MutateAndSave(f); }, [kind isEqual:@"missing"] ? @"scope_folder_not_found" : @"scope_conflict",
            [kind isEqual:@"missing"] ? @"folder_not_found" : ([kind isEqual:@"deleted"] ? @"folder_deleted" : @"folder_chain_invalid"));
    AssertUnchanged(f); [passed addObject:[kind stringByAppendingString:@" target ancestor refuses atomically"]];
  }
  f = Fixture(NO);
  peer = Peer(f[@"context"]);
  [[peer existingObjectWithID:[f[@"forbidden"] objectID] error:NULL] setValue:@YES forKey:@"markedForDeletion"];
  Assert([peer save:NULL], @"Peer forbidden-folder delete");
  ConfigureScopeGuard(Request(f, NO, @{ @"forbiddenAncestorFolderIds" : @[ URI(f[@"forbidden"]) ] }), ScopeSubjectNote);
  Refuses(^{ MutateAndSave(f); }, @"scope_folder_not_found", @"folder_deleted");
  AssertUnchanged(f); [passed addObject:@"deleted forbidden target id refuses atomically"];

  f = Fixture(YES);
  scope = @{ @"ifFolderId" : URI(f[@"targetHome"]), @"ifAncestorFolderId" : URI(f[@"allowed"]),
    @"forbiddenAncestorFolderIds" : @[ URI(f[@"forbidden"]) ] };
  ConfigureScopeGuard(Request(f, YES, scope), ScopeSubjectNote);
  CheckSectionLinkScopeBeforeMutation(f[@"context"]); MutateAndSave(f);
  Assert(gSaveSucceeded, @"Complete independent policies should permit expected save");
  [passed addObject:@"valid independent policies pass the guarded save"];
  Assert(!gFrameworkLoaded, @"NotesShared loaded by fixture");
  return passed;
}

int main(void) {
  @autoreleasepool {
    @try { EmitAndExit(@{ @"passed" : Run(), @"frameworkLoaded" : @(gFrameworkLoaded) }, 0); }
    @catch (NSException *error) { EmitAndExit(@{ @"error" : error.reason ?: error.name, @"frameworkLoaded" : @(gFrameworkLoaded) }, 1); }
  }
}
