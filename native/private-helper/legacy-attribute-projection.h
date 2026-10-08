// Exact comparison of the legacy edit getter projection. This is NOT a
// complete snapshot of opaque private state. It preserves the existing
// accessor-based availability boundary while removing decimal rounding and
// delimiter collisions; complete native-layout adapters remain separate.
#ifndef ANM_LEGACY_ATTRIBUTE_PROJECTION_H
#define ANM_LEGACY_ATTRIBUTE_PROJECTION_H
#include "content-preservation.h"
#import <objc/message.h>

// Length framing is injective for NSString UTF-16 units, including embedded
// separators and NULs. Dictionaries sort keys before encoding; no object
// descriptions, pointers, or unordered property-list bytes participate.
static NSString *ANMLegacyFrame(NSString *value) {
  return [NSString stringWithFormat:@"%lu:%@", (unsigned long)value.length, value];
}

static NSString *ANMLegacyEncode(id value) {
  if ([value isKindOfClass:NSString.class]) return [@"s" stringByAppendingString:ANMLegacyFrame(value)];
  if ([value isKindOfClass:NSData.class])
    return [@"d" stringByAppendingString:ANMLegacyFrame([value base64EncodedStringWithOptions:0])];
  if ([value isKindOfClass:NSNumber.class]) {
    NSString *reason = nil;
    id exact = ANMContentNumber(value, &reason);
    return exact ? ANMLegacyEncode(exact) : nil;
  }
  if ([value isKindOfClass:NSArray.class]) {
    NSMutableString *result = [NSMutableString stringWithFormat:@"a%lu:", (unsigned long)[value count]];
    for (id field in value) {
      NSString *encoded = ANMLegacyEncode(field);
      if (!encoded) return nil;
      [result appendString:ANMLegacyFrame(encoded)];
    }
    return [result copy];
  }
  if ([value isKindOfClass:NSDictionary.class]) {
    for (id key in value) if (![key isKindOfClass:NSString.class]) return nil;
    NSMutableString *result = [NSMutableString stringWithFormat:@"m%lu:", (unsigned long)[value count]];
    NSArray *keys = [[value allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
      return [a compare:b options:NSLiteralSearch];
    }];
    for (NSString *key in keys) {
      NSString *encoded = ANMLegacyEncode(value[key]);
      if (!encoded) return nil;
      [result appendString:ANMLegacyFrame(key)];
      [result appendString:ANMLegacyFrame(encoded)];
    }
    return [result copy];
  }
  return nil;
}

// Presence alone cannot justify an objc_msgSend cast. Validate each actual
// implementation's return ABI and argument count before calling a getter.
static BOOL ANMLegacyGetter(id value, NSString *name, const char *returnType) {
  Method method = class_getInstanceMethod(object_getClass(value), NSSelectorFromString(name));
  if (!method || method_getNumberOfArguments(method) != 2) return NO;
  char *actual = method_copyReturnType(method);
  BOOL matches = actual && strcmp(actual, returnType) == 0;
  free(actual);
  for (unsigned int i = 0; matches && i < 2; i++) {
    char *argument = method_copyArgumentType(method, i);
    matches = argument && strcmp(argument, i == 0 ? @encode(id) : @encode(SEL)) == 0;
    free(argument);
  }
  return matches;
}

static id ANMLegacyObject(id value, NSString *name) {
  return ((id (*)(id, SEL))objc_msgSend)(value, NSSelectorFromString(name));
}

static id ANMLegacyUUID(id value) {
  if (!value) return @[ @"null" ];
  return [value isKindOfClass:NSUUID.class] ? @[ @"uuid", [value UUIDString] ] : nil;
}

static NSString *ANMLegacyCanonicalValue(id value) {
  if (!value) return ANMLegacyEncode(@[ @"null" ]);
  // Use the exact scalar/color implementation without applying synthetic
  // layout pins to the legacy private getter projection below.
  if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class] ||
      [value isKindOfClass:NSURL.class] || [value isKindOfClass:NSUUID.class] ||
      [value isKindOfClass:NSDate.class] || [value isKindOfClass:NSColor.class] ||
      (ANMContentNamedClass(value, @[ @"CGColor", @"__NSCFType" ]) &&
       CFGetTypeID((__bridge CFTypeRef)value) == CGColorGetTypeID())) {
    NSString *reason = nil;
    id exact = ANMContentValue(value, &reason);
    return exact ? ANMLegacyEncode(exact) : nil;
  }
  Class paragraph = NSClassFromString(@"ICTTParagraphStyle");
  if (paragraph && [value isKindOfClass:paragraph]) {
    NSArray *u32 = @[ @"style", @"hints" ];
    NSArray *i64 = @[ @"alignment", @"writingDirection", @"indent", @"blockQuoteLevel", @"startingItemNumber" ];
    for (NSString *name in u32) if (!ANMLegacyGetter(value, name, @encode(unsigned int))) return nil;
    for (NSString *name in i64) if (!ANMLegacyGetter(value, name, @encode(long long))) return nil;
    if (!ANMLegacyGetter(value, @"uuid", @encode(id)) || !ANMLegacyGetter(value, @"todo", @encode(id))) return nil;
    id uuid = ANMLegacyUUID(ANMLegacyObject(value, @"uuid"));
    if (!uuid) return nil;
    id todo = ANMLegacyObject(value, @"todo");
    id todoFields = @[ @"null" ];
    if (todo) {
      if (!ANMLegacyGetter(todo, @"uuid", @encode(id)) || !ANMLegacyGetter(todo, @"done", @encode(BOOL))) return nil;
      id todoUUID = ANMLegacyUUID(ANMLegacyObject(todo, @"uuid"));
      if (!todoUUID) return nil;
      BOOL done = ((BOOL (*)(id, SEL))objc_msgSend)(todo, NSSelectorFromString(@"done"));
      todoFields = @[ @"todo", todoUUID, @(done) ];
    }
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithDictionary:@{ @"uuid" : uuid, @"todo" : todoFields }];
    for (NSString *name in u32)
      fields[name] = @(((unsigned int (*)(id, SEL))objc_msgSend)(value, NSSelectorFromString(name)));
    for (NSString *name in i64)
      fields[name] = @(((long long (*)(id, SEL))objc_msgSend)(value, NSSelectorFromString(name)));
    return ANMLegacyEncode(@[ @"paragraph-getters", fields ]);
  }
  Class attachment = NSClassFromString(@"ICTTAttachment");
  if (attachment && [value isKindOfClass:attachment]) {
    for (NSString *name in @[ @"attachmentIdentifier", @"attachmentUTI" ])
      if (!ANMLegacyGetter(value, name, @encode(id))) return nil;
    id identifier = ANMLegacyObject(value, @"attachmentIdentifier"), uti = ANMLegacyObject(value, @"attachmentUTI");
    if ((identifier && ![identifier isKindOfClass:NSString.class]) || (uti && ![uti isKindOfClass:NSString.class])) return nil;
    return ANMLegacyEncode(@[ @"attachment-getters", identifier ? @[ @"string", [identifier copy] ] : @[ @"null" ],
                            uti ? @[ @"string", [uti copy] ] : @[ @"null" ] ]);
  }
  Class font = NSClassFromString(@"ICTTFont");
  if (font && [value isKindOfClass:font]) {
    if (!ANMLegacyGetter(value, @"fontName", @encode(id)) || !ANMLegacyGetter(value, @"pointSize", @encode(double)) ||
        !ANMLegacyGetter(value, @"fontHints", @encode(unsigned int))) return nil;
    id name = ANMLegacyObject(value, @"fontName");
    if (name && ![name isKindOfClass:NSString.class]) return nil;
    double size = ((double (*)(id, SEL))objc_msgSend)(value, NSSelectorFromString(@"pointSize"));
    unsigned int hints = ((unsigned int (*)(id, SEL))objc_msgSend)(value, NSSelectorFromString(@"fontHints"));
    return ANMLegacyEncode(@[ @"font-getters", name ? @[ @"string", [name copy] ] : @[ @"null" ], @(size), @(hints) ]);
  }
  return nil;
}

static NSString *ANMLegacyCanonicalAttributes(NSDictionary *attributes, BOOL ignoreTimestamp, NSString *timestampKey) {
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  for (id key in attributes) {
    if (![key isKindOfClass:NSString.class]) return [@"unsupported:" stringByAppendingString:NSUUID.UUID.UUIDString];
    if (ignoreTimestamp && [key isEqual:timestampKey]) continue;
    NSString *value = ANMLegacyCanonicalValue(attributes[key]);
    // Unsupported values never compare equal, even to the same object.
    if (!value) return [@"unsupported:" stringByAppendingString:NSUUID.UUID.UUIDString];
    fields[[key copy]] = value;
  }
  return ANMLegacyEncode(fields);
}

static NSArray *ANMLegacyCanonicalRuns(NSAttributedString *text, NSRange range, BOOL ignoreTimestamp, NSString *timestampKey) {
  NSMutableArray *runs = [NSMutableArray array];
  if (!range.length) return @[];
  [text enumerateAttributesInRange:range options:0 usingBlock:^(NSDictionary *attrs, NSRange run, BOOL *stop) {
    (void)stop;
    NSString *canonical = ANMLegacyCanonicalAttributes(attrs, ignoreTimestamp, timestampKey);
    NSMutableArray *last = runs.lastObject;
    if (last && [last[2] isEqualToString:canonical]) last[1] = @([last[1] unsignedIntegerValue] + run.length);
    else [runs addObject:[@[ @(run.location - range.location), @(run.length), canonical ] mutableCopy]];
  }];
  NSMutableArray *frozen = [NSMutableArray array];
  for (NSArray *run in runs) [frozen addObject:[run copy]];
  return [frozen copy];
}

// Slice an already frozen full-body projection. Never re-read mutable
// attribute objects from an NSAttributedString shallow copy after mutation.
static NSArray *ANMLegacySliceRuns(NSArray *fullRuns, NSRange range) {
  NSMutableArray *sliced = [NSMutableArray array];
  for (NSArray *run in fullRuns) {
    NSRange overlap = NSIntersectionRange(range, NSMakeRange([run[0] unsignedIntegerValue], [run[1] unsignedIntegerValue]));
    if (overlap.length)
      [sliced addObject:@[ @(overlap.location - range.location), @(overlap.length), run[2] ]];
  }
  return [sliced copy];
}
#endif
