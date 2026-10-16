#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
(cd backend && npm test && npm run check && npm run build)
scripts/swift-test.sh
