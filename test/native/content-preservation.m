// Pure synthetic attributed text. No NotesShared, stores, writer, or dispatch.
#include "../../native/private-helper/content-preservation.h"

@interface ICTTTodo : NSObject { BOOL _done; NSUUID *_uuid; }
@property(nonatomic, readonly) NSUUID *uuid;
@property(nonatomic, readonly) BOOL done;
@end
@implementation ICTTTodo
@synthesize uuid = _uuid, done = _done;
@end

@interface ICTTParagraphStyle : NSObject<NSObject> {
  BOOL _needsParagraphCleanup, _needsListCleanup;
  unsigned int _style, _hints;
  NSInteger _alignment, _writingDirection;
  NSUInteger _indent, _blockQuoteLevel, _startingItemNumber;
  ICTTTodo *_todo;
  NSUUID *_uuid;
}
@property(nonatomic) NSInteger alignment, writingDirection;
@property(nonatomic) NSUInteger blockQuoteLevel, indent, startingItemNumber;
@property(nonatomic) unsigned int hints, style;
@property(nonatomic) BOOL needsListCleanup, needsParagraphCleanup;
@property(nonatomic, strong) ICTTTodo *todo;
@property(nonatomic, copy) NSUUID *uuid;
@property(nonatomic, readonly) BOOL canIndent, isBlockQuote, isChecklist, isHeader, isList, isRTL,
    preferSingleLine, supportsSectionLinks, uniqueToLine, wantsFollowingNewLine;
@property(nonatomic, readonly) NSUUID *todoTrackingUUID;
@end
@implementation ICTTParagraphStyle
@synthesize alignment = _alignment, writingDirection = _writingDirection, blockQuoteLevel = _blockQuoteLevel,
    indent = _indent, startingItemNumber = _startingItemNumber, hints = _hints, style = _style,
    needsListCleanup = _needsListCleanup, needsParagraphCleanup = _needsParagraphCleanup,
    todo = _todo, uuid = _uuid;
- (BOOL)canIndent { return NO; }
- (BOOL)isBlockQuote { return NO; }
- (BOOL)isChecklist { return NO; }
- (BOOL)isHeader { return NO; }
- (BOOL)isList { return NO; }
- (BOOL)isRTL { return NO; }
- (BOOL)preferSingleLine { return NO; }
- (BOOL)supportsSectionLinks { return NO; }
- (BOOL)uniqueToLine { return NO; }
- (BOOL)wantsFollowingNewLine { return NO; }
- (NSUUID *)todoTrackingUUID { return nil; }
@end

@interface ICTTMutableParagraphStyle : ICTTParagraphStyle
@property(nonatomic) NSInteger alignment, writingDirection;
@property(nonatomic) NSUInteger blockQuoteLevel, indent, startingItemNumber;
@property(nonatomic) unsigned int hints, style;
@property(nonatomic) BOOL needsListCleanup, needsParagraphCleanup;
@property(nonatomic, strong) ICTTTodo *todo;
@property(nonatomic, copy) NSUUID *uuid;
@end
@implementation ICTTMutableParagraphStyle
@dynamic alignment, writingDirection, blockQuoteLevel, indent, startingItemNumber, hints, style,
    needsListCleanup, needsParagraphCleanup, todo, uuid;
@end

@interface ICTTFont : NSObject {
  unsigned int _fontHints;
  NSString *_fontName;
  double _pointSize;
  id _nativeFont;
}
@property(nonatomic, readonly) unsigned int fontHints;
@property(nonatomic, readonly) NSString *fontName;
@property(nonatomic, readonly) double pointSize;
@property(nonatomic, strong) id nativeFont;
@end
@implementation ICTTFont
@synthesize fontHints = _fontHints, fontName = _fontName, pointSize = _pointSize, nativeFont = _nativeFont;
@end

@interface ICTTAttachment : NSObject<NSObject>
@property(nonatomic, copy) NSString *attachmentIdentifier, *attachmentUTI;
@end
@implementation ICTTAttachment
@end

static NSUInteger checks = 0;
static void Assert(BOOL condition, NSString *message) {
  if (!condition) @throw [NSException exceptionWithName:@"fixture_assertion" reason:message userInfo:nil];
  checks++;
}


static void BuildObservedClasses(void) {
  NSString *source = @(__FILE__);
  NSString *path = [[[source stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"fixtures/native-attribute-layouts-public.json"];
  NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:NULL];
  Assert([fixture[@"sourceSha256"] isEqual:@"a5abc6b1588edb5cc70da3371e3d6cc71eb56506a7483b469c082f4c8486eb53"], @"Independent public metadata fixture source");
  for (NSDictionary *metadata in fixture[@"classes"]) {
    Class cls = NSClassFromString(metadata[@"name"]);
    Assert(cls != Nil, @"Independent counterfeit class exists");
    Assert(class_getInstanceSize(cls) == [metadata[@"instanceSize"] unsignedIntegerValue], @"Observed fixture instance size");
    for (NSDictionary *field in metadata[@"ivars"]) {
      Ivar ivar = class_getInstanceVariable(cls, [field[@"name"] UTF8String]);
      Assert(ivar && ivar_getOffset(ivar) >= 0 && (NSUInteger)ivar_getOffset(ivar) == [field[@"offset"] unsignedIntegerValue] &&
          [@(ivar_getTypeEncoding(ivar)) isEqual:field[@"encoding"]], @"Observed fixture exact stored ABI and offset");
    }
    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    Assert(count == [metadata[@"properties"] count], @"Independent counterfeit full property surface");
    free(properties);
    for (NSDictionary *property in metadata[@"properties"]) {
      objc_property_t declared = class_getProperty(cls, [property[@"name"] UTF8String]);
      Assert(declared && [@(property_getAttributes(declared)) isEqual:property[@"attributes"]],
          [@"Independent counterfeit property: " stringByAppendingString:property[@"name"]]);
      Method method = class_getInstanceMethod(cls, NSSelectorFromString(property[@"getter"][@"selector"]));
      char *type = method_copyReturnType(method);
      Assert(method && [@(type) isEqual:property[@"getter"][@"returnType"]], @"Independent counterfeit getter ABI");
      free(type);
    }
  }
}

static ICTTParagraphStyle *FixtureStyle(void) {
  ICTTParagraphStyle *style = [NSClassFromString(@"ICTTParagraphStyle") new];
  [style setValue:@(103) forKey:@"style"];
  [style setValue:@(2) forKey:@"alignment"];
  [style setValue:@(-1) forKey:@"writingDirection"];
  [style setValue:@(3) forKey:@"indent"];
  [style setValue:@(2) forKey:@"blockQuoteLevel"];
  [style setValue:@(17) forKey:@"startingItemNumber"];
  [style setValue:@(3) forKey:@"hints"];
  [style setValue:([[NSUUID alloc] initWithUUIDString:@"11111111-1111-1111-1111-111111111111"]) forKey:@"uuid"];
  [style setValue:[ICTTTodo new] forKey:@"todo"];
  [style.todo setValue:[[NSUUID alloc] initWithUUIDString:@"22222222-2222-2222-2222-222222222222"] forKey:@"uuid"];
  [style.todo setValue:@YES forKey:@"done"];
  return style;
}

static NSMutableAttributedString *Body(NSString *text) {
  ICTTFont *font = [NSClassFromString(@"ICTTFont") new];
  [font setValue:@"FixtureFont" forKey:@"fontName"];
  [font setValue:@(13.123456789) forKey:@"pointSize"];
  [font setValue:@(5) forKey:@"fontHints"];
  return [[NSMutableAttributedString alloc] initWithString:text attributes:@{
    @"TTStyle" : FixtureStyle(), @"TTHints" : @3, @"TTUnderline" : @YES, @"TTStrikethrough" : @YES,
    @"TTEmphasis" : @4, @"NSLink" : [NSURL URLWithString:@"https://example.test/?q=é"],
    @"TTColor" : [NSColor colorWithSRGBRed:0.123456789 green:0.25 blue:0.75 alpha:0.5],
    @"ICTTFont" : font, @"TTTimestamp" : [NSDate dateWithTimeIntervalSinceReferenceDate:1.123456789]
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
  for (NSString *key in @[ @"TTHints", @"NSLink", @"TTEmphasis", @"TTUnderline", @"TTStrikethrough", @"ICTTFont", @"TTTimestamp" ]) {
    NSMutableAttributedString *lost = Body(before[@"text"]);
    [lost removeAttribute:key range:NSMakeRange(0, 1)];
    Assert(!ANMContentMatches(before, lost, &reason), [@"Must detect loss of " stringByAppendingString:key]);
  }
  for (NSString *field in @[ @"alignment", @"writingDirection", @"indent", @"blockQuoteLevel", @"startingItemNumber", @"style", @"hints", @"needsListCleanup", @"needsParagraphCleanup" ]) {
    NSMutableAttributedString *changed = Body(before[@"text"]);
    ICTTParagraphStyle *style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
    [style setValue:@42 forKey:field];
    Assert(!ANMContentMatches(before, changed, &reason), [@"Must detect paragraph field " stringByAppendingString:field]);
  }
  NSMutableAttributedString *changed = Body(before[@"text"]);
  ICTTParagraphStyle *style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
  [style.todo setValue:NSUUID.UUID forKey:@"uuid"];
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect changed todo UUID");
  changed = Body(before[@"text"]);
  style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
  [style.todo setValue:@NO forKey:@"done"];
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect changed todo checked state");
  changed = Body(before[@"text"]);
  style = [changed attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
  [style setValue:NSUUID.UUID forKey:@"uuid"];
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect changed paragraph UUID");
  changed = Body(before[@"text"]);
  [changed addAttribute:@"TTColor" value:[NSColor colorWithSRGBRed:0.123456780 green:0.25 blue:0.75 alpha:0.5]
      range:NSMakeRange(0, 1)];
  Assert(!ANMContentMatches(before, changed, &reason), @"Must detect color changes below rounded hex precision");
  changed = Body(before[@"text"]);
  ICTTFont *font = [changed attribute:@"ICTTFont" atIndex:0 effectiveRange:NULL];
  [font setValue:@(font.pointSize + 0.00000001) forKey:@"pointSize"];
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
  [style.todo setValue:@NO forKey:@"done"];
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



static void NativeFieldFixtures(void) {
  NSString *reason = nil;
  ICTTParagraphStyle *immutable = FixtureStyle();
  ICTTMutableParagraphStyle *mutable = [ICTTMutableParagraphStyle new];
  for (NSString *field in ANMContentLayout(immutable))
    [mutable setValue:[immutable valueForKey:field] forKey:field];
  Assert([ANMContentValue(immutable, &reason) isEqual:ANMContentValue(mutable, &reason)],
      @"Separate mutable and immutable layout contracts preserve equal complete stored semantics");
  [mutable setValue:@(NSUIntegerMax) forKey:@"indent"];
  id value = ANMContentValue(mutable, &reason);
  Assert(value != nil, @"Unsigned paragraph storage retains its high bit");
  NSArray *indent = value[1][@"indent"];
  Assert([indent[0] isEqual:@"stored-scalar"] && [indent[1] isEqual:@"Q"], @"Storage encoding stays unsigned despite NSNumber boxing");
  NSUInteger stored = 0;
  [(NSData *)indent[2] getBytes:&stored length:sizeof(stored)];
  Assert(stored == NSUIntegerMax, @"Unsigned storage retains every bit");
  Assert(ANMContentFields(mutable, @[ @"indent" ], &reason) == nil, @"Partial native stored field capture refuses");
  NSDictionary *layout = ANMObservedNativeLayout(@"ICTTParagraphStyle");
  NSMutableDictionary *changed = [layout mutableCopy];
  NSMutableDictionary *ivars = [layout[@"ivars"] mutableCopy];
  ivars[@"_indent"] = @{ @"encoding" : @"q", @"offset" : @40 };
  changed[@"ivars"] = ivars;
  Assert(!ANMContentObservedClassMatches(ICTTParagraphStyle.class, ICTTParagraphStyle.class, changed, &reason),
      @"Signed storage cannot satisfy the reviewed unsigned contract");
  ivars = [layout[@"ivars"] mutableCopy];
  [ivars removeObjectForKey:@"_needsListCleanup"];
  changed[@"ivars"] = ivars;
  Assert(!ANMContentObservedClassMatches(ICTTParagraphStyle.class, ICTTParagraphStyle.class, changed, &reason),
      @"Cleanup state cannot be dropped from a native layout contract");
  Assert(ANMContentFontFormatSupported(@(kCTFontFormatTrueType)) && ANMContentFontFormatSupported(@(kCTFontFormatOpenTypeTrueType)),
      @"Audited TrueType formats are explicit");
  for (id format in @[ @(kCTFontFormatUnrecognized), @(kCTFontFormatOpenTypePostScript), @(kCTFontFormatPostScript),
      @(kCTFontFormatBitmap), @999, @"3", NSNull.null ])
    Assert(!ANMContentFontFormatSupported(format), @"Unproven font resource formats refuse");
  Assert(!ANMContentFontPublicClass([NSObject new], NO), @"Unknown public font class cannot substitute for factory concrete class");
}

static void PublicFontFixtures(void) {
  NSString *reason = nil;
  NSFont *font = [NSFont fontWithName:@"Helvetica" size:13];
  Assert(font != nil, @"Public named test font exists");
  id original = ANMContentPublicFont(font, &reason);
  Assert(original != nil, reason ?: @"Complete public font representation");
  NSFont *same = [NSFont fontWithName:@"Helvetica" size:13];
  Assert([original isEqual:ANMContentPublicFont(same, &reason)], @"Named public font reconstruction freezes identically");
  NSFont *collisionBase = [NSFont fontWithDescriptor:font.fontDescriptor textTransform:font.textTransform];
  NSAffineTransform *shear = [NSAffineTransform transform];
  NSAffineTransformStruct matrix = font.textTransform.transformStruct;
  matrix.m21 += 0.123456789;
  shear.transformStruct = matrix;
  NSFont *transformed = [NSFont fontWithDescriptor:font.fontDescriptor textTransform:shear];
  Assert(transformed && [collisionBase.fontName isEqual:transformed.fontName] && collisionBase.pointSize == transformed.pointSize,
      @"Materialized transform collision keeps old name and size projection");
  id transformedSnapshot = ANMContentPublicFont(transformed, &reason);
  Assert(transformedSnapshot != nil, reason ?: @"Transformed public font round trip");
  Assert(![ANMContentPublicFont(collisionBase, &reason) isEqual:transformedSnapshot], @"Full public font witness detects materialized transform collision");
  ICTTFont *wrapper = [NSClassFromString(@"ICTTFont") new];
  [wrapper setValue:@"Helvetica" forKey:@"fontName"];
  [wrapper setValue:@13 forKey:@"pointSize"];
  [wrapper setValue:@5 forKey:@"fontHints"];
  wrapper.nativeFont = collisionBase;
  NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"x" attributes:@{ @"ICTTFont" : wrapper }];
  NSDictionary *frozen = Snapshot(text);
  wrapper.nativeFont = transformed;
  Assert(!ANMContentMatches(frozen, text, &reason), @"Nested nativeFont changes cannot disappear behind identical private font name/size/hints");
  wrapper.nativeFont = [NSObject new];
  Assert(ANMContentSnapshot(text, NSMakeRange(0, text.length), &reason) == nil, @"Unknown nested nativeFont refuses");
  // Independent pure nested-state fixtures cover numeric variation keys,
  // ordered duplicate feature/cascade values, cycles, unsupported values, and
  // mutation detachment even when platform font matching collapses a feature.
  NSMutableDictionary *descriptor = [@{ @"variation" : [@{ @1234 : @0.25 } mutableCopy],
      @"features" : [@[ @{ @"type" : @1, @"selector" : @0 }, @{ @"type" : @1, @"selector" : @1 } ] mutableCopy] } mutableCopy];
  NSUInteger budget = 0;
  id nested = ANMContentFontNested(descriptor, [NSMutableSet set], 0, &budget, &reason);
  Assert(nested != nil, @"Numeric axis keys and ordered feature settings remain representable");
  descriptor[@"variation"][@1234] = @0.250000001;
  budget = 0;
  Assert(![nested isEqual:ANMContentFontNested(descriptor, [NSMutableSet set], 0, &budget, &reason)], @"Frozen nested descriptor detaches mutable numeric axis settings");
  descriptor[@"variation"][@1234] = @0.25;
  descriptor[@"features"] = [[descriptor[@"features"] reverseObjectEnumerator] allObjects];
  budget = 0;
  Assert(![nested isEqual:ANMContentFontNested(descriptor, [NSMutableSet set], 0, &budget, &reason)], @"Feature setting order cannot collide");
  budget = 0;
  Assert(ANMContentFontNested(@{ @"unknown" : [NSObject new] }, [NSMutableSet set], 0, &budget, &reason) == nil, @"Unsupported nested descriptor objects refuse");
  budget = 0;
  Assert(ANMContentFontNested(@(NAN), [NSMutableSet set], 0, &budget, &reason) == nil, @"Nonfinite font numbers refuse");
  NSMutableArray *cycle = [NSMutableArray array];
  id cyclicItem = cycle;
  [cycle addObject:cyclicItem];
  budget = 0;
  Assert(ANMContentFontNested(cycle, [NSMutableSet set], 0, &budget, &reason) == nil, @"Cyclic descriptor state refuses");
  [cycle removeAllObjects];
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
  NSString *name = @"FixtureUnknownParagraphStyle";
  Class fixtureClass = [mode isEqual:@"subclass"] || [mode isEqual:@"hidden-ivar"] ?
      objc_allocateClassPair(NSClassFromString(@"ICTTMutableParagraphStyle"), name.UTF8String, 0) : NSClassFromString(@"ICTTMutableParagraphStyle");
  Assert(fixtureClass != Nil, @"Fabricated known mutable or unknown subclass");
  if ([mode isEqual:@"hidden-ivar"])
    Assert(class_addIvar(fixtureClass, "_hiddenStoredState", sizeof(long long), 3, "q"), @"Add hidden stored state");
  else if ([mode isEqual:@"extra-property"]) {
    objc_property_attribute_t attributes[] = { { "T", "q" }, { "R", "" } };
    Assert(class_addProperty(fixtureClass, "hiddenSemanticProperty", attributes, 2), @"Add extra property");
  } else if ([mode isEqual:@"getter-abi"])
    Assert(class_addMethod(fixtureClass, @selector(style), (IMP)IncompatibleStyleGetter, "d@:"), @"Override getter ABI");
  if ([mode isEqual:@"subclass"] || [mode isEqual:@"hidden-ivar"]) objc_registerClassPair(fixtureClass);
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
      BuildObservedClasses();
      if (argc == 2) LayoutFixture(@(argv[1]));
      else {
        BodyFixtures();
        NativeFieldFixtures();
        PublicFontFixtures();
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
