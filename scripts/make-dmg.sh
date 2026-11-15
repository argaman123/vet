#!/bin/zsh
# Builds a release Vet.app and packs it into build/Vet-<version>.dmg: the app beside a shortcut
# to Applications, for dragging across. The app is signed ad hoc (no Apple Developer ID), so
# macOS asks the person to allow it the first time it opens; the README says how.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/app.noindex/Vet.app "$STAGE/Vet.app"
# A local development identity means nothing on another Mac: sign the shipped copy ad hoc.
codesign --force --deep --sign - "$STAGE/Vet.app"
ln -s /Applications "$STAGE/Applications"
OUT="build/Vet-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Vet $VERSION" -srcfolder "$STAGE" -fs APFS -format UDZO -ov "$OUT" >/dev/null
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
