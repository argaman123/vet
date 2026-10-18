#!/bin/zsh
# Builds a release Vet.app and installs it to ~/Applications (quits a running Vet first).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
osascript -e 'quit app id "dev.vet.Vet"' 2>/dev/null || true
sleep 0.5
mkdir -p ~/Applications
rm -rf ~/Applications/Vet.app
cp -R build/app.noindex/Vet.app ~/Applications/Vet.app
echo "Installed ~/Applications/Vet.app"
