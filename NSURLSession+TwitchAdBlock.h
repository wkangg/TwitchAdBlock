#include <Foundation/Foundation.h>

// Custom proxy if enabled and non-empty, otherwise the default
NSString *TWAdBlockProxyAddress(void);

@interface NSURLSession (TwitchAdBlock)
- (NSURLSession *)twab_proxySessionWithAddress:(NSString *)address;
@end
