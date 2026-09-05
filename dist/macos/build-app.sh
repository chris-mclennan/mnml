#!/bin/sh
# build-app.sh — assemble mnml.app from a built mnml binary.
#
#   dist/macos/build-app.sh --bin PATH --version V --out DIR
#
# Produces DIR/mnml.app:
#   Contents/Info.plist              (dist/macos/Info.plist, version stamped)
#   Contents/MacOS/mnml-launcher     (dist/macos/launcher.sh)
#   Contents/Resources/bin/mnml      (the binary)
#
# Plain POSIX: it runs on the Linux release runner as well as a Mac
# (no plutil — the plist is a template with @VERSION@ / @BUILD@). No
# icon yet; when one exists, copy it to Contents/Resources/AppIcon.icns
# and add CFBundleIconFile to the plist.
set -eu

bin=
version=
out=
while [ $# -gt 0 ]; do
    case "$1" in
        --bin) bin=$2; shift 2 ;;
        --version) version=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-app.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$bin" ] && [ -n "$version" ] && [ -n "$out" ] || {
    echo "build-app.sh: --bin, --version and --out are required" >&2
    exit 2
}
[ -f "$bin" ] || { echo "build-app.sh: no binary at $bin" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
app="$out/mnml.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
cp "$here/launcher.sh" "$app/Contents/MacOS/mnml-launcher"
chmod 0755 "$app/Contents/MacOS/mnml-launcher"
cp "$bin" "$app/Contents/Resources/bin/mnml"
chmod 0755 "$app/Contents/Resources/bin/mnml"
# CFBundleVersion is the build stamp so Finder sees each rebuild as new.
build=$(date -u +%Y%m%d%H%M%S)
sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build/" "$here/Info.plist" > "$app/Contents/Info.plist"
# Best effort: drop the quarantine bit so the first launch is not blocked.
xattr -d com.apple.quarantine "$app" 2>/dev/null || true
echo "built $app"
