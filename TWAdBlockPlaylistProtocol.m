#import "TWAdBlockPlaylistProtocol.h"
#import <objc/runtime.h>
#import "TWAdBlockBackups.h"
#import "TWAdBlockLog.h"
#import "TWAdBlockPlaylist.h"


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

static _Atomic CFAbsoluteTime lastAdPlaylistTime;

NSTimeInterval TWAdBlockSecondsSinceAdPlaylist(void) {
  CFAbsoluteTime time = lastAdPlaylistTime;
  return time ? CFAbsoluteTimeGetCurrent() - time : -1;
}

static NSString *shortID(NSURL *URL) {
  NSString *name = URL.path.lastPathComponent.stringByDeletingPathExtension;
  return name.length > 8 ? [name substringFromIndex:name.length - 8] : name;
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
    NSString *name = TWAdBlockAttribute(line, @"VIDEO") ?: TWAdBlockAttribute(line, @"RESOLUTION") ?: @"?";
    [variants addObject:name];
  }
  TWAdBlockLog(@"MASTER %@ token[%@] variants[%@] query[%@]", URL.path.lastPathComponent, tokenInfo,
               [variants componentsJoinedByString:@","], [keys componentsJoinedByString:@","]);
}

static void logMedia(NSURL *URL, NSString *text) {
  TWAdBlockMediaPlaylist *playlist = [TWAdBlockMediaPlaylist playlistWithText:text];
  if (playlist.adSegments || playlist.adRanges) lastAdPlaylistTime = CFAbsoluteTimeGetCurrent();
  NSString *state = playlist.stateDescription;
  NSString *kind = [state componentsSeparatedByString:@" "].firstObject;
  // Log only changes per playlist, so a long stream doesn't flood the log
  static NSMutableDictionary<NSString *, NSString *> *lastStates;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lastStates = [NSMutableDictionary dictionary];
  });
  NSString *key = URL.path;
  NSString *lastState;
  @synchronized(lastStates) {
    lastState = lastStates[key];
    lastStates[key] = state;
  }
  if ([lastState isEqualToString:state]) return;
  TWAdBlockLog(@"MEDIA %@ seq=%ld %@", shortID(URL), (long)playlist.sequence, state);
  // The announcing and first ad playlist of a break, in full (a 12000-character cap used to cut
  // off the ad segments)
  if ((playlist.adSegments || playlist.adRanges) &&
      ![[lastState componentsSeparatedByString:@" "].firstObject isEqualToString:kind])
    TWAdBlockLog(@"MEDIA %@ playlist:\n%@", shortID(URL), text);
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
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"] && !TWAdBlockLogEnabled()) return NO;
  if ([self propertyForKey:kHandledKey inRequest:request]) return NO;
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
          NSString *text;
          if (!error && data && [response isKindOfClass:NSHTTPURLResponse.class] &&
              ((NSHTTPURLResponse *)response).statusCode == 200)
            text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
          else if (error)
            TWAdBlockLog(@"%@ %@ failed: %@", isUsherMaster(URL) ? @"MASTER" : @"MEDIA",
                         shortID(URL), error.localizedDescription);
          if (!text) return [weakSelf finishWithData:data response:response error:error];
          @try {
            if (isUsherMaster(URL)) {
              logMaster(URL, text);
              [TWAdBlockBackups.shared recordMaster:text URL:URL];
            } else {
              logMedia(URL, text);
            }
          } @catch (NSException *exception) {
            TWAdBlockLog(@"analysis failed: %@", exception);
          }
          if (isUsherMaster(URL) || ![tweakDefaults boolForKey:@"TWAdBlockEnabled"])
            return [weakSelf finishWithData:data response:response error:nil];
          [TWAdBlockBackups.shared
              playlistForMedia:text
                           URL:URL
                    completion:^(NSString *playlist) {
                      if (playlist == text)
                        return [weakSelf finishWithData:data response:response error:nil];
                      [weakSelf finishWithData:[playlist dataUsingEncoding:NSUTF8StringEncoding]
                                      response:[weakSelf replacedResponse:(NSHTTPURLResponse *)response]
                                         error:nil];
                    }];
        }];
  [self.task resume];
}

// The original response, for a body the protocol replaced
- (NSHTTPURLResponse *)replacedResponse:(NSHTTPURLResponse *)response {
  NSMutableDictionary *headers = response.allHeaderFields.mutableCopy;
  for (NSString *name in response.allHeaderFields) {
    NSString *lower = name.lowercaseString;
    if ([lower isEqualToString:@"content-length"] || [lower isEqualToString:@"content-encoding"])
      [headers removeObjectForKey:name];
  }
  return [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                     statusCode:200
                                    HTTPVersion:@"HTTP/1.1"
                                   headerFields:headers];
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
