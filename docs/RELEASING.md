# Releasing

TidalRPC supports macOS 26 or later on Apple silicon. Intel Macs are not supported.

## Identity and signing

1. **Bundle identifier.** Free; nothing to register. Set `TIDALRPC_BUNDLE_ID` to a
   reverse-DNS name you control, such as `io.github.<username>.tidalrpc`. The default is
   `io.github.yhkcyber.tidalrpc`. It determines where preferences are stored and which app macOS grants
   Screen Recording and login-item permissions to. Changing it after release
   resets users’ settings and permissions, so choose it before the first release.
2. **Discord application.** Releases use the original rxri/tidalRPC Discord
   application (the default). To switch, set `TIDALRPC_DISCORD_CLIENT_ID` to your
   own application and upload a Rich Presence art asset named `logo`.
3. **Signing.** Optional; requires the paid Apple Developer Program. Unsigned
   builds work, but users must right-click → Open on first launch. Set `TIDALRPC_SIGN_IDENTITY` to a Developer ID Application
   identity. The build then signs both bundles with the hardened runtime and a
   secure timestamp. Notarize and staple the outer bundle before distributing.
   Ad-hoc builds lose their Screen Recording permission on every rebuild.

## Automated checks

`sh scripts/ci.sh` must pass on the release commit before anything is published
or pushed, whether by a person or a coding agent.

## Manual checks

These need a real TIDAL and Discord session. Record results in the release notes.

- Playback: start, pause, resume, skip, and let a track end; the countdown and
  presence follow within a few seconds.
- Metadata: a track with and without album data; Album rows fall back to the title.
- Lifecycle: quit and relaunch TIDAL and Discord; sleep and wake; toggle Low
  Power Mode; Refresh Connection.
- Permission: fresh install without Screen Recording access shows the recovery
  item and the Settings notice; granting it is picked up when the menu opens.
- Settings: drag rows, repeat fields, change the status field, type invalid and
  long text, Undo/Redo, close while a change is saving, Launch at login
  (including approval required).
- Accessibility: keyboard-only reordering, VoiceOver row actions, Reduce Motion,
  Reduce Transparency, light and dark appearance.
- Cold install: first launch on a Mac that never ran TidalRPC; a second launch
  hands off to the running copy.
- Energy: sample CPU, memory and idle wakeups during active playback, paused,
  and with TIDAL closed, over at least an hour.

## Known limitations to document

- Playback position is estimated from window titles; seeking isn’t detected.
- Metadata uses TIDAL’s unofficial public web endpoint and token, US region.
  It may change without notice.
- Keep GPL-3.0 notices and publish corresponding source with every binary.
