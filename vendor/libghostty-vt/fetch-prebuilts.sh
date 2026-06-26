#!/usr/bin/env bash
# Fetch the vendored libghostty-vt.a prebuilts from the
# `vendored-libghostty-vt-0.1.0` GitHub release into the
# per-target lib-* dirs. Idempotent: skips files that already
# exist with the expected size.
#
# Used by:
#   - local devs after a fresh clone (~25MB download once)
#   - CI before `cargo build` on a cache miss
#
# To regenerate the .a's themselves (rare: only when ghostty
# bumps), see the matching `build-*.sh` scripts in this dir.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_TAG="vendored-libghostty-vt-0.1.0"
BASE_URL="https://github.com/chris-mclennan/mnml/releases/download/${RELEASE_TAG}"

# (asset name, target dir, expected size in bytes)
PREBUILTS=(
    "libghostty-vt-aarch64-darwin.a:lib-aarch64-darwin:8288216"
    "libghostty-vt-x86_64-linux.a:lib-x86_64-linux:14633768"
    "libghostty-vt-aarch64-linux.a:lib-aarch64-linux:14663002"
)

for entry in "${PREBUILTS[@]}"; do
    IFS=':' read -r asset subdir expected_size <<< "$entry"
    dest_dir="$DIR/$subdir"
    dest="$dest_dir/libghostty-vt.a"
    mkdir -p "$dest_dir"
    if [ -f "$dest" ]; then
        actual_size=$(wc -c < "$dest" | tr -d ' ')
        if [ "$actual_size" = "$expected_size" ]; then
            echo "$subdir/libghostty-vt.a — already present (${expected_size} bytes)"
            continue
        fi
        echo "$subdir/libghostty-vt.a — wrong size ($actual_size vs $expected_size), re-fetching"
    fi
    echo "fetching $asset → $dest"
    curl -fsSL -o "$dest" "$BASE_URL/$asset"
    actual_size=$(wc -c < "$dest" | tr -d ' ')
    if [ "$actual_size" != "$expected_size" ]; then
        echo "FAIL: $asset downloaded $actual_size bytes, expected $expected_size" >&2
        exit 1
    fi
done

echo "all prebuilts present"
