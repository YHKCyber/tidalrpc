# Maintaining

Notes for maintainers on handling issues, pull requests and releases.
GitHub’s `main` is the source of truth; keep your local `main` in sync with it.

```sh
git switch main
git pull github main
```

## Recommended GitHub settings

- **Settings → General → Pull Requests:** allow only *Squash merging*, and enable
  *Automatically delete head branches*.
- **Settings → Branches:** add a rule for `main` that requires a pull request
  before merging, so nothing lands without review (you can still bypass it).
- **Issues → Labels:** `bug`, `enhancement`, `question`, `needs info`,
  `good first issue`, `wontfix`. The issue forms apply `bug` and `enhancement`.

## Triaging issues

- Ask for missing details (version, macOS, menu status, steps) and label
  `needs info`. Close after a couple of weeks without a reply.
- Close out-of-scope requests politely: Windows support, Intel Macs, third-party
  packages, anything that reads Discord’s interface or account data. Point Windows
  users to [rxri/tidalRPC](https://github.com/rxri/tidalRPC).
- If someone posts a token or private data, edit it out or delete the comment.

## Reviewing a pull request

1. **Check out the branch locally** (with the GitHub CLI, or plain git):

   ```sh
   gh pr checkout 12
   # or: git fetch github pull/12/head:pr-12 && git switch pr-12
   ```

2. **Run local CI yourself.** Don’t rely on the pasted result:

   ```sh
   sh scripts/ci.sh
   ```

3. **Try it.** Build to a separate location so your installed copy stays put:

   ```sh
   sh scripts/build-native.sh /tmp/tidalrpc-pr/tidalRPC.app
   ```

   Quit your installed TidalRPC first (only one copy runs at a time), then open
   the test build. A new build needs Screen Recording access again; when you
   switch back, re-grant it to your installed copy.

4. **Review against the project rules:**
   - Does one thing, with a clear reason.
   - No new third-party dependencies, network endpoints or background timers.
   - Background work stays event-driven; nothing runs while TIDAL or Discord is closed.
   - Never touches Discord’s interface, tokens or account data.
   - Logic changes come with checks in `native/Tests`.
   - UI uses standard controls and works in light/dark mode and with VoiceOver.
   - No secrets, personal paths or build output committed.

5. **Respond.** Request changes with specific, friendly comments, or approve.
   For first-time contributors, thank them; small fixes can be made directly with
   a suggestion.

6. **Merge** with *Squash and merge*. Edit the squash message to follow the commit
   style in CONTRIBUTING.md and keep the `Fixes #…` reference.

7. **Clean up:** `git switch main && git pull github main`, then delete the local
   PR branch.

## Releasing

1. Make sure `main` is up to date and everything for the release is merged.
2. Bump the version in `scripts/build-native.sh`: `CFBundleShortVersionString`
   (for example `1.0.1`, or `1.1.0` for new features) and increase
   `CFBundleVersion` by one. Commit as `Release 1.0.1` and push.
3. Run through the manual checks in [RELEASING.md](RELEASING.md) that relate to
   the changes.
4. Build the release files:

   ```sh
   sh scripts/release.sh
   ```

   It runs CI, builds from a clean copy of the commit, and writes the zip and its
   SHA-256 to `native/build/release/`.
5. Tag and publish, using the commands the script prints. In the release notes,
   list the changes, credit contributors by username, and remind users that
   macOS may ask for Screen Recording access again after updating.

## Remotes

`github` is this repository. `origin` is the original rxri/tidalRPC; pushing to it
is disabled locally and should stay that way.
