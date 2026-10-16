#!/bin/bash
# Build, verify, and package dist/SpeedChat-macos-arm64.zip for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh >/dev/null
app="$PWD/dist/SpeedChat.app"
zip_path="$PWD/dist/SpeedChat-macos-arm64.zip"

codesign --verify --deep --strict "$app"
rm -f "$zip_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"

shasum -a 256 "$zip_path"
printf '%s\n' "$zip_path"
