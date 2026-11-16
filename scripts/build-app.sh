#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox --build-system native -c release
bin=$(swift build --disable-sandbox --build-system native -c release --show-bin-path)
app="$PWD/dist/SpeedChat.app"
rm -rf "$app/Contents/Resources/backend"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/SpeedChat" "$app/Contents/MacOS/SpeedChat"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp resources/MenuBarIcon.png resources/MenuBarIcon@2x.png "$app/Contents/Resources/"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset" "$PWD/resources/AppIcon.png"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp resources/Info.plist "$app/Contents/Info.plist"
# UTC bundle build time for About. package-release.sh calls this script.
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[[ "$build_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { printf 'Could not format build date: %s\n' "$build_date" >&2; exit 1; }
/usr/bin/plutil -insert SpeedChatBuildDate -string "$build_date" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
