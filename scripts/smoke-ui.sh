#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
"$PWD/dist/SpeedChat.app/Contents/MacOS/SpeedChat" --ui-smoke --smoke-output "$PWD/docs/ui-smoke"
cat docs/ui-smoke/report.json
