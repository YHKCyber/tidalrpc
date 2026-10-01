# Contributing

Thanks for helping improve TidalRPC for macOS. Bug reports, fixes and focused
improvements are all welcome.

## Reporting bugs and requesting features

Use the issue forms on the
[Issues](https://github.com/YHKCyber/tidalrpc/issues/new/choose) page. For a bug,
include your TidalRPC and macOS versions, what the menu-bar status says, and the
steps that cause it. Never post Discord tokens, account details or screenshots of
private conversations.

Before starting on a large change, open an issue first so we can agree on the
approach. That saves you from building something that can’t be merged.

## What fits this project

- macOS 26 or later on Apple silicon. Windows, Linux and Intel Macs are out of
  scope; the original [tidalRPC](https://github.com/rxri/tidalRPC) covers Windows.
- Swift and Apple frameworks only. No third-party packages.
- The background app must stay light: no new timers while idle, no artwork loading
  in the menu-bar process, and Discord updates only when something changes.
- TidalRPC must never read Discord’s interface, account data or tokens. It talks to
  Discord only through the local Rich Presence socket.
- UI follows Apple’s Human Interface Guidelines and uses standard controls.

## Making a change

1. Fork the repository and create a branch from `main`, named for the change,
   for example `fix-paused-status` or `album-year-option`.
2. Match the surrounding code: 4-space indentation, Swift naming conventions,
   short comments only where the reason isn’t obvious.
3. If you change logic in `native/Service` or the settings model, add or update
   checks in `native/Tests`. UI-only changes don’t need tests.
4. Keep each pull request to one change. Unrelated fixes belong in separate PRs.

### Commit messages

Write a short summary line in the imperative mood, under about 70 characters,
followed by a blank line and an explanation of why if it isn’t obvious:

```
Keep presence when TIDAL changes windows

TIDAL briefly reports an empty title while switching windows, which
cleared the presence. Treat a single empty title as unchanged.
```

## Before opening a pull request

Run the local CI script from the repository root and make sure it passes:

```sh
sh scripts/ci.sh
```

It checks for files and secrets that must not be published, type-checks both
targets with warnings as errors, runs the unit tests in `native/Tests`, and
verifies a complete build. Paste its final `Local CI passed: …` line into your
pull request, and describe how you tested the change in the app. Pull requests
without a passing run won’t be reviewed.

Never commit `.env` files, signing certificates, provisioning profiles or
notarization credentials. `.gitignore` excludes them by default.

## Review

A maintainer will run CI on your branch, try the change, and may ask for
adjustments. Accepted pull requests are squash-merged, so your branch can have as
many commits as you like.

By contributing you agree that your work is licensed under the GPL-3.0.
