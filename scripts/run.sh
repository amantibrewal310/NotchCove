#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pkill -x NotchCove 2>/dev/null || true

# Always rebuild (incremental, fast) so a stale bundle is never launched
"$PROJECT_ROOT/scripts/build.sh"

echo "🚀 Launching NotchCove..."
open "$PROJECT_ROOT/build/NotchCove.app"
echo "Done! Hover the notch, drag files toward it, or press ⌃⌥C."
