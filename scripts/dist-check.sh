#!/usr/bin/env bash
# dist-check.sh — after a release, prove the assets are really there.
#
#   scripts/dist-check.sh v0.3.0                       # the full set: 21 assets
#   scripts/dist-check.sh v0.3.0 --min 17 --without-linux-packages
#                                                      # release.yml's own check,
#                                                      # before package-linux runs
#
# Why: the Rust repo shipped two releases (v0.2.9, v0.2.18) whose workflow
# was green and whose release carried one file. GitHub had scrubbed a
# secret-shaped changelog line inside the build manifest, the matrix failed
# to parse, the build jobs were skipped, and nothing downstream noticed. A
# green run is a claim; this is the receipt.
#
# Checks: the release exists; every expected asset name is present; the
# count is at least --min (default: the full set); and one archive really
# holds share/mnml/lua/ — the curated Lua script set, without which the
# SCRIPTS section's Marketplace tab is empty for everyone who installed
# from a release rather than a checkout. Any miss is exit 1. Needs gh,
# authenticated, with GH_REPO set or a git remote to infer from.
# --names-only skips the download, for a quick name-and-count pass.
set -euo pipefail

tag=${1:?usage: dist-check.sh vX.Y.Z [--min N] [--without-linux-packages]}
shift
min=
with_linux=1
names_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --min) min=$2; shift 2 ;;
        --without-linux-packages) with_linux=0; shift ;;
        --names-only) names_only=1; shift ;;
        *) echo "dist-check: unknown argument: $1" >&2; exit 2 ;;
    esac
done

triples=(aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-pc-windows-gnu)
expected=()
for t in "${triples[@]}"; do
    case "$t" in
        *-windows-*) expected+=("mnml-$t.zip" "mnml-$t.zip.sha256") ;;
        *) expected+=("mnml-$t.tar.xz" "mnml-$t.tar.xz.sha256") ;;
    esac
done
expected+=(sha256.sum mnml-installer.sh mnml-installer.ps1 dist-manifest.json integrations.json)
expected+=(mnml-x86_64-pc-windows-gnu.msi mnml-x86_64-pc-windows-gnu.msi.sha256)
if [ "$with_linux" = 1 ]; then
    expected+=(mnml-x86_64-unknown-linux-gnu.deb mnml-x86_64-unknown-linux-gnu.rpm
               mnml-aarch64-unknown-linux-gnu.deb mnml-aarch64-unknown-linux-gnu.rpm)
fi
min=${min:-${#expected[@]}}

command -v gh >/dev/null 2>&1 || { echo "dist-check: gh is not installed" >&2; exit 1; }

echo "── $tag ──"
if ! names=$(gh release view "$tag" --json assets --jq '.assets[].name'); then
    echo "dist-check: FAIL — no release $tag (or gh cannot see it)" >&2
    exit 1
fi
count=$(printf '%s\n' "$names" | sed '/^$/d' | wc -l | tr -d ' ')
echo "$count assets:"
printf '%s\n' "$names" | sed 's/^/  /'

fail=0
for want in "${expected[@]}"; do
    if ! printf '%s\n' "$names" | grep -qx -- "$want"; then
        echo "dist-check: MISSING $want" >&2
        fail=1
    fi
done
if [ "$count" -lt "$min" ]; then
    echo "dist-check: FAIL — $count assets, wanted at least $min" >&2
    fail=1
fi

if [ "$fail" = 1 ]; then
    echo "dist-check: FAIL. A tag that shipped short cannot be reused safely — bump the patch and re-cut." >&2
    exit 1
fi

# The names are right; now prove one archive's CONTENT. A tarball whose
# binary is there but whose share/mnml/lua/ is not passes every name
# check and still ships an empty Marketplace tab, so the receipt has to
# open the box.
if [ "$names_only" = 0 ]; then
    probe=mnml-x86_64-unknown-linux-gnu.tar.xz
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    if ! gh release download "$tag" --pattern "$probe" --dir "$tmp" >/dev/null 2>&1; then
        echo "dist-check: FAIL — could not download $probe" >&2
        exit 1
    fi
    have=$(tar -tJf "$tmp/$probe" | grep -c 'share/mnml/lua/[^/]*/script\.zon$' || true)
    if [ "$have" -lt 1 ]; then
        echo "dist-check: FAIL — $probe carries no share/mnml/lua/<name>/script.zon" >&2
        echo "  the Marketplace tab would be empty on every install from this release." >&2
        exit 1
    fi
    echo "dist-check: $probe carries $have shipped script(s) under share/mnml/lua/"
fi
echo "dist-check: ok — $count assets, all ${#expected[@]} expected names present"
