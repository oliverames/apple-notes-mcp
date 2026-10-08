// Pure attributed-text preservation. No NotesShared loading, store access,
// action dispatch, or writes. Snapshots contain only immutable Foundation
// values; unsupported keys/classes/accessor types refuse before mutation.
#ifndef ANM_CONTENT_PRESERVATION_H
#define ANM_CONTENT_PRESERVATION_H
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>
#include "native-attribute-layouts.h"

static NSString *const ANMContentEvidencePolicy = @"supported-attributes-v2:observed-native-storage:exact-scalars:no-unknowns";

static id ANMContentValue(id value, NSString **reason);

static id ANMContentUnsupported(NSString **reason, NSString *detail) {
  if (reason) *reason = detail;
  return nil;
}

// Capture scalar bytes without decimal rounding, pointer descriptions, or
// delimiter-based encodings. Type tags also keep nil/string/UUID distinct.
static id ANMContentNumber(NSNumber *value, NSString **reason) {
  if ([value isKindOfClass:NSDecimalNumber.class])
    return ANMContentUnsupported(reason, @"Unsupported decimal numeric representation");
  const char *type = value.objCType;
  if (!type || strlen(type) != 1 || !strchr("cCsSiIlLqQfdB", type[0]))
    return ANMContentUnsupported(reason, @"Unsupported numeric representation");
  NSUInteger size = 0;
  NSGetSizeAndAlignment(type, &size, NULL);
  unsigned char bytes[16] = {0};
  if (!size || size > sizeof(bytes)) return ANMContentUnsupported(reason, @"Unsupported numeric size");
  [value getValue:bytes size:size];
  return @[ @"number", [NSString stringWithUTF8String:type], [NSData dataWithBytes:bytes length:size] ];
}

#include "public-font-preservation.h"

// The reviewed native layouts pin immutable and mutable classes separately.
// Every inherited stored field is captured; derived getters are ABI-pinned but
// never used as a substitute for opaque stored state.
static NSDictionary *ANMContentLayout(id value) {
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  for (Class cls = object_getClass(value); cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
    NSDictionary *observed = ANMObservedNativeLayout(NSStringFromClass(cls));
    if (!observed) return nil;
    for (NSString *ivar in observed[@"ivars"])
      fields[[ivar substringFromIndex:1]] = observed[@"ivars"][ivar][@"encoding"];
  }
  return fields.count ? [fields copy] : nil;
}

static BOOL ANMContentObservedClassMatches(Class cls, Class valueClass, NSDictionary *layout, NSString **reason) {
  if (![NSStringFromClass(class_getSuperclass(cls)) isEqual:layout[@"superclass"]] ||
      class_getInstanceSize(cls) != [layout[@"instanceSize"] unsignedIntegerValue]) {
    ANMContentUnsupported(reason, @"Unpinned native attribute superclass or instance size"); return NO;
  }
  unsigned int count = 0;
  Ivar *ivars = class_copyIvarList(cls, &count);
  NSMutableDictionary *stored = [NSMutableDictionary dictionary];
  for (unsigned int i = 0; i < count; i++) {
    const char *name = ivar_getName(ivars[i]), *type = ivar_getTypeEncoding(ivars[i]);
    if (!name || !type) { free(ivars); return NO; }
    stored[@(name)] = @{ @"encoding" : @(type), @"offset" : @(ivar_getOffset(ivars[i])) };
  }
  free(ivars);
  if (![stored isEqual:layout[@"ivars"]]) {
    ANMContentUnsupported(reason, @"Extra, missing, or incompatible native stored field"); return NO;
  }
  objc_property_t *properties = class_copyPropertyList(cls, &count);
  NSMutableDictionary *declared = [NSMutableDictionary dictionary];
  BOOL valid = YES;
  for (unsigned int i = 0; i < count; i++) {
    NSString *name = @(property_getName(properties[i]));
    if (declared[name]) { valid = NO; break; }
    char *customGetter = property_copyAttributeValue(properties[i], "G");
    NSString *selector = @(customGetter ?: property_getName(properties[i]));
    free(customGetter);
    Method method = class_getInstanceMethod(valueClass, NSSelectorFromString(selector));
    if (!method || method_getNumberOfArguments(method) != 2) { valid = NO; break; }
    char *result = method_copyReturnType(method), *selfType = method_copyArgumentType(method, 0),
        *selectorType = method_copyArgumentType(method, 1);
    valid = result && selfType && selectorType && strcmp(selfType, "@") == 0 && strcmp(selectorType, ":") == 0;
    if (valid) declared[name] = @{ @"attributes" : @(property_getAttributes(properties[i])),
        @"returnType" : @(result), @"selector" : selector };
    free(result); free(selfType); free(selectorType);
    if (!valid) break;
  }
  free(properties);
  if (!valid || ![declared isEqual:layout[@"properties"]]) {
    ANMContentUnsupported(reason, @"Extra, missing, or incompatible native property or getter ABI"); return NO;
  }
  return YES;
}

static BOOL ANMContentLayoutMatches(id value, NSString **reason) {
  Class valueClass = object_getClass(value);
  for (Class cls = valueClass; cls != NSObject.class; cls = class_getSuperclass(cls)) {
    NSDictionary *observed = cls ? ANMObservedNativeLayout(NSStringFromClass(cls)) : nil;
    if (!observed) { ANMContentUnsupported(reason, @"Unpinned native attribute class or superclass"); return NO; }
    if (!ANMContentObservedClassMatches(cls, valueClass, observed, reason)) return NO;
  }
  return YES;
}

static id ANMContentStoredField(id value, NSString *name, NSString **reason) {
  Ivar ivar = class_getInstanceVariable(object_getClass(value), [[@"_" stringByAppendingString:name] UTF8String]);
  if (!ivar) return ANMContentUnsupported(reason, @"Missing pinned native attribute field");
  const char *type = ivar_getTypeEncoding(ivar);
  if (!type) return ANMContentUnsupported(reason, @"Missing pinned native attribute storage ABI");
  if (type[0] == '@') return object_getIvar(value, ivar) ?: NSNull.null;
  const unsigned char *bytes = (const unsigned char *)(__bridge const void *)value + ivar_getOffset(ivar);
#define ANM_CONTENT_STORED(encoding, scalarType) \
  if (strcmp(type, @encode(encoding)) == 0) { scalarType result = 0; \
    memcpy(&result, bytes, sizeof(result)); return @(result); }
  ANM_CONTENT_STORED(unsigned int, unsigned int)
  ANM_CONTENT_STORED(long long, long long)
  ANM_CONTENT_STORED(unsigned long long, unsigned long long)
  ANM_CONTENT_STORED(BOOL, BOOL)
  ANM_CONTENT_STORED(double, double)
#undef ANM_CONTENT_STORED
  return ANMContentUnsupported(reason, @"Unsupported pinned native attribute storage ABI");
}

static id ANMContentFields(id value, NSArray<NSString *> *names, NSString **reason) {
  if (!ANMContentLayoutMatches(value, reason)) return nil;
  if (![[NSSet setWithArray:names] isEqual:[NSSet setWithArray:ANMContentLayout(value).allKeys]])
    return ANMContentUnsupported(reason, @"Incomplete native stored-field representation");
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  for (NSString *name in names) {
    // Read every pinned stored field itself; a getter projection cannot hide
    // state in a supported field. Getter ABI is independently checked above.
    id field = ANMContentStoredField(value, name, reason);
    if (!field) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(value), [[@"_" stringByAppendingString:name] UTF8String]);
    const char *type = ivar_getTypeEncoding(ivar);
    id canonical = nil;
    if (type[0] == '@') canonical = ANMContentValue(field, reason);
    else {
      NSUInteger size = 0;
      NSGetSizeAndAlignment(type, &size, NULL);
      if (!size || size > 16) return ANMContentUnsupported(reason, @"Unsupported native storage size");
      const unsigned char *bytes = (const unsigned char *)(__bridge const void *)value + ivar_getOffset(ivar);
      canonical = @[ @"stored-scalar", @(type), [NSData dataWithBytes:bytes length:size] ];
    }
    if (!canonical) return nil;
    fields[name] = canonical;
  }
  return [fields copy];
}

static BOOL ANMContentNamedClass(id value, NSArray<NSString *> *names) {
  return [names containsObject:NSStringFromClass(object_getClass(value))];
}

static id ANMContentValue(id value, NSString **reason) {
  if (!value || value == NSNull.null) return @[ @"null" ];
  if ([value isKindOfClass:NSNumber.class]) return ANMContentNumber(value, reason);
  if ([value isKindOfClass:NSString.class]) return @[ @"string", [value copy] ];
  if ([value isKindOfClass:NSData.class]) return @[ @"data", [value copy] ];
  if ([value isKindOfClass:NSUUID.class]) return @[ @"uuid", [value UUIDString] ];
  if ([value isKindOfClass:NSURL.class]) return @[ @"url", [[value absoluteString] copy] ];
  if ([value isKindOfClass:NSDate.class])
    return @[ @"date", ANMContentNumber(@([value timeIntervalSinceReferenceDate]), reason) ];
  if (ANMContentNamedClass(value, @[ @"ICTTParagraphStyle", @"ICTTMutableParagraphStyle" ])) {
    if (!ANMContentLayoutMatches(value, reason)) return nil;
    id uuid = ANMContentStoredField(value, @"uuid", reason);
    id todo = ANMContentStoredField(value, @"todo", reason);
    if (!uuid || !todo) return nil;
    if (uuid != NSNull.null && ![uuid isKindOfClass:NSUUID.class])
      return ANMContentUnsupported(reason, @"A paragraph identity is not a UUID");
    if (todo != NSNull.null && !ANMContentNamedClass(todo, @[ @"ICTTTodo" ]))
      return ANMContentUnsupported(reason, @"Unsupported checklist value class");
    id fields = ANMContentFields(value, @[ @"style", @"alignment", @"writingDirection", @"indent",
        @"blockQuoteLevel", @"startingItemNumber", @"hints", @"uuid", @"todo",
        @"needsListCleanup", @"needsParagraphCleanup" ], reason);
    return fields ? @[ @"paragraph", fields ] : nil;
  }
  if (ANMContentNamedClass(value, @[ @"ICTTTodo" ])) {
    if (!ANMContentLayoutMatches(value, reason)) return nil;
    id uuid = ANMContentStoredField(value, @"uuid", reason);
    id done = ANMContentStoredField(value, @"done", reason);
    if (![uuid isKindOfClass:NSUUID.class] || ![done isKindOfClass:NSNumber.class])
      return ANMContentUnsupported(reason, @"Incomplete checklist identity or state");
    id fields = ANMContentFields(value, @[ @"uuid", @"done" ], reason);
    return fields ? @[ @"todo", fields ] : nil;
  }
  if (ANMContentNamedClass(value, @[ @"ICTTAttachment" ])) {
    if (!ANMContentLayoutMatches(value, reason)) return nil;
    id identifier = ANMContentStoredField(value, @"attachmentIdentifier", reason);
    id uti = ANMContentStoredField(value, @"attachmentUTI", reason);
    if (![identifier isKindOfClass:NSString.class] || ![identifier length] || ![uti isKindOfClass:NSString.class])
      return ANMContentUnsupported(reason, @"Incomplete attachment glyph identity or type");
    return @[ @"attachment", [identifier copy], [uti copy] ];
  }
  if (ANMContentNamedClass(value, @[ @"ICTTFont" ])) {
    if (!ANMContentLayoutMatches(value, reason)) return nil;
    id name = ANMContentStoredField(value, @"fontName", reason);
    id nativeFont = ANMContentStoredField(value, @"nativeFont", reason);
    if (name != NSNull.null && ![name isKindOfClass:NSString.class])
      return ANMContentUnsupported(reason, @"Unsupported native font name representation");
    if (nativeFont != NSNull.null && ![nativeFont isKindOfClass:NSFont.class])
      return ANMContentUnsupported(reason, @"Unsupported nested native font class");
    id fields = ANMContentFields(value, @[ @"fontName", @"pointSize", @"fontHints", @"nativeFont" ], reason);
    return fields ? @[ @"font", fields ] : nil;
  }
  if ([value isKindOfClass:NSFont.class]) return ANMContentPublicFont(value, reason);
  // Exact component values and color-space property list retain alpha and
  // sub-byte color differences. Pattern/dynamic colors are unsupported.
  CGColorRef color = NULL;
  if ([value isKindOfClass:NSColor.class]) {
    NSColor *nativeColor = value;
    if (nativeColor.type != NSColorTypeComponentBased)
      return ANMContentUnsupported(reason, @"Unsupported non-component color");
    color = nativeColor.CGColor;
  } else if (ANMContentNamedClass(value, @[ @"CGColor", @"__NSCFType" ]) &&
             CFGetTypeID((__bridge CFTypeRef)value) == CGColorGetTypeID()) {
    color = (__bridge CGColorRef)value;
  }
  if (color) {
    CGColorSpaceRef space = CGColorGetColorSpace(color);
    if (!space || CGColorSpaceGetModel(space) == kCGColorSpaceModelPattern)
      return ANMContentUnsupported(reason, @"Unsupported color space");
    id properties = CFBridgingRelease(CGColorSpaceCopyPropertyList(space));
    if (!properties) return ANMContentUnsupported(reason, @"Unavailable color-space representation");
    // Round-trip to immutable property-list values, compared structurally so
    // dictionary enumeration order cannot change equality.
    NSData *spaceBytes = [NSPropertyListSerialization dataWithPropertyList:properties
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!spaceBytes) return ANMContentUnsupported(reason, @"Unsupported color-space representation");
    NSMutableArray *components = [NSMutableArray array];
    const CGFloat *values = CGColorGetComponents(color);
    for (size_t i = 0; i < CGColorGetNumberOfComponents(color); i++)
      [components addObject:ANMContentNumber(@(values[i]), reason)];
    id immutableSpace = [NSPropertyListSerialization propertyListWithData:spaceBytes
        options:NSPropertyListImmutable format:NULL error:NULL];
    if (!immutableSpace) return ANMContentUnsupported(reason, @"Unavailable immutable color space");
    return @[ @"color", immutableSpace, [components copy] ];
  }
  return ANMContentUnsupported(reason, [@"Unsupported attribute class: " stringByAppendingString:NSStringFromClass([value class])]);
}

static NSDictionary *ANMContentSnapshot(NSAttributedString *text, NSRange range, NSString **reason) {
  if (![text isKindOfClass:NSAttributedString.class] || range.location > text.length ||
      range.length > text.length - range.location)
    return ANMContentUnsupported(reason, @"Invalid attributed-text preservation range");
  NSSet *keys = [NSSet setWithArray:@[ @"TTStyle", @"TTHints", @"TTUnderline", @"TTStrikethrough",
      @"TTEmphasis", @"TTColor", @"TTTimestamp", @"TTFont", @"ICTTFont", @"NSFont", @"NSLink", @"NSAttachment" ]];
  NSMutableArray *runs = [NSMutableArray array];
  __block BOOL complete = YES;
  __block NSString *localReason = nil;
  [text enumerateAttributesInRange:range options:0 usingBlock:^(NSDictionary *attrs, NSRange run, BOOL *stop) {
    NSMutableDictionary *canonical = [NSMutableDictionary dictionary];
    for (id key in attrs) {
      if (![key isKindOfClass:NSString.class] || ![keys containsObject:key]) {
        ANMContentUnsupported(&localReason, @"Unsupported attributed-text key");
        complete = NO; *stop = YES; return;
      }
      id value = ANMContentValue(attrs[key], &localReason);
      if (!value) { complete = NO; *stop = YES; return; }
      canonical[[key copy]] = value;
    }
    NSMutableDictionary *last = runs.lastObject;
    if (last && [last[@"attributes"] isEqual:canonical])
      last[@"length"] = @([last[@"length"] unsignedIntegerValue] + run.length);
    else
      [runs addObject:[@{ @"location" : @(run.location - range.location), @"length" : @(run.length),
          @"attributes" : [canonical copy] } mutableCopy]];
  }];
  if (!complete) {
    if (reason) *reason = localReason;
    return nil;
  }
  NSMutableArray *immutableRuns = [NSMutableArray array];
  for (NSDictionary *run in runs) [immutableRuns addObject:[run copy]];
  return @{ @"text" : [[text.string substringWithRange:range] copy], @"runs" : [immutableRuns copy] };
}

static NSDictionary *ANMContentSlice(NSDictionary *snapshot, NSRange range) {
  NSMutableArray *runs = [NSMutableArray array];
  for (NSDictionary *run in snapshot[@"runs"]) {
    NSRange overlap = NSIntersectionRange(range,
        NSMakeRange([run[@"location"] unsignedIntegerValue], [run[@"length"] unsignedIntegerValue]));
    if (overlap.length) [runs addObject:@{ @"location" : @(overlap.location - range.location),
        @"length" : @(overlap.length), @"attributes" : run[@"attributes"] }];
  }
  return @{ @"text" : [snapshot[@"text"] substringWithRange:range], @"runs" : runs };
}

static BOOL ANMContentMatches(NSDictionary *expected, NSAttributedString *actual, NSString **reason) {
  NSDictionary *snapshot = ANMContentSnapshot(actual, NSMakeRange(0, actual.length), reason);
  if (!snapshot) return NO;
  if (![expected isEqual:snapshot]) {
    ANMContentUnsupported(reason, @"Untouched text, attributes, or checklist identities changed");
    return NO;
  }
  return YES;
}

// Offsets and lengths are NSString UTF-16 units. The complete inserted range
// includes intended prefix/trailing separators and their new styles. There
// is no allowance to rewrite any old character, paragraph style, or todo.
static BOOL ANMContentInsertionMatches(NSDictionary *before, NSAttributedString *after,
                                      NSUInteger at, NSUInteger insertedUTF16, NSString **reason) {
  NSUInteger oldLength = [before[@"text"] length];
  if (![after isKindOfClass:NSAttributedString.class] || at > oldLength ||
      insertedUTF16 > NSUIntegerMax - oldLength || after.length != oldLength + insertedUTF16) {
    ANMContentUnsupported(reason, @"Invalid UTF-16 insertion preservation map");
    return NO;
  }
  NSRange oldRanges[] = { NSMakeRange(0, at), NSMakeRange(at, oldLength - at) };
  for (NSUInteger i = 0; i < 2; i++) {
    NSRange actualRange = oldRanges[i];
    if (i == 1) actualRange.location += insertedUTF16;
    NSDictionary *actual = ANMContentSnapshot(after, actualRange, reason);
    if (!actual) return NO;
    if (![ANMContentSlice(before, oldRanges[i]) isEqual:actual]) {
      ANMContentUnsupported(reason, @"An existing attribute or checklist identity changed outside the composed insertion");
      return NO;
    }
  }
  return YES;
}

// Table snapshots use stable columnIdentifiers and rows[{identifier,cells}],
// where each cell is an ANMContentSnapshot. `expected` uses plain cell strings
// from the operation plan. Only newly inserted rows and the explicitly named
// replacement cell may have new attributes; all survivors compare in full.
static BOOL ANMTableSnapshotValid(NSDictionary *snapshot, BOOL plain, NSString **reason) {
  if (![snapshot isKindOfClass:NSDictionary.class] ||
      ![snapshot[@"columnIdentifiers"] isKindOfClass:NSArray.class] || ![snapshot[@"rows"] isKindOfClass:NSArray.class]) {
    ANMContentUnsupported(reason, @"Malformed table preservation snapshot"); return NO;
  }
  NSArray *columns = snapshot[@"columnIdentifiers"];
  NSMutableSet *seen = [NSMutableSet set];
  for (id column in columns) {
    if (![column isKindOfClass:NSString.class] || ![column length] || [seen containsObject:[column uppercaseString]]) {
      ANMContentUnsupported(reason, @"Missing or duplicate table column identity"); return NO;
    }
    [seen addObject:[column uppercaseString]];
  }
  [seen removeAllObjects];
  for (id row in snapshot[@"rows"]) {
    if (![row isKindOfClass:NSDictionary.class]) {
      ANMContentUnsupported(reason, @"Malformed table row snapshot"); return NO;
    }
    id identity = row[@"identifier"];
    NSArray *cells = row[@"cells"];
    if (![identity isKindOfClass:NSString.class] || ![identity length] || [seen containsObject:[identity uppercaseString]] ||
        ![cells isKindOfClass:NSArray.class] || cells.count != columns.count) {
      ANMContentUnsupported(reason, @"Missing or duplicate table row identity or inconsistent cell count"); return NO;
    }
    [seen addObject:[identity uppercaseString]];
    for (id cell in cells) {
      BOOL valid = plain ? [cell isKindOfClass:NSString.class] :
          ([cell isKindOfClass:NSDictionary.class] && [cell[@"text"] isKindOfClass:NSString.class] &&
           [cell[@"runs"] isKindOfClass:NSArray.class]);
      if (!valid) { ANMContentUnsupported(reason, @"Malformed table cell snapshot"); return NO; }
    }
  }
  return YES;
}

static BOOL ANMTableExistingCellsVerifiable(NSDictionary *snapshot, NSString *allowedRow,
                                           NSString *allowedColumn, NSString **reason) {
  if (!ANMTableSnapshotValid(snapshot, NO, reason)) return NO;
  NSArray *columns = snapshot[@"columnIdentifiers"];
  for (NSDictionary *row in snapshot[@"rows"]) {
    NSArray *cells = row[@"cells"];
    for (NSUInteger c = 0; c < cells.count; c++) {
      BOOL intendedDelta = allowedRow && [row[@"identifier"] isEqual:allowedRow] &&
          (!allowedColumn || [columns[c] isEqual:allowedColumn]);
      if (![cells[c][@"text"] length] && !intendedDelta) {
        ANMContentUnsupported(reason, @"An empty surviving table cell may carry latent attributes that cannot be compared");
        return NO;
      }
    }
  }
  return YES;
}

static BOOL ANMTableContentMatches(NSDictionary *before, NSDictionary *after, NSDictionary *expected,
                                  NSString *changedRow, NSString *changedColumn, NSString **reason) {
  if (!ANMTableSnapshotValid(before, NO, reason) || !ANMTableSnapshotValid(after, NO, reason) ||
      !ANMTableSnapshotValid(expected, YES, reason)) return NO;
  NSArray *columns = expected[@"columnIdentifiers"];
  NSArray *expectedRows = expected[@"rows"];
  NSArray *actualRows = after[@"rows"];
  if (![before[@"columnIdentifiers"] isEqual:columns] || ![after[@"columnIdentifiers"] isEqual:columns] ||
      expectedRows.count != actualRows.count) {
    ANMContentUnsupported(reason, @"Table survivor row or column identities changed");
    return NO;
  }
  NSMutableDictionary *oldRows = [NSMutableDictionary dictionary];
  for (NSDictionary *row in before[@"rows"]) oldRows[row[@"identifier"]] = row;
  for (NSUInteger r = 0; r < expectedRows.count; r++) {
    NSDictionary *planned = expectedRows[r];
    NSDictionary *actual = actualRows[r];
    NSArray *cells = actual[@"cells"];
    NSArray *texts = planned[@"cells"];
    if (![actual[@"identifier"] isEqual:planned[@"identifier"]] ||
        cells.count != columns.count || texts.count != columns.count) {
      ANMContentUnsupported(reason, @"Table survivor identity or cell count changed");
      return NO;
    }
    NSDictionary *old = oldRows[actual[@"identifier"]];
    for (NSUInteger c = 0; c < columns.count; c++) {
      if (![cells[c][@"text"] isEqual:texts[c]]) {
        ANMContentUnsupported(reason, @"A table cell does not contain its planned text");
        return NO;
      }
      BOOL replacement = changedRow && changedColumn && [actual[@"identifier"] isEqual:changedRow] &&
                         [columns[c] isEqual:changedColumn];
      if (old && !replacement && ![old[@"cells"][c] isEqual:cells[c]]) {
        ANMContentUnsupported(reason, @"An untouched table cell lost attributes or checklist identity");
        return NO;
      }
    }
  }
  return YES;
}

#endif
