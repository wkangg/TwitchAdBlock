#import "TWAdBlockLog.h"

extern NSUserDefaults *tweakDefaults;

static const unsigned long long kMaxLogSize = 25 * 1024 * 1024;

static dispatch_queue_t logQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.level3tjg.twitchadblock.log", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static NSString *logPath(void) {
  NSString *caches =
      NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  return [caches stringByAppendingPathComponent:@"TwitchAdBlock.log"];
}

BOOL TWAdBlockLogEnabled(void) {
  return [tweakDefaults boolForKey:@"TWAdBlockDebugLog"];
}

void TWAdBlockLog(NSString *format, ...) {
  if (!TWAdBlockLogEnabled()) return;
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss.SSS";
  });
  NSDate *date = [NSDate date];
  dispatch_async(logQueue(), ^{
    NSString *line =
        [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:date], message];
    NSString *path = logPath();
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
      [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
      return;
    }
    unsigned long long size = [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    if (size < kMaxLogSize) return;
    // Keep the newer half
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length / 2, data.length / 2)];
    NSRange newline = [tail rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                options:0
                                  range:NSMakeRange(0, tail.length)];
    if (newline.location != NSNotFound)
      tail = [tail subdataWithRange:NSMakeRange(NSMaxRange(newline),
                                                tail.length - NSMaxRange(newline))];
    [tail writeToFile:path atomically:YES];
  });
}

NSString *TWAdBlockLogContents(void) {
  __block NSString *contents;
  dispatch_sync(logQueue(), ^{
    contents = [NSString stringWithContentsOfFile:logPath()
                                         encoding:NSUTF8StringEncoding
                                            error:nil];
  });
  return contents ?: @"";
}

void TWAdBlockLogClear(void) {
  dispatch_sync(logQueue(), ^{
    [NSFileManager.defaultManager removeItemAtPath:logPath() error:nil];
  });
}
