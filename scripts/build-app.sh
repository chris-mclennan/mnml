#!/usr/bin/env bash
#
# Build mnml.app — a hand-rolled macOS app bundle.
#
#   ./scripts/build-app.sh                    # debug profile, builds target/mnml.app
#   ./scripts/build-app.sh release            # release profile
#   ./scripts/build-app.sh --bin-path PATH    # skip cargo build, use this binary
#   ./scripts/build-app.sh --nightly          # builds target/mnml-nightly.app
#                                             # (uses Info-nightly.plist + nightly icon;
#                                             # launcher always execs the latest
#                                             # ~/Projects/mnml/target/release/mnml)
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
# Launcher dispatch: if `tmnl` is on PATH the launcher opens mnml as
# a native tmnl tab; otherwise it falls back to Terminal.app.
#
# `--bin-path` is for CI — cargo-dist has already built the binary
# at a known path; we just package it.

set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="debug"
BIN_PATH=""
NIGHTLY=0
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
        --nightly)
            NIGHTLY=1
            shift
            ;;
        *)
            echo "usage: $0 [debug|release] [--bin-path PATH] [--nightly]" >&2
            exit 2
            ;;
    esac
done

if [ "$NIGHTLY" = 0 ]; then
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
fi

if [ "$NIGHTLY" = 1 ]; then
    APP="target/mnml-nightly.app"
    LAUNCHER_SRC="scripts/launcher-nightly.sh"
    LAUNCHER_NAME="mnml-nightly-launcher"
    PLIST_SRC="scripts/Info-nightly.plist"
    ICON_SRC="scripts/icon/AppIcon-nightly.icns"
else
    APP="target/mnml.app"
    LAUNCHER_SRC="scripts/launcher.sh"
    LAUNCHER_NAME="mnml-launcher"
    PLIST_SRC="scripts/Info.plist"
    ICON_SRC="scripts/icon/AppIcon.icns"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$LAUNCHER_SRC" "$APP/Contents/MacOS/$LAUNCHER_NAME"
chmod +x "$APP/Contents/MacOS/$LAUNCHER_NAME"
# Stable bundles ship a packaged copy of the binary; nightly skips
# this and points the launcher straight at the source tree.
if [ "$NIGHTLY" = 0 ]; then
    cp "$BIN_PATH" "$APP/Contents/Resources/bin/mnml"
fi
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
    if [ "$NIGHTLY" = 1 ]; then
        (cd scripts/icon && swift gen_icon.swift AppIcon-nightly.iconset nightly && iconutil -c icns AppIcon-nightly.iconset -o AppIcon-nightly.icns) >/dev/null
    else
        (cd scripts/icon && ./build.sh) >/dev/null
    fi
fi
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

# Strip the quarantine bit so Finder doesn't Gatekeeper-block the
# first launch. Best-effort.
xattr -d com.apple.quarantine "$APP" 2>/dev/null || true

echo "built $APP"
echo "launch: open $APP"
