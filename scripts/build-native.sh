#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Apple silicon only; Intel Macs are not supported.
arch=arm64
output="${1:-native/build/tidalRPC.app}"
mkdir -p native/build/ModuleCache "$output/Contents/MacOS" "$output/Contents/Resources"
xcrun swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos26.0" \
  -module-cache-path native/build/ModuleCache native/Service/*.swift -o "$output/Contents/MacOS/tidalRPC"
editor="$output/Contents/Resources/PresenceEditor.app"
mkdir -p "$editor/Contents/MacOS" "$editor/Contents/Resources"
xcrun swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos26.0" \
  -module-cache-path native/build/ModuleCache native/PresenceEditor/PresenceEditor.swift -o "$editor/Contents/MacOS/PresenceEditor"
cp native/Resources/AppIcon.icns "$output/Contents/Resources/AppIcon.icns"
cp native/Resources/AppIcon.icns "$editor/Contents/Resources/AppIcon.icns"
cp LICENSE "$output/Contents/Resources/LICENSE"
python3 - "$output" <<'PY'
import plistlib,sys,os
from pathlib import Path
app=Path(sys.argv[1])
bundle_id=os.environ.get('TIDALRPC_BUNDLE_ID','io.github.yhkcyber.tidalrpc')
base=dict(CFBundleIdentifier=bundle_id,CFBundleName='tidalRPC',CFBundleDisplayName='TidalRPC',CFBundleExecutable='tidalRPC',CFBundlePackageType='APPL',CFBundleShortVersionString='1.0.0',CFBundleVersion='1',LSMinimumSystemVersion='26.0',LSArchitecturePriority=['arm64'],LSUIElement=True,NSHighResolutionCapable=True,NSPrincipalClass='NSApplication',CFBundleIconFile='AppIcon',NSHumanReadableCopyright='Based on rxri/tidalRPC. GPL-3.0.')
base['DiscordClientID']=os.environ.get('TIDALRPC_DISCORD_CLIENT_ID','793071505327652864')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(base))
base.update(CFBundleIdentifier=bundle_id+'.PresenceEditor',CFBundleName='PresenceEditor',CFBundleDisplayName='TidalRPC Presence Editor',CFBundleExecutable='PresenceEditor',LSUIElement=False)
(app/'Contents/Resources/PresenceEditor.app/Contents/Info.plist').write_bytes(plistlib.dumps(base))
PY
xattr -cr "$output"
identity="${TIDALRPC_SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
  codesign --force --sign - "$editor"
  codesign --force --sign - "$output"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$editor"
  codesign --force --options runtime --timestamp --sign "$identity" "$output"
fi
printf 'Native app built: %s\n' "$output"
