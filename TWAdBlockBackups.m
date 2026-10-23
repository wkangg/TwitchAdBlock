#import "TWAdBlockBackups.h"
#import "TWAdBlockLog.h"
#import "TWAdBlockPlaylist.h"

// The app's own token query (Twitch 31.x, PrefetchPlaybackAccessToken), sent as full text
static NSString *const kTokenQuery =
    @"query PrefetchPlaybackAccessToken($login: String!, $playerType: String!, $platform: String!) {\n"
    @"  streamPlaybackAccessToken(channelName: $login, params: {platform: $platform, playerBackend: "
    @"\"mediaplayer\", playerType: $playerType}) {\n"
    @"    value\n    signature\n    expiresAt\n"
    @"    authorization {\n      isForbidden\n      forbiddenReasonCode\n    }\n  }\n"
    @"  user(login: $login) {\n    id\n    login\n    profileImageURL(width: 600)\n  }\n}";

// mobile_feed (the app's feed previews) first: in testing on 31.7 it was the only clean type during
// prerolls, at full quality. Then Purple's order (F-09): the 720p types, then the 360p-only ones;
// autoplay was usually clean during prerolls on the web (B-052).
static NSArray<NSString *> *backupPlayerTypes(void) {
  return @[
    @"mobile_feed", @"embed", @"popout", @"site", @"mobile_web", @"frontpage",
    @"picture-by-picture", @"autoplay"
  ];
}

static NSString *platformForPlayerType(NSString *playerType) {
  if ([playerType isEqualToString:@"autoplay"]) return @"android";
  if ([playerType hasPrefix:@"mobile_"] && ![playerType isEqualToString:@"mobile_web"]) return @"ios";
  return @"web";
}

static const NSInteger kMaxTypesPerPoll = 3;
static const NSTimeInterval kPollBudget = 3.0;
static const NSTimeInterval kBackupLifetime = 5 * 60;

static NSString *channelForMaster(NSURL *URL) {
  if (![URL.host isEqualToString:@"usher.ttvnw.net"]) return nil;
  NSArray<NSString *> *parts = URL.path.pathComponents;
  NSUInteger hls = [parts indexOfObject:@"hls"];
  if (hls == NSNotFound || hls + 1 >= parts.count || ![parts containsObject:@"channel"]) return nil;
  return parts[hls + 1].stringByDeletingPathExtension.lowercaseString;
}

static NSString *queryEncode(NSString *value) {
  NSMutableCharacterSet *allowed = NSCharacterSet.URLQueryAllowedCharacterSet.mutableCopy;
  [allowed removeCharactersInString:@"&=+?#"];
  return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

@interface TWAdBlockMediaInfo : NSObject
@property(nonatomic, copy) NSString *channel;
@property(nonatomic, strong) TWAdBlockVariant *variant;
@end
@implementation TWAdBlockMediaInfo
@end

@interface TWAdBlockBackupMaster : NSObject
@property(nonatomic, copy) NSArray<TWAdBlockVariant *> *variants;
@property(nonatomic, strong) NSDate *date;
@end
@implementation TWAdBlockBackupMaster
@end

@interface TWAdBlockBackups ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *tokenHeaders;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *masterURLs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, TWAdBlockMediaInfo *> *media;
@property(nonatomic, strong) NSMutableDictionary<NSString *, TWAdBlockBackupMaster *> *backupMasters;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lastCleanType;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *nextTypeIndex;
@property(nonatomic, strong) NSMutableSet<NSString *> *requestedAds;
@end

@implementation TWAdBlockBackups
+ (instancetype)shared {
  static TWAdBlockBackups *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[self alloc] init];
  });
  return shared;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.level3tjg.twitchadblock.backups", DISPATCH_QUEUE_SERIAL);
    NSURLSessionConfiguration *configuration =
        NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 4;
    _session = [NSURLSession sessionWithConfiguration:configuration];
    _masterURLs = [NSMutableDictionary dictionary];
    _media = [NSMutableDictionary dictionary];
    _backupMasters = [NSMutableDictionary dictionary];
    _lastCleanType = [NSMutableDictionary dictionary];
    _nextTypeIndex = [NSMutableDictionary dictionary];
    _requestedAds = [NSMutableSet set];
  }
  return self;
}

- (void)recordTokenRequest:(NSURLRequest *)request {
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  [request.allHTTPHeaderFields
      enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        NSString *lower = name.lowercaseString;
        if ([@[ @"content-length", @"content-type", @"sentry-trace", @"baggage" ]
                containsObject:lower])
          return;
        headers[name] = value;
      }];
  if (!headers.count) return;
  dispatch_async(self.queue, ^{
    if (!self.tokenHeaders) TWAdBlockLog(@"BACKUP token headers captured (%lu)", (unsigned long)headers.count);
    self.tokenHeaders = headers;
  });
}

- (void)recordMaster:(NSString *)text URL:(NSURL *)URL {
  NSString *channel = channelForMaster(URL);
  if (!channel) return;
  NSArray<TWAdBlockVariant *> *variants = [TWAdBlockVariant variantsInMaster:text];
  dispatch_async(self.queue, ^{
    self.masterURLs[channel] = URL;
    for (TWAdBlockVariant *variant in variants) {
      TWAdBlockMediaInfo *info = [[TWAdBlockMediaInfo alloc] init];
      info.channel = channel;
      info.variant = variant;
      self.media[variant.URL.path] = info;
    }
  });
}

- (void)playlistForMedia:(NSString *)text
                     URL:(NSURL *)URL
              completion:(void (^)(NSString *playlist))completion {
  TWAdBlockMediaPlaylist *playlist = [TWAdBlockMediaPlaylist playlistWithText:text];
  // Even when ads pass through, the player gets no ad markers, so the ad UI never starts
  NSString *original = TWAdBlockHasAdMarkers(text) ? TWAdBlockCleanPlaylist(text, NSNotFound) : text;
  // Swap from the announcing poll on (an ad range before any ad segment), like vaft does:
  // midroll ads still played for a few seconds when the swap waited for ad-titled segments
  if (!playlist.adSegments && !playlist.adRanges) return completion(original);
  dispatch_async(self.queue, ^{
    if (![playlist.rollType isEqualToString:@"MIDROLL"]) [self fetchOneAdSegment:playlist URL:URL];
    TWAdBlockMediaInfo *info = self.media[URL.path];
    if (!info) {
      TWAdBlockLog(@"BACKUP no master known for this playlist, passing ads through");
      return completion(original);
    }
    NSMutableArray<NSString *> *types = [NSMutableArray array];
    NSString *lastClean = self.lastCleanType[info.channel];
    if (lastClean) [types addObject:lastClean];
    NSArray<NSString *> *all = backupPlayerTypes();
    NSInteger start = self.nextTypeIndex[info.channel].integerValue;
    for (NSUInteger i = 0; i < all.count && types.count < kMaxTypesPerPoll; i++) {
      NSString *type = all[(start + i) % all.count];
      if (![types containsObject:type]) [types addObject:type];
    }
    [self tryTypes:types
               index:0
                info:info
            playlist:playlist
            deadline:[NSDate dateWithTimeIntervalSinceNow:kPollBudget]
          completion:^(NSString *backup) {
            completion(backup ?: original);
          }];
  });
}

// vaft: during a preroll the player never loads the ad (it gets a backup), so load one ad segment
// per poll ourselves; the preroll otherwise doesn't count as watched. Runs on self.queue.
- (void)fetchOneAdSegment:(TWAdBlockMediaPlaylist *)playlist URL:(NSURL *)URL {
  for (NSString *string in playlist.adSegmentURLs) {
    NSURL *segment = [NSURL URLWithString:string relativeToURL:URL].absoluteURL;
    if (!segment || [self.requestedAds containsObject:segment.absoluteString]) continue;
    if (self.requestedAds.count > 500) [self.requestedAds removeAllObjects];
    [self.requestedAds addObject:segment.absoluteString];
    [[self.session dataTaskWithURL:segment] resume];
    return;
  }
}

// Runs on self.queue
- (void)tryTypes:(NSArray<NSString *> *)types
           index:(NSUInteger)index
            info:(TWAdBlockMediaInfo *)info
        playlist:(TWAdBlockMediaPlaylist *)playlist
        deadline:(NSDate *)deadline
      completion:(void (^)(NSString *backup))completion {
  if (index >= types.count || deadline.timeIntervalSinceNow <= 0) {
    TWAdBlockLog(@"BACKUP %@: no clean backup this poll, passing ads through", info.channel);
    return completion(nil);
  }
  NSString *type = types[index];
  NSArray<NSString *> *all = backupPlayerTypes();
  NSUInteger position = [all indexOfObject:type];
  if (position != NSNotFound) self.nextTypeIndex[info.channel] = @((position + 1) % all.count);
  void (^next)(void) = ^{
    [self tryTypes:types index:index + 1 info:info playlist:playlist deadline:deadline completion:completion];
  };
  [self backupVariantForChannel:info.channel
                     playerType:type
                        variant:info.variant
                     completion:^(TWAdBlockVariant *variant) {
                       if (!variant) return next();
                       [self fetch:[NSURLRequest requestWithURL:variant.URL]
                           completion:^(NSData *data, NSInteger status) {
                             NSString *text = data ? [[NSString alloc] initWithData:data
                                                                           encoding:NSUTF8StringEncoding]
                                                   : nil;
                             TWAdBlockMediaPlaylist *backup =
                                 text ? [TWAdBlockMediaPlaylist playlistWithText:text] : nil;
                             if (!backup || backup.adSegments || !backup.liveSegments) {
                               TWAdBlockLog(@"BACKUP %@ %@: %@", info.channel, type,
                                            backup ? backup.stateDescription
                                                   : [NSString stringWithFormat:@"playlist failed (%ld)",
                                                                                (long)status]);
                               // A new token next time: a backup with ads keeps its own pod
                               [self.backupMasters
                                   removeObjectForKey:[self keyForChannel:info.channel type:type]];
                               if ([self.lastCleanType[info.channel] isEqualToString:type])
                                 [self.lastCleanType removeObjectForKey:info.channel];
                               return next();
                             }
                             NSInteger sequence = [self sequenceFor:backup alignedTo:playlist];
                             TWAdBlockLog(@"BACKUP %@ %@ %@: clean, serving seq %ld (own %ld)",
                                          info.channel, type, variant.video ?: variant.resolution,
                                          (long)sequence, (long)backup.sequence);
                             self.lastCleanType[info.channel] = type;
                             completion(TWAdBlockCleanPlaylist(text, sequence));
                           }];
                     }];
}

// Purple F-23: number the backup's segments as the original playlist numbers the same moment
- (NSInteger)sequenceFor:(TWAdBlockMediaPlaylist *)backup alignedTo:(TWAdBlockMediaPlaylist *)original {
  if (original.sequence == NSNotFound || !original.firstSegmentDate || !backup.firstSegmentDate)
    return NSNotFound;
  NSTimeInterval duration = original.segmentDuration > 0 ? original.segmentDuration : 2;
  NSTimeInterval offset = [backup.firstSegmentDate timeIntervalSinceDate:original.firstSegmentDate];
  return original.sequence + (NSInteger)llround(offset / duration);
}

- (NSString *)keyForChannel:(NSString *)channel type:(NSString *)type {
  return [NSString stringWithFormat:@"%@|%@", channel, type];
}

// Runs on self.queue; calls back on self.queue
- (void)backupVariantForChannel:(NSString *)channel
                     playerType:(NSString *)type
                        variant:(TWAdBlockVariant *)variant
                     completion:(void (^)(TWAdBlockVariant *variant))completion {
  NSString *key = [self keyForChannel:channel type:type];
  TWAdBlockBackupMaster *cached = self.backupMasters[key];
  if (cached && -cached.date.timeIntervalSinceNow < kBackupLifetime)
    return completion([variant closestIn:cached.variants]);
  NSURL *masterURL = self.masterURLs[channel];
  NSDictionary *headers = self.tokenHeaders;
  if (!masterURL || !headers) {
    TWAdBlockLog(@"BACKUP %@: %@", channel, headers ? @"no master URL" : @"no token headers yet");
    return completion(nil);
  }
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
  request.HTTPMethod = @"POST";
  request.allHTTPHeaderFields = headers;
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
    @"operationName" : @"PrefetchPlaybackAccessToken",
    @"query" : kTokenQuery,
    @"variables" : @{@"login" : channel, @"playerType" : type, @"platform" : platformForPlayerType(type)}
  }
                                                     options:0
                                                       error:nil];
  [self fetch:request
      completion:^(NSData *data, NSInteger status) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *payload = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        // vaft: embed answers without the data wrapper
        if (![payload isKindOfClass:NSDictionary.class]) payload = json;
        NSDictionary *token = [payload isKindOfClass:NSDictionary.class]
                                  ? payload[@"streamPlaybackAccessToken"]
                                  : nil;
        if (![token isKindOfClass:NSDictionary.class] || ![token[@"value"] isKindOfClass:NSString.class] ||
            ![token[@"signature"] isKindOfClass:NSString.class]) {
          NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
          TWAdBlockLog(@"BACKUP %@ %@: token failed (%ld) %@", channel, type, (long)status,
                       body.length > 300 ? [body substringToIndex:300] : body);
          return completion(nil);
        }
        NSURLComponents *components = [NSURLComponents componentsWithURL:masterURL
                                                 resolvingAgainstBaseURL:NO];
        NSDictionary *replace = @{
          @"sig" : token[@"signature"],
          @"token" : token[@"value"],
          @"player_type" : type,
          @"platform" : platformForPlayerType(type),
          @"play_session_id" : [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-"
                                                                                  withString:@""]
                                   .lowercaseString,
        };
        NSMutableArray *items = [NSMutableArray array];
        for (NSURLQueryItem *item in components.queryItems) {
          if (replace[item.name] || [item.name isEqualToString:@"parent_domains"]) continue;
          [items addObject:[NSString stringWithFormat:@"%@=%@", item.name, queryEncode(item.value ?: @"")]];
        }
        [replace enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
          [items addObject:[NSString stringWithFormat:@"%@=%@", name, queryEncode(value)]];
        }];
        components.percentEncodedQuery = [items componentsJoinedByString:@"&"];
        [self fetch:[NSURLRequest requestWithURL:components.URL]
            completion:^(NSData *masterData, NSInteger masterStatus) {
              NSString *text = masterData ? [[NSString alloc] initWithData:masterData
                                                                  encoding:NSUTF8StringEncoding]
                                          : nil;
              NSArray<TWAdBlockVariant *> *variants = text ? [TWAdBlockVariant variantsInMaster:text] : nil;
              if (!variants.count) {
                TWAdBlockLog(@"BACKUP %@ %@: master failed (%ld)", channel, type, (long)masterStatus);
                return completion(nil);
              }
              TWAdBlockBackupMaster *master = [[TWAdBlockBackupMaster alloc] init];
              master.variants = variants;
              master.date = [NSDate date];
              self.backupMasters[key] = master;
              completion([variant closestIn:variants]);
            }];
      }];
}

// Calls back on self.queue with the body of a 200 response (else nil) and the status (0 on error)
- (void)fetch:(NSURLRequest *)request completion:(void (^)(NSData *data, NSInteger status))completion {
  [[self.session dataTaskWithRequest:request
                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                     NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                                            ? ((NSHTTPURLResponse *)response).statusCode
                                            : 0;
                     if (error) status = 0;
                     dispatch_async(self.queue, ^{
                       completion(status == 200 ? data : nil, status);
                     });
                   }] resume];
}
@end
