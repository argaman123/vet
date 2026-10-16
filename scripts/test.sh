#!/bin/zsh
# Runs Swift tests with Command Line Tools (adds the Swift Testing macro plugin path).
set -euo pipefail
# Command Line Tools work without accepting the Xcode license; override by exporting DEVELOPER_DIR.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# The Command Line Tools lack SwiftUI's macro plugin (@State, @Entry); borrow Xcode's when it's installed.
SWIFTUI_PLUGINS=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
EXTRA=()
[[ -d "$SWIFTUI_PLUGINS" ]] && EXTRA=(-Xswiftc -plugin-path -Xswiftc "$SWIFTUI_PLUGINS")
cd "$(dirname "$0")/.."
P=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$P" ]]; then swift test -Xswiftc -plugin-path -Xswiftc "$P" "${EXTRA[@]}" "$@"; else swift test "${EXTRA[@]}" "$@"; fi
