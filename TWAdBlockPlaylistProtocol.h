#import <Foundation/Foundation.h>

// Sits in front of the IVS player's playlist requests (usher masters and media playlists).
// For now it only passes them through and logs what it sees: tokens, variants, ad breaks.
@interface TWAdBlockPlaylistProtocol : NSURLProtocol
+ (BOOL)isPlayerSessionDelegate:(id)delegate;
+ (NSURLSessionConfiguration *)configurationByAddingProtocol:(NSURLSessionConfiguration *)configuration;
@end
