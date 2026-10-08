// Pure synthetic attributed text. No NotesShared, stores, writer, or dispatch.
#include "../../native/private-helper/content-preservation.h"

@interface ICTTTodo : NSObject
@property(nonatomic, copy) NSUUID *uuid;
@property(nonatomic) BOOL done;
@end
@implementation ICTTTodo
@end

@interface ICTTParagraphStyle : NSObject
@property(nonatomic) unsigned int style;
@property(nonatomic) NSInteger alignment, writingDirection, indent, blockQuoteLevel, startingItemNumber;
@property(nonatomic) unsigned int hints;
@property(nonatomic, copy) NSUUID *uuid;
@property(nonatomic) ICTTTodo *todo;
@end
@implementation ICTTParagraphStyle
@end

@interface ICTTFont : NSObject
@property(nonatomic, copy) NSString *fontName;
@property(nonatomic) double pointSize;
@property(nonatomic) unsigned int fontHints;
@end
@implementation ICTTFont
@end

@interface ICTTAttachment : NSObject
@property(nonatomic, copy) NSString *attachmentIdentifier, *attachmentUTI;
@end
@implementation ICTTAttachment
@end

static NSUInteger checks = 0;
static void Assert(BOOL condition, NSString *message) {
  if (!condition) @throw [NSException exceptionWithName:@"fixture_assertion" reason:message userInfo:nil];
  checks++;
}

static ICTTParagraphStyle *FixtureStyle(void) {
  ICTTParagraphStyle *style = [ICTTParagraphStyle new];
  style.style = 103;
  style.alignment = 2;
  style.writingDirection = -1;
  style.indent = 3;
  style.blockQuoteLevel = 2;
  style.startingItemNumber = 17;
  style.hints = 3;
  style.uuid = [[NSUUID alloc] initWithUUIDString:@"11111111-1111-1111-1111-111111111111"];
  style.todo = [ICTTTodo new];
  style.todo.uuid = [[NSUUID alloc] initWithUUIDString:@"22222222-2222-2222-2222-222222222222"];
  style.todo.done = YES;
  return style;
}

static NSMutableAttributedString *Body(NSString *text) {
  ICTTFont *font = [ICTTFont new];
  font.fontName = @"FixtureFont";
  font.pointSize = 13.123456789;
  font.fontHints = 5;
  return [[NSMutableAttributedString alloc] initWithString:text attributes:@{
    @"TTStyle" : FixtureStyle(), @"TTHints" : @3, @"TTUnderline" : @YES, @"TTStrikethrough" : @YES,
    @"TTEmphasis" : @4, @"NSLink" : [NSURL URLWithString:@"https://example.test/?q=é"],
    @"TTColor" : [NSColor colorWithSRGBRed:0.123456789 green:0.25 blue:0.75 alpha:0.5],
    @"NSFont" : font, @"TTTimestamp" : [NSDate dateWithTimeIntervalSinceReferenceDate:1.123456789]
  }];
}

static NSDictionary *Snapshot(NSAttributedString *text) {
  NSString *reason = nil;
  NSDictionary *snapshot = ANMContentSnapshot(text, NSMakeRange(0, text.length), &reason);
  Assert(snapshot != nil, reason ?: @"Snapshot must be complete");
  return snapshot;
}

static void BodyFixtures(void) {
  NSString *reason = nil;
  NSDictionary *before = Snapshot(Body(@"Title\nChecklist 🙂\nHeading\nOld tail"));
  Assert(ANMContentMatches(before, Body(before[@"text"]), &reason), @"Separate equal objects compare without pointer identity");
  for (NSString *key in @[ @"TTHints", @"NSLink", @"TTEmphasis", @"TTUnderline", @"TTStrikethrough", @"NSFont", @"TTTimestamp" ]) {
    NSMutableAttributedString *lost = Body(before[@"text"]);
    [lost removeAttribute:key range:NSMakeRange(0, 1)];
    Assert(!ANMContentMatches(before, lost, &reason), [@"Must detect loss of " stringByAppendingString:key]);
  }
  for (NSString *field in @[ @"alignment", @"writingDirection", @"indent", @"blockQuoteLevel", @"startingItemNumber", @"style", @"hints" ]) {
    NSMutableAttributedString *changed = Body(before[@"text"]);
    ICTTParagraphStyle *style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
    [style setValue:@42 forKey:field];
    Assert(!ANMContentMatches(before, changed, &reason), [@"Must detect paragraph field " stringByAppendingString:field]);
  }
  NSMutableAttributedString *changed = Body(before[@"text"]);
  ICTTParagraphStyle *style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
  style.todo.uuid = NSUUID.UUID;
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect changed todo UUID");
  changed = Body(before[@"text"]);
  style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
  style.todo.done = NO;
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect changed todo checked state");
  changed = Body(before[@"text"]);
  style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
  style.uuid = NSUUID.UUID;
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect changed paragraph UUID");
  changed = Body(before[@"text"]);
  [changed addAttribute:@"TTColor" value:[NSColor colorWithSRGBRed:0.123456780 green:0.25 blue:0.75 alpha:0.5]
      range:NSMakeRange(0, 1)];
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect color changes below rounded hex precision");
  changed = Body(before[@"text"]);
  ICTTFont *font = [changed attribute:@"NSFont" atIndex:0 effectiveRange:NULL];
  font.pointSize += 0.00000001;
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect font changes below four-decimal precision");
  changed = Body(before[@"text"]);
  [changed addAttribute:@"TTTimestamp" value:[NSDate dateWithTimeIntervalSinceReferenceDate:1.123456780]
      range:NSMakeRange(0, 1)];
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect timestamps below six-decimal precision");
  changed = Body(before[@"text"]);
  [changed addAttribute:@"UnknownAttribute" value:@1 range:NSMakeRange(0, 1)];
  Assert(ANMContentSnapshot(changed, NSMakeRange(0, changed.length), &reason) == nil,
      @"Unknown attribute keys refuse before write");
  changed = Body(before[@"text"]);
  [changed addAttribute:@"TTStyle" value:[NSObject new] range:NSMakeRange(0, 1)];
  Assert(ANMContentSnapshot(changed, NSMakeRange(0, changed.length), &reason) == nil,
      @"Unknown attribute classes refuse before write");
  // Delimiter-bearing strings cannot collide with another key/value pair.
  NSAttributedString *one = [[NSAttributedString alloc] initWithString:@"x" attributes:@{ @"NSLink" : @"a\x1fTTEmphasis=n:4" }];
  NSAttributedString *two = [[NSAttributedString alloc] initWithString:@"x" attributes:@{ @"NSLink" : @"a", @"TTEmphasis" : @4 }];
  Assert(![Snapshot(one) isEqual:Snapshot(two)], @"Canonical dictionaries avoid delimiter collisions");
  // Deep snapshots must survive mutation of retained private attribute objects.
  NSMutableAttributedString *original = Body(@"x");
  NSDictionary *frozen = Snapshot(original);
  style = [original attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
  style.todo.done = NO;
  Assert(!ANMContentMatches(frozen, original, &reason), @"Snapshot freezes mutable attribute fields");
  ICTTAttachment *attachment = [ICTTAttachment new];
  attachment.attachmentIdentifier = @"unrelated-glyph";
  attachment.attachmentUTI = @"fixture.media";
  NSMutableAttributedString *glyph = [[NSMutableAttributedString alloc] initWithString:@"\uFFFC"
      attributes:@{ @"NSAttachment" : attachment }];
  frozen = Snapshot(glyph);
  attachment.attachmentIdentifier = @"changed-glyph";
  Assert(!ANMContentMatches(frozen, glyph, &reason), @"Unrelated body glyph identity must remain unchanged");
}

static void InsertionFixtures(void) {
  NSString *reason = nil;
  // These exact NSString offsets cover append, prepend below title, heading
  // insertion, append without a final newline, and title-only prepend.
  for (NSArray *fixture in @[ @[ @"Title\nOld 🙂\n", @13, @"New" ],
                              @[ @"Title\nOld 🙂", @6, @"New\n" ],
                              @[ @"Title\nOld 🙂\nHeading\nTail", @13, @"New\n" ],
                              @[ @"Title\nOld 🙂", @12, @"\nNew" ],
                              @[ @"Title 🙂", @8, @"\nNew" ] ]) {
    NSMutableAttributedString *body = Body(fixture[0]);
    NSDictionary *before = Snapshot(body);
    NSUInteger at = [fixture[1] unsignedIntegerValue];
    NSAttributedString *insertion = [[NSAttributedString alloc] initWithString:fixture[2]];
    [body insertAttributedString:insertion atIndex:at];
    Assert(ANMContentInsertionMatches(before, body, at, insertion.length, &reason),
        @"Valid placement including intended separator must preserve old runs");
    // Alter a pre-existing character after it shifted, never a new separator.
    NSUInteger oldUnit = at < [before[@"text"] length] ? at + insertion.length : 0;
    [body removeAttribute:@"NSLink" range:NSMakeRange(oldUnit, 1)];
    Assert(!ANMContentInsertionMatches(before, body, at, insertion.length, &reason),
        @"Must detect changed old attributes around every placement");
  }
  NSMutableAttributedString *body = Body(@"Title\n🙂 heading\nTail");
  NSDictionary *before = Snapshot(body);
  NSAttributedString *insertion = [[NSAttributedString alloc] initWithString:@"🌱\n"];
  [body insertAttributedString:insertion atIndex:6];
  Assert(ANMContentInsertionMatches(before, body, 6, 3, &reason), @"Emoji insertion length is three UTF-16 units");
  Assert(!ANMContentInsertionMatches(before, body, 6, 2, &reason), @"Code-point count cannot substitute for UTF-16 length");
  Assert(!ANMContentInsertionMatches(before, body, NSUIntegerMax, 3, &reason), @"Invalid map refuses");
}

static NSDictionary *Table(NSArray *ids, NSArray *cells) {
  NSMutableArray *rows = [NSMutableArray array];
  for (NSUInteger r = 0; r < ids.count; r++) {
    NSMutableArray *snapshots = [NSMutableArray array];
    for (NSAttributedString *cell in cells[r]) [snapshots addObject:Snapshot(cell)];
    [rows addObject:@{ @"identifier" : ids[r], @"cells" : snapshots }];
  }
  return @{ @"columnIdentifiers" : @[ @"c1", @"c2", @"c3" ], @"rows" : rows };
}

static void TableFixtures(void) {
  NSString *reason = nil;
  NSArray *ids = @[ @"r1", @"r2", @"r3" ];
  NSArray *cells = @[ @[ Body(@"a"), Body(@"b"), Body(@"c") ],
                      @[ Body(@"d"), Body(@"e"), Body(@"f") ],
                      @[ Body(@"g"), Body(@"h"), Body(@"i") ] ];
  NSDictionary *before = Table(ids, cells);
  NSDictionary *plain = @{ @"columnIdentifiers" : before[@"columnIdentifiers"], @"rows" : @[
      @{ @"identifier" : @"r1", @"cells" : @[ @"a", @"b", @"c" ] },
      @{ @"identifier" : @"r2", @"cells" : @[ @"d", @"e", @"f" ] },
      @{ @"identifier" : @"r3", @"cells" : @[ @"g", @"h", @"i" ] } ] };
  Assert(ANMTableContentMatches(before, Table(ids, cells), plain, nil, nil, &reason), @"Unchanged rich cells pass");
  NSMutableArray *replacementCells = [cells mutableCopy];
  replacementCells[1] = @[ cells[1][0], [[NSAttributedString alloc] initWithString:@"replacement"], cells[1][2] ];
  NSMutableDictionary *expected = [plain mutableCopy];
  NSMutableArray *expectedRows = [plain[@"rows"] mutableCopy];
  expectedRows[1] = @{ @"identifier" : @"r2", @"cells" : @[ @"d", @"replacement", @"f" ] };
  expected[@"rows"] = expectedRows;
  NSDictionary *actual = Table(ids, replacementCells);
  Assert(ANMTableContentMatches(before, actual, expected, @"r2", @"c2", &reason), @"Exact intended plain cell replacement passes");
  Assert(!ANMTableContentMatches(before, actual, expected, nil, nil, &reason), @"Plain replacement outside allowance refuses");
  NSMutableAttributedString *lost = [cells[2][2] mutableCopy];
  [lost removeAttribute:@"TTHints" range:NSMakeRange(0, lost.length)];
  replacementCells[2] = @[ cells[2][0], cells[2][1], lost ];
  Assert(!ANMTableContentMatches(before, Table(ids, replacementCells), expected, @"r2", @"c2", &reason),
      @"Unrelated surviving cell style loss refuses with identical text");
  NSDictionary *deletedExpected = @{ @"columnIdentifiers" : plain[@"columnIdentifiers"],
      @"rows" : @[ plain[@"rows"][0], plain[@"rows"][2] ] };
  Assert(ANMTableContentMatches(before, Table(@[ @"r1", @"r3" ], @[ cells[0], cells[2] ]), deletedExpected, nil, nil, &reason),
      @"Row deletion retains arbitrary stable survivor IDs and rich cells");
  Assert(!ANMTableContentMatches(before, Table(@[ @"r1", @"wrong" ], @[ cells[0], cells[2] ]), deletedExpected, nil, nil, &reason),
      @"Changed surviving row identity refuses");
  NSMutableDictionary *wrongColumns = [before mutableCopy];
  wrongColumns[@"columnIdentifiers"] = @[ @"c1", @"wrong", @"c3" ];
  Assert(!ANMTableContentMatches(before, wrongColumns, plain, nil, nil, &reason), @"Changed column identity refuses");
  NSMutableDictionary *remintedPlan = [plain mutableCopy];
  remintedPlan[@"columnIdentifiers"] = wrongColumns[@"columnIdentifiers"];
  Assert(!ANMTableContentMatches(before, wrongColumns, remintedPlan, nil, nil, &reason),
      @"Matching expected and persisted columns cannot remint original survivor identities");
  NSDictionary *insertExpected = @{ @"columnIdentifiers" : plain[@"columnIdentifiers"], @"rows" : @[
      plain[@"rows"][0], @{ @"identifier" : @"new", @"cells" : @[ @"1", @"2", @"3" ] }, plain[@"rows"][1], plain[@"rows"][2] ] };
  Assert(ANMTableContentMatches(before, Table(@[ @"r1", @"new", @"r2", @"r3" ],
      @[ cells[0], @[ Body(@"1"), Body(@"2"), Body(@"3") ], cells[1], cells[2] ]), insertExpected, nil, nil, &reason),
      @"Inserted row allowance preserves every old row and column");
  NSDictionary *empty = Table(@[ @"r1" ], @[ @[ Body(@"a"), Body(@""), Body(@"c") ] ]);
  Assert(!ANMTableExistingCellsVerifiable(empty, nil, nil, &reason), @"Empty surviving cell refuses latent-state uncertainty");
  Assert(ANMTableExistingCellsVerifiable(empty, @"r1", @"c2", &reason), @"Exact replaced empty cell is an intended delta");
  Assert(ANMTableExistingCellsVerifiable(empty, @"r1", nil, &reason), @"Empty cells in the deleted row are intended deltas");
  Assert(!ANMTableExistingCellsVerifiable(empty, @"r1", @"c1", &reason), @"A different selected cell cannot exempt the empty survivor");
  NSDictionary *duplicate = Table(@[ @"r1", @"R1" ], @[ cells[0], cells[1] ]);
  Assert(!ANMTableContentMatches(duplicate, before, plain, nil, nil, &reason), @"Duplicate original row identities refuse");
  Assert(!ANMTableContentMatches(before, duplicate, plain, nil, nil, &reason), @"Duplicate persisted row identities refuse");
  NSDictionary *duplicatePlan = @{ @"columnIdentifiers" : plain[@"columnIdentifiers"],
      @"rows" : @[ plain[@"rows"][0], plain[@"rows"][0] ] };
  Assert(!ANMTableContentMatches(before, before, duplicatePlan, nil, nil, &reason), @"Duplicate expected row identities refuse");
  wrongColumns[@"columnIdentifiers"] = @[ @"c1", @"c2", @"C1" ];
  Assert(!ANMTableContentMatches(wrongColumns, before, plain, nil, nil, &reason), @"Duplicate original column identities refuse");
  Assert(!ANMTableContentMatches(before, wrongColumns, plain, nil, nil, &reason), @"Duplicate persisted column identities refuse");
  duplicatePlan = @{ @"columnIdentifiers" : @[ @"c1", @"c2", @"C1" ], @"rows" : plain[@"rows"] };
  Assert(!ANMTableContentMatches(before, before, duplicatePlan, nil, nil, &reason), @"Duplicate expected column identities refuse");
}

static double IncompatibleStyleGetter(id object, SEL selector) {
  (void)object; (void)selector;
  return 103.0;
}

static void LayoutFixture(NSString *mode) {
  NSString *name = [mode isEqual:@"subclass"] ? @"FixtureUnknownParagraphStyle" : @"ICTTMutableParagraphStyle";
  Class fixtureClass = objc_allocateClassPair(ICTTParagraphStyle.class, name.UTF8String, 0);
  Assert(fixtureClass != Nil, @"Allocate fresh fabricated class");
  if ([mode isEqual:@"hidden-ivar"])
    Assert(class_addIvar(fixtureClass, "_hiddenStoredState", sizeof(long long), 3, "q"), @"Add hidden stored state");
  else if ([mode isEqual:@"extra-property"]) {
    objc_property_attribute_t attributes[] = { { "T", "q" }, { "R", "" } };
    Assert(class_addProperty(fixtureClass, "hiddenSemanticProperty", attributes, 2), @"Add extra property");
  } else if ([mode isEqual:@"getter-abi"])
    Assert(class_addMethod(fixtureClass, @selector(style), (IMP)IncompatibleStyleGetter, "d@:"), @"Override getter ABI");
  objc_registerClassPair(fixtureClass);
  id style = [[fixtureClass alloc] init];
  NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"old" attributes:@{ @"TTStyle" : style }];
  NSString *reason = nil;
  Assert(ANMContentSnapshot(text, NSMakeRange(0, text.length), &reason) == nil,
      @"Unpinned superclass field/property/subclass/ABI must refuse");
  Assert(reason.length > 0, @"Refusal explains unsupported evidence");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    @try {
      if (argc == 2) LayoutFixture(@(argv[1]));
      else {
        BodyFixtures();
        InsertionFixtures();
        TableFixtures();
      }
      printf("{\"checks\":%lu,\"fixture\":\"pure-attributed-text\"}\n", (unsigned long)checks);
      return 0;
    } @catch (NSException *error) {
      fprintf(stderr, "%s\n", error.reason.UTF8String);
      return 1;
    }
  }
}
