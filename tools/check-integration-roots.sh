#!/usr/bin/env bash
# tools/check-integration-roots.sh
#
# Builds and tests the integrations that live OUTSIDE this repository —
# a private repo's, a team's — against the SDK they depend on, so a
# verification chain notices when an SDK change breaks one of them.
#
#   MNML_EXTRA_INTEGRATION_ROOTS   a path-delimited list (`:`; `;` on
#                                  Windows) of `integrations/`-shaped
#                                  folders: each subfolder holding a
#                                  `build.zig` and a `manifest.zon` is
#                                  one integration
#   ZIG                            the zig to run (default: `zig` on PATH)
#   CHECK_ROOTS_LOG_DIR            where each build's output goes
#                                  (default: a fresh temp folder)
#
# For every integration: `zig build`, then `zig build test --summary all`,
# in its own folder (so the build lands in that folder's own `zig-out` /
# `.zig-cache` — nothing else is written). One line each:
#
#   ok   <root>/<id> (<n> tests)
#   FAIL <root>/<id> (<n> tests) — build|test failed, log: <file>
#
# Exits 1 when any failed, 0 otherwise — and 0 with a note when the
# variable is unset or empty: no extra roots is the normal case.
set -u
roots="${MNML_EXTRA_INTEGRATION_ROOTS:-}"
if [ -z "$roots" ]; then
    echo "check-integration-roots: MNML_EXTRA_INTEGRATION_ROOTS is not set — no extra roots"
    exit 0
fi
zig="${ZIG:-zig}"
logs="${CHECK_ROOTS_LOG_DIR:-}"
if [ -z "$logs" ]; then
    logs=$(mktemp -d "${TMPDIR:-/tmp}/check-integration-roots.XXXXXX") || exit 2
fi
mkdir -p "$logs" || exit 2
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) sep=';' ;;
    *) sep=':' ;;
esac

fails=0
checked=0
IFS="$sep" read -r -a list <<< "$roots"
for root in "${list[@]}"; do
    [ -n "$root" ] || continue
    root="${root%/}"
    if [ ! -d "$root" ]; then
        echo "FAIL $root — not a folder"
        fails=$((fails + 1))
        continue
    fi
    for dir in "$root"/*/; do
        dir="${dir%/}"
        [ -f "$dir/build.zig" ] && [ -f "$dir/manifest.zon" ] || continue
        id=$(basename "$dir")
        log="$logs/$(basename "$root")-$id.log"
        checked=$((checked + 1))
        what=""
        if ! (cd "$dir" && "$zig" build) >"$log" 2>&1; then
            what="build"
        elif ! (cd "$dir" && "$zig" build test --summary all) >>"$log" 2>&1; then
            what="test"
        fi
        n=$(sed -nE 's/.*[0-9]+\/([0-9]+) tests passed.*/\1/p' "$log" | tail -1)
        [ -n "$n" ] || n=0
        if [ -z "$what" ]; then
            echo "ok   $root/$id ($n tests)"
        else
            echo "FAIL $root/$id ($n tests) — $what failed, log: $log"
            fails=$((fails + 1))
        fi
    done
done
if [ "$checked" -eq 0 ] && [ "$fails" -eq 0 ]; then
    echo "check-integration-roots: no integration folders (build.zig + manifest.zon) under $roots"
fi
[ "$fails" -eq 0 ]
