#!/usr/bin/env bash
# Builds EmbedSearch.app (Release, arm64) into build/EmbedSearch.app.
#   scripts/build-app.sh            # Release
#   CONFIGURATION=Debug scripts/build-app.sh
# The shell may run under Rosetta, so every xcodebuild call is prefixed with `arch -arm64`.
# Signs with your "Apple Development" identity when the keychain has one (TCC grants then survive
# rebuilds), otherwise ad hoc. ADHOC=1 forces ad hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="$ROOT/build/dd-app"
PRODUCT="$DERIVED_DATA/Build/Products/$CONFIGURATION/EmbedSearch.app"
OUTPUT="$ROOT/build/EmbedSearch.app"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found (brew install xcodegen)" >&2
    exit 1
fi

"$ROOT/scripts/fetch-opendataloader.sh"

echo "==> xcodegen generate"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet

TEAM_ID=""
if [[ "${ADHOC:-0}" != "1" ]] && security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development' >/dev/null; then
    # The team ID is the certificate subject's OU.
    TEAM_ID="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | awk -F' = ' '/organizationalUnitName/ {print $2; exit}' || true)"
fi
SIGN_ARGS=()
if [[ -n "$TEAM_ID" ]]; then
    echo "==> sign: Apple Development (team $TEAM_ID)"
    SIGN_ARGS=(CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES)
else
    echo "==> sign: ad hoc"
fi

echo "==> xcodebuild ($CONFIGURATION, arm64)"
arch -arm64 xcodebuild \
    -project "$ROOT/EmbedSearch.xcodeproj" \
    -scheme EmbedSearch \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
    build

echo "==> copy to $OUTPUT"
rm -rf "$OUTPUT"
mkdir -p "$ROOT/build"
ditto "$PRODUCT" "$OUTPUT"
codesign --verify --deep --strict "$OUTPUT" && echo "codesign: ok"
echo "built $OUTPUT"
