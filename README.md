# TidalRPC for macOS

Show what you’re playing in TIDAL as Discord Rich Presence. A small native
Swift/AppKit menu-bar app with an on-demand SwiftUI settings window. No
Electron, Node or third-party packages.

## Why a native version?

[tidalRPC](https://github.com/rxri/tidalRPC) by ririxi is built with Electron,
which lets one codebase run on both Windows and macOS. While using it on a Mac,
we tracked down a memory leak in one of its native dependencies and found that,
on macOS specifically, the app could be far lighter if it were written in Swift
with Apple’s own frameworks. That made this a separate, Mac-only project: it
doesn’t run on Windows, so Windows users should keep using the original.

| | Electron version | Native version |
|---|---|---|
| App size | 449 MB | 1.4 MB |
| Memory | ~130 MB across three processes | ~21 MB, one process |
| CPU while running | Up to 13–22% in local tests | ~0.2% |

Figures come from one Apple silicon Mac and will vary by setup.

It also keeps working when TIDAL isn’t on screen. The original only detects
TIDAL while its window is visible, so presence stops when TIDAL is minimized,
hidden or on another desktop. This version reads TIDAL’s window title in all of
those cases.

The native version only checks for TIDAL while TIDAL and Discord are both open,
pauses while your Mac sleeps, checks less often when music is paused or Low Power
Mode is on, and only updates Discord when something changes.

## Install

Requires macOS 26 or later on a Mac with Apple silicon. Intel Macs aren’t supported.

1. Download `TidalRPC-<version>.zip` from
   [Releases](../../releases) and unzip it.
2. Move `tidalRPC.app` to your Applications folder.
3. The app isn’t notarized by Apple, so the first time, **Control-click**
   (or right-click) it and choose **Open**, then confirm **Open**. If macOS still
   blocks it, go to System Settings → Privacy & Security and click **Open Anyway**.
4. A music-note icon appears in the menu bar. Choose **Help → Allow TIDAL Title
   Access…** and turn TidalRPC on under **Screen & System Audio Recording**.
   Then open the menu again; the status shows **Active** once TIDAL and
   Discord are both running and a track is playing.

After updating to a new version, macOS may ask for Screen Recording access again.
If TidalRPC already looks switched on but the menu still asks for access, remove
it from the list with **−**, add it back, and switch it on.

## Build from source

Requires the Xcode Command Line Tools.

```sh
sh scripts/build-native.sh
open native/build/tidalRPC.app
```

See [native/README.md](native/README.md) for architecture, signing options and
energy decisions.

## Use

Click the music-note icon in the menu bar:

- **Show Rich Presence** turns sharing on or off.
- **Settings…** (⌘,) opens the settings window. Each of the three card rows can
  show your custom App text, the song, the artist or the album. Rows can repeat
  and can be dragged into any order. Choose which one follows “Playing” under
  your name. Changes save automatically and support Undo.
- **Help** has Allow TIDAL Title Access… and Refresh Connection.

TidalRPC reads TIDAL’s window title to find the current track, which macOS treats
as Screen Recording. It never captures screenshots and never reads Discord’s UI
or account data. It only talks to Discord through the local Rich Presence socket.

Playback time is estimated: window titles don’t expose position or seeking.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for what fits the project and how to submit changes.

## Credits and license

Based on [rxri/tidalRPC](https://github.com/rxri/tidalRPC). Licensed under the
GNU General Public License v3.0; see [LICENSE](LICENSE). Not affiliated with
TIDAL or Discord.
