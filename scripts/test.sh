#!/bin/zsh
# Runs Swift tests with Command Line Tools (adds the Swift Testing macro plugin path).
set -euo pipefail
cd "$(dirname "$0")/.."
P=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$P" ]]; then swift test -Xswiftc -plugin-path -Xswiftc "$P" "$@"; else swift test "$@"; fi
