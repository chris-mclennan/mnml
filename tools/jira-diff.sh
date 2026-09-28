#!/usr/bin/env bash
# tools/jira-diff.sh [work|fix-versions|boards]…
#
# Runs the reference tracker and the port headless against the offline
# Jira (integrations/jira/tools/fake_jira) through the same scripted
# session, and prints the rows that differ per screen — by content, not
# by cell (tools/jira-diff-compare.py explains the reduction).
#
# The reference is driven in a pty by tools/jira-capture.py with a
# throw-away HOME (its config and a fake token live there) and a private
# rate-limiter bucket; the port by `mnml-jira --dump`. Both read
# tools/jira-diff/*.steps for the family.
#
#   JIRA_REF_BIN   the reference binary (default: the release build in
#                  /tmp/mnml-int-target, else mnml-tracker-jira on PATH)
#   JIRA_DIFF_OUT  where the dumps land (default: a temp dir, kept)
#
# Exit 0 when both sides produced every screen; 1 when a side failed to
# run. The diff counts are the deliverable, not a gate.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1

families=("$@")
[ ${#families[@]} -eq 0 ] && families=(work fix-versions boards)

ref=${JIRA_REF_BIN:-}
if [ -z "$ref" ]; then
    if [ -x /tmp/mnml-int-target/release/mnml-tracker-jira ]; then
        ref=/tmp/mnml-int-target/release/mnml-tracker-jira
    else
        ref=$(command -v mnml-tracker-jira || true)
    fi
fi
[ -n "$ref" ] && [ -x "$ref" ] || { echo "jira-diff: no reference binary (set JIRA_REF_BIN)" >&2; exit 1; }

out=${JIRA_DIFF_OUT:-$(mktemp -d /tmp/jira-diff.XXXXXX)}
mkdir -p "$out"
echo "jira-diff: dumps in $out"

# The port and the offline server, built at the root the way the corpus has them.
zig build jira-integration >/dev/null 2>&1 || { echo "jira-diff: zig build jira-integration failed" >&2; exit 1; }
port_bin=zig-out/bin/mnml-jira
fake_bin=zig-out/bin/mnml-fake-jira

# The server on a free port, for the whole run.
# --parent-pid: a run killed half way leaves no server on the port.
"$fake_bin" --port 0 --port-file "$out/port" --pid-file "$out/fake.pid" --life-secs 900 --parent-pid $$ --quiet >/dev/null 2>&1 &
for _ in $(seq 1 50); do [ -s "$out/port" ] && break; sleep 0.1; done
port=$(cat "$out/port" 2>/dev/null)
[ -n "$port" ] || { echo "jira-diff: the offline server did not start" >&2; exit 1; }
cleanup() { [ -f "$out/fake.pid" ] && kill "$(cat "$out/fake.pid")" 2>/dev/null; }
trap cleanup EXIT

# The reference's HOME: its config and a fake token; a private limiter bucket.
home="$out/home"
mkdir -p "$home/.config/mnml-tracker-jira" "$out/ratelimit"
sed "s/PORT/$port/" tools/jira-diff/config.toml > "$home/.config/mnml-tracker-jira.toml"
printf 'fake-token' > "$home/.config/mnml-tracker-jira/token"
chmod 600 "$home/.config/mnml-tracker-jira/token"
sed "s/PORT/$port/" tools/jira-diff/config.zon > "$out/config.zon"

status=0
for fam in "${families[@]}"; do
    echo "jira-diff: $fam — the reference"
    rdir="$out/rust-$fam"
    mkdir -p "$rdir"
    python3 tools/jira-capture.py --bin "$ref" --out "$rdir" --size 120x40 --home "$home" \
        --env "MNML_SHARED_STATE_DIR=$out/ratelimit" --env "BITBUCKET_ACCESS_TOKEN=fake-forge" \
        --steps "tools/jira-diff/rust-$fam.steps" -- --config "$home/.config/mnml-tracker-jira.toml" --only "$fam" \
        > "$out/rust-$fam.log" 2>&1 || { echo "jira-diff: the reference failed on $fam (see $out/rust-$fam.log)"; status=1; }
    echo "jira-diff: $fam — the port"
    JIRA_API_TOKEN=fake-token BITBUCKET_ACCESS_TOKEN=fake-forge \
        "$port_bin" --dump --only "$fam" --config "$out/config.zon" --steps "tools/jira-diff/zig-$fam.steps" --size 120x40 \
        > "$out/zig-$fam.txt" 2> "$out/zig-$fam.log" || { echo "jira-diff: the port failed on $fam (see $out/zig-$fam.log)"; status=1; }
    echo
    echo "### $fam"
    python3 tools/jira-diff-compare.py --rust "$rdir" --zig "$out/zig-$fam.txt"
    echo
done
exit $status
