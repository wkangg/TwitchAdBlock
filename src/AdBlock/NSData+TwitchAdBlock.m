#import "NSData+TwitchAdBlock.h"
#import "TWAdBlockBackups.h"
#import "Log/TWAdBlockLog.h"

// object[key] if it's a mutable dictionary, else nil (GQL fields can be null)
static NSMutableDictionary *twab_dictionary(id object, NSString *key) {
  if (![object isKindOfClass:NSDictionary.class]) return nil;
  id value = object[key];
  return [value isKindOfClass:NSMutableDictionary.class] ? value : nil;
}

@implementation NSData (TwitchAdBlock)
- (NSData *)twab_requestDataForRequest:(NSURLRequest *)request {
  if (!request) return self;
  NSData *modifiedData;
  if ([request.URL.host isEqualToString:@"gql.twitch.tv"] &&
      [request.URL.path isEqualToString:@"/gql"]) {
    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:self
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) return self;
    NSArray *operations = [json isKindOfClass:NSArray.class] ? json : @[ json ];
    for (NSMutableDictionary *operation in operations) {
      if (![operation isKindOfClass:NSMutableDictionary.class]) continue;
      NSString *operationName = operation[@"operationName"];
      NSString *query = operation[@"query"];
      if (![operationName isKindOfClass:NSString.class]) operationName = nil;
      if (![query isKindOfClass:NSString.class]) query = nil;
      // StreamAccessToken, VodAccessToken, ClipAccessToken, PrefetchPlaybackAccessToken,
      // TheaterPortalPreload (31.x fetches the stream token as part of this query)
      if (![operationName containsString:@"AccessToken"] &&
          ![operationName isEqualToString:@"TheaterPortalPreload"] &&
          ![query containsString:@"PlaybackAccessToken"])
        continue;
      NSMutableDictionary *variables = operation[@"variables"];
      if (![variables isKindOfClass:NSMutableDictionary.class]) continue;
      [TWAdBlockBackups.shared recordTokenRequest:request];
      if (TWAdBlockLogEnabled()) {
        NSDictionary *tokenParams = variables[@"params"] ?: variables[@"tokenParams"];
        if (![tokenParams isKindOfClass:NSDictionary.class]) tokenParams = variables;
        NSDictionary *extensions = operation[@"extensions"];
        BOOL persisted = [extensions isKindOfClass:NSDictionary.class] && extensions[@"persistedQuery"];
        // Header names only: which ones a backup token request will need to copy
        NSMutableArray *headers = [NSMutableArray array];
        for (NSString *name in request.allHTTPHeaderFields)
          if (![name.lowercaseString isEqualToString:@"content-type"] &&
              ![name.lowercaseString isEqualToString:@"content-length"])
            [headers addObject:name];
        TWAdBlockLog(@"GQL %@ playerType=%@ platform=%@ persisted=%@ headers[%@]",
                     operationName ?: @"(unnamed)", tokenParams[@"playerType"],
                     tokenParams[@"platform"], persisted ? @"yes" : @"no",
                     [[headers sortedArrayUsingSelector:@selector(compare:)]
                         componentsJoinedByString:@","]);
      }
      NSString *platform = [NSUUID UUID].UUIDString;
      if (variables[@"platform"]) variables[@"platform"] = platform;
      for (NSString *key in @[ @"params", @"tokenParams" ]) {
        NSMutableDictionary *params = variables[key];
        if ([params isKindOfClass:NSMutableDictionary.class]) params[@"platform"] = platform;
      }
    }
    modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (error) return self;
  }
  return modifiedData ?: self;
}
- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request {
  if (!request) return self;
  NSData *modifiedData;
  if ([request.URL.host isEqualToString:@"gql.twitch.tv"] &&
      [request.URL.path isEqualToString:@"/gql"]) {
    // Most GQL responses have neither; skip parsing them (and partial chunks of them)
    static NSData *feedItemsKey, *channelSkinKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      feedItemsKey = [@"\"feedItems\"" dataUsingEncoding:NSUTF8StringEncoding];
      channelSkinKey = [@"\"channelSkin\"" dataUsingEncoding:NSUTF8StringEncoding];
    });
    NSRange all = NSMakeRange(0, self.length);
    if (![self rangeOfData:feedItemsKey options:0 range:all].length &&
        ![self rangeOfData:channelSkinKey options:0 range:all].length)
      return self;
    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:self
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) return self;
    BOOL changed = NO;
    NSArray *operations = [json isKindOfClass:NSArray.class] ? json : @[ json ];
    for (NSMutableDictionary *operation in operations) {
      NSMutableDictionary *data = twab_dictionary(operation, @"data");
      NSMutableDictionary *feedItems = twab_dictionary(data, @"feedItems");
      NSArray *edges = feedItems[@"edges"];
      if ([edges isKindOfClass:NSArray.class]) {
        // Edges or nodes can be null (partial GQL errors): keep those, drop only FeedAd nodes
        NSArray *kept = [edges filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                               id edge, NSDictionary *bindings) {
                                 id node = [edge isKindOfClass:NSDictionary.class] ? edge[@"node"] : nil;
                                 return !([node isKindOfClass:NSDictionary.class] &&
                                          [node[@"__typename"] isEqual:@"FeedAd"]);
                               }]];
        if (kept.count != edges.count) {
          feedItems[@"edges"] = kept;
          changed = YES;
        }
      }
      // ChannelSkins: a sponsor's banner under the player ("Ad", logo, call to action). A null
      // skin is what channels without a sponsorship get
      NSMutableDictionary *sponsorships =
          twab_dictionary(twab_dictionary(data, @"channel"), @"sponsorships");
      if ([sponsorships[@"channelSkin"] isKindOfClass:NSDictionary.class]) {
        TWAdBlockLog(@"SPONSOR channel skin removed");
        sponsorships[@"channelSkin"] = NSNull.null;
        changed = YES;
      }
    }
    if (!changed) return self;
    modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (error) return self;
  }
  return modifiedData ?: self;
}
@end