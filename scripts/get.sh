#!/usr/bin/env bash
# Installs the latest EmbedSearch release into /Applications (or ~/Applications) and launches it:
#   curl -fsSL https://raw.githubusercontent.com/wooseungw/embedsearch/main/scripts/get.sh | bash
# Files fetched with curl carry no quarantine flag, so Gatekeeper does not stop the un-notarized app.
# For a local build use scripts/install.sh instead.
set -euo pipefail

# Wrapped in a function so bash reads the whole script before running any of it when piped from curl.
main() {
    local base="https://github.com/wooseungw/embedsearch/releases/latest/download"
    local bundle_id="com.seungwoo.embedsearch"

    # Not `uname -m`: a shell under Rosetta reports x86_64 on Apple Silicon.
    if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]]; then
        echo "error: EmbedSearch needs an Apple Silicon Mac" >&2
        exit 1
    fi
    local version
    version="$(sw_vers -productVersion)"
    if (( ${version%%.*} < 15 )); then
        echo "error: EmbedSearch needs macOS 15 or later (this Mac: $version)" >&2
        exit 1
    fi

    local dest_dir="/Applications"
    [[ -w "$dest_dir" ]] || dest_dir="$HOME/Applications"
    local dest="$dest_dir/EmbedSearch.app"

    WORK="$(mktemp -d)"
    trap 'hdiutil detach -quiet "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT

    echo "==> download EmbedSearch.dmg"
    curl -fL --progress-bar -o "$WORK/EmbedSearch.dmg" "$base/EmbedSearch.dmg"
    curl -fsSL -o "$WORK/EmbedSearch.dmg.sha256" "$base/EmbedSearch.dmg.sha256"
    (cd "$WORK" && shasum -a 256 -c EmbedSearch.dmg.sha256 >/dev/null) || {
        echo "error: checksum mismatch" >&2
        exit 1
    }

    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$WORK/mnt" "$WORK/EmbedSearch.dmg" </dev/null

    echo "==> quit running EmbedSearch"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x EmbedSearch >/dev/null || break
        sleep 0.25
    done
    pkill -x EmbedSearch 2>/dev/null || true

    echo "==> install to $dest"
    mkdir -p "$dest_dir"
    rm -rf "$dest"
    ditto "$WORK/mnt/EmbedSearch.app" "$dest"

    open "$dest"
    echo "installed $dest — press ⌥Space to search"
}

main "$@"
