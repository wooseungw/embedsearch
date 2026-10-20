#!/usr/bin/env bash
# Builds an ad hoc–signed Release app and zips it for a GitHub release:
#   scripts/package-release.sh      # → build/EmbedSearch-<version>-arm64.zip and .sha256
# Ad hoc rather than Apple Development: a development certificate is not meant for distribution and
# would put your name and email in the signature. Not notarized, so users clear Gatekeeper once
# (README). Leaves build/EmbedSearch.app ad hoc; rerun scripts/build-app.sh before scripts/install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/EmbedSearch.app"

ADHOC=1 "$ROOT/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="EmbedSearch-$VERSION-arm64.zip"
echo "==> zip $NAME"
rm -f "$ROOT/build/$NAME" "$ROOT/build/$NAME.sha256"
ditto -c -k --keepParent "$APP" "$ROOT/build/$NAME"
(cd "$ROOT/build" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "packaged build/$NAME ($(du -h "$ROOT/build/$NAME" | cut -f1))"
