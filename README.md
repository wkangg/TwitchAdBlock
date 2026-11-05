# TwitchAdBlock

An iOS tweak that blocks video ads in the Twitch app. It works on Twitch 31.x (tested on 31.7, 31.9 checked) and runs on jailbroken devices (rootful or rootless `.deb`) or sideloaded as a patched IPA.

This is a fork of [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock), whose maintainer no longer works on it, rewritten for Twitch 31.x.

## How it works

Twitch inserts ads into the stream itself (server-side ad insertion, or SSAI). The app's player gets HLS playlists where ad segments take the place of live ones. So the tweak works on the playlists:

1. **Playlist interception.** A `NSURLProtocol` (`TWAdBlockPlaylistProtocol`) is installed on the Amazon IVS player's URL session only. It sees every usher master playlist and every `.m3u8` media playlist from `*.ttvnw.net` / `*.live-video.net`.
2. **Ad detection.** `TWAdBlockPlaylist` parses each media playlist and spots ad breaks by their `twitch-stitched-ad` DATERANGEs, `EXT-X-CUE-OUT`, and ad segment titles and URLs (`Amazon|…`, `DCM`, `/adsquared/`, …).
3. **Backup streams.** When a break is announced, `TWAdBlockBackups` asks for a new playback token with a different player type (`mobile_feed` first, then `embed`, `popout`, `site`, `mobile_web`, …), using the app's own request headers. It builds a new usher URL, picks the variant closest to what the player is watching, and serves the first playlist without ads in place of the original.
4. **Seamless numbering.** The backup and the original count segments differently, and every SSAI break shifts the original's numbers and timestamps. To keep the player from replaying or skipping video, every playlist for a channel is renumbered onto one timeline, lined up by `#EXT-X-TWITCH-LIVE-SEQUENCE` (Twitch's own number for the live segment), or by `PROGRAM-DATE-TIME` when there isn't one.
5. **Cleanup.** Ad DATERANGEs (which drive the yellow "Ad 00:00" bar), prefetch and preload hints are removed from every playlist the player gets.

The tweak also:

- clears the client-side ad controllers (stream display ads, VAST) by hooking Swift weak references with [fishhook](https://github.com/facebook/fishhook)
- removes headliner ads from the Following tab
- filters `FeedAd` entries out of GraphQL feed responses
- turns off the app update prompt

The backup strategy draws on [Purple Adblock](https://github.com/arthurbolsoni/Purple-adblock) and on vaft ([pixeltris/TwitchAdSolutions](https://github.com/pixeltris/TwitchAdSolutions) and [ryanbr's fork](https://github.com/ryanbr/TwitchAdSolutions)).

### Limitations

- If none of the backup player types has a clean playlist, the ads play (with their markers removed).
- A break can show a second or two of ad before the swap.
- Twitch changes how it serves ads often, so expect things to break.

## Installation

### Jailbroken

Grab the rootful or rootless `.deb` from the latest [CI run](https://github.com/wkangg/TwitchAdBlock/actions/workflows/build.yml) (every push builds both) and install it with your package manager.

### Sideloaded

Build a patched IPA from your own **decrypted** Twitch IPA (see [Building an IPA](#building-an-ipa)), then sideload it with the tool you normally use (AltStore, Sideloadly, TrollStore, …).

## Settings

In Twitch, go to your account menu → **Settings**, then the **TwitchAdBlock** row at the bottom.

| Setting | Default | What it does |
| --- | --- | --- |
| Ad Block | On | Turns ad blocking on or off |
| Ad Detection Log | Off | Records the stream tokens, playlists and ad breaks the player sees |
| View Log | | Shows the end of the log and lets you share the whole file |

The log lives at `Library/Caches/TwitchAdBlock.log` in the app's container (capped at 25 MB). Each entry also goes to the device log as `[TwitchAdblock] …`. To report a problem, turn the log on, watch until it happens, then share the log along with roughly when it happened.

## Building

The tweak uses [Theos](https://theos.dev) and Logos.

```sh
git clone --recursive https://github.com/wkangg/TwitchAdBlock
cd TwitchAdBlock

make package                                # rootful .deb
THEOS_PACKAGE_SCHEME=rootless make package  # rootless .deb
```

### Building an IPA

Sideloaded builds need [theos-jailed](https://github.com/level3tjg/theos-jailed) and a decrypted IPA:

```sh
make package SIDELOADED=1 FINALPACKAGE=1 IPA=/path/to/Twitch.ipa APP_VERSION=31.9
```

Set `TW_BUNDLE_ID=tv.twitch.beta` when patching the beta app.

You can also let GitHub Actions do it. Run the **CI** workflow by hand with a direct link to the decrypted IPA:

```sh
gh workflow run build.yml -R wkangg/TwitchAdBlock --ref master -f ipa_url=<url>
```

Optional inputs: `bundle_freemote` (also inject [Freemote](https://github.com/wkangg/Freemote) for BTTV, 7TV and FFZ emotes) and `create_release` (save the IPA to a draft release).

## Project layout

| File | Purpose |
| --- | --- |
| `Tweak.x` | Hooks: IVS session setup, GraphQL rewrites, client-side ad controllers, Following tab, update prompt |
| `NSData+TwitchAdBlock.m` | GraphQL request and response rewriting |
| `TWAdBlockPlaylistProtocol.m` | `NSURLProtocol` that intercepts master and media playlists |
| `TWAdBlockPlaylist.m` | HLS parsing: ad detection, variants, cleanup |
| `TWAdBlockBackups.m` | Backup tokens, variant matching, sequence alignment |
| `TWAdBlockLog.m`, `TWAdBlockLogViewController.m` | Debug log and its viewer |
| `Settings.x`, `TWAdBlockSettingsViewController.m` | Settings entry and screen |
| `Sideloaded.x` | Sideload-only fixes: original bundle ID (for the low-latency player), keychain and app group containers |
| `include/` | Headers for the Twitch, TwitchCoreUI, TwitchKit and IVS classes that get hooked |

## License

[MIT](LICENSE)
