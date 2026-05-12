#!/usr/bin/env bash
# Compile scripts/skybg.swift into bin/skybg.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$HERE/bin"
/usr/bin/swiftc -O "$HERE/scripts/skybg.swift" -o "$HERE/bin/skybg"
echo "built $HERE/bin/skybg"
