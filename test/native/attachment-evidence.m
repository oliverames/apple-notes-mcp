#include "../../native/private-helper/attachment-evidence.h"
#include <string.h>

typedef struct {
  __unsafe_unretained NSData *data;
  __unsafe_unretained NSString *mode;
  struct stat info;
  size_t offset;
  NSUInteger descriptorStats, pathStats, closes;
} Fixture;

static int FixtureOpen(void *context, const char *path, int flags) {
  (void)path;
  Fixture *f = context;
  if (!(flags & O_NOFOLLOW) || !(flags & O_NONBLOCK)) return -1;
  return [f->mode isEqual:@"unreadable"] ? -1 : 42;
}
static int FixtureStatFile(void *context, int fd, struct stat *info) {
  (void)fd;
  Fixture *f = context;
  *info = f->info;
  if (f->descriptorStats++ && [f->mode isEqual:@"drift"]) info->st_ctimespec.tv_nsec++;
  return 0;
}
static ssize_t FixtureRead(void *context, int fd, void *buffer, size_t count) {
  (void)fd;
  Fixture *f = context;
  if ([f->mode isEqual:@"read-error"]) { errno = EIO; return -1; }
  size_t remaining = f->data.length - f->offset;
  count = MIN(count, MIN(remaining, 2));
  if (count) memcpy(buffer, (const char *)f->data.bytes + f->offset, count);
  f->offset += count;
  return count;
}
static int FixtureStatPath(void *context, const char *path, struct stat *info) {
  (void)path;
  Fixture *f = context;
  if ([f->mode isEqual:@"missing"]) return -1;
  *info = f->info;
  if ([f->mode isEqual:@"nonregular"]) info->st_mode = S_IFIFO;
  if ([f->mode isEqual:@"symlink"]) info->st_mode = S_IFLNK;
  if (f->pathStats++ && [f->mode isEqual:@"replaced"]) info->st_ino++;
  return 0;
}
static int FixtureClose(void *context, int fd) { (void)fd; ((Fixture *)context)->closes++; return 0; }

int main(void) {
  @autoreleasepool {
    NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
    NSMutableDictionary *output = [NSMutableDictionary dictionary];
    if (request[@"snapshot"]) output[@"token"] = ANMAttachmentSnapshotToken(request[@"snapshot"]);
    if (request[@"dates"]) {
      NSMutableArray *dates = [NSMutableArray array];
      for (NSNumber *time in request[@"dates"])
        [dates addObject:ANMCanonicalStoredValue([NSDate dateWithTimeIntervalSinceReferenceDate:time.doubleValue])];
      output[@"dates"] = dates;
    }
    if (request[@"numbers"]) {
      NSMutableArray *numbers = [NSMutableArray array];
      for (NSNumber *number in request[@"numbers"]) [numbers addObject:ANMCanonicalStoredValue(number)];
      output[@"numbers"] = numbers;
      output[@"unsupported"] = ANMCanonicalStoredValue([NSObject new]) == nil ? @YES : @NO;
    }
    long long budget = request[@"budget"] ? [request[@"budget"] longLongValue] : 8;
    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *file in request[@"files"]) {
      NSData *data = [file[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
      Fixture f = { .data = data, .mode = file[@"mode"] ?: @"ok" };
      f.info.st_dev = 1;
      f.info.st_ino = 2;
      f.info.st_mode = S_IFREG | 0600;
      f.info.st_size = file[@"size"] ? [file[@"size"] longLongValue] : (off_t)data.length;
      f.info.st_mtimespec.tv_sec = 100;
      f.info.st_ctimespec.tv_sec = 101;
      ANMAttachmentEvidenceIO io = {&f, FixtureOpen, FixtureStatFile, FixtureRead, FixtureStatPath, FixtureClose};
      NSError *error = nil;
      NSDictionary *evidence = ANMCompleteFileEvidence(@"fixture", &budget, &io, &error);
      NSMutableDictionary *result = [evidence mutableCopy] ?: [NSMutableDictionary dictionary];
      result[@"error"] = @(error.code);
      result[@"closed"] = @(f.closes);
      result[@"remainingBudget"] = @(budget);
      [files addObject:result];
    }
    output[@"files"] = files;
    NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
  }
  return 0;
}
