#!/usr/bin/env bash
# Builds an ad hoc–signed Release app and packs it in a drag-to-Applications disk image for a GitHub release:
#   scripts/package-release.sh      # → build/EmbedSearch.dmg, .sha256 and appcast.xml (the update feed)
# The name carries no version so .../releases/latest/download/EmbedSearch.dmg always serves the newest.
# Upload all three to a release tagged vX.Y.Z (the feed links the dmg by that tag).
# Ad hoc rather than Apple Development: a development certificate is not meant for distribution and
# would put your name and email in the signature. Not notarized, so users clear Gatekeeper once
# (README). Leaves build/EmbedSearch.app ad hoc; rerun scripts/build-app.sh before scripts/install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/EmbedSearch.app"

# Each release needs a new version tag (the feed links the dmg by it) and a higher CFBundleVersion
# than the last release's, or installed copies never see it.
yml() { sed -n "s/^ *$1: \"\(.*\)\"$/\1/p" "${2:-$ROOT/project.yml}"; }
git -C "$ROOT" fetch -q --tags origin
# The release tag goes on the commit built here (--target below), so it must be committed and pushed.
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]] || ! git -C "$ROOT" merge-base --is-ancestor HEAD origin/main; then
    echo "error: commit and push first; releases are built from a clean checkout of origin/main" >&2
    exit 1
fi
NEXT="$(yml CFBundleShortVersionString)"
BUILD="$(yml CFBundleVersion)"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$NEXT" >/dev/null; then
    echo "error: v$NEXT is already released; raise CFBundleShortVersionString in project.yml" >&2
    exit 1
fi
LAST_TAG="$(git -C "$ROOT" tag -l 'v*' --sort=-v:refname | head -1)"
if [[ -n "$LAST_TAG" ]]; then
    LAST_BUILD="$(git -C "$ROOT" show "$LAST_TAG:project.yml" | yml CFBundleVersion /dev/stdin)"
    if ! [[ "$BUILD" =~ ^[0-9]+$ && "$LAST_BUILD" =~ ^[0-9]+$ ]] || (( BUILD <= LAST_BUILD )); then
        echo "error: CFBundleVersion \"$BUILD\" must be a number above $LAST_TAG's \"$LAST_BUILD\"" >&2
        exit 1
    fi
fi

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
"$ROOT/scripts/make-appcast.sh" "$APP" "$ROOT/build/$NAME"
echo "packaged build/$NAME, version $VERSION ($(du -h "$ROOT/build/$NAME" | cut -f1))"
echo "release: gh release create v$VERSION --target $(git -C "$ROOT" rev-parse HEAD) build/$NAME build/$NAME.sha256 build/appcast.xml"
