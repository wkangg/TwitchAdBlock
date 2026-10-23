#import "TWAdBlockPlaylist.h"

NSString *TWAdBlockAttribute(NSString *line, NSString *name) {
  NSString *pattern = [NSString stringWithFormat:@"(^|[:,])%@=(\"[^\"]*\"|[^,]*)", name];
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                         options:0
                                                                           error:nil];
  NSTextCheckingResult *match = [regex firstMatchInString:line
                                                  options:0
                                                    range:NSMakeRange(0, line.length)];
  if (!match) return nil;
  NSString *value = [line substringWithRange:[match rangeAtIndex:2]];
  return [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
}

static NSArray<NSString *> *lines(NSString *text) {
  return [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

static NSDate *parseDate(NSString *string) {
  static NSISO8601DateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions =
        NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
  });
  @synchronized(formatter) {
    return [formatter dateFromString:string];
  }
}

// twitch-stitched-ad and newer twitch-stitched-* variants, and twitch-trigger (vaft: only ever seen
// during breaks)
static BOOL isBreakClass(NSString *rangeClass) {
  return [rangeClass hasPrefix:@"twitch-stitched"] || [rangeClass isEqualToString:@"twitch-trigger"];
}

static BOOL isAdSegmentURL(NSString *URL) {
  return [URL containsString:@"/adsquared/"] || [URL containsString:@"/_404/"] ||
         [URL containsString:@"/processing"];
}

static BOOL isAdDateRange(NSString *line) {
  if (![line hasPrefix:@"#EXT-X-DATERANGE:"]) return NO;
  NSString *rangeClass = TWAdBlockAttribute(line, @"CLASS");
  // Purple F-20: with these gone the app's ad UI doesn't start
  return isBreakClass(rangeClass) || [rangeClass isEqualToString:@"twitch-ad-quartile"] ||
         [rangeClass isEqualToString:@"twitch-maf-ad"];
}

@implementation TWAdBlockMediaPlaylist
+ (instancetype)playlistWithText:(NSString *)text {
  TWAdBlockMediaPlaylist *playlist = [[self alloc] init];
  playlist->_sequence = NSNotFound;
  NSDate *pendingDate;
  NSMutableArray<NSString *> *adSegmentURLs = [NSMutableArray array];
  NSString *pendingTitle;
  for (NSString *line in lines(text)) {
    if (pendingTitle && line.length && ![line hasPrefix:@"#"]) {
      if ([pendingTitle isEqualToString:@"live"] && !isAdSegmentURL(line)) {
        playlist->_liveSegments++;
      } else {
        playlist->_adSegments++;
        [adSegmentURLs addObject:line];
        if (!playlist->_adTitle) playlist->_adTitle = [pendingTitle componentsSeparatedByString:@"|"].firstObject;
      }
      pendingTitle = nil;
    } else if ([line hasPrefix:@"#EXT-X-PROGRAM-DATE-TIME:"]) {
      pendingDate = parseDate([line substringFromIndex:25]);
    } else if ([line hasPrefix:@"#EXTINF:"]) {
      NSString *info = [line substringFromIndex:8];
      NSRange comma = [info rangeOfString:@","];
      pendingTitle = comma.location == NSNotFound ? @"" : [info substringFromIndex:comma.location + 1];
      if (!playlist->_firstSegmentDate && pendingDate) {
        playlist->_firstSegmentDate = pendingDate;
        playlist->_segmentDuration = info.doubleValue;
      }
    } else if ([line hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
      playlist->_sequence = [line substringFromIndex:22].integerValue;
    } else if ([line hasPrefix:@"#EXT-X-CUE-OUT"]) {
      playlist->_adRanges++;
    } else if ([line hasPrefix:@"#EXT-X-DATERANGE:"]) {
      NSString *rangeClass = TWAdBlockAttribute(line, @"CLASS");
      if (isBreakClass(rangeClass)) {
        playlist->_adRanges++;
        if (!playlist->_rollType)
          playlist->_rollType = TWAdBlockAttribute(line, @"X-TV-TWITCH-AD-ROLL-TYPE");
      } else if ([rangeClass isEqualToString:@"twitch-maf-ad"]) {
        playlist->_mafAdRanges++;
      }
    }
  }
  playlist->_adSegmentURLs = adSegmentURLs;
  return playlist;
}

- (NSString *)stateDescription {
  if (self.adSegments)
    return [NSString stringWithFormat:@"ADS %ld/%ld title=%@ roll=%@", (long)self.adSegments,
                                      (long)(self.adSegments + self.liveSegments), self.adTitle,
                                      self.rollType ?: @"?"];
  if (self.adRanges)
    return [NSString stringWithFormat:@"announced (ad range, roll=%@)", self.rollType ?: @"?"];
  if (self.mafAdRanges) return @"maf-ad slot (client-side ad)";
  return @"clean";
}
@end

// vaft's videoCodecFamily: any entry of CODECS, case-insensitive
static NSString *codecFamily(NSString *codecs) {
  for (NSString *part in [codecs.lowercaseString componentsSeparatedByString:@","]) {
    NSString *codec = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([codec hasPrefix:@"avc"]) return @"avc";
    if ([codec hasPrefix:@"hev"] || [codec hasPrefix:@"hvc"]) return @"hevc";
    if ([codec hasPrefix:@"av0"]) return @"av1";
  }
  return nil;
}

@implementation TWAdBlockVariant
+ (NSArray<TWAdBlockVariant *> *)variantsInMaster:(NSString *)text {
  NSMutableArray *variants = [NSMutableArray array];
  TWAdBlockVariant *pending;
  for (NSString *line in lines(text)) {
    if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
      pending = [[self alloc] init];
      pending->_video = TWAdBlockAttribute(line, @"VIDEO");
      pending->_resolution = TWAdBlockAttribute(line, @"RESOLUTION");
      pending->_bandwidth = TWAdBlockAttribute(line, @"BANDWIDTH").integerValue;
      pending->_codecFamily = codecFamily(TWAdBlockAttribute(line, @"CODECS"));
    } else if (pending && line.length && ![line hasPrefix:@"#"]) {
      pending->_URL = [NSURL URLWithString:line];
      if (pending->_URL) [variants addObject:pending];
      pending = nil;
    }
  }
  return variants;
}

- (TWAdBlockVariant *)closestIn:(NSArray<TWAdBlockVariant *> *)variants {
  if (self.codecFamily) {
    NSPredicate *sameFamily = [NSPredicate predicateWithFormat:@"codecFamily == %@", self.codecFamily];
    NSArray *matching = [variants filteredArrayUsingPredicate:sameFamily];
    if (matching.count) variants = matching;
  }
  for (TWAdBlockVariant *variant in variants)
    if (self.video && [variant.video isEqualToString:self.video]) return variant;
  for (TWAdBlockVariant *variant in variants)
    if (self.resolution && [variant.resolution isEqualToString:self.resolution]) return variant;
  TWAdBlockVariant *closest;
  for (TWAdBlockVariant *variant in variants) {
    if ([variant.video isEqualToString:@"audio_only"]) continue;
    if (!closest || labs(variant.bandwidth - self.bandwidth) < labs(closest.bandwidth - self.bandwidth))
      closest = variant;
  }
  return closest;
}
@end

BOOL TWAdBlockHasAdMarkers(NSString *text) {
  return [text containsString:@"twitch-stitched"] || [text containsString:@"twitch-ad-quartile"] ||
         [text containsString:@"twitch-maf-ad"] || [text containsString:@"twitch-trigger"] ||
         [text containsString:@"#EXT-X-CUE-OUT"];
}

NSString *TWAdBlockCleanPlaylist(NSString *text, NSInteger sequence) {
  // vaft: no low-latency prefetch during ads, or the player can fetch and show ad segments the
  // playlist doesn't list yet
  BOOL dropPrefetch = TWAdBlockHasAdMarkers(text);
  NSMutableArray *output = [NSMutableArray array];
  for (NSString *line in lines(text)) {
    if (isAdDateRange(line)) continue;
    if (dropPrefetch &&
        ([line hasPrefix:@"#EXT-X-TWITCH-PREFETCH:"] || [line hasPrefix:@"#EXT-X-PRELOAD-HINT:"]))
      continue;
    if (sequence != NSNotFound && [line hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
      [output addObject:[NSString stringWithFormat:@"#EXT-X-MEDIA-SEQUENCE:%ld", (long)sequence]];
      continue;
    }
    [output addObject:line];
  }
  return [output componentsJoinedByString:@"\n"];
}
