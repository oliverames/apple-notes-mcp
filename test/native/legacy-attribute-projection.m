// Pure public/synthetic objects only; no writer, store, NotesShared or dispatch.
#include "../../native/private-helper/legacy-attribute-projection.h"
#include <math.h>

@interface ICTTTodo : NSObject
@property(nonatomic, copy) NSUUID *uuid;
@property(nonatomic) BOOL done;
@end
@implementation ICTTTodo
@end
@interface ICTTParagraphStyle : NSObject
@property(nonatomic) unsigned int style, hints;
@property(nonatomic) long long alignment, writingDirection, indent, blockQuoteLevel, startingItemNumber;
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

static NSUInteger checks = 0, invalidGetterCalls = 0;
static void Check(BOOL value, NSString *message) {
  if (!value) @throw [NSException exceptionWithName:@"fixture_assertion" reason:message userInfo:nil];
  checks++;
}
static float WrongSize(id self, SEL cmd) { (void)self; (void)cmd; invalidGetterCalls++; return 13; }
static ICTTFont *Font(void) {
  ICTTFont *font = [ICTTFont new];
  font.fontName = @"Public fixture"; font.pointSize = 13.123456789; font.fontHints = 7;
  return font;
}
static ICTTParagraphStyle *FixtureParagraphStyle(void) {
  ICTTParagraphStyle *style = [ICTTParagraphStyle new];
  style.style = 103; style.hints = 3; style.indent = 2; style.startingItemNumber = 17;
  style.uuid = [[NSUUID alloc] initWithUUIDString:@"11111111-1111-1111-1111-111111111111"];
  style.todo = [ICTTTodo new];
  style.todo.uuid = [[NSUUID alloc] initWithUUIDString:@"22222222-2222-2222-2222-222222222222"];
  style.todo.done = YES;
  return style;
}
static NSArray *Runs(NSAttributedString *body, BOOL ignoreTimestamp) {
  return ANMLegacyCanonicalRuns(body, NSMakeRange(0, body.length), ignoreTimestamp, @"TTTimestamp");
}
int main(void) {
  @autoreleasepool {
    @try {
      ICTTFont *font = Font(); NSString *before = ANMLegacyCanonicalValue(font);
      Check(before != nil, @"Known getter projection remains supported");
      Check([before isEqual:ANMLegacyCanonicalValue(Font())], @"Separate equal fonts compare equally");
      font.pointSize = nextafter(font.pointSize, INFINITY);
      Check(![before isEqual:ANMLegacyCanonicalValue(font)], @"One-ULP font-size drift cannot round away");
      double t = 1.123456789;
      Check(![ANMLegacyCanonicalValue([NSDate dateWithTimeIntervalSinceReferenceDate:t])
          isEqual:ANMLegacyCanonicalValue([NSDate dateWithTimeIntervalSinceReferenceDate:nextafter(t, INFINITY)])],
          @"One-ULP timestamp drift cannot round away");
      Check(![ANMLegacyCanonicalValue(@(-0.0)) isEqual:ANMLegacyCanonicalValue(@(0.0))], @"Signed-zero bytes remain distinct");
      Check(![ANMLegacyCanonicalValue(@(nextafter(1.0, INFINITY))) isEqual:ANMLegacyCanonicalValue(@(1.0))], @"Numeric bytes remain exact");
      Check(ANMLegacyCanonicalValue([NSDecimalNumber decimalNumberWithString:@"1.123456789"]) == nil, @"Unknown decimal representation refuses");
      Check(![ANMLegacyCanonicalValue(@"nil") isEqual:ANMLegacyCanonicalValue(nil)], @"Nil and string cannot collide");
      NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:@"11111111-1111-1111-1111-111111111111"];
      Check(![ANMLegacyCanonicalValue(uuid) isEqual:ANMLegacyCanonicalValue(uuid.UUIDString)], @"UUID and string remain typed");
      Check(![ANMLegacyCanonicalValue([NSURL URLWithString:@"https://example.test/"])
          isEqual:ANMLegacyCanonicalValue(@"https://example.test/")], @"URL and string remain typed");
      NSDictionary *one = @{ @"A" : @"x\x1f" @"B=s:y" };
      NSDictionary *two = @{ @"A" : @"x", @"B" : @"y" };
      Check(![ANMLegacyCanonicalAttributes(one, NO, @"TTTimestamp")
          isEqual:ANMLegacyCanonicalAttributes(two, NO, @"TTTimestamp")], @"Attribute separators cannot create a second key");
      Check([ANMLegacyEncode(@{ @"A": @"x", @"B": @"y" }) isEqual:ANMLegacyEncode(@{ @"B": @"y", @"A": @"x" })], @"Dictionary order does not affect equality");
      NSMutableDictionary *unicodeOne = [NSMutableDictionary dictionary], *unicodeTwo = [NSMutableDictionary dictionary];
      unicodeOne[@"é"] = @"composed"; unicodeOne[@"e\u0301"] = @"decomposed";
      unicodeTwo[@"e\u0301"] = @"decomposed"; unicodeTwo[@"é"] = @"composed";
      Check([ANMLegacyEncode(unicodeOne) isEqual:ANMLegacyEncode(unicodeTwo)], @"Distinct canonically equivalent keys sort by literal UTF-16");
      Check(![ANMLegacyCanonicalValue(@"a\0b") isEqual:ANMLegacyCanonicalValue(@"a")], @"Embedded NUL is retained");
      NSColor *color = [NSColor colorWithSRGBRed:0.123456789 green:0.25 blue:0.75 alpha:0.5];
      Check(![ANMLegacyCanonicalValue(color) isEqual:ANMLegacyCanonicalValue(
          [NSColor colorWithSRGBRed:0.123456780 green:0.25 blue:0.75 alpha:0.5])], @"Sub-byte color drift is detected");
      Check(![ANMLegacyCanonicalValue(color) isEqual:ANMLegacyCanonicalValue(
          [NSColor colorWithSRGBRed:0.123456789 green:0.25 blue:0.75 alpha:0.50000001])], @"Exact alpha participates");
      Check(![ANMLegacyCanonicalValue(color) isEqual:ANMLegacyCanonicalValue(
          [NSColor colorWithDisplayP3Red:0.123456789 green:0.25 blue:0.75 alpha:0.5])], @"Color space participates");
      Check(ANMLegacyCanonicalValue([NSColor colorWithPatternImage:[[NSImage alloc] initWithSize:NSMakeSize(1, 1)]]) == nil,
          @"Pattern color refuses");
      ICTTAttachment *a = [ICTTAttachment new]; a.attachmentUTI = @"a|b"; a.attachmentIdentifier = @"c";
      ICTTAttachment *b = [ICTTAttachment new]; b.attachmentUTI = @"a"; b.attachmentIdentifier = @"b|c";
      Check(![ANMLegacyCanonicalValue(a) isEqual:ANMLegacyCanonicalValue(b)], @"Attachment delimiters cannot collide");
      ICTTParagraphStyle *style = FixtureParagraphStyle(); before = ANMLegacyCanonicalValue(style);
      Check([before isEqual:ANMLegacyCanonicalValue(FixtureParagraphStyle())], @"Separate checklist projections compare equally");
      style.todo.done = NO;
      Check(![before isEqual:ANMLegacyCanonicalValue(style)], @"Checked-state drift is detected");
      style = FixtureParagraphStyle(); style.todo.uuid = uuid;
      Check(![before isEqual:ANMLegacyCanonicalValue(style)], @"Todo identity drift is detected");
      style = FixtureParagraphStyle(); style.uuid = style.todo.uuid;
      Check(![before isEqual:ANMLegacyCanonicalValue(style)], @"Paragraph identity drift is detected");
      for (NSString *field in @[ @"style", @"hints", @"alignment", @"writingDirection", @"indent", @"blockQuoteLevel", @"startingItemNumber" ]) {
        style = FixtureParagraphStyle(); [style setValue:@42 forKey:field];
        Check(![before isEqual:ANMLegacyCanonicalValue(style)], [@"Exact paragraph getter participates: " stringByAppendingString:field]);
      }
      NSMutableString *mutable = [@"frozen" mutableCopy];
      before = ANMLegacyCanonicalValue(mutable); [mutable appendString:@" changed"];
      Check(![before isEqual:ANMLegacyCanonicalValue(mutable)], @"Projection freezes mutable string values");
      NSMutableAttributedString *body = [[NSMutableAttributedString alloc] initWithString:@"A🙂B" attributes:@{ @"NSFont": Font(), @"TTTimestamp": [NSDate dateWithTimeIntervalSinceReferenceDate:t] }];
      NSArray *runs = Runs(body, NO);
      [body addAttribute:@"NSFont" value:Font() range:NSMakeRange(1, 2)];
      Check([runs isEqual:Runs(body, NO)], @"Equivalent run splits merge over UTF-16 emoji units");
      [body addAttribute:@"TTTimestamp" value:[NSDate dateWithTimeIntervalSinceReferenceDate:nextafter(t, INFINITY)] range:NSMakeRange(1, 2)];
      Check(![runs isEqual:Runs(body, NO)], @"Untouched timestamp drift detected in split run");
      Check([Runs(body, YES) isEqual:Runs([[NSAttributedString alloc] initWithString:@"A🙂B" attributes:@{ @"NSFont": Font() }], YES)],
          @"Explicit replacement timestamp-ignore policy remains scoped");
      body = [[NSMutableAttributedString alloc] initWithString:@"A🙂B" attributes:@{ @"TTStyle": FixtureParagraphStyle() }];
      NSArray *frozenBody = Runs(body, NO);
      NSAttributedString *shallowCopy = [body copy];
      ICTTParagraphStyle *sharedStyle = [body attribute:@"TTStyle" atIndex:0 effectiveRange:NULL];
      sharedStyle.todo.done = NO;
      Check([Runs(body, NO) isEqual:Runs(shallowCopy, NO)], @"Fixture demonstrates native attribute sharing in shallow copies");
      Check(![ANMLegacySliceRuns(frozenBody, NSMakeRange(1, 2))
          isEqual:ANMLegacyCanonicalRuns(body, NSMakeRange(1, 2), NO, @"TTTimestamp")], @"Frozen old slice detects shared todo mutation");
      Check([ANMLegacySliceRuns(frozenBody, NSMakeRange(1, 2))
          isEqual:ANMLegacyCanonicalRuns([[NSAttributedString alloc] initWithString:@"🙂" attributes:@{ @"TTStyle": FixtureParagraphStyle() }], NSMakeRange(0, 2), NO, @"TTTimestamp")],
          @"Frozen slice normalizes relative UTF-16 offsets");
      Check([ANMLegacySliceRuns(frozenBody, NSMakeRange(4, 0)) count] == 0, @"Empty edited boundary remains empty");
      id unknown = [NSObject new];
      Check(ANMLegacyCanonicalValue(unknown) == nil, @"Unknown class refuses");
      NSDictionary *bad = @{ @"Unknown": unknown };
      Check(![ANMLegacyCanonicalAttributes(bad, NO, @"TTTimestamp") isEqual:ANMLegacyCanonicalAttributes(bad, NO, @"TTTimestamp")],
          @"Unverifiable values never compare equal");
      Class wrongABI = objc_allocateClassPair(ICTTFont.class, "FixtureWrongABIFont", 0);
      Check(wrongABI != Nil && class_addMethod(wrongABI, @selector(pointSize), (IMP)WrongSize, "f@:"), @"Install incompatible getter only on synthetic subclass");
      objc_registerClassPair(wrongABI);
      Check(ANMLegacyCanonicalValue([wrongABI new]) == nil, @"Wrong getter ABI refuses before casting");
      Check(invalidGetterCalls == 0, @"Invalid-ABI getter was never invoked");
      NSData *json = [NSJSONSerialization dataWithJSONObject:@{ @"fixture": @"pure-legacy-getter-projection", @"checks": @(checks), @"notesSharedLoaded": @NO, @"storesOpened": @0 } options:0 error:NULL];
      fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); return 0;
    } @catch (NSException *exception) {
      fprintf(stderr, "%s\n", exception.reason.UTF8String); return 1;
    }
  }
}
