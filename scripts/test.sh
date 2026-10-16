#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-test.sh "$@"
