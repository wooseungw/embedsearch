#!/usr/bin/env bash
# Builds EmbedSearch.app (Release, arm64) into build/EmbedSearch.app.
#   scripts/build-app.sh            # Release
#   CONFIGURATION=Debug scripts/build-app.sh
# The shell may run under Rosetta, so every xcodebuild call is prefixed with `arch -arm64`.
# Signs with the "Apple Development" identity from project.yml; set ADHOC=1 to sign ad hoc instead.
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

SIGN_ARGS=()
if [[ "${ADHOC:-0}" == "1" ]]; then
    SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO)
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
