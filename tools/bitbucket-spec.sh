#!/usr/bin/env bash
# bitbucket-spec — dump the Zig Bitbucket pane's own screens against the
# offline fake server, the way tools/bitbucket-capture.py cuts the Rust
# reference's: docs/ui-spec/bitbucket/zig-<name>-<size>.txt.
#
#   tools/bitbucket-spec.sh                 # every screen, 120x40 and 80x24
#   tools/bitbucket-spec.sh prs 120x40      # one family at one size
#
# The driver is `mnml-bitbucket --dump` (the pane's own App and paint,
# no host around it — the same shape the rust-*.txt files have), on a
# scratch config over the fake's `acme` workspace. Nothing here ever
# reaches a live Bitbucket.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BB=$ROOT/zig-out/bin/mnml-bitbucket
FAKE=$ROOT/zig-out/bin/mnml-fake-bitbucket
OUT=$ROOT/docs/ui-spec/bitbucket
[ -x "$BB" ] && [ -x "$FAKE" ] || { echo "build first: zig build" >&2; exit 64; }
ONLY_FAMILY=${1:-}
ONLY_SIZE=${2:-}

TMP=$(mktemp -d)
trap 'kill $fake_pid 2>/dev/null; rm -rf "$TMP"' EXIT
"$FAKE" --port 0 --url-file "$TMP/bb.url" --lifetime-secs 120 >/dev/null 2>&1 &
fake_pid=$!
for _ in $(seq 1 50); do [ -s "$TMP/bb.url" ] && break; sleep 0.1; done
mkdir -p "$TMP/cfg" "$TMP/data"
cat >"$TMP/cfg/config.zon" <<'ZON'
.{ .email = "me@example.com", .workspace = "acme", .repos = .{ "api", "web" }, .refresh_interval_secs = 0, .rate = .{ .rate_per_sec = 1000, .capacity = 1000 }, .tabs = .{ .{ .name = "Open + Draft", .kind = .workspace_open_prs }, .{ .name = "Merged", .kind = .workspace_merged_prs }, .{ .name = "Pipelines", .kind = .workspace_pipelines } } }
ZON

dump() { # family size steps-file name
  local family=$1 size=$2 steps=$3 name=$4
  # A fresh state file per dump: the chips start on their defaults.
  rm -f "$TMP/cfg/state.zon"
  MNML_BITBUCKET_CONFIG=$TMP/cfg/config.zon BITBUCKET_BASE_URL=@$TMP/bb.url BITBUCKET_API_TOKEN=x \
  BITBUCKET_RATELIMIT_STATE=$TMP/bucket.json MNML_DATA_ROOT=$TMP/data \
    "$BB" --dump --only "$family" --size "$size" --steps "$steps" 2>"$TMP/err" \
    | sed -e '1{/^=== /d;}' >"$OUT/zig-$name-$size.txt"
  [ -s "$TMP/err" ] && cat "$TMP/err" >&2
  echo "== $OUT/zig-$name-$size.txt"
}

printf 'snap screen\n' >"$TMP/plain.txt"
printf 'key shift+s\nsnap screen\n' >"$TMP/status-picker.txt"
printf 'rclickon show:\nsnap screen\n' >"$TMP/show-menu.txt"
printf 'key shift+a\nkey shift+a\nsnap screen\n' >"$TMP/awaiting.txt"
printf 'key shift+s\nsnap screen\n' >"$TMP/pstatus-picker.txt"

for size in 120x40 80x24; do
  [ -n "$ONLY_SIZE" ] && [ "$ONLY_SIZE" != "$size" ] && continue
  if [ -z "$ONLY_FAMILY" ] || [ "$ONLY_FAMILY" = prs ]; then
    dump prs "$size" "$TMP/plain.txt" prs
    dump prs "$size" "$TMP/status-picker.txt" prs-status-picker
    dump prs "$size" "$TMP/show-menu.txt" prs-show-menu
    dump prs "$size" "$TMP/awaiting.txt" prs-awaiting
  fi
  if [ -z "$ONLY_FAMILY" ] || [ "$ONLY_FAMILY" = pipelines ]; then
    dump pipelines "$size" "$TMP/plain.txt" pipelines
    dump pipelines "$size" "$TMP/pstatus-picker.txt" pipelines-status-picker
  fi
done
