# Rich Presence editor

Native SwiftUI editor for macOS 26 and newer, built here with the macOS 27 SDK.
Open **Settings…** (Command-comma) from the TidalRPC menu bar menu. This is the
single settings window. Each of the three card rows can show App text,
Song, Artist or Album; pick with the row’s arrows or its context menu. Rows may
repeat. Drag a row onto another to reorder, or use the context menu,
Option-Up/Down on a focused row, or VoiceOver Move Up/Down. **Show after
“Playing”** lists the fields currently shown; if a row change removes the chosen
field, the status follows the row just changed. The App text box accepts any nonblank wording up to 128
characters; Suggestions offers Tidal, TIDAL, Listening with Tidal, and Listening
with TIDAL. **More options** holds Show track link, Include album year, Launch at
login (SMAppService, including approval-needed state) and Reset presence layout
(the former Original preset: App/Song/Artist, status App, custom text kept).

Changes save automatically: drags, picker and checkbox changes immediately,
valid typing after 600 ms. Undo/Redo covers one step per drag or selection and
coalesces a typing run. Each save carries a request id; the service replies with
the same id and its persisted settings, and older acknowledgements are ignored,
so they never replace newer edits. Invalid text is never sent (other edits still
save with the last saved text). Closing flushes pending edits and waits for the
acknowledgement; failures offer Retry/Discard and invalid text offers Fix/Discard.
A single recovery notice (title access or Discord connection) appears only when
action is needed.

The dark card is an approximation of Discord's layout. Album artwork, metadata,
and remaining time come from TIDAL; no Discord profile data is read. Without a
track, the preview shows example values. Discord owns the final
rendering; acceptance of an RPC request is not a visual verification.

## Architecture and building

`sh scripts/build-native.sh` bundles the editor as
`Contents/Resources/PresenceEditor.app`. The native process exchanges
newline-delimited JSON over inherited stdin/stdout with `EditorBridge.swift`.
The editor has no network listener, tokens, or direct Discord API connection. Artwork is loaded on demand from the existing TIDAL image URL.
Closing the window exits the helper. EOF from the parent also exits it. Playback
snapshots are sent only when changed and only while the helper is running.

`DiscordIPC.swift` sends `name` and `status_display_type` explicitly. Rows map
to `name`, `details`, `state`; the status uses the first row showing the chosen
field (Name=0, Details=2, State=1). Identical
activities aren't resent, and changed requests remain throttled to five seconds.
The default card order is retained; the new status default is Artist.

## Design references

- [Apple Landmarks: Building an app with Liquid Glass](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Discord activity and status display fields](https://github.com/discord/discord-api-docs/blob/main/developers/events/gateway-events.mdx#activity-object)
- [Discord custom application names](https://github.com/discord/discord-api-docs/blob/main/developers/discord-social-sdk/development-guides/setting-rich-presence.mdx#setting-the-application-name)

Uses native toolbar controls, glass/glassProminent button styles, grouped custom
glass effects, system typography, spring transitions, Reduce Motion support,
and non-drag reorder actions. Glass is limited to controls, while the preview
uses an opaque surface for legibility. No perpetual decorative animations.
