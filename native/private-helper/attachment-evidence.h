// Original, Foundation-only attachment byte/receipt substrate. No Notes API,
// store access, action dispatch or process preferences. Include in one TU.
#ifndef ANM_ATTACHMENT_EVIDENCE_H
#define ANM_ATTACHMENT_EVIDENCE_H
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const ANMAttachmentEvidencePolicy =
    @"complete-sha256-v1:512MiB:stored-attributes:transient-excluded:version-floor-may-rise";

// Exact Foundation scalars for stored row evidence. Rounded date/number text
// cannot establish equality. Unknown decoded transformables fail closed.
static id ANMCanonicalStoredValue(id value) {
  if (!value) return @{@"type" : @"nil"};
  if ([value isKindOfClass:[NSString class]]) return @{@"type" : @"string", @"value" : value};
  if ([value isKindOfClass:[NSData class]]) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    NSUInteger length = [value length];
    const unsigned char *bytes = [value bytes];
    for (NSUInteger offset = 0; offset < length;) {
      CC_LONG count = (CC_LONG)MIN(length - offset, (NSUInteger)65536);
      CC_SHA256_Update(&hash, bytes + offset, count);
      offset += count;
    }
    CC_SHA256_Final(digest, &hash);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return @{@"type" : @"data", @"bytes" : @([value length]), @"sha256" : hex};
  }
  if ([value isKindOfClass:[NSDate class]])
    return @{@"type" : @"date", @"value" : [NSString stringWithFormat:@"%a", [value timeIntervalSinceReferenceDate]]};
  if ([value isKindOfClass:[NSDecimalNumber class]])
    return @{@"type" : @"decimal", @"value" : [value stringValue]};
  if ([value isKindOfClass:[NSNumber class]]) {
    const char *type = [value objCType];
    if (!type || strlen(type) != 1 || !strchr("cCsSiIlLqQfdB", type[0])) return nil;
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    if (!size || size > 16) return nil;
    unsigned char bytes[16] = {0};
    [value getValue:bytes size:size];
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < size; i++) [hex appendFormat:@"%02x", bytes[i]];
    return @{@"type" : [NSString stringWithUTF8String:type], @"value" : hex};
  }
  if ([value isKindOfClass:[NSUUID class]]) return @{@"type" : @"uuid", @"value" : [value UUIDString]};
  if ([value isKindOfClass:[NSURL class]]) return @{@"type" : @"url", @"value" : [value absoluteString]};
  return nil;
}

// Inject only the I/O seam, so small fixtures can model budgets and drift.
typedef struct {
  void *context;
  int (*openFile)(void *, const char *, int);
  int (*statFile)(void *, int, struct stat *);
  ssize_t (*readFile)(void *, int, void *, size_t);
  int (*statPath)(void *, const char *, struct stat *);
  int (*closeFile)(void *, int);
} ANMAttachmentEvidenceIO;

static int ANMEvidenceOpen(void *c, const char *p, int f) { (void)c; return open(p, f); }
static int ANMEvidenceFstat(void *c, int fd, struct stat *s) { (void)c; return fstat(fd, s); }
static ssize_t ANMEvidenceRead(void *c, int fd, void *b, size_t n) { (void)c; return read(fd, b, n); }
static int ANMEvidenceLstat(void *c, const char *p, struct stat *s) { (void)c; return lstat(p, s); }
static int ANMEvidenceClose(void *c, int fd) { (void)c; return close(fd); }

static BOOL ANMEvidenceSameFile(struct stat a, struct stat b) {
  return S_ISREG(a.st_mode) && S_ISREG(b.st_mode) && a.st_dev == b.st_dev && a.st_ino == b.st_ino &&
         a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
         a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
         a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}

static NSDictionary *ANMEvidenceFailure(NSError **error, NSInteger code, NSString *reason) {
  if (error) *error = [NSError errorWithDomain:@"AttachmentEvidence" code:code
                                    userInfo:@{NSLocalizedDescriptionKey : reason}];
  return nil;
}

// Every accepted digest describes bytes read from one regular-file descriptor.
// Path and descriptor metadata agree before/after, including ctime, so neither
// equal size/mtime nor an unavailable-state sentinel can establish equality.
// The budget is consumed only on success. Zero-byte regular files are valid.
static NSDictionary *ANMCompleteFileEvidence(NSString *path, long long *budget,
                                             const ANMAttachmentEvidenceIO *injected, NSError **error) {
  ANMAttachmentEvidenceIO real = {NULL, ANMEvidenceOpen, ANMEvidenceFstat, ANMEvidenceRead,
                                ANMEvidenceLstat, ANMEvidenceClose};
  const ANMAttachmentEvidenceIO *io = injected ?: &real;
  if (!path || !budget || *budget < 0)
    return ANMEvidenceFailure(error, 1, @"The required attachment file is unavailable");
  struct stat pathBefore, before, after, pathAfter;
  if (io->statPath(io->context, path.fileSystemRepresentation, &pathBefore) != 0 ||
      !S_ISREG(pathBefore.st_mode))
    return ANMEvidenceFailure(error, 1, @"The required attachment file is unavailable or not regular");
  int fd = io->openFile(io->context, path.fileSystemRepresentation,
                        O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return ANMEvidenceFailure(error, 2, @"The required attachment file is unreadable");
  NSDictionary *result = nil;
  @try {
    if (io->statFile(io->context, fd, &before) != 0 || !ANMEvidenceSameFile(pathBefore, before))
      return ANMEvidenceFailure(error, 3, @"The attachment file changed before hashing");
    if (before.st_size < 0 || before.st_size > *budget)
      return ANMEvidenceFailure(error, 4, @"Complete attachment bytes exceed the remaining snapshot budget");
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    unsigned char buffer[65536];
    long long total = 0;
    for (;;) {
      ssize_t count = io->readFile(io->context, fd, buffer, sizeof buffer);
      if (count < 0 && errno == EINTR) continue;
      if (count < 0) return ANMEvidenceFailure(error, 2, @"The required attachment file could not be read completely");
      if (!count) break;
      if (count > before.st_size - total)
        return ANMEvidenceFailure(error, 3, @"The attachment file grew during hashing");
      CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
      total += count;
    }
    if (total != before.st_size || io->statFile(io->context, fd, &after) != 0 ||
        !ANMEvidenceSameFile(before, after) ||
        io->statPath(io->context, path.fileSystemRepresentation, &pathAfter) != 0 ||
        !ANMEvidenceSameFile(after, pathAfter))
      return ANMEvidenceFailure(error, 3, @"The attachment file changed during hashing");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    result = @{@"bytes" : @(total), @"sha256" : hex};
    *budget -= total;
  } @finally {
    io->closeFile(io->context, fd);
  }
  return result;
}

// The complete snapshot and its policy are reviewed together. No apply-only
// token can substitute for the receipt returned by a prior read-only plan.
static NSString *ANMAttachmentSnapshotToken(NSDictionary *snapshot) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{
    @"policy" : ANMAttachmentEvidencePolicy, @"snapshot" : snapshot,
  } options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
  if (!data) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *token = [NSMutableString stringWithString:@"a1:"];
  for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [token appendFormat:@"%02x", digest[i]];
  return token;
}
#endif
