#!/usr/bin/env bash
# Installs build/EmbedSearch.app into ~/Applications and launches it.
# Run scripts/build-app.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/EmbedSearch.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/EmbedSearch.app"
BUNDLE_ID="com.seungwoo.embedsearch"

if [[ ! -d "$SOURCE" ]]; then
    echo "error: $SOURCE not found — run scripts/build-app.sh first" >&2
    exit 1
fi

echo "==> quit running EmbedSearch"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -x EmbedSearch >/dev/null || break
    sleep 0.25
done
pkill -x EmbedSearch 2>/dev/null || true

echo "==> install to $DEST"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SOURCE" "$DEST"

echo "==> launch"
open "$DEST"
echo "installed $DEST"
