#!/bin/bash
# Install/update locally without touching chat state, preferences or login items.
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/dist/SpeedChat.app"
case "${1:-}" in
  --help|-h)
    printf 'Usage: %s [--check | destination-dir]\n' "$0"
    exit 0
    ;;
  --check)
    codesign --verify --deep --strict "$source_app"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" == "local.speedchat" ]]
    printf 'Validated local bundle; no installation performed.\n'
    exit 0
    ;;
  -*)
    printf 'Unknown option: %s (expected --check or destination directory)\n' "$1" >&2
    exit 2
    ;;
esac
destination="${1:-/Applications}/SpeedChat.app"
parent=$(dirname "$destination")
[[ -d "$source_app" ]] || { printf 'Build first: scripts/build-app.sh\n' >&2; exit 1; }
[[ -d "$parent" && -w "$parent" ]] || { printf 'Destination is not writable: %s\n' "$parent" >&2; exit 1; }
[[ ! -L "$destination" ]] || { printf 'Refusing symlink destination.\n' >&2; exit 1; }
codesign --verify --deep --strict "$source_app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" == "local.speedchat" ]]
if [[ -e "$destination" ]]; then
 [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")" == "local.speedchat" ]] || { printf 'Refusing to overwrite another app.\n' >&2; exit 1; }
fi
stage=$(mktemp -d "$parent/.SpeedChat-install.XXXXXX")
backup_dir="$HOME/Library/Application Support/SpeedChat"
mkdir -p "$backup_dir"
backup="$backup_dir/SpeedChat.previous.app"
cleanup() { /bin/rm -rf "$stage"; }
trap cleanup EXIT
/usr/bin/ditto "$source_app" "$stage/SpeedChat.app"
codesign --verify --deep --strict "$stage/SpeedChat.app"
# Resolve only this app's running executable; do not send quit to unrelated apps.
if /usr/bin/pgrep -f '/SpeedChat.app/Contents/MacOS/SpeedChat$' >/dev/null; then
 /usr/bin/osascript -e 'tell application id "local.speedchat" to quit'
 for ((i=0;i<100;i++)); do
  if ! /usr/bin/pgrep -f '/SpeedChat.app/Contents/MacOS/SpeedChat$' >/dev/null; then break; fi
  /bin/sleep 0.1
 done
 ! /usr/bin/pgrep -f '/SpeedChat.app/Contents/MacOS/SpeedChat$' >/dev/null || { printf 'App is still closing; installation aborted.\n' >&2; exit 1; }
fi
if [[ -e "$destination" ]]; then
 [[ ! -e "$backup" ]] || { printf 'Previous backup exists: %s. Move it before updating.\n' "$backup" >&2; exit 1; }
 /bin/mv "$destination" "$backup"
fi
if ! /bin/mv "$stage/SpeedChat.app" "$destination"; then
 [[ ! -e "$backup" ]] || /bin/mv "$backup" "$destination"
 exit 1
fi
codesign --verify --deep --strict "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination" >/dev/null 2>&1 || true
/usr/bin/touch "$destination"
/usr/bin/open "$destination"
printf 'Installed and launched: %s\n' "$destination"
printf 'Chat state, preferences and login items were not modified.\n'
