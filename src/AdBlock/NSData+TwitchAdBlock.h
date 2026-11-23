#import <Foundation/Foundation.h>

@interface NSData (TwitchAdBlock)
// A GQL token request: keeps its headers for backup tokens and logs it
- (void)twab_recordTokenRequest:(NSURLRequest *)request;
- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request;
@end