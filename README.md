# Loudness Preview

A macOS app for hearing how your master sounds after Spotify and YouTube loudness normalization and lossy encoding.

- **Spotify**: Loud −11 / Normal −14 / Quiet −19 LUFS. In Normal and Quiet, gain is capped at −1 dBTP. Loud uses a −1 dB limiter. Codecs: Ogg Vorbis 96/160/320 and Lossless.
- **YouTube**: −14 LUFS, turned down only. Codecs: Opus 128 and AAC 128.
- Loudness follows ITU-R BS.1770-4 (integrated LUFS). True peak uses 4x oversampling.
- Each codec version is encoded and decoded with libvorbis or libopus, the same encoders the services use.
- Load several songs and compare them. Click a waveform to switch songs.

## Install

Download `Loudness Preview.zip` from [Releases](../../releases), unzip it, and move the app to Applications.
The app is not notarized. If macOS blocks it the first time, run this in Terminal:

```sh
xattr -cr "/Applications/Loudness Preview.app"
```

Requires macOS 15 or later on Apple silicon.

## Build

Needs only the Xcode Command Line Tools.

```sh
./build.sh   # → build/Loudness Preview.app
```

## Shortcuts

| Key | Action |
|---|---|
| `1` `2` `3` | Original / Spotify / YouTube (press `2` again to cycle Normal → Loud → Quiet) |
| `Space` | Play / Pause |
| `←` `→` | Seek ±5 s |
| `↑` `↓` | Switch song |
| `⌫` | Remove song |

## Third-party

`Vendor/` holds the original sources of libogg 1.3.5, libvorbis 1.3.7 and libopus 1.5.2, each under its own BSD license.
