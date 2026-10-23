#import <Foundation/Foundation.h>

// HLS parsing for Twitch playlists. Ad detection follows Purple Adblock's findings
// (github.com/arthurbolsoni/Purple-adblock, Apache-2.0): live segments are titled "live", ad
// segments carry another title (Amazon|…, DCM, FT|…) inside a twitch-stitched-ad DATERANGE;
// twitch-maf-ad ranges are client-side ad slots. Extra markers from ryanbr's vaft fork
// (github.com/ryanbr/TwitchAdSolutions): any twitch-stitched-* class and
// EXT-X-CUE-OUT announce a break; segment URLs with /adsquared/, /_404/ or /processing are ads.

@interface TWAdBlockMediaPlaylist : NSObject
@property(nonatomic, readonly) NSInteger sequence;
@property(nonatomic, readonly) NSInteger liveSegments;
@property(nonatomic, readonly) NSInteger adSegments;
// Break announcements: twitch-stitched-* ranges, EXT-X-CUE-OUT
@property(nonatomic, readonly) NSInteger adRanges;
@property(nonatomic, readonly) NSInteger mafAdRanges;
// twitch-ad-quartile ranges (vaft counts them as not an ad on their own)
@property(nonatomic, readonly) NSInteger quartileRanges;
@property(nonatomic, readonly, copy) NSString *rollType;
@property(nonatomic, readonly, copy) NSString *adTitle;
@property(nonatomic, readonly, copy) NSArray<NSString *> *adSegmentURLs;
// Date and duration of the first segment, to line up two playlists of the same stream
@property(nonatomic, readonly) NSDate *firstSegmentDate;
@property(nonatomic, readonly) NSTimeInterval segmentDuration;
+ (instancetype)playlistWithText:(NSString *)text;
- (NSString *)stateDescription;
@end

@interface TWAdBlockVariant : NSObject
@property(nonatomic, readonly) NSURL *URL;
@property(nonatomic, readonly, copy) NSString *video;  // "chunked", "720p60", …
@property(nonatomic, readonly, copy) NSString *resolution;
@property(nonatomic, readonly) NSInteger bandwidth;
@property(nonatomic, readonly, copy) NSString *codecFamily;  // "avc", "hevc", "av1" or nil
+ (NSArray<TWAdBlockVariant *> *)variantsInMaster:(NSString *)text;
// Same codec family when there is one (a codec switch inside one playlist shows nothing), then
// same video name, else same resolution, else closest bandwidth
- (TWAdBlockVariant *)closestIn:(NSArray<TWAdBlockVariant *> *)variants;
@end

// Value of NAME=… or NAME="…" in an attribute line
NSString *TWAdBlockAttribute(NSString *line, NSString *name);

BOOL TWAdBlockHasAdMarkers(NSString *text);

// Drops ad DATERANGEs (so the app shows no ad UI) and, when there were any, low-latency prefetch
// lines; unless NSNotFound, sets MEDIA-SEQUENCE
NSString *TWAdBlockCleanPlaylist(NSString *text, NSInteger sequence);
