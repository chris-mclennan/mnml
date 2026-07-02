#!/usr/bin/env bash
#
# Build mnml.app — a hand-rolled macOS app bundle.
#
#   ./scripts/build-app.sh                    # debug profile, builds target/mnml.app
#   ./scripts/build-app.sh release            # release profile
#   ./scripts/build-app.sh --bin-path PATH    # skip cargo build, use this binary
#
# Launch with:  open target/mnml.app
#
# Bundle layout:
#   target/mnml.app/Contents/
#     Info.plist
#     MacOS/mnml-launcher       (small dispatch script — Contents/Resources/bin/mnml)
#     Resources/AppIcon.icns
#     Resources/bin/mnml        (the actual TUI binary)
#
# Launcher dispatch: opens mnml in Ghostty (falls back to Terminal.app).
#
# `--bin-path` is for CI — cargo-dist has already built the binary
# at a known path; we just package it.

set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="debug"
BIN_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        debug|release)
            PROFILE="$1"
            shift
            ;;
        --bin-path)
            BIN_PATH="$2"
            shift 2
            ;;
        *)
            echo "usage: $0 [debug|release] [--bin-path PATH]" >&2
            exit 2
            ;;
    esac
done

if [ -z "$BIN_PATH" ]; then
    case "$PROFILE" in
        debug)   cargo build --bin mnml ;;
        release) cargo build --release --bin mnml ;;
    esac
    BIN_PATH="target/$PROFILE/mnml"
fi
if [ ! -f "$BIN_PATH" ]; then
    echo "error: binary not found at $BIN_PATH" >&2
    exit 1
fi

APP="target/mnml.app"
LAUNCHER_SRC="scripts/launcher.sh"
LAUNCHER_NAME="mnml-launcher"
PLIST_SRC="scripts/Info.plist"
ICON_SRC="scripts/icon/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$LAUNCHER_SRC" "$APP/Contents/MacOS/$LAUNCHER_NAME"
chmod +x "$APP/Contents/MacOS/$LAUNCHER_NAME"
cp "$BIN_PATH" "$APP/Contents/Resources/bin/mnml"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"

# Stamp the build timestamp into CFBundleVersion so each rebuild is
# a distinct version from Finder's perspective. Without this,
# replacing an .app in /Applications often shows the stale icon /
# stale launcher because Finder's icon cache keys on bundle version
# + path. The user-facing CFBundleShortVersionString stays clean.
BUILD_STAMP="$(date +%Y%m%d%H%M%S)"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_STAMP" "$APP/Contents/Info.plist"

# App icon — built on demand if missing (no external image-tool deps;
# scripts/icon/gen_icon.swift draws from scratch in AppKit).
if [ ! -f "$ICON_SRC" ]; then
    echo "building app icon ($ICON_SRC)…"
    (cd scripts/icon && ./build.sh) >/dev/null
fi
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

# Strip the quarantine bit so Finder doesn't Gatekeeper-block the
# first launch. Best-effort.
xattr -d com.apple.quarantine "$APP" 2>/dev/null || true

echo "built $APP"
echo "launch: open $APP"
