// Public AppKit/CoreText font semantics. Never inspect private font ivars or
// use descriptions/archives. A normalized descriptor is documented to recreate
// its font; the additional explicit getters and complete selected-face tables
// detect best-match substitution and name/resource collisions for supported
// TrueType SFNT faces. Other font resource formats remain unsupported.
// Unsupported
// values, arbitrary subclasses, missing tables, and failed round trips refuse.
#ifndef ANM_PUBLIC_FONT_PRESERVATION_H
#define ANM_PUBLIC_FONT_PRESERVATION_H
#import <CoreText/CoreText.h>
#include <math.h>

static id ANMContentFontNested(id value, NSMutableSet *active, NSUInteger depth, NSUInteger *budget, NSString **reason);
static BOOL ANMContentFontPublicClass(id value, BOOL descriptor) {
  // Match a documented public factory's concrete class, rather than accepting
  // arbitrary NSFont/descriptor subclasses or assuming private class names.
  CFTypeRef reference = descriptor
      ? (CFTypeRef)CTFontDescriptorCreateWithNameAndSize(CFSTR("Helvetica"), 13)
      : (CFTypeRef)CTFontCreateWithName(CFSTR("Helvetica"), 13, NULL);
  if (!reference) return NO;
  BOOL matches = object_getClass(value) == object_getClass((__bridge id)reference);
  CFRelease(reference);
  return matches;
}
static BOOL ANMContentFontFormatSupported(id format) {
  if (![format isKindOfClass:NSNumber.class]) return NO;
  return [format isEqual:@(kCTFontFormatTrueType)] || [format isEqual:@(kCTFontFormatOpenTypeTrueType)];
}
static id ANMContentFontFloat(CGFloat value, NSString **reason) {
  if (!isfinite(value)) return ANMContentUnsupported(reason, @"Nonfinite public font scalar");
  return ANMContentNumber(@(value), reason);
}
static id ANMContentFontTransform(NSAffineTransformStruct transform, NSString **reason) {
  CGFloat values[] = { transform.m11, transform.m12, transform.m21, transform.m22, transform.tX, transform.tY };
  NSMutableArray *result = [NSMutableArray array];
  for (NSUInteger i = 0; i < 6; i++) {
    id number = ANMContentFontFloat(values[i], reason);
    if (!number) return nil;
    [result addObject:number];
  }
  return @[ @"affine-transform", [result copy] ];
}
static id ANMContentFontNested(id value, NSMutableSet *active, NSUInteger depth, NSUInteger *budget, NSString **reason) {
  if (!value) return @[ @"null" ];
  if (depth > 32 || ++*budget > 16384) return ANMContentUnsupported(reason, @"Public font descriptor budget exceeded");
  if ([value isKindOfClass:NSNumber.class]) {
    if (!isfinite([value doubleValue])) return ANMContentUnsupported(reason, @"Nonfinite public font descriptor number");
    return ANMContentNumber(value, reason);
  }
  if ([value isKindOfClass:NSString.class]) return @[ @"string", [value copy] ];
  if ([value isKindOfClass:NSData.class]) return @[ @"data", [value copy] ];
  if ([value isKindOfClass:NSURL.class]) return @[ @"url", [[value absoluteString] copy] ];
  if ([value isKindOfClass:NSCharacterSet.class]) return @[ @"character-set", [[value bitmapRepresentation] copy] ];
  if ([value isKindOfClass:NSAffineTransform.class]) return ANMContentFontTransform([value transformStruct], reason);
  NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)value];
  if ([active containsObject:identity]) return ANMContentUnsupported(reason, @"Cyclic public font descriptor");
  [active addObject:identity];
  id result = nil;
  if ([value isKindOfClass:NSFontDescriptor.class]) {
    if (!ANMContentFontPublicClass(value, YES) || CFGetTypeID((__bridge CFTypeRef)value) != CTFontDescriptorGetTypeID())
      result = ANMContentUnsupported(reason, @"Unsupported font descriptor subclass");
    else {
      id fields = ANMContentFontNested([value fontAttributes], active, depth + 1, budget, reason);
      if (fields) result = @[ @"font-descriptor", fields ];
    }
  } else if ([value isKindOfClass:NSArray.class]) {
    NSMutableArray *items = [NSMutableArray array];
    for (id item in value) {
      id frozen = ANMContentFontNested(item, active, depth + 1, budget, reason);
      if (!frozen) { [active removeObject:identity]; return nil; }
      [items addObject:frozen];
    }
    result = @[ @"array", [items copy] ]; // Feature/cascade order and duplicates matter.
  } else if ([value isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    for (id key in value) {
      if (![key isKindOfClass:NSString.class] && ![key isKindOfClass:NSNumber.class]) {
        [active removeObject:identity]; return ANMContentUnsupported(reason, @"Unsupported public font dictionary key");
      }
      id frozenKey = ANMContentFontNested(key, active, depth + 1, budget, reason);
      id frozenValue = ANMContentFontNested(value[key], active, depth + 1, budget, reason);
      if (!frozenKey || !frozenValue) { [active removeObject:identity]; return nil; }
      // Typed immutable array keys preserve NSNumber axis-key types, without
      // reducing numeric keys to decimal strings or sorting ordered arrays.
      items[frozenKey] = frozenValue;
    }
    result = @[ @"dictionary", [items copy] ];
  } else result = ANMContentUnsupported(reason, @"Unsupported public font descriptor value");
  [active removeObject:identity];
  return result;
}
static id ANMContentPublicFontUnchecked(NSFont *font, NSString **reason) {
  if (!ANMContentFontPublicClass(font, NO) || CFGetTypeID((__bridge CFTypeRef)font) != CTFontGetTypeID())
    return ANMContentUnsupported(reason, @"Unsupported public font subclass");
  CTFontRef ctFont = (__bridge CTFontRef)font;
  id format = CFBridgingRelease(CTFontCopyAttribute(ctFont, kCTFontFormatAttribute));
  if (!ANMContentFontFormatSupported(format))
    return ANMContentUnsupported(reason, @"Unsupported public font resource format");
  CTFontDescriptorRef normalized = CTFontCopyFontDescriptor(ctFont);
  if (!normalized) return ANMContentUnsupported(reason, @"Unavailable normalized public font descriptor");
  id normalizedAttributes = CFBridgingRelease(CTFontDescriptorCopyAttributes(normalized));
  CFRelease(normalized);
  NSMutableSet *active = [NSMutableSet set];
  NSUInteger budget = 0;
  id descriptor = ANMContentFontNested(font.fontDescriptor.fontAttributes, active, 0, &budget, reason);
  id normalizedFields = ANMContentFontNested(normalizedAttributes, active, 0, &budget, reason);
  id variation = ANMContentFontNested(CFBridgingRelease(CTFontCopyVariation(ctFont)), active, 0, &budget, reason);
  id features = ANMContentFontNested(CFBridgingRelease(CTFontCopyFeatureSettings(ctFont)), active, 0, &budget, reason);
  id size = ANMContentFontFloat(font.pointSize, reason);
  id transform = ANMContentFontTransform(font.textTransform.transformStruct, reason);
  const CGFloat *matrixValues = font.matrix;
  if (!descriptor || !normalizedFields || !variation || !features || !size || !transform || !matrixValues) return nil;
  NSMutableArray *matrix = [NSMutableArray array];
  for (NSUInteger i = 0; i < 6; i++) {
    id component = ANMContentFontFloat(matrixValues[i], reason);
    if (!component) return nil;
    [matrix addObject:component];
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSFontRenderingMode mode = font.renderingMode;
#pragma clang diagnostic pop
  if (mode == NSFontDefaultRenderingMode || mode > NSFontAntialiasedIntegerAdvancementsRenderingMode)
    return ANMContentUnsupported(reason, @"Unresolved public font rendering mode");
  CFArrayRef tags = CTFontCopyAvailableTables(ctFont, kCTFontTableOptionNoOptions);
  if (!tags || CFArrayGetCount(tags) == 0 || CFArrayGetCount(tags) > 4096) {
    if (tags) CFRelease(tags);
    return ANMContentUnsupported(reason, @"Unavailable complete public font table witness");
  }
  NSMutableDictionary *tables = [NSMutableDictionary dictionary];
  NSUInteger totalBytes = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(tags); i++) {
    uintptr_t rawTag = (uintptr_t)CFArrayGetValueAtIndex(tags, i); // Tags are unboxed, per SDK contract.
    if (rawTag > UINT32_MAX || tables[@(rawTag)]) { CFRelease(tags); return ANMContentUnsupported(reason, @"Unsupported public font table tag"); }
    NSData *data = CFBridgingRelease(CTFontCopyTable(ctFont, (CTFontTableTag)rawTag, kCTFontTableOptionNoOptions));
    if (!data || data.length > 64 * 1024 * 1024 - totalBytes) {
      CFRelease(tags); return ANMContentUnsupported(reason, @"Unavailable or oversized public font table witness");
    }
    totalBytes += data.length;
    tables[@(rawTag)] = [data copy];
  }
  CFRelease(tags);
  for (NSNumber *required in @[ @(kCTFontTableHead), @(kCTFontTableHhea), @(kCTFontTableMaxp),
      @(kCTFontTableHmtx), @(kCTFontTableCmap), @(kCTFontTableName), @(kCTFontTableGlyf), @(kCTFontTableLoca),
      @(kCTFontTablePost) ])
    if (![tables[required] length]) return ANMContentUnsupported(reason, @"Incomplete TrueType face table witness");
  if ([format isEqual:@(kCTFontFormatOpenTypeTrueType)] && ![tables[@(kCTFontTableOS2)] length])
    return ANMContentUnsupported(reason, @"Incomplete OpenType TrueType face table witness");
  return @[ @"public-font-v1", @{ @"descriptor" : descriptor, @"normalizedDescriptor" : normalizedFields,
      @"fontName" : [font.fontName copy], @"pointSize" : size, @"matrix" : [matrix copy],
      @"textTransform" : transform, @"vertical" : @(font.isVertical), @"renderingMode" : @(mode),
      @"variation" : variation, @"features" : features, @"resourceFormat" : ANMContentNumber(format, reason),
      @"selectedFaceTables" : [tables copy] } ];
}
static id ANMContentPublicFont(NSFont *font, NSString **reason) {
  id frozen = ANMContentPublicFontUnchecked(font, reason);
  if (!frozen) return nil;
  // The documented size and transform factories have different precedence.
  // Try both; acceptance always requires the *entire* witness to match. No
  // field is excluded to accommodate the factory's best-match substitution.
  NSFont *sizeCandidate = [NSFont fontWithDescriptor:font.fontDescriptor size:font.pointSize];
  NSFont *transformCandidate = [NSFont fontWithDescriptor:font.fontDescriptor textTransform:font.textTransform];
  for (NSFont *candidate in @[ sizeCandidate ?: (id)NSNull.null, transformCandidate ?: (id)NSNull.null ]) {
    if ((id)candidate == NSNull.null) continue;
    NSFont *rebuilt = font.isVertical ? candidate.verticalFont : candidate;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (rebuilt.renderingMode != font.renderingMode) rebuilt = [rebuilt screenFontWithRenderingMode:font.renderingMode];
#pragma clang diagnostic pop
    id roundTrip = rebuilt ? ANMContentPublicFontUnchecked(rebuilt, reason) : nil;
    if (roundTrip && [frozen isEqual:roundTrip]) return frozen;
  }
  return ANMContentUnsupported(reason, @"Public font reconstruction changed the complete supported representation");
}
#endif
