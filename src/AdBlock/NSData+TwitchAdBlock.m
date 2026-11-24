#import "NSData+TwitchAdBlock.h"
#import "TWAdBlockBackups.h"
#import "Log/TWAdBlockLog.h"

extern NSUserDefaults *tweakDefaults;

// object[key] if it's a mutable dictionary, else nil (GQL fields can be null)
static NSMutableDictionary *twab_dictionary(id object, NSString *key) {
  if (![object isKindOfClass:NSDictionary.class]) return nil;
  id value = object[key];
  return [value isKindOfClass:NSMutableDictionary.class] ? value : nil;
}

@implementation NSData (TwitchAdBlock)
- (void)twab_recordTokenRequest:(NSURLRequest *)request {
  if (![request.URL.host isEqualToString:@"gql.twitch.tv"] ||
      ![request.URL.path isEqualToString:@"/gql"])
    return;
  id json = [NSJSONSerialization JSONObjectWithData:self options:0 error:nil];
  if (!json) return;
  NSArray *operations = [json isKindOfClass:NSArray.class] ? json : @[ json ];
  for (NSDictionary *operation in operations) {
    if (![operation isKindOfClass:NSDictionary.class]) continue;
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
    NSDictionary *variables = operation[@"variables"];
    if (![variables isKindOfClass:NSDictionary.class]) continue;
    [TWAdBlockBackups.shared recordTokenRequest:request];
    if (!TWAdBlockLogEnabled()) continue;
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
                 operationName ?: @"(unnamed)", tokenParams[@"playerType"], tokenParams[@"platform"],
                 persisted ? @"yes" : @"no",
                 [[headers sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
  }
}
- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request {
  if (!request) return self;
  NSData *modifiedData;
  if ([request.URL.host isEqualToString:@"gql.twitch.tv"] &&
      [request.URL.path isEqualToString:@"/gql"]) {
    // Most GQL responses have neither; skip parsing them (and partial chunks of them)
    static NSData *feedItemsKey, *channelSkinKey, *turboUpsellQuery;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      feedItemsKey = [@"\"feedItems\"" dataUsingEncoding:NSUTF8StringEncoding];
      channelSkinKey = [@"\"channelSkin\"" dataUsingEncoding:NSUTF8StringEncoding];
      turboUpsellQuery = [@"TurboUpsellButton" dataUsingEncoding:NSUTF8StringEncoding];
    });
    // Feed ads go with Ad Block; the sponsor banner and the Turbo button with Hide Promotions
    BOOL blockAds = [tweakDefaults boolForKey:@"TWAdBlockEnabled"];
    BOOL hidePromotions = [tweakDefaults boolForKey:@"TWAdBlockHidePromotions"];
    // The "Try Ad-Free" (Turbo upsell) query's positions in the request. Matched by the request,
    // since the Turbo tray fetches the same subscriptionProduct and must keep its offers, and by
    // position, since Apollo batches queries and a response lines up with its request
    NSMutableIndexSet *turboUpsell = [NSMutableIndexSet indexSet];
    NSData *body = request.HTTPBody;
    if (hidePromotions && body &&
        [body rangeOfData:turboUpsellQuery options:0 range:NSMakeRange(0, body.length)].length) {
      id requestJSON = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
      NSArray *requests = [requestJSON isKindOfClass:NSArray.class] ? requestJSON
                          : requestJSON                             ? @[ requestJSON ]
                                                                    : @[];
      [requests enumerateObjectsUsingBlock:^(id operation, NSUInteger i, BOOL *stop) {
        if ([operation isKindOfClass:NSDictionary.class] &&
            [operation[@"operationName"] isEqual:@"TurboUpsellButton"])
          [turboUpsell addIndex:i];
      }];
    }
    NSRange all = NSMakeRange(0, self.length);
    if (!turboUpsell.count &&
        !(blockAds && [self rangeOfData:feedItemsKey options:0 range:all].length) &&
        !(hidePromotions && [self rangeOfData:channelSkinKey options:0 range:all].length))
      return self;
    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:self
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) return self;
    BOOL changed = NO;
    NSArray *operations = [json isKindOfClass:NSArray.class] ? json : @[ json ];
    for (NSUInteger i = 0; i < operations.count; i++) {
      NSMutableDictionary *data = twab_dictionary(operations[i], @"data");
      NSMutableDictionary *feedItems = twab_dictionary(data, @"feedItems");
      NSArray *edges = feedItems[@"edges"];
      if (blockAds && [edges isKindOfClass:NSArray.class]) {
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
      if (hidePromotions && [sponsorships[@"channelSkin"] isKindOfClass:NSDictionary.class]) {
        TWAdBlockLog(@"SPONSOR channel skin removed");
        sponsorships[@"channelSkin"] = NSNull.null;
        changed = YES;
      }
      // useTurboUpsell shows the button only when an offer is eligible; with none it hides it
      // (subscriptionProduct.self, the user's own Turbo, is left alone)
      NSMutableDictionary *product = twab_dictionary(data, @"subscriptionProduct");
      if ([turboUpsell containsIndex:i] && [product[@"offers"] isKindOfClass:NSArray.class] &&
          [product[@"offers"] count]) {
        TWAdBlockLog(@"TURBO upsell offers removed");
        product[@"offers"] = @[];
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