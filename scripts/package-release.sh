#!/bin/bash
# Build, verify, and package dist/SpeedChat-macos-arm64.zip for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh >/dev/null
app="$PWD/dist/SpeedChat.app"
zip_path="$PWD/dist/SpeedChat-macos-arm64.zip"

codesign --verify --deep --strict "$app"
build_date=$(/usr/bin/plutil -extract SpeedChatBuildDate raw "$app/Contents/Info.plist") || { printf 'Info.plist is missing SpeedChatBuildDate\n' >&2; exit 1; }
[[ "$build_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { printf 'SpeedChatBuildDate is not a UTC build timestamp: %s\n' "$build_date" >&2; exit 1; }
rm -f "$zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"

shasum -a 256 "$zip_path"
printf '%s\n' "$zip_path"
