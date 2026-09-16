#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Kill any existing instance
pkill -x NotchCove 2>/dev/null || true

# Run build if not yet built
if [ ! -f "$PROJECT_ROOT/build/NotchCove.app/Contents/MacOS/NotchCove" ]; then
    "$PROJECT_ROOT/scripts/build.sh"
fi

echo "🚀 Launching NotchCove..."
open "$PROJECT_ROOT/build/NotchCove.app"
echo "Done! Look at the top center of your screen or the menu bar (tray icon)."
