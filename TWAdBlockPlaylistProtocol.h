#import <Foundation/Foundation.h>

// Sits in front of the IVS player's playlist requests (usher masters and media playlists): logs
// what it sees, and swaps a media playlist with ads for a clean backup (TWAdBlockBackups).
@interface TWAdBlockPlaylistProtocol : NSURLProtocol
+ (BOOL)isPlayerSessionDelegate:(id)delegate;
+ (NSURLSessionConfiguration *)configurationByAddingProtocol:(NSURLSessionConfiguration *)configuration;
@end
