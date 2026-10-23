#import "TWAdBlockPlaylistProtocol.h"
#import <objc/runtime.h>
#import "TWAdBlockLog.h"

// Ad detection follows Purple Adblock's findings (github.com/arthurbolsoni/Purple-adblock,
// Apache-2.0): live segments are titled "live"; ad segments carry another title (Amazon|…, FT|…)
// and sit inside a twitch-stitched-ad DATERANGE. twitch-maf-ad ranges are client-side ad slots.

extern NSUserDefaults *tweakDefaults;

static NSString *const kHandledKey = @"TWAdBlockPlaylistHandled";

static BOOL isUsherMaster(NSURL *URL) {
  return [URL.host isEqualToString:@"usher.ttvnw.net"] &&
         [URL.path.pathExtension isEqualToString:@"m3u8"];
}

static BOOL isMediaPlaylist(NSURL *URL) {
  if (![URL.path.pathExtension isEqualToString:@"m3u8"] || isUsherMaster(URL)) return NO;
  NSString *host = URL.host;
  return [host hasSuffix:@".ttvnw.net"] || [host hasSuffix:@".live-video.net"];
}

static NSString *shortID(NSURL *URL) {
  NSString *name = URL.path.lastPathComponent.stringByDeletingPathExtension;
  return name.length > 8 ? [name substringFromIndex:name.length - 8] : name;
}

static NSString *attribute(NSString *line, NSString *name) {
  NSString *pattern = [NSString stringWithFormat:@"%@=(\"[^\"]*\"|[^,]*)", name];
  NSRange range = [line rangeOfString:pattern options:NSRegularExpressionSearch];
  if (range.location == NSNotFound) return nil;
  NSString *value = [line substringWithRange:NSMakeRange(range.location + name.length + 1,
                                                         range.length - name.length - 1)];
  return [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
}

static void logMaster(NSURL *URL, NSString *text) {
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
  NSMutableArray *keys = [NSMutableArray array];
  NSString *tokenInfo = @"";
  for (NSURLQueryItem *item in components.queryItems) {
    [keys addObject:item.name];
    if (![item.name isEqualToString:@"token"] || !item.value) continue;
    NSDictionary *token = [NSJSONSerialization
        JSONObjectWithData:[item.value dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     error:nil];
    if (![token isKindOfClass:NSDictionary.class]) continue;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in @[
           @"player_type", @"platform", @"server_ads", @"show_ads", @"hide_ads", @"adblock",
           @"turbo", @"subscriber", @"role", @"geoblock_reason"
         ]) {
      if (token[key]) [parts addObject:[NSString stringWithFormat:@"%@=%@", key, token[key]]];
    }
    tokenInfo = [parts componentsJoinedByString:@" "];
  }
  NSMutableArray *variants = [NSMutableArray array];
  for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;
    NSString *name = attribute(line, @"VIDEO") ?: attribute(line, @"RESOLUTION") ?: @"?";
    [variants addObject:name];
  }
  TWAdBlockLog(@"MASTER %@ token[%@] variants[%@] query[%@]", URL.path.lastPathComponent, tokenInfo,
               [variants componentsJoinedByString:@","], [keys componentsJoinedByString:@","]);
}

static void logMedia(NSURL *URL, NSString *text) {
  NSInteger live = 0, ads = 0, stitched = 0, maf = 0;
  NSString *sequence = @"?", *rollType, *adTitle;
  for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    if ([line hasPrefix:@"#EXTINF:"]) {
      NSRange comma = [line rangeOfString:@","];
      NSString *title = comma.location == NSNotFound ? @"" : [line substringFromIndex:comma.location + 1];
      if ([title isEqualToString:@"live"]) {
        live++;
      } else {
        ads++;
        if (!adTitle) adTitle = [title componentsSeparatedByString:@"|"].firstObject;
      }
    } else if ([line hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
      sequence = [line substringFromIndex:22];
    } else if ([line hasPrefix:@"#EXT-X-DATERANGE:"]) {
      NSString *rangeClass = attribute(line, @"CLASS");
      if ([rangeClass isEqualToString:@"twitch-stitched-ad"]) {
        stitched++;
        rollType = rollType ?: attribute(line, @"X-TV-TWITCH-AD-ROLL-TYPE");
      } else if ([rangeClass isEqualToString:@"twitch-maf-ad"]) {
        maf++;
      }
    }
  }
  NSString *state;
  if (ads)
    state = [NSString stringWithFormat:@"ADS %ld/%ld title=%@ roll=%@", (long)ads, (long)(ads + live),
                                       adTitle, rollType ?: @"?"];
  else if (stitched)
    state = [NSString stringWithFormat:@"announced (stitched-ad range, roll=%@)", rollType ?: @"?"];
  else if (maf)
    state = @"maf-ad slot (client-side ad)";
  else
    state = @"clean";

  // Log only changes per playlist, so a long stream doesn't flood the log
  static NSMutableDictionary<NSString *, NSString *> *lastStates;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lastStates = [NSMutableDictionary dictionary];
  });
  NSString *key = URL.path;
  BOOL changed;
  @synchronized(lastStates) {
    changed = ![lastStates[key] isEqualToString:state];
    lastStates[key] = state;
  }
  if (!changed) return;
  TWAdBlockLog(@"MEDIA %@ seq=%@ %@", shortID(URL), sequence, state);
  // The first playlist of a break, in full, to build the replacement logic on
  if (ads || stitched) TWAdBlockLog(@"MEDIA %@ playlist:\n%@", shortID(URL),
                                    text.length > 6000 ? [text substringToIndex:6000] : text);
}

@interface TWAdBlockPlaylistProtocol ()
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSThread *clientThread;
@property(nonatomic, copy) NSArray<NSString *> *modes;
@property(nonatomic, assign) BOOL stopped;
@end

@implementation TWAdBlockPlaylistProtocol
+ (BOOL)isPlayerSessionDelegate:(id)delegate {
  Class delegateClass = objc_getClass("IVSPlayerURLSessionDelegate");
  return delegateClass && [delegate isKindOfClass:delegateClass];
}

+ (NSURLSessionConfiguration *)configurationByAddingProtocol:(NSURLSessionConfiguration *)configuration {
  NSURLSessionConfiguration *copy = configuration.copy;
  NSMutableArray *protocols = [NSMutableArray arrayWithObject:self];
  if (copy.protocolClasses) [protocols addObjectsFromArray:copy.protocolClasses];
  copy.protocolClasses = protocols;
  return copy;
}

+ (NSURLSession *)innerSession {
  static NSURLSession *session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.URLCache = nil;
    session = [NSURLSession sessionWithConfiguration:configuration];
  });
  return session;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  if (!TWAdBlockLogEnabled() || [self propertyForKey:kHandledKey inRequest:request]) return NO;
  // Its own fetch would skip the proxy
  if ([tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"]) return NO;
  return isUsherMaster(request.URL) || isMediaPlaylist(request.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return request;
}

- (void)startLoading {
  self.clientThread = NSThread.currentThread;
  NSString *mode = NSRunLoop.currentRunLoop.currentMode;
  self.modes = mode && ![mode isEqualToString:NSDefaultRunLoopMode]
                   ? @[ mode, NSDefaultRunLoopMode ]
                   : @[ NSDefaultRunLoopMode ];
  NSMutableURLRequest *request = self.request.mutableCopy;
  [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:request];
  NSURL *URL = request.URL;
  __weak typeof(self) weakSelf = self;
  self.task = [[self.class innerSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          if (!error && data && [response isKindOfClass:NSHTTPURLResponse.class] &&
              ((NSHTTPURLResponse *)response).statusCode == 200) {
            @try {
              NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
              if (text) {
                if (isUsherMaster(URL))
                  logMaster(URL, text);
                else
                  logMedia(URL, text);
              }
            } @catch (NSException *exception) {
              TWAdBlockLog(@"analysis failed: %@", exception);
            }
          } else if (error) {
            TWAdBlockLog(@"%@ %@ failed: %@", isUsherMaster(URL) ? @"MASTER" : @"MEDIA",
                         shortID(URL), error.localizedDescription);
          }
          [weakSelf finishWithData:data response:response error:error];
        }];
  [self.task resume];
}

- (void)finishWithData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
  [self performOnClientThread:^{
    if (self.stopped) return;
    id<NSURLProtocolClient> client = self.client;
    if (error) return [client URLProtocol:self didFailWithError:error];
    [client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (data.length) [client URLProtocol:self didLoadData:data];
    [client URLProtocolDidFinishLoading:self];
  }];
}

- (void)performOnClientThread:(dispatch_block_t)block {
  [self performSelector:@selector(runBlock:)
               onThread:self.clientThread
             withObject:[block copy]
          waitUntilDone:NO
                  modes:self.modes];
}

- (void)runBlock:(dispatch_block_t)block {
  block();
}

- (void)stopLoading {
  self.stopped = YES;
  [self.task cancel];
  self.task = nil;
}
@end
