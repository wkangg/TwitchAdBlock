#import "Tweak.h"

NSBundle *tweakBundle;
NSUserDefaults *tweakDefaults;

// Server-side video ad blocking

// ryanbr's vaft: count client-side ad requests (edge.ads.twitch.tv) and whether a playlist with ads
// came shortly before; ones with none are ads the playlist swap can't see
static void logClientAdRequest(NSURLRequest *request) {
  if (!TWAdBlockLogEnabled() || ![request.URL.host isEqualToString:@"edge.ads.twitch.tv"]) return;
  NSString *query = request.URL.query ?: @"";
  NSString *type = [query containsString:@"bp=midroll"]   ? @"midroll"
                   : [query containsString:@"bp=preroll"] ? @"preroll"
                                                          : request.URL.path;
  static NSCountedSet *counts;
  static NSString *lastURL;
  static CFAbsoluteTime lastTime;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    counts = [NSCountedSet set];
  });
  NSUInteger count;
  @synchronized(counts) {
    // One task method can call the other (with a copy of the request)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ([request.URL.absoluteString isEqualToString:lastURL] && now - lastTime < 1) return;
    lastURL = request.URL.absoluteString;
    lastTime = now;
    [counts addObject:type];
    count = [counts countForObject:type];
  }
  if (count != 1 && count % 10) return;
  NSTimeInterval since = TWAdBlockSecondsSinceAdPlaylist();
  TWAdBlockLog(@"CSAI request #%lu %@ %@ (%@)", (unsigned long)count, type, request.URL.path,
               since < 0 ? @"no ad playlist yet"
                         : [NSString stringWithFormat:@"ad playlist %.0f s ago", since]);
}

%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id<NSURLSessionDelegate>)delegate
                             delegateQueue:(NSOperationQueue *)queue {
  if (![TWAdBlockPlaylistProtocol isPlayerSessionDelegate:delegate])
    return %orig(configuration, delegate, queue);
  TWAdBlockLog(@"player session created");
  return %orig([TWAdBlockPlaylistProtocol configurationByAddingProtocol:configuration], delegate,
               queue);
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  logClientAdRequest(request);
  if ([tweakDefaults boolForKey:@"TWAdBlockEnabled"]) [request.HTTPBody twab_recordTokenRequest:request];
  return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
  logClientAdRequest(request);
  return %orig;
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData {
  if ([tweakDefaults boolForKey:@"TWAdBlockEnabled"]) [bodyData twab_recordTokenRequest:request];
  return %orig;
}
%end

// Client-side video ad blocking

static void removeAdControllers(void *ptr) {
  if (((uintptr_t)ptr & 0xFFFF800000000000) != 0) return;
  id obj = (__bridge id)ptr;
  Ivar theaterAdControllerIvar =
      class_getInstanceVariable(object_getClass(obj), "theaterAdController");
  if (!theaterAdControllerIvar) return;
  id theaterAdController = object_getIvar(obj, theaterAdControllerIvar);
  const char *ivars[] = {"streamDisplayAdStateManager", "streamDisplayAdPodStateManager",
                         "vastAdController"};
  for (int i = 0; i < sizeof(ivars) / sizeof(ivars[0]); i++) {
    Ivar adControllerIvar =
        class_getInstanceVariable(object_getClass(theaterAdController), ivars[i]);
    if (!adControllerIvar) continue;
    // All Optional<class> in 31.7 through 32.1, so reading them is safe; logs once per controller
    // cleared
    id adController = object_getIvar(theaterAdController, adControllerIvar);
    if (!adController) continue;
    TWAdBlockLog(@"CLIENT AD cleared %s (%@)", ivars[i], NSStringFromClass(object_getClass(adController)));
    object_setIvar(theaterAdController, adControllerIvar, nil);
  }
}

static void *(*orig_swift_unknownObjectWeakAssign)(void *, void *);
static void *hook_swift_unknownObjectWeakAssign(void *ref, void *value) {
  void *result = orig_swift_unknownObjectWeakAssign(ref, value);
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return result;
  removeAdControllers(value);
  return result;
}

static void *(*orig_swift_unknownObjectWeakLoadStrong)(void *);
static void *hook_swift_unknownObjectWeakLoadStrong(void *ref) {
  void *result = orig_swift_unknownObjectWeakLoadStrong(ref);
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return result;
  removeAdControllers(result);
  return result;
}

// Block ads in feed tab

%hook _TtC9TwitchKit18TKURLSessionClient
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return %orig;
  %orig(session, dataTask, [data twab_responseDataForRequest:dataTask.currentRequest]);
}
%end

// React Native's fetch: the JS theatre's ChannelSkins GQL query. A response can arrive in several
// chunks, none of them whole JSON, so ChannelSkins responses are held until the task completes
// and handed on filtered in one piece (fetch only reads the whole body anyway). Other requests,
// which may want incremental data, pass through as they come.
static const void *kGQLBufferKey = &kGQLBufferKey;
static const void *kGQLPassthroughKey = &kGQLPassthroughKey;

static BOOL isGQLTask(NSURLSessionTask *task) {
  NSURL *url = task.currentRequest.URL;
  return [url.host isEqualToString:@"gql.twitch.tv"] && [url.path isEqualToString:@"/gql"];
}

// Decided once, on a GQL task's first chunk
static BOOL shouldHoldResponse(NSURLSessionTask *task) {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return NO;
  static NSData *channelSkins;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    channelSkins = [@"ChannelSkins" dataUsingEncoding:NSUTF8StringEncoding];
  });
  NSData *body = task.originalRequest.HTTPBody;
  // No body to look at (sent as a stream): hold it, it's a small GQL response either way
  return !body || [body rangeOfData:channelSkins options:0 range:NSMakeRange(0, body.length)].length;
}

%hook RCTHTTPRequestHandler
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  // Other requests (images, other APIs) are never held
  if (!isGQLTask(dataTask)) return %orig;
  // Not held, our own flush below, or another tweak re-sending it after we've flushed
  if (objc_getAssociatedObject(dataTask, kGQLPassthroughKey)) return %orig;
  NSMutableData *buffer = objc_getAssociatedObject(dataTask, kGQLBufferKey);
  if (!buffer) {
    if (!shouldHoldResponse(dataTask)) {
      // So a later chunk isn't held after this one went through (Ad Block turned on mid-response)
      objc_setAssociatedObject(dataTask, kGQLPassthroughKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      return %orig;
    }
    buffer = [NSMutableData data];
    objc_setAssociatedObject(dataTask, kGQLBufferKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  [buffer appendData:data];
}
- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  NSMutableData *buffer = objc_getAssociatedObject(task, kGQLBufferKey);
  if (!buffer) return %orig;
  objc_setAssociatedObject(task, kGQLBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // Stays set: a tweak hooked inside this one (Freemote) can hold the body and re-send it after
  // this returns, and that must reach React Native rather than be held again
  objc_setAssociatedObject(task, kGQLPassthroughKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // A failed request's body isn't read, so it's dropped
  if (!error && buffer.length && [task isKindOfClass:NSURLSessionDataTask.class])
    [self URLSession:session
              dataTask:(NSURLSessionDataTask *)task
        didReceiveData:[buffer twab_responseDataForRequest:task.currentRequest]];
  %orig;
}
%end

// Block ads in following tab

// Both are Optional<class> in 31.7 through 32.1, so nil is a valid value
static void removeHeadliners(id followingViewController) {
  if (![tweakDefaults boolForKey:@"TWAdBlockEnabled"]) return;
  for (NSString *name in @[ @"headlinerManager", @"headlinerAdRenderer" ]) {
    Ivar ivar = class_getInstanceVariable(object_getClass(followingViewController), name.UTF8String);
    if (ivar) object_setIvar(followingViewController, ivar, nil);
  }
}

%hook _TtC6Twitch23FollowingViewController
// 31.x
- (instancetype)initWithThemeManager:(id)themeManager urlController:(id)urlController {
  self = %orig;
  if (self) removeHeadliners(self);
  return self;
}
// 32.0: no init is visible to ObjC any more, so clear them before the view loads
- (void)viewDidLoad {
  removeHeadliners(self);
  %orig;
}
%end

// Block update prompt

// 31.x
%hook TWAppUpdatePrompt
+ (void)startMonitoringSavantSettingsToShowPromptIfNeeded {
}
%end

// 32.0 has no TWAppUpdatePrompt class (the prompt code is Swift only), so stop the prompt where
// the app presents it (full screen modal)
%hook UIViewController
- (void)presentViewController:(UIViewController *)viewController
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
  Class promptClass = objc_getClass("_TtC6Twitch29AppUpdatePromptViewController");
  if (promptClass && [viewController isKindOfClass:promptClass]) return;
  %orig;
}
%end

%ctor {
  rebind_symbols(
      (struct rebinding[]){
          {"swift_unknownObjectWeakAssign", (void *)hook_swift_unknownObjectWeakAssign,
           (void **)&orig_swift_unknownObjectWeakAssign},
          {"swift_unknownObjectWeakLoadStrong", (void *)hook_swift_unknownObjectWeakLoadStrong,
           (void **)&orig_swift_unknownObjectWeakLoadStrong},
      },
      2);
  tweakBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"TwitchAdBlock"
                                                                       ofType:@"bundle"]];
  if (!tweakBundle)
    tweakBundle = [NSBundle
        bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/TwitchAdBlock.bundle")];
  tweakDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.level3tjg.twitchadblock"];
  if (![tweakDefaults objectForKey:@"TWAdBlockEnabled"])
    [tweakDefaults setBool:YES forKey:@"TWAdBlockEnabled"];
  TWAdBlockLog(@"--- launch: Twitch %@, TwitchAdBlock %@ (%@), %@",
               [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
               PACKAGE_VERSION, GIT_COMMIT, NSProcessInfo.processInfo.operatingSystemVersionString);
}
