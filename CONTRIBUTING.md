# Contributing

Thanks for helping improve TidalRPC for macOS.

## Before opening a pull request

Run the local CI script from the repository root and make sure it passes:

```sh
sh scripts/ci.sh
```

It checks for files and secrets that must not be published, type-checks both
targets with warnings as errors, runs the unit tests in `native/Tests`, and
verifies a complete signed build. Paste its final `Local CI passed: …` line into
your pull request. Pull requests without a passing run won’t be reviewed.

If your change affects behavior, also run through the relevant manual checks in
[docs/RELEASING.md](docs/RELEASING.md) and describe what you tried.

## Guidelines

- macOS 26 or later, Swift and Apple frameworks only; no third-party packages.
- Keep background work event-driven and cheap: no new timers while idle, no
  artwork loading in the menu-bar process, change-only Discord updates.
- Follow Apple’s Human Interface Guidelines and use standard controls.
- TidalRPC must never read Discord’s interface, account data or tokens.
- Never commit `.env` files, signing certificates, provisioning profiles or
  notarization credentials. `.gitignore` excludes them by default.

By contributing you agree that your work is licensed under the GPL-3.0.
