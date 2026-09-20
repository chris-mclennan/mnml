#!/bin/sh
# package.sh — turn zig-out/release/<rust-triple>/mnml into release assets.
#
# `zig build dist` runs this after `zig build release`. It is a plain POSIX
# script so the same packaging runs on the author's Mac and the ubuntu
# release runner without a third tool.
#
# Per target:      mnml-<triple>.tar.xz      (mnml-<triple>.zip for Windows)
#                  mnml-<triple>.tar.xz.sha256   `<hash>  <file>` (sha256sum -c)
# Once:            sha256.sum                    `<hash> *<file>`, every archive
#                  mnml-installer.sh / mnml-installer.ps1   copied from dist/
#                  dist-manifest.json            what a release carries, as data
#
# Each archive holds one directory, mnml-<triple>/, with the binary, the two
# licenses, README.md and CHANGELOG.md — the layout cargo-dist produced, so
# Homebrew's strip-one-directory extraction and package-linux's `find` keep
# working — plus share/mnml/lua/, the curated Lua script set (the repo's
# lua/). The binary looks for that folder beside itself and one level up, so
# an unpacked archive lists the five official scripts in the SCRIPTS
# section's Marketplace tab with no config; package-linux re-lays the same
# tree at /usr/share/mnml/lua — plus share/mnml/fonts/MnmlSymbols.ttf, the
# face mnml's own marks are drawn from (`zig build font`). No completions
# or man page yet; when they exist, stage them here.
#
# With --macos-app, every *-apple-darwin binary is also wrapped as an
# app bundle (dist/macos/build-app.sh) and shipped as
# mnml-<triple>.app.zip — an optional asset, off by default.
#
# Usage: scripts/package.sh --version V --release-dir DIR --out DIR [--name mnml] [--macos-app]
set -eu

name=mnml
version=
release_dir=
out=
macos_app=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) version=$2; shift 2 ;;
        --release-dir) release_dir=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --name) name=$2; shift 2 ;;
        --macos-app) macos_app=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "package.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$version" ] && [ -n "$release_dir" ] && [ -n "$out" ] || {
    echo "package.sh: --version, --release-dir and --out are required" >&2
    exit 2
}
[ -d "$release_dir" ] || { echo "package.sh: no release dir at $release_dir (run \`zig build release\`)" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)

# One sha256 for every platform: coreutils, perl's shasum, or openssl.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else openssl dgst -sha256 "$1" | sed 's/^.*= //'
    fi
}

rm -rf "$out"
mkdir -p "$out"
stage=$(mktemp -d "${TMPDIR:-/tmp}/mnml-dist.XXXXXX")
trap 'rm -rf "$stage"' EXIT

archives=
for dir in "$release_dir"/*/; do
    triple=$(basename "$dir")
    case "$triple" in
        *-windows-*) bin=mnml.exe; ext=zip ;;
        *) bin=mnml; ext=tar.xz ;;
    esac
    [ -f "$dir/$bin" ] || { echo "package.sh: $dir has no $bin" >&2; exit 1; }

    pkg="$name-$triple"
    mkdir -p "$stage/$pkg"
    cp "$dir/$bin" "$stage/$pkg/$bin"
    chmod 0755 "$stage/$pkg/$bin"
    for extra in LICENSE-MIT LICENSE-APACHE README.md CHANGELOG.md; do
        [ -f "$repo/$extra" ] && cp "$repo/$extra" "$stage/$pkg/$extra"
    done
    # The curated Lua script set, at the path the binary probes:
    # <exe dir>/share/mnml/lua (and <exe dir>/../share/mnml/lua once an
    # installer puts the binary in a bin/). Missing it would ship an
    # empty Marketplace tab, so this is fatal, not best-effort.
    [ -d "$repo/lua" ] || { echo "package.sh: no lua/ in $repo" >&2; exit 1; }
    mkdir -p "$stage/$pkg/share/mnml"
    cp -R "$repo/lua" "$stage/$pkg/share/mnml/lua"
    # MnmlSymbols.ttf, the face mnml's own block is drawn from — the
    # Claude and Codex marks, the tree connectors, the terminal icon.
    # `zig build` writes it beside the binary it just built; without it
    # every one of those renders as `?`, so this is fatal too.
    font_src="$dir/share/mnml/fonts/MnmlSymbols.ttf"
    [ -f "$font_src" ] || { echo "package.sh: $dir has no share/mnml/fonts/MnmlSymbols.ttf (run \`zig build\`)" >&2; exit 1; }
    mkdir -p "$stage/$pkg/share/mnml/fonts"
    cp "$font_src" "$stage/$pkg/share/mnml/fonts/MnmlSymbols.ttf"
    # The mnml catalogue — the INTEGRATIONS section's Marketplace tab
    # default source, probed beside the binary exactly as lua/ is.
    # Without it a packaged mnml lists no integrations at all, so this
    # is fatal too.
    [ -f "$repo/data/marketplace.zon" ] || { echo "package.sh: no data/marketplace.zon in $repo" >&2; exit 1; }
    cp "$repo/data/marketplace.zon" "$stage/$pkg/share/mnml/marketplace.zon"

    asset="$pkg.$ext"
    case "$ext" in
        zip) (cd "$stage" && zip -q -r -X "$out/$asset" "$pkg") ;;
        tar.xz) (cd "$stage" && tar -cf - "$pkg") | xz -9 -T0 > "$out/$asset" ;;
    esac
    rm -rf "$stage/$pkg"

    hash=$(sha256 "$out/$asset")
    printf '%s  %s\n' "$hash" "$asset" > "$out/$asset.sha256"
    printf '%s *%s\n' "$hash" "$asset" >> "$out/sha256.sum"
    archives="$archives $asset"
    echo "  $asset  $(wc -c < "$out/$asset" | tr -d ' ') bytes  $hash"

    # The optional macOS app bundle beside the archive.
    case "$triple" in
        *-apple-darwin)
            if [ "$macos_app" = 1 ]; then
                "$repo/dist/macos/build-app.sh" --bin "$dir/$bin" --version "$version" --out "$stage" >/dev/null
                app_asset="$pkg.app.zip"
                (cd "$stage" && zip -q -r -X -y "$out/$app_asset" "$name.app")
                rm -rf "$stage/$name.app"
                app_hash=$(sha256 "$out/$app_asset")
                printf '%s  %s\n' "$app_hash" "$app_asset" > "$out/$app_asset.sha256"
                printf '%s *%s\n' "$app_hash" "$app_asset" >> "$out/sha256.sum"
                app_assets="${app_assets:-} $app_asset"
                echo "  $app_asset  $(wc -c < "$out/$app_asset" | tr -d ' ') bytes  $app_hash"
            fi
            ;;
    esac
done
[ -n "$archives" ] || { echo "package.sh: nothing under $release_dir" >&2; exit 1; }

cp "$repo/dist/install.sh" "$out/$name-installer.sh"
cp "$repo/dist/install.ps1" "$out/$name-installer.ps1"
chmod 0755 "$out/$name-installer.sh"

# dist-manifest.json — hand-written JSON, no jq dependency. One object per
# asset keyed by filename, in the spirit of cargo-dist's manifest (the fields
# consumers actually read: kind, target, checksum), nothing more.
manifest="$out/dist-manifest.json"
case "$version" in *-*) prerelease=true ;; *) prerelease=false ;; esac
{
    printf '{\n'
    printf '  "dist_version": "mnml-zig %s",\n' "$version"
    printf '  "app_name": "%s",\n' "$name"
    printf '  "app_version": "%s",\n' "$version"
    printf '  "announcement_tag": "v%s",\n' "$version"
    printf '  "announcement_is_prerelease": %s,\n' "$prerelease"
    printf '  "artifacts": {\n'
    first=1
    for asset in $archives; do
        triple=${asset#"$name-"}
        triple=${triple%.tar.xz}
        triple=${triple%.zip}
        hash=$(cut -d' ' -f1 "$out/$asset.sha256")
        [ $first -eq 1 ] || printf ',\n'
        first=0
        printf '    "%s": {"kind": "executable-zip", "target_triples": ["%s"], "checksum": "%s.sha256", "sha256": "%s"}' "$asset" "$triple" "$asset" "$hash"
        printf ',\n    "%s.sha256": {"kind": "checksum", "target_triples": ["%s"]}' "$asset" "$triple"
    done
    for asset in ${app_assets:-}; do
        triple=${asset#"$name-"}
        triple=${triple%.app.zip}
        hash=$(cut -d' ' -f1 "$out/$asset.sha256")
        printf ',\n    "%s": {"kind": "macos-app", "target_triples": ["%s"], "checksum": "%s.sha256", "sha256": "%s"}' "$asset" "$triple" "$asset" "$hash"
        printf ',\n    "%s.sha256": {"kind": "checksum", "target_triples": ["%s"]}' "$asset" "$triple"
    done
    printf ',\n    "%s-installer.sh": {"kind": "installer", "target_triples": ["aarch64-apple-darwin", "x86_64-apple-darwin", "aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"]}' "$name"
    printf ',\n    "%s-installer.ps1": {"kind": "installer", "target_triples": ["x86_64-pc-windows-gnu"]}' "$name"
    printf ',\n    "sha256.sum": {"kind": "checksum"}\n'
    printf '  }\n'
    printf '}\n'
} > "$manifest"

echo "package.sh: $(ls "$out" | wc -l | tr -d ' ') files in $out"
