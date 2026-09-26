#!/bin/sh
# package-integration.sh — turn one integration's per-target builds into
# release assets. `release-integration.yml` runs it after building
# `integrations/<id>/` for the five shipped targets; it runs the same on
# a Mac.
#
# In:   <release-dir>/<rust-triple>/bin/<binary>[.exe]   one per target
# Out:  mnml-<id>-<triple>.tar.xz          (.zip for Windows)
#       mnml-<id>-<triple>.tar.xz.sha256   `<hash>  <file>` (sha256sum -c)
#       sha256.sum                         `<hash> *<file>`, every archive
#       integration.json                   what this release carries, as
#                                          data: id, version, the SDK it
#                                          was built on, the binary, and
#                                          per target the asset's URL and
#                                          sha256. `release.yml` folds one
#                                          of these per integration into
#                                          the mnml release's
#                                          integrations.json.
#
# Each archive holds one directory, mnml-<id>-<triple>/, with the binary,
# the integration's README.md and the two licenses — the layout the mnml
# archives have. mnml's marketplace install takes the file whose name is
# the binary's out of it and ignores the rest.
#
# Usage: scripts/package-integration.sh --id ID --version V --binary NAME
#            --sdk V --release-dir DIR --out DIR --url-base URL
#   --url-base  where the assets will be downloadable, without the file
#               name: https://github.com/<repo>/releases/download/<tag>
set -eu

id=
version=
binary=
sdk=
release_dir=
out=
url_base=
while [ $# -gt 0 ]; do
    case "$1" in
        --id) id=$2; shift 2 ;;
        --version) version=$2; shift 2 ;;
        --binary) binary=$2; shift 2 ;;
        --sdk) sdk=$2; shift 2 ;;
        --release-dir) release_dir=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --url-base) url_base=$2; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "package-integration.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done
for v in id version binary sdk release_dir out url_base; do
    eval "val=\${$v}"
    [ -n "$val" ] || { echo "package-integration.sh: --$(echo "$v" | tr _ -) is required" >&2; exit 2; }
done
case "$id" in
    *[!A-Za-z0-9_-]*) echo "package-integration.sh: '$id' is not an integration id" >&2; exit 2 ;;
esac
[ -d "$release_dir" ] || { echo "package-integration.sh: no release dir at $release_dir" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/integrations/$id"
[ -d "$src" ] || { echo "package-integration.sh: no integrations/$id in $repo" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else openssl dgst -sha256 "$1" | sed 's/^.*= //'
    fi
}

rm -rf "$out"
mkdir -p "$out"
stage=$(mktemp -d "${TMPDIR:-/tmp}/mnml-int.XXXXXX")
trap 'rm -rf "$stage"' EXIT

assets_json=
count=0
for dir in "$release_dir"/*/; do
    triple=$(basename "$dir")
    case "$triple" in
        *-windows-*) bin="$binary.exe"; ext=zip ;;
        *) bin=$binary; ext=tar.xz ;;
    esac
    [ -f "$dir/bin/$bin" ] || { echo "package-integration.sh: $dir has no bin/$bin" >&2; exit 1; }

    pkg="mnml-$id-$triple"
    mkdir -p "$stage/$pkg"
    cp "$dir/bin/$bin" "$stage/$pkg/$bin"
    chmod 0755 "$stage/$pkg/$bin"
    [ -f "$src/README.md" ] && cp "$src/README.md" "$stage/$pkg/README.md"
    for extra in LICENSE-MIT LICENSE-APACHE; do
        [ -f "$repo/$extra" ] && cp "$repo/$extra" "$stage/$pkg/$extra"
    done

    asset="$pkg.$ext"
    case "$ext" in
        zip) (cd "$stage" && zip -q -r -X "$out/$asset" "$pkg") ;;
        tar.xz) (cd "$stage" && tar -cf - "$pkg") | xz -9 -T0 > "$out/$asset" ;;
    esac
    rm -rf "$stage/$pkg"

    hash=$(sha256 "$out/$asset")
    printf '%s  %s\n' "$hash" "$asset" > "$out/$asset.sha256"
    printf '%s *%s\n' "$hash" "$asset" >> "$out/sha256.sum"
    echo "  $asset  $(wc -c < "$out/$asset" | tr -d ' ') bytes  $hash"

    entry=$(printf '{"target":"%s","name":"%s","url":"%s/%s","sha256":"%s"}' "$triple" "$asset" "$url_base" "$asset" "$hash")
    if [ -z "$assets_json" ]; then assets_json=$entry; else assets_json="$assets_json,$entry"; fi
    count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "package-integration.sh: nothing under $release_dir" >&2; exit 1; }

printf '{"schema":1,"id":"%s","version":"%s","sdk":"%s","binary":"%s","assets":[%s]}\n' \
    "$id" "$version" "$sdk" "$binary" "$assets_json" > "$out/integration.json"
echo "  integration.json  $count target(s)"
