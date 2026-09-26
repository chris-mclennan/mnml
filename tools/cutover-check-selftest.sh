#!/usr/bin/env bash
# tools/cutover-check-selftest.sh — proves every tools/cutover-check.sh
# FAIL fires, on a throwaway repo, with a fake gh (MNML_GH) and a fake
# zig (MNML_ZIG). No network, no build, ~15 s.
#
# A good fake repo first: every item ok, exit 0. Then one breakage per
# case, each on a fresh copy, each asserting its item's verdict and the
# exit code:
#   tree          a dirty tracked file; a branch that is not main
#   work-data     a pattern hit → FAIL; no patterns file → todo, not ok
#   scrub         an API-key prefix, an auth header, a token assignment
#                 in CHANGELOG.md; a key prefix in docs/release-notes/
#   parity        a Remaining row beyond --demo; totals that do not add up
#   version       a tag build.zig.zon does not carry; the changelog
#                 heading that does not name it
#   integrations  a missing <id>-v<ver> release; one with 11 assets; a
#                 draft; no index.zon at all
#   dist-check    a script expecting 20; and the REAL scripts/dist-check.sh
#                 parsed (named == wanted), so a changed output format
#                 cannot turn the item into a silent FAIL-or-pass
#   secrets       a secret the workflows read that the repo lacks
#   gh            unauthenticated / --offline → the network items are
#                 todo, the exit stays 0
#   readme        no install line for the final repo
#   old-repo      an installer defaulting to the old repo; a URL in src/;
#                 (and docs/ history naming it stays ok)
#   --build       gate-targets failing; a --version that does not print
#                 the tag
#   --json        parses, carries ok=false and the failing item
#
#   tools/cutover-check-selftest.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$ROOT/tools/cutover-check.sh"
TMPDIR_BASE=${TMPDIR:-/tmp}; TMPDIR_BASE=${TMPDIR_BASE%/}
TMP=$(mktemp -d "${TMPDIR_BASE}/cutover-selftest.XXXXXX") || exit 70
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 30 | sed 's/^/       /'; }

# ── the fakes ──────────────────────────────────────────────────────────
# gh: `release view TAG` answers from $FAKE_GH/releases/TAG ("<n> <draft>"),
# `secret list` from $FAKE_GH/secrets; $FAKE_GH/unauth fails `auth status`.
FAKE_GH="$TMP/gh-state"
mkdir -p "$FAKE_GH/releases" "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "auth status") [ -f "$FAKE_GH/unauth" ] && exit 1; exit 0 ;;
  "api rate_limit") exit 0 ;;
  "release view")
    if [ -f "$FAKE_GH/releases/\$3" ]; then cat "$FAKE_GH/releases/\$3"; exit 0; fi
    echo "release not found" >&2; exit 1 ;;
  "secret list") cat "$FAKE_GH/secrets"; exit 0 ;;
esac
echo "fake gh: unexpected: \$*" >&2; exit 9
EOF
# zig: `build gate-targets` exits \$FAKE_ZIG_RC; a -p build writes a
# binary whose --version prints -Dversion (or \$FAKE_ZIG_SAYS).
cat > "$TMP/bin/zig" <<'EOF'
#!/bin/sh
[ "$2" = gate-targets ] && exit "${FAKE_ZIG_RC:-0}"
v=; p=
while [ $# -gt 0 ]; do
  case "$1" in -Dversion=*) v=${1#-Dversion=} ;; -p) p=$2; shift ;; esac
  shift
done
mkdir -p "$p/bin"
printf '#!/bin/sh\necho "mnml-zig %s (stable profile)"\n' "${FAKE_ZIG_SAYS:-$v}" > "$p/bin/mnml-zig"
chmod +x "$p/bin/mnml-zig"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/zig"
export MNML_GH="$TMP/bin/gh" MNML_ZIG="$TMP/bin/zig"
export MNML_WORK_DATA_PATTERNS="$TMP/patterns" MNML_WORK_DATA_ALLOW="$TMP/none"
printf '# the fake employer\nACMEWIDGETCO\n' > "$MNML_WORK_DATA_PATTERNS"

# Credential-shaped strings are assembled at run time, so this file never
# holds one itself.
KEY="sk-""a1b2c3d4e5f6g7h8"
AUTH="Authorization: ""Bearer abc.def"
TOKEN_LINE="token = ""\"x1\""

# ── the good repo ──────────────────────────────────────────────────────
GOOD="$TMP/good"
mkdir -p "$GOOD/tools" "$GOOD/scripts" "$GOOD/docs/release-notes" "$GOOD/integrations" "$GOOD/.github/workflows" "$GOOD/dist"
cp "$ROOT/tools/work-data-audit.sh" "$GOOD/tools/"
# A dist-check with the real one's output shapes and a list we control.
cat > "$GOOD/scripts/dist-check.sh" <<'EOF'
#!/usr/bin/env bash
n=${DIST_N:-21}; names=$(gh release view "$1" --json assets --jq '.assets[].name')
i=0; while [ $i -lt $n ]; do echo "dist-check: MISSING asset-$i" >&2; i=$((i + 1)); done
echo "dist-check: FAIL — 0 assets, wanted at least $n" >&2; exit 1
EOF
cat > "$GOOD/CHANGELOG.md" <<'EOF'
# Changelog

## v0.3.0 (unreleased)

- A line a user can see.

## v0.2.21

- An older line.
EOF
printf '# 0.3.0 notes\n\nPlain prose.\n' > "$GOOD/docs/release-notes/0.3.0.md"
cat > "$GOOD/docs/PARITY.md" <<'EOF'
# Parity

## Totals

| section | done | partial | cut | missing | rows |
|---|---|---|---|---|---|
| Editing | 10 | 0 | 1 | 0 | 11 |
| Headless | 5 | 0 | 0 | 1 | 6 |
| **total** | **15** | **0** | **1** | **1** | **17** |

## Remaining — what is still missing

| item | size | section |
|---|---|---|
| (none — every spec id has a runner) | — | Headless |
| `--demo` launch mode (deferred) | M | Headless |

## Cuts
EOF
printf '.{\n    .name = .mnml_zig,\n    .version = "0.3.0-dev",\n}\n' > "$GOOD/build.zig.zon"
cat > "$GOOD/integrations/index.zon" <<'EOF'
.{
    .integrations = .{
        .{ .id = "jira", .version = "0.2.0" },
        .{ .id = "sample", .version = "0.1.0" },
    },
}
EOF
cat > "$GOOD/README.md" <<'EOF'
# mnml

    curl -LsSf https://github.com/chris-mclennan/mnml/releases/latest/download/mnml-installer.sh | sh
EOF
printf 'repo=${MNML_REPO:-chris-mclennan/mnml}\n' > "$GOOD/dist/install.sh"
cat > "$GOOD/.github/workflows/release.yml" <<'EOF'
jobs:
  a:
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      TAP: ${{ secrets.TAP_TOKEN }}
EOF
( cd "$GOOD" && git init -q && git checkout -q -b main \
    && git -c user.name=t -c user.email=t@example.invalid add -A \
    && git -c user.name=t -c user.email=t@example.invalid commit -q -m good ) || { echo "selftest: git init failed" >&2; exit 70; }

reset_gh() {
    rm -rf "$FAKE_GH/releases" "$FAKE_GH/unauth"; mkdir -p "$FAKE_GH/releases"
    echo "12 false" > "$FAKE_GH/releases/jira-v0.2.0"
    echo "12 false" > "$FAKE_GH/releases/sample-v0.1.0"
    printf 'TAP_TOKEN\nOTHER\n' > "$FAKE_GH/secrets"
}
n_case=0
fresh() { n_case=$((n_case + 1)); R="$TMP/case$n_case"; cp -R "$GOOD" "$R"; reset_gh; }
commit() { (cd "$R" && git -c user.name=t -c user.email=t@example.invalid commit -qam "$1"); }

# run [args…] — runs the check on $R; OUT, RC.
run() { OUT=$(bash "$CHECK" --repo "$R" "$@" 2>&1); RC=$?; }
state() { printf '%s\n' "$OUT" | awk -v id="$1" '$2 == id { print $1; exit }'; }
expect() {  # expect LABEL ID STATE RC
    local got; got=$(state "$2")
    if [ "$got" = "$3" ] && [ "$RC" = "$4" ]; then ok "$1"
    else bad "$1 — $2 is '${got:-absent}' (want $3), exit $RC (want $4)" "$OUT"; fi
}

# ── 0. the good repo is all ok ─────────────────────────────────────────
fresh; run --tag v0.3.0 --build
if [ "$RC" = 0 ] && ! printf '%s\n' "$OUT" | grep -qE '^(FAIL|todo) '; then
    ok "good repo: every item ok, exit 0 ($(printf '%s\n' "$OUT" | grep -c '^ok ') items)"
else bad "good repo: not all ok (exit $RC)" "$OUT"; fi
for id in tree work-data scrub parity version changelog integrations dist-check secrets readme old-repo targets version-build; do
    [ "$(state $id)" = ok ] || bad "good repo: $id is not ok" "$OUT"
done
run
expect "no --tag, no --build: the four are todo, exit stays 0" version todo 0
[ "$(state version-build)" = todo ] && [ "$(state targets)" = todo ] && [ "$(state changelog)" = todo ] \
    && ok "no --tag, no --build: changelog / targets / version-build are todo" || bad "todo items" "$OUT"

# ── 1. tree ────────────────────────────────────────────────────────────
fresh; echo "- dirty" >> "$R/CHANGELOG.md"; run
expect "tree: a dirty tracked file → FAIL" tree FAIL 1
fresh; (cd "$R" && git checkout -q -b cutover); run
expect "tree: on a branch that is not main → FAIL" tree FAIL 1

# ── 2. work-data ───────────────────────────────────────────────────────
fresh; echo "ACMEWIDGETCO ticket" >> "$R/README.md"; commit wd; run
expect "work-data: a pattern hit → FAIL" work-data FAIL 1
fresh; OUT=$(MNML_WORK_DATA_PATTERNS="$TMP/absent" bash "$CHECK" --repo "$R" 2>&1); RC=$?
expect "work-data: no patterns file → todo (checked nothing), not ok" work-data todo 0

# ── 3. scrub ───────────────────────────────────────────────────────────
fresh; printf -- '- the key %s leaked\n' "$KEY" >> "$R/CHANGELOG.md"; commit s1; run
expect "scrub: an API-key prefix in CHANGELOG.md → FAIL" scrub FAIL 1
printf '%s\n' "$OUT" | grep -q 'CHANGELOG.md:[0-9]' && ok "scrub: names the file and line" || bad "scrub: no file:line" "$OUT"
fresh; printf -- '- sends %s\n' "$AUTH" >> "$R/CHANGELOG.md"; commit s2; run
expect "scrub: an auth header with its value → FAIL" scrub FAIL 1
fresh; printf -- '- %s\n' "$TOKEN_LINE" >> "$R/CHANGELOG.md"; commit s3; run
expect "scrub: a token assignment with a quoted value → FAIL" scrub FAIL 1
fresh; printf 'uses %s\n' "$KEY" >> "$R/docs/release-notes/0.3.0.md"; commit s4; run
expect "scrub: a key prefix in docs/release-notes/ → FAIL" scrub FAIL 1

# ── 4. parity ──────────────────────────────────────────────────────────
fresh; awk '{ print } /^\| `--demo`/ { print "| WebP decoding | S | UI |" }' "$R/docs/PARITY.md" > "$R/p.new" && mv "$R/p.new" "$R/docs/PARITY.md"
commit p1; run
expect "parity: a Remaining row beyond --demo → FAIL" parity FAIL 1
fresh; sed -i.bak 's/| \*\*17\*\* |/| **18** |/' "$R/docs/PARITY.md" && rm -f "$R/docs/PARITY.md.bak"; commit p2; run
expect "parity: totals that do not add up → FAIL" parity FAIL 1
fresh; sed -i.bak 's/^| Editing | 10 |/| Editing | 9 |/' "$R/docs/PARITY.md" && rm -f "$R/docs/PARITY.md.bak"; commit p3; run
expect "parity: sections that do not sum to the total line → FAIL" parity FAIL 1

# ── 5. version / changelog ─────────────────────────────────────────────
fresh; run --tag v0.4.0
expect "version: a tag build.zig.zon does not carry → FAIL" version FAIL 1
[ "$(state changelog)" = FAIL ] && ok "changelog: a heading that does not name the tag → FAIL" || bad "changelog heading" "$OUT"
fresh; run --tag v0.3.0-rc0
expect "version: a prerelease of the zon's version is ok" version ok 0

# ── 6. integrations ────────────────────────────────────────────────────
fresh; rm "$FAKE_GH/releases/sample-v0.1.0"; run
expect "integrations: a missing <id>-v<ver> release → FAIL" integrations FAIL 1
printf '%s\n' "$OUT" | grep -q 'sample-v0.1.0: no release' && ok "integrations: names the missing tag" || bad "integrations: tag not named" "$OUT"
fresh; echo "11 false" > "$FAKE_GH/releases/jira-v0.2.0"; run
expect "integrations: a release with 11 assets → FAIL" integrations FAIL 1
fresh; echo "12 true" > "$FAKE_GH/releases/jira-v0.2.0"; run
expect "integrations: a draft release → FAIL" integrations FAIL 1
fresh; (cd "$R" && git rm -q integrations/index.zon); commit i4; run
expect "integrations: no integrations/index.zon → FAIL" integrations FAIL 1

# ── 7. dist-check ──────────────────────────────────────────────────────
fresh; OUT=$(DIST_N=20 bash "$CHECK" --repo "$R" 2>&1); RC=$?
expect "dist-check: a script expecting 20 → FAIL" dist-check FAIL 1
fresh; cp "$ROOT/scripts/dist-check.sh" "$R/scripts/dist-check.sh"; commit real; run
line=$(printf '%s\n' "$OUT" | grep -E '^(ok|FAIL) +dist-check ')
k=$(printf '%s\n' "$line" | sed -n 's/.*names \([0-9]*\) asset(s) and wants \([0-9]*\);.*/\1 \2/p')
if printf '%s' "$line" | grep -q '^ok '; then ok "dist-check: the real script parses: $line"
elif [ -n "$k" ] && [ "${k% *}" = "${k#* }" ] && [ "${k% *}" -ge 16 ]; then ok "dist-check: the real script parses (names == wants == ${k% *})"
else bad "dist-check: the real script's output did not parse" "$OUT"; fi

# ── 8. secrets / gh ────────────────────────────────────────────────────
fresh; printf 'OTHER\n' > "$FAKE_GH/secrets"; run
expect "secrets: a secret the workflows read is missing → FAIL" secrets FAIL 1
printf '%s\n' "$OUT" | grep -q 'TAP_TOKEN' && ok "secrets: names it" || bad "secrets: not named" "$OUT"
fresh; touch "$FAKE_GH/unauth"; run
expect "gh unauthenticated: integrations → todo, exit 0" integrations todo 0
[ "$(state secrets)" = todo ] && ok "gh unauthenticated: secrets → todo" || bad "secrets not todo" "$OUT"
fresh; run --offline
expect "--offline: integrations → todo, exit 0" integrations todo 0

# ── 9. readme ──────────────────────────────────────────────────────────
fresh; printf 'repo=${MNML_REPO:-chris-mclennan/mnml-zig}\n' > "$R/dist/install.sh"; commit r1; run
expect "old-repo: an installer defaulting to the old repo → FAIL" old-repo FAIL 1
fresh; mkdir -p "$R/src"; printf 'const url = "https://github.com/chris-mclennan/mnml-zig/issues";\n' > "$R/src/a.zig"; (cd "$R" && git add src/a.zig); commit r3; run
expect "old-repo: a URL baked into src/ → FAIL" old-repo FAIL 1
fresh; mkdir -p "$R/docs"; printf 'history: chris-mclennan/mnml-zig\n' > "$R/docs/h.md"; (cd "$R" && git add docs/h.md); commit r4; run
expect "old-repo: docs/ history naming it is not shipped → ok" old-repo ok 0
fresh; printf '# mnml\n\nNo install line.\n' > "$R/README.md"; commit r2; run
expect "readme: no install line for the final repo → FAIL" readme FAIL 1

# ── 10. --build ────────────────────────────────────────────────────────
fresh; OUT=$(FAKE_ZIG_RC=1 bash "$CHECK" --repo "$R" --tag v0.3.0 --build 2>&1); RC=$?
expect "--build: gate-targets failing → FAIL" targets FAIL 1
fresh; OUT=$(FAKE_ZIG_SAYS=0.3.0-dev+gabc bash "$CHECK" --repo "$R" --tag v0.3.1 --build 2>&1); RC=$?
[ "$(state version-build)" = FAIL ] && ok "--build: a --version that does not print the tag → FAIL" || bad "version-build" "$OUT"

# ── 11. --json ─────────────────────────────────────────────────────────
fresh; rm "$FAKE_GH/releases/jira-v0.2.0"; OUT=$(bash "$CHECK" --repo "$R" --json 2>&1); RC=$?
if command -v python3 >/dev/null 2>&1; then
    j=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], [i["status"] for i in d["items"] if i["id"]=="integrations"][0], d["counts"]["fail"])' 2>&1)
    [ "$j" = "False FAIL 1" ] && [ "$RC" = 1 ] && ok "--json: parses; ok=false, integrations FAIL, exit 1" || bad "--json: got '$j' exit $RC" "$OUT"
else
    printf '%s' "$OUT" | grep -q '"ok":false' && ok "--json: ok=false (no python3 to parse)" || bad "--json" "$OUT"
fi

# ── 12. usage ──────────────────────────────────────────────────────────
bash "$CHECK" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help"
bash "$CHECK" --bogus >/dev/null 2>&1; [ $? = 64 ] && ok "an unknown argument exits 64" || bad "unknown argument"
bash "$CHECK" --tag 0.3 >/dev/null 2>&1; [ $? = 64 ] && ok "a tag without the v exits 64" || bad "bad tag"

echo "cutover-check-selftest: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
