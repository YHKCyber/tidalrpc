# TidalRPC for macOS — agent guide

Native macOS TIDAL → Discord Rich Presence. `CLAUDE.md` is a symlink to this file.

## Layout

- `native/Service/` — AppKit menu-bar service: `Main.swift` (menu, lifecycle),
  `Engine.swift` (TIDAL title polling, publishing), `DiscordIPC.swift` (Unix-socket
  RPC), `Metadata.swift` (TIDAL lookup, 32-entry cache), `Models.swift`
  (preferences, `nativePreferences` defaults key), `EditorBridge.swift`
  (settings-process bridge, launch-at-login helper).
- `native/PresenceEditor/PresenceEditor.swift` — short-lived SwiftUI settings app,
  embedded as `Contents/Resources/PresenceEditor.app`.
- Source folder is `Service`, not `App` (case-insensitive filesystem pitfalls).

## Build

`sh scripts/build-native.sh [output.app]`. Apple silicon only (arm64).
Env: `TIDALRPC_BUNDLE_ID`, `TIDALRPC_DISCORD_CLIENT_ID`, `TIDALRPC_SIGN_IDENTITY`.
Ad-hoc builds invalidate the Screen Recording grant on every rebuild.
Transient SwiftUI state uses ObservableObject; avoid macros that the
command-line SDK setup may lack.

## Rules

- Never inspect Discord UI, profile, messages or tokens; only our own IPC status.
- Preserve efficiency: event-driven lifecycle, 2/5 s (4/10 s Low Power) polling
  with tolerance, change-only publishing max once per 5 s, no background artwork.
- Settings protocol (newline JSON): editor sends `ready`, `save{id,settings}`,
  `login{id,enabled}`, `openLoginSettings`, `allowTitles`, `refresh`; service
  replies `saved{id,ok,error,settings}` / `login{id,ok,error,login}` and sends
  snapshots. Stale acknowledgements must never overwrite newer edits; snapshots
  seed the draft only once.
- Layout: `order` is three rows, each `app|song|artist|album` (repeats allowed);
  `statusField` must be one of them; app text 1–128 characters, nonblank.
- Run `sh scripts/ci.sh` before committing, opening a PR, pushing or publishing; tests live in
  `native/Tests` (plain assertion executables, no XCTest). Keep GPL-3.0 and
  rxri/tidalRPC attribution.

## Handoff Notes

- 2026-09-29: Version 1.0.0, bundle ID `io.github.yhkcyber.tidalrpc` (preferences
  copy once from `ririxidev.TidalRPC`); original Discord application kept.
  Apple silicon only. Unsigned/un-notarized; README documents Control-click Open
  and the Screen Recording grant.
- Workflow: GitHub `main` (remote `github`, YHKCyber/tidalrpc) is the source of
  truth. Branch from it, open PRs, squash-merge; never rewrite published history.
  Maintainer/PR/release steps: docs/MAINTAINING.md, scripts/release.sh. Pushing to
  `origin` (rxri/tidalRPC) is disabled locally and must never be re-enabled.
- Verified: local CI (unit tests, build checks), fresh-clone CI, settings
  migration, single-instance handoff, light-use energy sample (~0.2% CPU).
- 2026-10-01: Owner ran the manual checks; only issue is the known approximate
  timer (documented). Builds are reproducible: a fresh build of `publish` matches
  the tested app and TidalRPC-1.0.0.zip exactly. v1.0.0 is released on GitHub
  (YHKCyber/tidalrpc). Local `main` matches the working branch.
