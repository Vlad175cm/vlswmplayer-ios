# vlswmplayer for iOS

English | [Русский](README.ru.md)

Hi, I'm **Vlad175cm**. This is the iOS port of my desktop player
[vlswmplayer](https://github.com/Vlad175cm/vlswmplayer), which I use inside
[VLSWM](https://github.com/Vlad175cm/VLSWM) — a minimal black-and-white
Wayland shell.

Same idea on the phone: search SoundCloud without an account, tap a track,
listen. Only black and white, only square corners, one monospace font.
No third-party libraries: SwiftUI and AVPlayer.

![icon](Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png)

## What it does

- **Search** SoundCloud through the public `api-v2` endpoint, no login.
- **Plays HLS directly** with `AVPlayer`, no download before playback.
- **Caches what you play.** The first play streams and downloads in the
  background; the next start comes from disk in about a second.
- **Likes** in a separate tab, stored locally in `Documents/likes.json`.
- **Local files** in an `UPLOADED` tab. Files are copied into the app sandbox,
  title, artist and cover are read from the tags. OGG, Opus and WMA are skipped:
  iOS cannot decode them.
- **Portable library**: the hamburger menu exports and imports likes as one
  JSON file, the same format the Linux version uses.
- **Full screen player**: tap the artwork for cover, title, artist, length,
  seek bar and the like / previous / play / next buttons.
- Skips DRM-protected tracks instead of hanging.

## Requirements

- iOS 15 or newer, arm64 device
- Built with Xcode 16 / iOS 17 SDK, deployment target iOS 15

## Install

### TrollStore (jailbreak, recommended)

TrollStore installs unsigned IPAs permanently: no Apple ID, no certificate,
no 7-day expiry. Open the `.ipa` in TrollStore and tap Install.

This is how I install it on my own iPhone 7.

### AppSync Unified (jailbreak, alternative)

If you prefer the classic route instead of TrollStore:

1. Install **AppSync Unified** (rootless build) from Karen's Repo.
2. Copy the `.ipa` to the device and open it in Filza, or from a terminal:
   `appinst VLSWMPlayer.ipa`.

### Sideloadly (no jailbreak)

Sideloadly signs the IPA with a free Apple ID and installs it over USB.
Enable Developer Mode first (`Settings → Privacy & Security → Developer Mode`),
then trust the certificate in `Settings → General → VPN & Device Management`.
The app stops working after 7 days and has to be re-signed.

## Controls

- Tap a row — play that track.
- Tap the artwork in the player bar — full screen player.
- `|<` / `>|` — previous / next track.
- Middle button — pause and resume.
- Drag the bar under the artwork — seek.
- `VOL` — app volume.
- `+` / `*` — like or unlike the current track.
- Tabs: `SEARCH` / `LIKES` / `UPLOADED`, the `*` marks liked tracks.
- Hamburger menu: add local files, export likes, import likes.
- While files are copied, `UPLOADING 2/5 name` and a progress bar appear above
  the player panel.
- Swipe down or `X` closes the full screen player.

## Files on the device

| Path | Contents |
| --- | --- |
| `Documents/tracks/` | cached audio, one file per track |
| `Documents/likes.json` | liked tracks |
| `Documents/uploaded/` | your own audio files |
| `Documents/uploaded.json` | index of uploaded files |
| `Documents/artwork/` | covers extracted from local files |
| `Documents/vlswmplayer.log` | debug log: search, resolve, playback, cache |

The log is the first thing to check if something does not play. Find it with:

```bash
find /var/mobile/Containers/Data/Application -name vlswmplayer.log 2>/dev/null
```

## How it works

- Search: `GET https://api-v2.soundcloud.com/search/tracks` with a `client_id`
  baked into the bundle. On `401` the app reloads `soundcloud.com`, extracts a
  fresh id from the JavaScript bundle and retries.
- Playback: a `media.transcodings` entry is resolved into a direct HLS URL and
  handed to `AVPlayer`. `*-encrypted-hls` tracks are filtered out at search time.
- Cache: the same resolved URL is downloaded in the background into
  `Documents/tracks/<id>.<ext>`, the extension is chosen from the file header
  (`ftyp` → `.m4a`, `ID3` → `.mp3`, `OggS` → `.ogg`). HLS is stored as one
  concatenated file.
- Likes: plain JSON, no account, nothing is sent anywhere.

## Build

The IPA is built in GitHub Actions on a macOS runner
(`.github/workflows/build.yml`). Pushing a `v*` tag builds the IPA and attaches
it to a GitHub release automatically.

Locally (macOS with Xcode):

```bash
brew install xcodegen ldid
xcodegen generate
xcodebuild -project VLSWMPlayer.xcodeproj -scheme VLSWMPlayer \
  -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO
```

Then package:

```bash
mkdir Payload
cp -R build/Build/Products/Release-iphoneos/VLSWMPlayer.app Payload/
ldid -S"$PWD/entitlements.plist" Payload/VLSWMPlayer.app/VLSWMPlayer
zip -qry VLSWMPlayer.ipa Payload
```

## Notes

- SoundCloud's public endpoints are not an official API. They can change, and
  the `client_id` can expire.
- The player never touches your SoundCloud account: no login, likes stay local.
- The app is unsigned by design; that is what makes TrollStore and AppSync
  installation possible.

## License

[MIT](LICENSE). The bundled JetBrains Mono font is licensed under the
[SIL Open Font License 1.1](https://github.com/JetBrains/JetBrainsMono/blob/master/OFL.txt).
