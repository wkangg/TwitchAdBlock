#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <rootless.h>

#import "AdBlock/NSData+TwitchAdBlock.h"
#import "Log/TWAdBlockLog.h"
#import "AdBlock/TWAdBlockPlaylistProtocol.h"
#import "fishhook/fishhook.h"

// React Native's fetch handler (React.framework); declared so the hook can message self under ARC
@interface RCTHTTPRequestHandler : NSObject <NSURLSessionDataDelegate>
@end
