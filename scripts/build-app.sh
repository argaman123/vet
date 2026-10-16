#!/bin/zsh
# Builds build/Vet.app from the Swift package and signs it.
# Signs with the "Vet Local Development" identity when present so macOS keeps
# the Accessibility permission across rebuilds (see setup-signing.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Vet
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Vet"
APP=build/Vet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if security find-identity -p codesigning 2>/dev/null | grep -q "Vet Local Development"; then
  codesign --force --sign "Vet Local Development" "$APP"
else
  codesign --force --sign - "$APP"
  echo "warning: signed ad-hoc; Accessibility permission resets on every rebuild. Run scripts/setup-signing.sh once." >&2
fi
echo "built $APP"
