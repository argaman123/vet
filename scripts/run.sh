#!/bin/zsh
# Rebuilds Vet.app, quits any running copy, and opens the new one.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-release}"
osascript -e 'quit app id "dev.vet.Vet"' 2>/dev/null || true
sleep 0.5
open build/app.noindex/Vet.app
