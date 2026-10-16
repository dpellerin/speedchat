#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --disable-sandbox --disable-xctest --build-system native -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" "$@"
