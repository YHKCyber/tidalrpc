#!/bin/sh
# Local CI. Run before opening a pull request: sh scripts/ci.sh
# Checks repository hygiene, type-checks with warnings as errors, runs the
# unit tests and verifies a complete signed build. Touches nothing outside a
# temporary directory and native/build/.
set -eu
cd "$(dirname "$0")/.."
arch=arm64  # Apple silicon only
[ "$(uname -m)" = arm64 ] || { echo "TidalRPC builds and runs on Apple silicon only."; exit 1; }
target="$arch-apple-macos26.0"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cache="native/build/ModuleCache"
mkdir -p "$cache"
swiftc() { xcrun swiftc -parse-as-library -swift-version 5 -target "$target" -module-cache-path "$cache" "$@"; }
step() { printf '\n==> %s\n' "$1"; }

step "Repository hygiene"
bad="$(git ls-files | grep -Ei '(^|/)(\.env(\..*)?|.*\.(pem|p12|p8|key|cer|mobileprovision|keychain)|\.DS_Store|node_modules/.*|package(-lock)?\.json|xcuserdata/.*)$' || true)"
[ -z "$bad" ] || { printf 'Tracked files that must not be published:\n%s\n' "$bad"; exit 1; }
if git grep -nIE '/Users/[A-Za-z]|/private/var/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{20}|xox[bp]-' -- . ':!scripts/ci.sh'; then
  echo "Personal paths or secrets found above."; exit 1
fi
echo "ok"

step "Type check (warnings are errors)"
swiftc -typecheck -warnings-as-errors native/Service/*.swift
swiftc -typecheck -warnings-as-errors native/PresenceEditor/PresenceEditor.swift
echo "ok"

step "Unit tests"
services="$(ls native/Service/*.swift | grep -v '/Main.swift$')"
# shellcheck disable=SC2086
swiftc $services native/Tests/Check.swift native/Tests/ServiceTests.swift -o "$work/service-tests"
"$work/service-tests"
sed 's/^@main struct PresenceEditorApp/struct PresenceEditorApp/' native/PresenceEditor/PresenceEditor.swift > "$work/Editor.swift"
swiftc "$work/Editor.swift" native/Tests/Check.swift native/Tests/EditorTests.swift -o "$work/editor-tests"
"$work/editor-tests" > /dev/null

step "Build and bundle checks"
app="$work/tidalRPC.app"
sh scripts/build-native.sh "$app" > /dev/null 2>&1 || { sh scripts/build-native.sh "$app"; exit 1; }
codesign --verify --deep --strict "$app"
editor="$app/Contents/Resources/PresenceEditor.app"
for plist in "$app/Contents/Info.plist" "$editor/Contents/Info.plist"; do plutil -lint -s "$plist"; done
[ "$(plutil -extract LSUIElement raw "$app/Contents/Info.plist")" = "true" ] || { echo "Service must be a menu-bar app"; exit 1; }
plutil -extract DiscordClientID raw "$app/Contents/Info.plist" | grep -Eq '^[0-9]{17,20}$' || { echo "Invalid DiscordClientID"; exit 1; }
lipo "$app/Contents/MacOS/tidalRPC" -verify_arch "$arch"
lipo "$editor/Contents/MacOS/PresenceEditor" -verify_arch "$arch"
echo "ok"

commit="$(git rev-parse --short HEAD)"
state="clean"; [ -z "$(git status --porcelain)" ] || state="with uncommitted changes"
printf '\nLocal CI passed: %s (%s), %s, %s\n' "$commit" "$state" "$arch" "$(sw_vers -productVersion)"
