#import <Foundation/Foundation.h>

// Purple Adblock's backup strategy: when a live media playlist has ad segments, ask Twitch for the
// same stream under other player types and serve the first playlist without ads instead.
@interface TWAdBlockBackups : NSObject
+ (instancetype)shared;
// Headers of the app's own token requests, reused for backup tokens
- (void)recordTokenRequest:(NSURLRequest *)request;
// A live channel master from usher, to map its media playlists back to channel and quality
- (void)recordMaster:(NSString *)text URL:(NSURL *)URL;
// Calls back with the playlist to give the player: a backup without ads, or the original text
- (void)playlistForMedia:(NSString *)text
                     URL:(NSURL *)URL
              completion:(void (^)(NSString *playlist))completion;
@end
