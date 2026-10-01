# TidalRPC Native for macOS

A macOS-only app. Swift/AppKit manages
the menu bar, playback observation, metadata and Discord IPC. The Liquid Glass
SwiftUI editor lives in a separate app bundle and starts only when opened.

## Build

Requires macOS 26+ and Apple Command Line Tools with a macOS 26+ SDK. Developed
with the macOS 27 SDK. No Node, npm, Electron, or third-party Swift packages.

```sh
sh scripts/build-native.sh
open native/build/tidalRPC.app
```

Apple silicon (arm64) only; Intel Macs are not supported. To choose an output
path, pass it as the first argument. Builds are locally ad-hoc signed; public distribution would
require Developer ID signing and notarization.

## Features

- TIDAL now-playing Rich Presence, with album art and optional track link.
- Three card rows, each showing App text, Song, Artist or Album (repeats allowed),
  in any drag-and-drop order; choose which shown field follows “Playing” under
  your Discord username. Custom App text (1–128 characters) has suggestions:
  Tidal, TIDAL, Listening with Tidal, Listening with TIDAL. Album falls back to
  the song title when TIDAL has no album metadata.
- Pause/quit handling, bounded metadata cache, reconnect with exponential backoff.
- Launch at Login through macOS Service Management; previous preferences migrate
  once from tidalrpc/config.json into native UserDefaults.
- Screen Recording permission is used only to read TIDAL's window titles. The
  app never captures screenshots. No Discord UI, user token, messages, channels,
  or profile data are inspected. Only its own presence IPC is used.

## Energy and memory decisions

- No Electron, Chromium, Node, browser renderers or third-party packages.
- NSWorkspace launch/quit/sleep/wake notifications control work. No playback
  timer while TIDAL/Discord is absent, presence is disabled, or the Mac sleeps.
- One window-list snapshot every 2 seconds during playback, every 5 seconds when
  paused. Low Power Mode uses 4/10 seconds; timers allow 20% scheduling tolerance.
  This trades up to that interval of detection latency for fewer wakeups.
- Window metadata is scoped to an autorelease pool and only TIDAL titles are
  extracted. No per-window rescans or persistent accessibility-object cache.
- Changed tracks cancel obsolete metadata requests. Metadata cache is capped at
  32 songs; failed lookups back off 60 seconds. HTTP requests have timeouts.
- The background process never downloads or decodes artwork; only the open
  editor does. Closing the editor releases its process and image memory.
- Discord frames are asynchronous, bounded to 1 MiB, handle fragmentation and
  multiple frames, respond to pings and impose handshake/response deadlines.
  Identical activity payloads are suppressed; changes are limited to one every
  5 seconds. Reconnection retries back off to 60 seconds only while needed.
- Tray items are reused and changed on events, not recreated every tick.

## Limits

TIDAL window titles don't expose playback position or seeking. The countdown is
an estimate from observed track changes and pause duration. Repeating the same
track is inferred from its duration. Metadata uses the predecessor's public
TIDAL web endpoint/token and US region; unavailable metadata falls back to the
observed title/artist and retries later. No private MediaRemote APIs are used.

Ad-hoc signed builds are identified by their exact hash, so each rebuild
invalidates the Screen Recording grant while System Settings still shows it on.
Remove TidalRPC from Screen & System Audio Recording with −, add it again, then
open the menu. Signing with a stable identity (TIDALRPC_SIGN_IDENTITY) avoids this. The app
never changes privacy permissions on its own. Settings persist under the
bundle ID, `io.github.yhkcyber.tidalrpc`, using the `nativePreferences` defaults key.
Preferences saved under the earlier `ririxidev.TidalRPC` ID are copied once.

## Sources

- [Apple timer and wakeup guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html)
- [NSWorkspace lifecycle](https://developer.apple.com/documentation/appkit/nsworkspace)
- [Low Power Mode](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)
- [Native launch at login](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
- [Network.framework endpoints](https://developer.apple.com/documentation/network/nwendpoint)
- [Liquid Glass design references](PresenceEditor/README.md)

## Releases

See [docs/RELEASING.md](../docs/RELEASING.md). The build accepts TIDALRPC_BUNDLE_ID, TIDALRPC_DISCORD_CLIENT_ID and
TIDALRPC_SIGN_IDENTITY. The last is optional for local ad-hoc builds.
