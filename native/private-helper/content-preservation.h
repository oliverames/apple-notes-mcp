// Pure attributed-text preservation. No NotesShared loading, store access,
// action dispatch, or writes. Snapshots contain only immutable Foundation
// values; unsupported keys/classes/accessor types refuse before mutation.
#ifndef ANM_CONTENT_PRESERVATION_H
#define ANM_CONTENT_PRESERVATION_H
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static NSString *const ANMContentEvidencePolicy = @"supported-attributes-v1:pinned-native-layouts:exact-scalars:no-unknowns";

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

// Explicit synthetic-supported layouts. This is deliberately not a layout
// inferred from a loaded private framework. A real native value whose opaque
// or additional stored state differs refuses until separately reviewed.
static NSDictionary *ANMContentLayout(id value) {
  NSString *name = NSStringFromClass(object_getClass(value));
  if ([name isEqual:@"ICTTParagraphStyle"] || [name isEqual:@"ICTTMutableParagraphStyle"])
    return @{ @"style" : @"I", @"alignment" : @"q", @"writingDirection" : @"q", @"indent" : @"q",
        @"blockQuoteLevel" : @"q", @"startingItemNumber" : @"q", @"hints" : @"I", @"uuid" : @"@", @"todo" : @"@" };
  if ([name isEqual:@"ICTTTodo"]) return @{ @"uuid" : @"@", @"done" : @(@encode(BOOL)) };
  if ([name isEqual:@"ICTTFont"]) return @{ @"fontName" : @"@", @"pointSize" : @"d", @"fontHints" : @"I" };
  if ([name isEqual:@"ICTTAttachment"]) return @{ @"attachmentIdentifier" : @"@", @"attachmentUTI" : @"@" };
  return nil;
}

static BOOL ANMContentLayoutMatches(id value, NSString **reason) {
  NSDictionary *layout = ANMContentLayout(value);
  if (!layout) { ANMContentUnsupported(reason, @"Unpinned native attribute class"); return NO; }
  NSMutableSet *ivarsSeen = [NSMutableSet set], *propertiesSeen = [NSMutableSet set];
  Class directSuperclass = class_getSuperclass(object_getClass(value));
  NSString *className = NSStringFromClass(object_getClass(value));
  BOOL validSuperclass = directSuperclass == NSObject.class ||
      ([className isEqual:@"ICTTMutableParagraphStyle"] && directSuperclass == NSClassFromString(@"ICTTParagraphStyle"));
  if (!validSuperclass) { ANMContentUnsupported(reason, @"Unpinned native attribute superclass"); return NO; }
  for (Class cls = object_getClass(value); cls != NSObject.class; cls = class_getSuperclass(cls)) {
    NSString *className = NSStringFromClass(cls);
    if (!cls || ![@[ @"ICTTParagraphStyle", @"ICTTMutableParagraphStyle", @"ICTTTodo", @"ICTTFont", @"ICTTAttachment" ] containsObject:className]) {
      ANMContentUnsupported(reason, @"Unpinned native attribute superclass"); return NO;
    }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    BOOL valid = YES;
    for (unsigned int i = 0; i < count; i++) {
      NSString *storedName = @(ivar_getName(ivars[i]));
      NSString *field = [storedName hasPrefix:@"_"] ? [storedName substringFromIndex:1] : nil;
      NSString *abi = field ? layout[field] : nil;
      const char *type = ivar_getTypeEncoding(ivars[i]);
      BOOL objectType = [abi isEqual:@"@"] && type && type[0] == '@';
      if (!abi || [ivarsSeen containsObject:field] || (!objectType && strcmp(type, abi.UTF8String) != 0)) {
        valid = NO; break;
      }
      [ivarsSeen addObject:field];
    }
    free(ivars);
    if (!valid) { ANMContentUnsupported(reason, @"Extra, opaque, or incompatible stored native attribute field"); return NO; }
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
      NSString *field = @(property_getName(properties[i]));
      if (!layout[field] || [propertiesSeen containsObject:field]) { valid = NO; break; }
      [propertiesSeen addObject:field];
    }
    free(properties);
    if (!valid) { ANMContentUnsupported(reason, @"Extra native attribute property"); return NO; }
  }
  NSSet *required = [NSSet setWithArray:layout.allKeys];
  if (![ivarsSeen isEqual:required] || ![propertiesSeen isEqual:required]) {
    ANMContentUnsupported(reason, @"Incomplete pinned native attribute layout"); return NO;
  }
  for (NSString *field in layout) {
    NSMethodSignature *signature = [value methodSignatureForSelector:NSSelectorFromString(field)];
    if (!signature || signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, [layout[field] UTF8String]) != 0) {
      ANMContentUnsupported(reason, @"Incompatible pinned native attribute getter ABI"); return NO;
    }
  }
  return YES;
}

static id ANMContentStoredField(id value, NSString *name, NSString **reason) {
  Ivar ivar = class_getInstanceVariable(object_getClass(value), [[@"_" stringByAppendingString:name] UTF8String]);
  const char *type = ivar_getTypeEncoding(ivar);
  if (type[0] == '@') return object_getIvar(value, ivar) ?: NSNull.null;
  const unsigned char *bytes = (const unsigned char *)(__bridge const void *)value + ivar_getOffset(ivar);
#define ANM_CONTENT_STORED(encoding, scalarType) \
  if (strcmp(type, @encode(encoding)) == 0) { scalarType result = 0; \
    memcpy(&result, bytes, sizeof(result)); return @(result); }
  ANM_CONTENT_STORED(unsigned int, unsigned int)
  ANM_CONTENT_STORED(long long, long long)
  ANM_CONTENT_STORED(BOOL, BOOL)
  ANM_CONTENT_STORED(double, double)
#undef ANM_CONTENT_STORED
  return ANMContentUnsupported(reason, @"Unsupported pinned native attribute storage ABI");
}

static id ANMContentFields(id value, NSArray<NSString *> *names, NSString **reason) {
  if (!ANMContentLayoutMatches(value, reason)) return nil;
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  for (NSString *name in names) {
    // Read every pinned stored field itself; a getter projection cannot hide
    // state in a supported field. Getter ABI is independently checked above.
    id field = ANMContentStoredField(value, name, reason);
    if (!field) return nil;
    id canonical = ANMContentValue(field, reason);
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
        @"blockQuoteLevel", @"startingItemNumber", @"hints", @"uuid", @"todo" ], reason);
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
    id fields = ANMContentFields(value, @[ @"fontName", @"pointSize", @"fontHints" ], reason);
    return fields ? @[ @"font", fields ] : nil;
  }
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
      @"TTEmphasis", @"TTColor", @"TTTimestamp", @"TTFont", @"NSFont", @"NSLink", @"NSAttachment" ]];
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
