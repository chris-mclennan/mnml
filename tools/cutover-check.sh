#!/usr/bin/env bash
# tools/cutover-check.sh — is this tree ready to become chris-mclennan/mnml?
#
#   tools/cutover-check.sh                       # the static items; network ones if gh can see GitHub
#   tools/cutover-check.sh --tag v0.3.0          # + the version and changelog items for that tag
#   tools/cutover-check.sh --tag v0.3.0 --build  # + the five-target build and a fresh --version
#   tools/cutover-check.sh --json                # one JSON object on stdout, for machines
#
# One line per item: `ok`, `FAIL` or `todo`. `todo` is an item this run
# could not decide — no --tag, no --build, gh offline or unauthenticated,
# a work-data audit with no patterns to check — and never counts as a
# pass: cutover day wants every line `ok`. Any FAIL exits 1; otherwise 0.
#
# Read-only and idempotent: it runs git, gh, the repo's own audit
# scripts and (with --build) zig, and writes only under a temp dir —
# except --build's `zig build gate-targets`, which installs into
# zig-out/ as it always does. It never tags, pushes or edits a file.
#
# The items, in order (docs/CUTOVER.md, "Before the day", runs this):
#   tree          the working tree is clean and on main
#   work-data     tools/work-data-audit.sh reports 0 lines
#   scrub         no credential-shaped literal in CHANGELOG.md, the
#                 release notes under docs/release-notes/ or
#                 docs/CUTOVER.md (release.yml's pattern, plus a few
#                 more key shapes — the trap is in docs/RELEASE.md)
#   parity        docs/PARITY.md's totals add up, and the Remaining list
#                 holds only the agreed cut (--allow-remaining)
#   version       build.zig.zon's .version is the tag's version (-dev
#                 and any prerelease suffix aside)          needs --tag
#   changelog     CHANGELOG.md's top heading names the tag's version and
#                 its section is not empty                  needs --tag
#   integrations  every integrations/index.zon row has an <id>-v<ver>
#                 release on --gh-repo with 12 assets       needs gh
#   dist-check    scripts/dist-check.sh expects 21 assets (asked of the
#                 script itself, against a fake gh — not grepped)
#   secrets       every secrets.NAME a workflow reads exists on
#                 --gh-repo (GITHUB_TOKEN aside)            needs gh
#   readme        README's install lines download from --final-repo
#   old-repo      nothing that ships (src/, dist/, data/, the installers,
#                 README, workflows, …) still names --old-repo
#   targets       `zig build gate-targets` builds           needs --build
#   version-build a fresh ReleaseSafe build's --version prints the tag
#                                                           needs --tag --build
#
# Options:
#   --tag vX.Y.Z            the tag cutover day will push
#   --build                 run the two build items (minutes, not seconds)
#   --json                  JSON on stdout instead of the table
#   --repo DIR              the tree to check (default: this script's repo)
#   --final-repo O/N        where the release lives after the swap
#                           (default chris-mclennan/mnml)
#   --old-repo O/N          the name that must be gone (default
#                           chris-mclennan/mnml-zig)
#   --gh-repo O/N           where integration releases and secrets are
#                           looked up (default: --final-repo)
#   --offline               treat the network items as todo without asking
#   --allow-remaining RE    what PARITY's Remaining rows may be (default --demo)
#   --dist-assets N         dist-check's expected count (default 21)
#   --integration-assets N  assets per integration release (default 12)
#
# Environment: MNML_GH (a gh to run, default gh), MNML_ZIG (a zig, default
# zig), MNML_WORK_DATA_PATTERNS / MNML_WORK_DATA_ALLOW (passed through to
# the audit). tools/cutover-check-selftest.sh proves each FAIL fires.
set -u

usage() { sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

TAG=
BUILD=0
JSON=0
REPO=
FINAL_REPO=chris-mclennan/mnml
OLD_REPO=chris-mclennan/mnml-zig
GH_REPO_ARG=
OFFLINE=0
ALLOW_REMAINING='--demo'
DIST_ASSETS=21
INT_ASSETS=12
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG=${2:?--tag needs a value}; shift 2 ;;
        --build) BUILD=1; shift ;;
        --json) JSON=1; shift ;;
        --repo) REPO=${2:?--repo needs a value}; shift 2 ;;
        --final-repo) FINAL_REPO=${2:?}; shift 2 ;;
        --old-repo) OLD_REPO=${2:?}; shift 2 ;;
        --gh-repo) GH_REPO_ARG=${2:?}; shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        --allow-remaining) ALLOW_REMAINING=${2:?}; shift 2 ;;
        --dist-assets) DIST_ASSETS=${2:?}; shift 2 ;;
        --integration-assets) INT_ASSETS=${2:?}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "cutover-check: unknown argument: $1 (--help)" >&2; exit 64 ;;
    esac
done
case "$TAG" in
    ''|v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "cutover-check: --tag must look like v0.3.0 or v0.3.0-rc0" >&2; exit 64 ;;
esac
[ -n "$REPO" ] || REPO=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$REPO" 2>/dev/null && pwd) || { echo "cutover-check: no such directory: $REPO" >&2; exit 64; }
GH_REPO_USE=${GH_REPO_ARG:-$FINAL_REPO}
GH=${MNML_GH:-gh}
ZIG=${MNML_ZIG:-zig}
VERSION=${TAG#v}
base_version() { printf '%s' "${1%%[-+]*}"; }

TMPDIR_BASE=${TMPDIR:-/tmp}; TMPDIR_BASE=${TMPDIR_BASE%/}
TMP=$(mktemp -d "${TMPDIR_BASE}/cutover-check.XXXXXX") || { echo "cutover-check: mktemp failed" >&2; exit 70; }
trap 'rm -rf "$TMP"' EXIT

# ── the record ─────────────────────────────────────────────────────────
ids=(); states=(); details=()
n_ok=0; n_fail=0; n_todo=0
record() {  # record ID ok|FAIL|todo DETAIL
    ids+=("$1"); states+=("$2"); details+=("$3")
    case "$2" in ok) n_ok=$((n_ok + 1)) ;; FAIL) n_fail=$((n_fail + 1)) ;; *) n_todo=$((n_todo + 1)) ;; esac
    if [ "$JSON" = 0 ]; then
        printf '%-5s %-13s %s\n' "$2" "$1" "$(printf '%s' "$3" | head -n 1)"
        printf '%s\n' "$3" | tail -n +2 | sed 's/^/                    /'
    fi
}
json_str() {  # a JSON string literal for $1
    printf '%s' "$1" | awk 'BEGIN { ORS = ""; print "\"" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
          if (NR > 1) print "\\n"; print }
        END { print "\"" }'
}

[ "$JSON" = 0 ] && echo "cutover-check: $REPO$([ -n "$TAG" ] && echo " for $TAG")"

# ── tree ───────────────────────────────────────────────────────────────
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    record tree FAIL "$REPO is not a git checkout"
else
    dirty=$(git -C "$REPO" --no-optional-locks status --porcelain --untracked-files=no 2>/dev/null)
    branch=$(git -C "$REPO" symbolic-ref -q --short HEAD 2>/dev/null || echo "(detached)")
    if [ -n "$dirty" ]; then
        record tree FAIL "uncommitted changes (a dirty tree ships -dirty binaries):
$(printf '%s\n' "$dirty" | head -n 10)"
    elif [ "$branch" != main ]; then
        record tree FAIL "on $branch, not main"
    else
        record tree ok "clean, on main at $(git -C "$REPO" rev-parse --short HEAD)"
    fi
fi

# ── work-data ──────────────────────────────────────────────────────────
if [ ! -f "$REPO/tools/work-data-audit.sh" ]; then
    record work-data FAIL "tools/work-data-audit.sh is missing"
else
    out=$(bash "$REPO/tools/work-data-audit.sh" 2>&1); rc=$?
    last=$(printf '%s\n' "$out" | tail -n 1)
    if [ $rc -ne 0 ]; then
        record work-data FAIL "$last
$(printf '%s\n' "$out" | sed '$d' | head -n 10)"
    elif printf '%s' "$last" | grep -q 'nothing to check\|has no patterns'; then
        # An audit with no patterns checked nothing; that is not a pass.
        record work-data todo "$last"
    else
        record work-data ok "$last"
    fi
fi

# ── scrub ──────────────────────────────────────────────────────────────
# release.yml's pattern, verbatim (so this fails wherever CI would), then
# the other key shapes a changelog could carry. Written with bracket
# classes so BSD and GNU grep read it the same.
SCRUB='(bearer |xox[bp]-|sk-[a-z0-9]{8,}|token[[:space:]]*=[[:space:]]*"|xox[aors]-|sk-(proj|ant)-|gh[pousr]_[a-z0-9]{16,}|github_pat_|akia[0-9a-z]{16}|authorization:[[:space:]]*(basic|token|digest)[[:space:]]+[^[:space:]{])'
scrub_files=()
[ -f "$REPO/CHANGELOG.md" ] && scrub_files+=("CHANGELOG.md")
[ -f "$REPO/docs/CUTOVER.md" ] && scrub_files+=("docs/CUTOVER.md")
if [ -d "$REPO/docs/release-notes" ]; then
    for f in "$REPO"/docs/release-notes/*.md; do
        [ -f "$f" ] && scrub_files+=("docs/release-notes/$(basename "$f")")
    done
fi
if [ ! -f "$REPO/CHANGELOG.md" ]; then
    record scrub FAIL "CHANGELOG.md is missing — release.yml cuts the notes from it"
else
    hits=$(cd "$REPO" && grep -EinH "$SCRUB" "${scrub_files[@]}" 2>/dev/null | cut -c1-160)
    if [ -n "$hits" ]; then
        record scrub FAIL "credential-shaped literal(s) — describe the shape in prose (docs/RELEASE.md, Trap 1):
$(printf '%s\n' "$hits" | head -n 10)"
    else
        record scrub ok "${#scrub_files[@]} file(s) clean: ${scrub_files[*]}"
    fi
fi

# ── parity ─────────────────────────────────────────────────────────────
P="$REPO/docs/PARITY.md"
if [ ! -f "$P" ]; then
    record parity FAIL "docs/PARITY.md is missing"
else
    total=$(grep -E '^\| \*\*total\*\* \|' "$P" | head -n 1 | tr -d '*' | tr '|' ' ')
    # total → "total D P C M R"
    set -- $total
    if [ $# -ne 6 ]; then
        record parity FAIL "no parseable '| **total** | d | p | c | m | rows |' line in the Totals table"
    else
        td=$2 tp=$3 tc=$4 tm=$5 tr=$6
        # The section rows between "## Totals" and the total line.
        sums=$(awk '/^## Totals/ { on = 1; next }
                    on && /^\| \*\*total\*\*/ { exit }
                    on && /^\| / && $0 !~ /^\| section/ && $0 !~ /^\|---/ {
                        n = split($0, f, "|"); d += f[n-5]; p += f[n-4]; c += f[n-3]; m += f[n-2]; r += f[n-1] }
                    END { printf "%d %d %d %d %d", d, p, c, m, r }' "$P")
        set -- $sums
        remaining=$(awk '/^## Remaining/ { on = 1; next } on && /^## / { exit }
                         on && /^\| / && $0 !~ /^\| item \|/ && $0 !~ /^\|---/' "$P")
        stray=$(printf '%s\n' "$remaining" | sed '/^$/d' | grep -v '^| (none' | grep -Ev -- "$ALLOW_REMAINING")
        if [ $((td + tp + tc + tm)) -ne "$tr" ]; then
            record parity FAIL "totals do not add up: $td+$tp+$tc+$tm != $tr"
        elif [ "$1 $2 $3 $4 $5" != "$td $tp $tc $tm $tr" ]; then
            record parity FAIL "section rows sum to $1/$2/$3/$4 of $5, the total line says $td/$tp/$tc/$tm of $tr"
        elif [ -z "$remaining" ]; then
            record parity FAIL "no Remaining table under '## Remaining'"
        elif [ -n "$stray" ]; then
            record parity FAIL "Remaining holds more than the agreed cut ($ALLOW_REMAINING):
$(printf '%s\n' "$stray" | cut -c1-140)"
        else
            record parity ok "$td done / $tp partial / $tc cut / $tm missing of $tr; Remaining is only $ALLOW_REMAINING"
        fi
    fi
fi

# ── version / changelog ────────────────────────────────────────────────
zon_version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' "$REPO/build.zig.zon" 2>/dev/null | head -n 1)
if [ -z "$TAG" ]; then
    record version todo "no --tag given (build.zig.zon says ${zon_version:-nothing})"
    record changelog todo "no --tag given"
else
    if [ -z "$zon_version" ]; then
        record version FAIL "build.zig.zon has no .version"
    elif [ "$(base_version "$zon_version")" != "$(base_version "$VERSION")" ]; then
        record version FAIL "build.zig.zon .version is $zon_version; $TAG wants $(base_version "$VERSION")"
    else
        record version ok "build.zig.zon $zon_version → $TAG (release.yml stamps -Dversion=$VERSION)"
    fi
    heading=$(grep -m 1 '^## ' "$REPO/CHANGELOG.md" 2>/dev/null)
    body=$(awk '/^## / { if (seen) exit; seen = 1; next } seen && NF' "$REPO/CHANGELOG.md" 2>/dev/null | head -n 1)
    case "$heading" in
        *"$VERSION"*|*"$(base_version "$VERSION")"*)
            if [ -n "$body" ]; then record changelog ok "top section: $heading"
            else record changelog FAIL "top section '$heading' is empty — release-notes.sh fails on it"; fi ;;
        '') record changelog FAIL "CHANGELOG.md has no '## ' section" ;;
        *) record changelog FAIL "top heading '$heading' does not name $VERSION" ;;
    esac
fi

# ── gh: can we ask GitHub? ─────────────────────────────────────────────
gh_why=
if [ "$OFFLINE" = 1 ]; then gh_why="--offline"
elif ! command -v "$GH" >/dev/null 2>&1; then gh_why="gh is not installed"
elif ! "$GH" auth status >/dev/null 2>&1; then gh_why="gh is not authenticated (gh auth login)"
elif ! "$GH" api rate_limit >/dev/null 2>&1; then gh_why="GitHub is unreachable (offline?)"
fi

# ── integrations ───────────────────────────────────────────────────────
IDX="$REPO/integrations/index.zon"
if [ ! -f "$IDX" ]; then
    record integrations FAIL "integrations/index.zon is missing — the release index has nothing to list (the integration-release track)"
else
    rows=$(sed -n 's/.*\.id = "\([^"]*\)", *\.version = "\([^"]*\)".*/\1 \2/p' "$IDX")
    if [ -z "$rows" ]; then
        record integrations FAIL "integrations/index.zon has no '.id = \"…\", .version = \"…\"' rows"
    elif [ -n "$gh_why" ]; then
        record integrations todo "$(printf '%s\n' "$rows" | awk '{ printf "%s%s-v%s", (NR > 1 ? ", " : ""), $1, $2 }') not checked: $gh_why"
    else
        bad_list=; unsure=; good=
        while read -r id ver; do
            [ -n "$id" ] || continue
            t="$id-v$ver"
            if got=$("$GH" release view "$t" --repo "$GH_REPO_USE" --json assets,isDraft --jq '"\(.assets|length) \(.isDraft)"' 2>"$TMP/gh.err"); then
                set -- $got
                if [ "$2" = true ]; then bad_list="$bad_list
$t is a draft (the index cannot download from it)"
                elif [ "$1" -ne "$INT_ASSETS" ]; then bad_list="$bad_list
$t has $1 assets, wants $INT_ASSETS"
                else good="$good $t"; fi
            elif grep -qi 'not found' "$TMP/gh.err"; then
                bad_list="$bad_list
$t: no release on $GH_REPO_USE"
            else
                unsure="$unsure
$t: $(head -n 1 "$TMP/gh.err")"
            fi
        done <<EOF
$rows
EOF
        if [ -n "$bad_list" ]; then
            record integrations FAIL "integration releases missing or short on $GH_REPO_USE — cut the <id>-v* tags first:$bad_list$unsure"
        elif [ -n "$unsure" ]; then
            record integrations todo "gh could not answer:$unsure"
        else
            record integrations ok "$INT_ASSETS assets each on $GH_REPO_USE:$good"
        fi
    fi
fi

# ── dist-check ─────────────────────────────────────────────────────────
# Ask the script, not a grep: a gh that knows no assets makes dist-check
# name every one it expects and say how many it wanted.
DC="$REPO/scripts/dist-check.sh"
if [ ! -f "$DC" ]; then
    record dist-check FAIL "scripts/dist-check.sh is missing"
else
    mkdir -p "$TMP/fakegh"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/fakegh/gh"
    chmod +x "$TMP/fakegh/gh"
    out=$(cd "$REPO" && PATH="$TMP/fakegh:$PATH" GH_REPO=x/y bash "$DC" v0.0.0 --names-only 2>&1)
    named=$(printf '%s\n' "$out" | grep -c 'MISSING')
    wanted=$(printf '%s\n' "$out" | sed -n 's/.*wanted at least \([0-9][0-9]*\).*/\1/p' | head -n 1)
    if [ "$named" = "$DIST_ASSETS" ] && [ "${wanted:-}" = "$DIST_ASSETS" ]; then
        record dist-check ok "expects $DIST_ASSETS assets by name"
    else
        record dist-check FAIL "dist-check.sh names $named asset(s) and wants ${wanted:-?}; cutover expects $DIST_ASSETS (20 + integrations.json)"
    fi
fi

# ── secrets ────────────────────────────────────────────────────────────
used=$(cat "$REPO"/.github/workflows/*.yml "$REPO"/.github/workflows/*.yaml 2>/dev/null \
    | grep -o 'secrets\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^secrets\.//' | grep -vx GITHUB_TOKEN | sort -u)
if [ -z "$used" ]; then
    record secrets ok "the workflows read no secret beyond GITHUB_TOKEN"
elif [ -n "$gh_why" ]; then
    record secrets todo "$(echo $used) on $GH_REPO_USE not checked: $gh_why"
elif ! have=$("$GH" secret list --repo "$GH_REPO_USE" --json name --jq '.[].name' 2>"$TMP/gh.err"); then
    record secrets todo "gh secret list on $GH_REPO_USE: $(head -n 1 "$TMP/gh.err") (needs admin on the repo)"
else
    missing=
    for s in $used; do printf '%s\n' "$have" | grep -qx "$s" || missing="$missing $s"; done
    if [ -n "$missing" ]; then
        record secrets FAIL "the workflows read secrets $GH_REPO_USE does not have:$missing"
    else
        record secrets ok "$GH_REPO_USE has every secret the workflows read: $(echo $used)"
    fi
fi

# ── readme / old-repo ──────────────────────────────────────────────────
if [ ! -f "$REPO/README.md" ]; then
    record readme FAIL "README.md is missing"
else
    final_install=$(grep -cE "github\.com/$FINAL_REPO/releases/(latest/)?download/" "$REPO/README.md")
    if [ "$final_install" -lt 1 ]; then
        record readme FAIL "README.md has no install line downloading from github.com/$FINAL_REPO/releases"
    else
        record readme ok "$final_install README install line(s) download from github.com/$FINAL_REPO/releases"
    fi
fi
# Everything that ships or runs: a URL baked into the binary, an
# installer's default repo, the marketplace index URL, a workflow. docs/
# and tools/ are history and tooling, not shipped.
SHIPPED="README.md CHANGELOG.md dist nfpm data src scripts sdk integrations lua themes .github"
old_hits=$(cd "$REPO" && git grep -nF "$OLD_REPO" -- $SHIPPED 2>/dev/null | grep -vF "$OLD_REPO-" | cut -c1-150)
if [ -n "$old_hits" ]; then
    record old-repo FAIL "$(printf '%s\n' "$old_hits" | wc -l | tr -d ' ') shipped line(s) still name $OLD_REPO (installers, links and index URLs would point at the old repo):
$(printf '%s\n' "$old_hits" | head -n 12)"
else
    record old-repo ok "nothing under $(echo $SHIPPED | tr ' ' ',') names $OLD_REPO"
fi

# ── targets / version-build ────────────────────────────────────────────
if [ "$BUILD" = 0 ]; then
    record targets todo "not built (--build runs zig build gate-targets)"
else
    start=$(date +%s)
    if (cd "$REPO" && "$ZIG" build gate-targets) > "$TMP/targets.log" 2>&1; then
        record targets ok "zig build gate-targets: the five targets build ($(( $(date +%s) - start ))s)"
    else
        record targets FAIL "zig build gate-targets failed:
$(tail -n 8 "$TMP/targets.log")"
    fi
fi
if [ "$BUILD" = 0 ] || [ -z "$TAG" ]; then
    record version-build todo "needs --tag and --build"
else
    if (cd "$REPO" && "$ZIG" build -Doptimize=ReleaseSafe -Dversion="$VERSION" -p "$TMP/prefix") > "$TMP/vb.log" 2>&1; then
        bin=$(ls "$TMP"/prefix/bin/mnml* 2>/dev/null | head -n 1)
        said=$([ -n "$bin" ] && "$bin" --version 2>&1 | head -n 1)
        case "$said" in
            *"$VERSION"*) record version-build ok "$said" ;;
            *) record version-build FAIL "--version said '${said:-nothing}', not $VERSION" ;;
        esac
    else
        record version-build FAIL "ReleaseSafe build with -Dversion=$VERSION failed:
$(tail -n 8 "$TMP/vb.log")"
    fi
fi

# ── verdict ────────────────────────────────────────────────────────────
if [ "$JSON" = 1 ]; then
    printf '{"repo":%s,"tag":%s,"ok":%s,"counts":{"ok":%d,"fail":%d,"todo":%d},"items":[' \
        "$(json_str "$REPO")" "$(json_str "$TAG")" "$([ $n_fail -eq 0 ] && echo true || echo false)" $n_ok $n_fail $n_todo
    i=0
    while [ $i -lt ${#ids[@]} ]; do
        [ $i -gt 0 ] && printf ','
        printf '{"id":%s,"status":%s,"detail":%s}' "$(json_str "${ids[$i]}")" "$(json_str "${states[$i]}")" "$(json_str "${details[$i]}")"
        i=$((i + 1))
    done
    printf ']}\n'
else
    echo "cutover-check: $n_ok ok, $n_fail FAIL, $n_todo todo"
fi
[ $n_fail -eq 0 ]
