#!/bin/sh
# Builds a release zip from a clean copy of HEAD: sh scripts/release.sh
# Bump CFBundleShortVersionString and CFBundleVersion in build-native.sh first.
set -eu
cd "$(dirname "$0")/.."
version="$(sed -n "s/.*CFBundleShortVersionString='\([^']*\)'.*/\1/p" scripts/build-native.sh)"
[ -n "$version" ] || { echo "Couldn't read the version from scripts/build-native.sh"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or discard your changes first."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null && [ "$(git rev-parse "v$version^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo "Tag v$version already exists on another commit. Bump the version in scripts/build-native.sh."; exit 1
fi

sh scripts/ci.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone -q "$(pwd)" "$work/src"
git -C "$work/src" checkout -q "$(git rev-parse HEAD)"
sh "$work/src/scripts/build-native.sh" "$work/tidalRPC.app" > /dev/null 2>&1
codesign --verify --deep --strict "$work/tidalRPC.app"

out="native/build/release"
mkdir -p "$out"
zip="$out/TidalRPC-$version.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$work/tidalRPC.app" "$zip"
(cd "$out" && shasum -a 256 "TidalRPC-$version.zip" > "TidalRPC-$version.zip.sha256")

printf '\nRelease files for %s:\n  %s\n  %s\n  SHA-256 %s\n' "$version" "$zip" "$zip.sha256" "$(cut -d' ' -f1 "$zip.sha256")"
printf '\nNext:\n  git tag v%s && git push github main v%s\n  gh release create v%s %s --title "TidalRPC %s" --notes-file <notes.md>\n' \
  "$version" "$version" "$version" "$zip" "$version"
