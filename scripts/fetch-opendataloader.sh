#!/usr/bin/env bash
# Fetches the opendataloader-pdf CLI JAR (Apache-2.0, https://github.com/opendataloader-project/opendataloader-pdf)
# into vendor/opendataloader/, pinned to one version and verified by SHA-256. The JAR ships inside the
# PyPI wheel; only it and its license files are kept. Re-running is a no-op when the JAR is present.
#   scripts/fetch-opendataloader.sh
set -euo pipefail

VERSION="2.5.12"
URL="https://files.pythonhosted.org/packages/08/69/1e77a850a6fe0b9b27a3459059f60ecce7ae191a2e16bc4488c8c0e10adc/opendataloader_pdf-${VERSION}-py3-none-any.whl"
SHA256="2b8da8b3f93f9912e47f090abe357d91e0b4aac8613af75b1a77c7e8e13ed1c0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/opendataloader"
if [[ -f "$DEST/opendataloader-pdf-cli.jar" && "$(cat "$DEST/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
    echo "opendataloader-pdf $VERSION already in $DEST"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "==> download opendataloader-pdf $VERSION"
curl -fsSL -o "$WORK/odl.whl" "$URL"
ACTUAL="$(shasum -a 256 "$WORK/odl.whl" | cut -d' ' -f1)"
if [[ "$ACTUAL" != "$SHA256" ]]; then
    echo "error: checksum mismatch (expected $SHA256, got $ACTUAL)" >&2
    exit 1
fi
unzip -q "$WORK/odl.whl" 'opendataloader_pdf/jar/*' 'opendataloader_pdf/LICENSE' 'opendataloader_pdf/NOTICE' \
    'opendataloader_pdf/THIRD_PARTY/*' -d "$WORK/wheel"

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$WORK/wheel/opendataloader_pdf/jar/opendataloader-pdf-cli.jar" "$DEST/"
cp "$WORK/wheel/opendataloader_pdf/LICENSE" "$WORK/wheel/opendataloader_pdf/NOTICE" "$DEST/"
cp -R "$WORK/wheel/opendataloader_pdf/THIRD_PARTY" "$DEST/"
echo "$VERSION" > "$DEST/VERSION"
echo "installed $DEST ($(du -sh "$DEST" | cut -f1))"
