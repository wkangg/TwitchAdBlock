#import "NSData+TwitchAdBlock.h"

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
    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:self
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) return self;
    if ([json isKindOfClass:NSMutableArray.class]) {
      NSMutableArray *jsonArray = json;
      for (NSMutableDictionary *operation in jsonArray) {
        NSMutableDictionary *feedItems = operation[@"data"][@"feedItems"];
        if (feedItems)
          feedItems[@"edges"] = [feedItems[@"edges"]
              filteredArrayUsingPredicate:[NSPredicate
                                              predicateWithFormat:@"node.__typename != 'FeedAd'"]];
      }
    }
    modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (error) return self;
  }
  return modifiedData ?: self;
}
@end