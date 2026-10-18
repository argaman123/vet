#!/bin/zsh
# Builds build/app.noindex/Vet.app from the Swift package and signs it.
# Signs with the "Vet Local Development" identity when present so macOS keeps
# the Accessibility permission across rebuilds (see setup-signing.sh).
set -euo pipefail
# Command Line Tools work without accepting the Xcode license; override by exporting DEVELOPER_DIR.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# The Command Line Tools lack SwiftUI's macro plugin (@State, @Entry); borrow Xcode's when it's installed.
SWIFTUI_PLUGINS=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
EXTRA=()
[[ -d "$SWIFTUI_PLUGINS" ]] && EXTRA=(-Xswiftc -plugin-path -Xswiftc "$SWIFTUI_PLUGINS")
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Vet "${EXTRA[@]}"
BIN="$(swift build -c "$CONFIG" "${EXTRA[@]}" --show-bin-path)/Vet"
APP=build/app.noindex/Vet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
if security find-identity -p codesigning 2>/dev/null | grep -q "Vet Local Development"; then
  codesign --force --sign "Vet Local Development" "$APP"
else
  codesign --force --sign - "$APP"
  echo "warning: signed ad-hoc; Accessibility permission resets on every rebuild. Run scripts/setup-signing.sh once." >&2
fi
echo "built $APP"
