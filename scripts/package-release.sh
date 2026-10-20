#!/usr/bin/env bash
# Builds an ad hoc–signed Release app and packs it in a drag-to-Applications disk image for a GitHub release:
#   scripts/package-release.sh      # → build/EmbedSearch.dmg and .sha256
# The name carries no version so .../releases/latest/download/EmbedSearch.dmg always serves the newest.
# Ad hoc rather than Apple Development: a development certificate is not meant for distribution and
# would put your name and email in the signature. Not notarized, so users clear Gatekeeper once
# (README). Leaves build/EmbedSearch.app ad hoc; rerun scripts/build-app.sh before scripts/install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/EmbedSearch.app"

ADHOC=1 "$ROOT/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="EmbedSearch.dmg"

# The image holds the app and an /Applications link to drop it on.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/EmbedSearch.app"
ln -s /Applications "$STAGE/Applications"

echo "==> dmg $NAME"
rm -f "$ROOT/build/$NAME" "$ROOT/build/$NAME.sha256"
hdiutil create -quiet -volname EmbedSearch -srcfolder "$STAGE" -format UDZO -ov "$ROOT/build/$NAME"
(cd "$ROOT/build" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "packaged build/$NAME, version $VERSION ($(du -h "$ROOT/build/$NAME" | cut -f1))"
