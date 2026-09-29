#!/bin/bash
# Builds Awake.app (release, arm64, ad-hoc signed).
#
#   ./build.sh             build into build/Awake.app
#   ./build.sh --install   also quit a running Awake, copy to ~/Applications and open it
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Awake"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        *) echo "unknown option: $arg (supported: --install)" >&2; exit 2 ;;
    esac
done

echo "==> Compiling (release, arm64)"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Every build gets its own version (a timestamp), so an installed copy is always
# distinguishable. Set on the copy in build/, never on the template.
BUILD_VERSION="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"

# App icon, drawn by Scripts/make-icon.swift. Optional: the build succeeds without it.
make_icon() {
    local work
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' RETURN
    swiftc -swift-version 5 -O Scripts/make-icon.swift -o "$work/make-icon" &&
        "$work/make-icon" "$work/AppIcon.iconset" &&
        iconutil -c icns "$work/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
}
echo "==> Generating icon"
if ! make_icon; then
    echo "warning: icon generation failed; building without an icon" >&2
    rm -f "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "Built $APP"

if $INSTALL; then
    INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
    INSTALLED_BIN="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ROOT="$(pwd -P)"

    echo "==> Installing to $INSTALL_DIR"
    pkill -x "$APP_NAME" || true
    # Wait (up to 5 s) for the old process to exit so it can save its data first.
    for _ in $(seq 1 50); do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
        # No kill -9: a forced kill would skip saving the day's time.
        echo "error: $APP_NAME is still running after 5 s, so it was not replaced." >&2
        echo "       Quit it from its menu bar icon (Quit Awake), then run this again." >&2
        exit 1
    fi

    # Another copy of the app could be opened instead of this one. Warn only; never delete.
    others="$(mdfind "kMDItemCFBundleIdentifier == 'com.abhishek.awake'" 2>/dev/null |
        grep -v -e "^$ROOT/$BUILD_DIR/" -e "^$INSTALL_DIR/" || true)"
    if [ -n "$others" ]; then
        echo "warning: other copies of $APP_NAME.app exist that macOS might open instead:" >&2
        echo "$others" | sed 's/^/           /' >&2
        echo "         (left untouched; delete them yourself if they are stale)" >&2
    fi

    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALLED_APP"
    ditto "$APP" "$INSTALLED_APP"
    open "$INSTALLED_APP"

    # Verify: the new process is running, from the installed path, with the binary just built.
    for _ in $(seq 1 50); do
        pgrep -x "$APP_NAME" >/dev/null && break
        sleep 0.1
    done
    pids="$(pgrep -x "$APP_NAME" || true)"
    if [ -z "$pids" ]; then
        echo "error: $APP_NAME did not start within 5 s after opening $INSTALLED_APP." >&2
        exit 1
    fi
    for pid in $pids; do
        running_from="$(ps -o comm= -p "$pid" | sed 's/[[:space:]]*$//')"
        if [ "$running_from" != "$INSTALLED_BIN" ]; then
            echo "error: $APP_NAME (pid $pid) runs from '$running_from', expected '$INSTALLED_BIN'." >&2
            exit 1
        fi
    done
    built_sum="$(shasum -a 256 "$APP/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)"
    installed_sum="$(shasum -a 256 "$INSTALLED_BIN" | cut -d' ' -f1)"
    if [ "$built_sum" != "$installed_sum" ]; then
        echo "error: installed binary differs from the one just built." >&2
        echo "       built     $built_sum" >&2
        echo "       installed $installed_sum" >&2
        exit 1
    fi
    echo "Installed and verified: $INSTALLED_APP (version $BUILD_VERSION, pid $(echo $pids | tr ' ' ','), sha256 ${built_sum:0:12})"
fi
