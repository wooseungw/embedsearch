#!/usr/bin/env bash
# Writes the Sparkle update feed for a release dmg, signed with the EmbedSearch key in your keychain:
#   scripts/make-appcast.sh build/EmbedSearch.app build/EmbedSearch.dmg    # → build/appcast.xml
# Installed apps read .../releases/latest/download/appcast.xml (SUFeedURL in project.yml), so every
# release ships this file beside the dmg. It lists only that release and links its dmg by tag (vX.Y.Z).
# DOWNLOAD_URL overrides the dmg's address, for a local test feed.
# The private key was made once with
#   build/dd-app/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account com.seungwoo.embedsearch
# Back it up (generate_keys … -x <file>): without it, installed copies can never be updated again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
DMG="$2"
OUT="$(dirname "$DMG")/appcast.xml"
BIN="$ROOT/build/dd-app/SourcePackages/artifacts/sparkle/Sparkle/bin"
ACCOUNT="com.seungwoo.embedsearch"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MIN_SYSTEM="$(plist LSMinimumSystemVersion)"
URL="${DOWNLOAD_URL:-https://github.com/wooseungw/embedsearch/releases/download/v$VERSION/$(basename "$DMG")}"

# Written into XML unescaped.
if [[ "$URL$VERSION$BUILD" == *[\&\<\>\"]* ]]; then
    echo "error: & < > \" in the version or download URL: $VERSION $BUILD $URL" >&2
    exit 1
fi

# Installed copies reject an update signed with any other key than the one they carry.
# The Sparkle tools print their errors on stdout.
KEY="$("$BIN/generate_keys" --account "$ACCOUNT" -p)" || { echo "error: generate_keys: $KEY" >&2; exit 1; }
if [[ "$KEY" != "$(plist SUPublicEDKey)" ]]; then
    echo "error: the keychain's signing key does not match SUPublicEDKey in $APP: $KEY" >&2
    exit 1
fi

echo "==> sign $(basename "$DMG")"
SIGNATURE="$("$BIN/sign_update" --account "$ACCOUNT" "$DMG")" || { echo "error: sign_update: $SIGNATURE" >&2; exit 1; }
if ! [[ "$SIGNATURE" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]]; then
    echo "error: unexpected sign_update output: $SIGNATURE" >&2
    exit 1
fi

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EmbedSearch</title>
    <item>
      <title>EmbedSearch $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/wooseungw/embedsearch/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
echo "wrote $OUT ($VERSION, build $BUILD)"
