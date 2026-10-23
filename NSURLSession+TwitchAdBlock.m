#import "NSURLSession+TwitchAdBlock.h"
#import "Config.h"

extern NSUserDefaults *tweakDefaults;

NSString *TWAdBlockProxyAddress(void) {
  NSString *custom = [[tweakDefaults stringForKey:@"TWAdBlockProxy"]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"] && custom.length) return custom;
  return PROXY_ADDR;
}

@implementation NSURLSession (TwitchAdBlock)
- (NSURLSession *)twab_proxySessionWithAddress:(NSString *)address {
  NSArray<NSString *> *addressComponents = [address componentsSeparatedByString:@":"];
  NSString *host = addressComponents.firstObject;
  // Unusable address: send the request unproxied rather than crash
  if (!host.length) return self;
  NSInteger port = addressComponents.count > 1 ? addressComponents[1].integerValue : 0;
  NSURLSessionConfiguration *configuration =
      self.configuration ?: NSURLSessionConfiguration.defaultSessionConfiguration;
  configuration.connectionProxyDictionary = @{
    @"HTTPSEnable" : @YES,
    @"HTTPSProxy" : host,
    @"HTTPSPort" : @(port > 0 ? port : 8080),
  };
  return [NSURLSession sessionWithConfiguration:configuration
                                       delegate:self.delegate
                                  delegateQueue:self.delegateQueue];
}
@end
