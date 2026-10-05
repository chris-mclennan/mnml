#!/usr/bin/env bash
# tools/upstream-watch.sh — what mnml pins, and how far behind upstream it is
#
#   tools/upstream-watch.sh --dry-run                 # report + state JSON on stdout, writes nothing
#   tools/upstream-watch.sh --dry-run --only zig,threads
#   tools/upstream-watch.sh --dry-run --json --only zig      # the state JSON alone
#   tools/upstream-watch.sh --dry-run --prev-state OLD.json   # + the comment decision against OLD
#   tools/upstream-watch.sh --decide OLD.json NEW.json        # the decision alone (offline)
#   tools/upstream-watch.sh --publish                 # the weekly workflow: update the tracking issue
#
# Read-only against every upstream. The only writes anywhere are
# --publish's, and they go to this repository's own issues: ONE issue,
# found by the label `upstream-watch` (created when missing), whose body
# is the report plus the state JSON in a hidden HTML comment. A comment
# — the thing that notifies — is added only when the state's fingerprint
# differs from the stored one; with no change the body is left as it is.
# Never pushes, never opens a pull request, never moves a pin: pins move
# only by a deliberate branch through tools/gate/ (docs/RELEASE.md,
# "Dependencies").
#
# Sections (`--only` takes a comma list of these names):
#   pins      build.zig.zon, parsed generically. A GitHub archive at a
#             commit: commits ahead on the default branch, and the pin's
#             date. A deps.files.ghostty.org mirror (named by commit):
#             the commit ghostty's own main pins for it. static.crates.io:
#             crates.io's newest stable version. lua.org: the newest
#             5.4.x on the ftp listing. Only what is behind is reported.
#   zig       ziglang.org's newest stable release against
#             minimum_zig_version and the version ci.yml installs.
#   actions   every `uses: owner/repo@<sha> # vN…` in the workflows whose
#             sha is not the current sha of its major tag vN.
#   npm       site/ and demo/cloudflare/: `npm outdated` by major/minor/
#             patch and `npm audit` by severity. Skipped (and said so)
#             where node_modules is absent — the workflow runs `npm ci`.
#   threads   the upstream discussions in THREADS below: open/closed,
#             answered, comments, maintainer comments, labels; a change
#             since --prev-state is called out.
#   channels  the latest GitHub release against the Homebrew tap's
#             formula, winget's newest manifest (and an open winget PR),
#             the version the site's /download page prints, and
#             https://mnml.sh/demo answering 200. Only disagreements.
#   ci        the workflow's ghostty-main and zig-next jobs, from the
#             UW_CI_* variables (below); absent when none is set.
#
# The state JSON. Every value under a key named `info` is context only;
# everything else is signal. The fingerprint is the sha256 of the signal
# (the state with every `info` and `generated` removed, keys sorted).
# What is info, and why: a GitHub pin's latest sha and commit count (main
# moves daily — the weekly ghostty-main job says whether moving is
# safe), npm's minor/patch counts, the release tag the channels agree
# on. A new crate, Lua or Zig version, a moved action tag, a new npm
# major or audit finding, any change on a watched thread, a channel
# that disagrees, a change in a CI result: each changes the fingerprint.
#
# Environment:
#   UW_ROOT        the checkout to read (default: this script's repo)
#   UW_FIXTURES    directories of canned responses, colon-separated, the
#                  first holding a request wins; every network call reads
#                  from them instead (tools/upstream-watch-check.sh)
#   UW_THREADS     replaces THREADS below (space-separated)
#   UW_PACE        seconds between crates.io requests (default 1)
#   UW_NOW         the `generated` timestamp (default: now, UTC)
#   UW_REPO        owner/repo for --publish and the release (default
#                  $GITHUB_REPOSITORY, else chris-mclennan/mnml)
#   UW_CI_GHOSTTY_SHA, UW_CI_GHOSTTY_BUILD, UW_CI_TERMINAL_TESTS,
#   UW_CI_TERMINAL_FAILED, UW_CI_RESIZE, UW_CI_ZIG_NEXT,
#   UW_CI_ZIG_NEXT_VERSION — the workflow's job results (success /
#                  failure / skipped / cancelled; RESIZE is broken /
#                  fixed / unknown).
#   UW_RUN_URL     a link to the workflow run, put under the report
#
# Needs bash, jq, curl, gh (authenticated for public reads; --publish
# needs issues: write) and, for npm, node. Exit 0 unless a usage error
# (64) or --publish could not write the issue (1). An upstream that does
# not answer is reported as such and does not fail the run.

set -u

# Upstream discussions to follow: owner/repo#number. Add a line to add one.
# (UW_THREADS, space-separated, replaces the list — the offline check's.)
THREADS=(
    "ghostty-org/ghostty#13629"
    "ghostty-org/ghostty#13460"
)
[ -z "${UW_THREADS:-}" ] || read -r -a THREADS <<< "$UW_THREADS"

LABEL=upstream-watch
UA="mnml upstream-watch (https://github.com/chris-mclennan/mnml)"
STATE_MARK=upstream-watch-state

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

root="${UW_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_slug="${UW_REPO:-${GITHUB_REPOSITORY:-chris-mclennan/mnml}}"
mode=
json_only=
only=
prev_state=
decide_old=
decide_new=
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) mode=dry ;;
        --json) json_only=1 ;;
        --publish) mode=publish ;;
        --only) only="${2:?--only needs a list}"; shift ;;
        --prev-state) prev_state="${2:?--prev-state needs a file}"; shift ;;
        --decide) mode=decide; decide_old="${2:?}"; decide_new="${3:?}"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "upstream-watch: unknown argument $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done
[ -n "$mode" ] || { echo "upstream-watch: give --dry-run, --publish or --decide" >&2; exit 64; }
command -v jq > /dev/null || { echo "upstream-watch: needs jq" >&2; exit 64; }

# ── the network, or the fixtures ────────────────────────────────────

# A fixture's file name: the request with everything but [A-Za-z0-9._-]
# turned into `_`.
fkey() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# A fixture by kind and request: the first of UW_FIXTURES' directories
# (colon-separated, so a later week can overlay an earlier one) holding
# <kind>/<key>. A miss is said on stderr and answers nothing, as an
# upstream that does not answer would.
fixture() { # kind request
    local d key
    key="$1/$(fkey "$2")"
    local IFS=:
    for d in $UW_FIXTURES; do
        [ -f "$d/$key" ] && { cat "$d/$key"; return 0; }
    done
    echo "upstream-watch: no fixture $key" >&2
    return 1
}

# Body of a GET; empty on failure.
http_get() {
    if [ -n "${UW_FIXTURES:-}" ]; then
        fixture http "$1"
        return
    fi
    curl -sSfL --max-time 30 -A "$UA" "$1" 2> /dev/null
}

# Final status code of a GET (redirects followed); 000 when unreachable.
http_status() {
    if [ -n "${UW_FIXTURES:-}" ]; then
        fixture status "$1" || echo 000
        return
    fi
    curl -sL -o /dev/null --max-time 30 -A "$UA" -w '%{http_code}' "$1" 2> /dev/null || echo 000
}

# `gh api <path>`; empty on failure.
gh_get() {
    if [ -n "${UW_FIXTURES:-}" ]; then
        fixture gh "$1"
        return
    fi
    gh api "$1" 2> /dev/null
}

# A file's raw contents through the contents API; empty on failure.
gh_raw() {
    if [ -n "${UW_FIXTURES:-}" ]; then
        fixture gh "raw:$1"
        return
    fi
    gh api -H 'Accept: application/vnd.github.raw' "$1" 2> /dev/null
}

# One discussion through GraphQL (discussions are not in the REST API).
gh_discussion() { # owner name number
    if [ -n "${UW_FIXTURES:-}" ]; then
        fixture gh "graphql:$1/$2#$3"
        return
    fi
    gh api graphql -F owner="$1" -F name="$2" -F number="$3" -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          discussion(number: $number) {
            title closed isAnswered updatedAt url
            labels(first: 20) { nodes { name } }
            comments(last: 100) {
              totalCount
              nodes { authorAssociation replies(last: 50) { nodes { authorAssociation } } }
            }
          }
        }
      }' 2> /dev/null
}

wants() { [ -z "$only" ] || [[ ",$only," == *",$1,"* ]]; }
short() { printf '%s' "${1:0:8}"; }

# The report (markdown) and the state, built section by section.
report=""
say() { report+="$*"$'\n'; }
state='{}'
put() { state=$(jq -c --argjson v "$2" "$1 = \$v" <<< "$state"); }

# ── pins ─────────────────────────────────────────────────────────────

# `name url` per dependency of a build.zig.zon on stdin.
zon_deps() {
    awk '
        /^[[:space:]]*\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*\.\{/ {
            name = $1; sub(/^\./, "", name)
        }
        /\.url[[:space:]]*=/ {
            u = $0; sub(/^[^"]*"/, "", u); sub(/".*$/, "", u)
            if (name != "") print name, u
        }'
}

# owner/repo named on the `// owner/repo` comment above `url` in a zon.
zon_upstream_of() { # url < zon
    awk -v u="$1" '
        /^[[:space:]]*\/\/[[:space:]]*[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+[[:space:]]*$/ {
            c = $0; sub(/^[[:space:]]*\/\/[[:space:]]*/, "", c); sub(/[[:space:]]*$/, "", c); next
        }
        index($0, u) { print c; exit }
        /\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*\.\{/ { c = "" }'
}

section_pins() {
    local zon="$root/build.zig.zon" name url pins='{}' lines="" unknown=""
    local ghostty_zon=""
    [ -f "$zon" ] || { say "## Pins behind"; say ""; say "- no build.zig.zon at the checkout"; say ""; return; }
    while read -r name url; do
        case "$url" in
            https://github.com/*/archive/*.tar.gz)
                local path="${url#https://github.com/}" owner repo sha
                owner="${path%%/*}"; path="${path#*/}"; repo="${path%%/*}"
                sha="${url##*/}"; sha="${sha%.tar.gz}"
                if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
                    unknown+="$name (archive of $sha, not a commit), "; continue
                fi
                local def cmp ahead date latest
                def=$(gh_get "repos/$owner/$repo" | jq -r '.default_branch // empty')
                # per_page=1: ahead_by is the whole count either way, and the
                # commit list (up to 250, with files) is not needed.
                cmp=$(gh_get "repos/$owner/$repo/compare/$sha...${def:-main}?per_page=1")
                ahead=$(jq -r '.ahead_by // empty' <<< "$cmp" 2> /dev/null)
                latest=$(gh_get "repos/$owner/$repo/commits/${def:-main}" | jq -r '.sha // empty' 2> /dev/null)
                date=$(gh_get "repos/$owner/$repo/commits/$sha" | jq -r '.commit.committer.date // empty' 2> /dev/null)
                if [ -z "$ahead" ]; then
                    lines+="- $name ($owner/$repo @ $(short "$sha")): could not compare with ${def:-main}"$'\n'
                elif [ "$ahead" -gt 0 ]; then
                    lines+="- $name ($owner/$repo): pinned $(short "$sha") (${date%%T*}), $ahead commits behind ${def:-main}"$'\n'
                    pins=$(jq -c --arg n "$name" --arg c "$sha" --arg l "$latest" --argjson a "$ahead" --arg d "$date" \
                        '.[$n] = {kind: "github", current: $c, info: {latest: $l, ahead: $a, pin_date: $d}}' <<< "$pins")
                fi
                ;;
            https://deps.files.ghostty.org/*)
                # A mirror ghostty keeps, named <pkg>-<commit>.tar.gz. Which
                # commit ghostty's own main pins for it is the comparison.
                local file="${url##*/}" pkg ours theirs up
                pkg="${file%-*}"; ours="${file##*-}"; ours="${ours%.tar.gz}"
                [ -n "$ghostty_zon" ] || ghostty_zon=$(gh_raw "repos/ghostty-org/ghostty/contents/build.zig.zon")
                theirs=$(printf '%s\n' "$ghostty_zon" | grep -oE "deps\.files\.ghostty\.org/$pkg-[0-9a-f]{40}\.tar\.gz" | head -1)
                theirs="${theirs##*-}"; theirs="${theirs%.tar.gz}"
                if [ -z "$theirs" ]; then
                    lines+="- $name: ghostty main's build.zig.zon names no $pkg mirror (we pin $(short "$ours"))"$'\n'
                    continue
                fi
                [ "$theirs" = "$ours" ] && continue
                up=$(printf '%s\n' "$ghostty_zon" | zon_upstream_of "deps.files.ghostty.org/$pkg-$theirs")
                local upahead=""
                [ -n "$up" ] && upahead=$(gh_get "repos/$up/compare/$ours...$theirs" | jq -r '.ahead_by // empty' 2> /dev/null)
                lines+="- $name: ghostty main uses $pkg $(short "$theirs"); we pin $(short "$ours")${up:+ ($up${upahead:+, $upahead commits apart})}"$'\n'
                pins=$(jq -c --arg n "$name" --arg c "$ours" --arg t "$theirs" --arg up "$up" --arg ua "$upahead" \
                    '.[$n] = {kind: "mirror", current: $c, ghostty_uses: $t, info: {upstream: $up, ahead: $ua}}' <<< "$pins")
                ;;
            https://static.crates.io/crates/*)
                local crate ver latest
                crate=$(cut -d/ -f5 <<< "$url")
                ver="${url##*/}"; ver="${ver#"$crate"-}"; ver="${ver%.crate}"
                latest=$(http_get "https://crates.io/api/v1/crates/$crate" | jq -r '.crate.max_stable_version // empty' 2> /dev/null)
                [ -n "${UW_FIXTURES:-}" ] || sleep "${UW_PACE:-1}"
                if [ -z "$latest" ]; then
                    lines+="- $crate: crates.io did not answer (pinned $ver)"$'\n'
                elif [ "$latest" != "$ver" ] && [ "$(printf '%s\n%s\n' "$ver" "$latest" | sort -V | tail -1)" = "$latest" ]; then
                    lines+="- $crate: $ver → $latest"$'\n'
                    pins=$(jq -c --arg n "$name" --arg c "$ver" --arg l "$latest" \
                        '.[$n] = {kind: "crate", current: $c, latest: $l}' <<< "$pins")
                fi
                ;;
            https://www.lua.org/ftp/lua-*.tar.gz)
                local ver latest series
                ver="${url##*/lua-}"; ver="${ver%.tar.gz}"; series="${ver%.*}"
                latest=$(http_get "https://www.lua.org/ftp/" | grep -oE "lua-${series//./\\.}\.[0-9]+\.tar\.gz" \
                    | sed 's/^lua-//; s/\.tar\.gz$//' | sort -uV | tail -1)
                if [ -z "$latest" ]; then
                    lines+="- lua: lua.org's ftp listing did not answer (pinned $ver)"$'\n'
                elif [ "$latest" != "$ver" ] && [ "$(printf '%s\n%s\n' "$ver" "$latest" | sort -V | tail -1)" = "$latest" ]; then
                    lines+="- lua: $ver → $latest"$'\n'
                    pins=$(jq -c --arg n "$name" --arg c "$ver" --arg l "$latest" \
                        '.[$n] = {kind: "lua", current: $c, latest: $l}' <<< "$pins")
                fi
                ;;
            *) unknown+="$name, " ;;
        esac
    done < <(zon_deps < "$zon")
    say "## Pins behind"
    say ""
    if [ -n "$lines" ]; then report+="$lines"; else say "- every pin is current"; fi
    [ -z "$unknown" ] || say "- not checked (no rule for the source): ${unknown%, }"
    say ""
    put .pins "$pins"
}

# ── zig ──────────────────────────────────────────────────────────────

section_zig() {
    local min ci latest idx
    min=$(grep -oE 'minimum_zig_version[[:space:]]*=[[:space:]]*"[^"]+"' "$root/build.zig.zon" 2> /dev/null | sed 's/.*"\(.*\)"/\1/')
    # ci.yml's ZIG_VERSION env, else the first `version:` given to setup-zig.
    ci=$(grep -E '^[[:space:]]*ZIG_VERSION:' "$root/.github/workflows/ci.yml" 2> /dev/null | head -1 | sed 's/.*:[[:space:]]*//; s/["'\'']//g; s/[[:space:]]*#.*//')
    [ -n "$ci" ] || ci=$(awk '/uses:.*setup-zig/{f=1} f && /version:/{sub(/.*version:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit}' \
        "$root/.github/workflows/ci.yml" 2> /dev/null)
    idx=$(http_get "https://ziglang.org/download/index.json")
    latest=$(jq -r 'keys[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<< "$idx" 2> /dev/null | sort -V | tail -1)
    say "## Zig"
    say ""
    if [ -z "$latest" ]; then
        say "- ziglang.org/download/index.json did not answer (minimum $min, CI $ci)"
    elif [ "$latest" = "$min" ] && [ "$latest" = "$ci" ]; then
        say "- $latest is the newest stable release; minimum_zig_version and CI agree"
    else
        say "- newest stable: $latest — minimum_zig_version $min, CI installs $ci"
    fi
    say ""
    put .zig "$(jq -nc --arg m "$min" --arg c "$ci" --arg l "$latest" '{minimum: $m, ci: $c, latest_stable: $l}')"
}

# ── actions ──────────────────────────────────────────────────────────

section_actions() {
    local acts='[]' lines="" uses action sha tag major ref type tsha
    while read -r uses; do
        action=$(sed -E 's/^.*uses:[[:space:]]*([^@[:space:]]+)@.*$/\1/' <<< "$uses")
        sha=$(sed -E 's/^.*@([0-9a-f]{40}).*$/\1/' <<< "$uses")
        tag=$(sed -E 's/^.*#[[:space:]]*(v[0-9][0-9A-Za-z.-]*).*$/\1/' <<< "$uses")
        major=$(grep -oE '^v[0-9]+' <<< "$tag")
        local owner_repo
        owner_repo=$(cut -d/ -f1-2 <<< "$action")
        ref=$(gh_get "repos/$owner_repo/git/ref/tags/$major")
        type=$(jq -r '.object.type // empty' <<< "$ref" 2> /dev/null)
        tsha=$(jq -r '.object.sha // empty' <<< "$ref" 2> /dev/null)
        if [ "$type" = tag ]; then
            tsha=$(gh_get "repos/$owner_repo/git/tags/$tsha" | jq -r '.object.sha // empty' 2> /dev/null)
        fi
        if [ -z "$tsha" ]; then
            lines+="- $action ($tag): could not read tag $major upstream"$'\n'
        elif [ "$tsha" != "$sha" ]; then
            lines+="- $action: pinned $(short "$sha") ($tag); $major is now $(short "$tsha")"$'\n'
            acts=$(jq -c --arg a "$action" --arg p "$sha" --arg t "$tag" --arg m "$major" --arg s "$tsha" \
                '. + [{action: $a, pinned: $p, comment: $t, major: $m, major_sha: $s}]' <<< "$acts")
        fi
    done < <(cat "$root"/.github/workflows/*.yml 2> /dev/null \
        | grep -E 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]*#[[:space:]]*v[0-9]' \
        | sed -E 's/^[[:space:]]*-?[[:space:]]*//' | sort -u)
    say "## Actions"
    say ""
    if [ -n "$lines" ]; then report+="$lines"; else say "- every sha-pinned action is its major tag's current sha"; fi
    say ""
    put .actions "$acts"
}

# ── npm ──────────────────────────────────────────────────────────────

section_npm() {
    local dir npm='{}' out aud
    say "## npm"
    say ""
    for dir in site demo/cloudflare; do
        if [ -n "${UW_FIXTURES:-}" ]; then
            out=$(fixture npm "$dir.outdated.json")
            aud=$(fixture npm "$dir.audit.json")
            [ -n "$out$aud" ] || { say "- $dir: skipped (no node_modules)"; continue; }
        elif [ ! -d "$root/$dir/node_modules" ]; then
            say "- $dir: skipped — no node_modules (the workflow runs \`npm ci\` first)"
            npm=$(jq -c --arg d "$dir" '.[$d] = {skipped: true}' <<< "$npm")
            continue
        elif ! command -v npm > /dev/null; then
            say "- $dir: skipped — no npm on PATH"
            continue
        else
            out=$(cd "$root/$dir" && npm outdated --json 2> /dev/null)
            aud=$(cd "$root/$dir" && npm audit --json 2> /dev/null)
        fi
        local v
        v=$(jq -nc --argjson o "${out:-"{}"}" --argjson a "${aud:-"{}"}" '
            def parts: (. // "0.0.0") | sub("[-+].*$"; "") | split(".") | map(tonumber? // 0);
            def bump($c; $l): ($c | parts) as $x | ($l | parts) as $y
                | if $x[0] != $y[0] then "major" elif $x[1] != $y[1] then "minor"
                  elif $x[2] != $y[2] then "patch" else "none" end;
            ([$o | to_entries[] | .value | (if type == "array" then .[0] else . end)
              | bump(.current; .latest)]) as $b
            | ($a.metadata.vulnerabilities // {}) as $vul
            | {major: ($b | map(select(. == "major")) | length),
               audit: {critical: ($vul.critical // 0), high: ($vul.high // 0),
                       moderate: ($vul.moderate // 0), low: ($vul.low // 0)},
               info: {minor: ($b | map(select(. == "minor")) | length),
                      patch: ($b | map(select(. == "patch")) | length)}}' 2> /dev/null)
        if [ -z "$v" ]; then
            say "- $dir: npm's output did not parse"
            continue
        fi
        say "- $dir: $(jq -r '"outdated \(.major) major, \(.info.minor) minor, \(.info.patch) patch; audit \(.audit.critical) critical, \(.audit.high) high, \(.audit.moderate) moderate, \(.audit.low) low"' <<< "$v")"
        npm=$(jq -c --arg d "$dir" --argjson v "$v" '.[$d] = $v' <<< "$npm")
    done
    say ""
    put .npm "$npm"
}

# ── threads ──────────────────────────────────────────────────────────

section_threads() {
    local t owner name num raw d threads='{}' line was
    say "## Upstream threads"
    say ""
    for t in "${THREADS[@]}"; do
        owner="${t%%/*}"; name="${t#*/}"; name="${name%%#*}"; num="${t##*#}"
        raw=$(gh_discussion "$owner" "$name" "$num")
        d=$(jq -c '.data.repository.discussion // empty
            | {state: (if .closed then "closed" else "open" end),
               answered: .isAnswered,
               comments: .comments.totalCount,
               maintainer_comments: ([.comments.nodes[] | ., (.replies.nodes[]?)
                   | select(.authorAssociation == "OWNER" or .authorAssociation == "MEMBER"
                            or .authorAssociation == "COLLABORATOR")] | length),
               labels: ([.labels.nodes[].name] | sort | join(", ")),
               info: {title: .title, updated: .updatedAt}}' <<< "$raw" 2> /dev/null)
        if [ -z "$d" ]; then
            say "- $t: could not be read"
            continue
        fi
        line=$(jq -r '"\(.state), \(if .answered then "answered" else "unanswered" end), \(.comments) comments (\(.maintainer_comments) from maintainers), labels: \(if .labels == "" then "none" else .labels end) — \(.info.title)"' <<< "$d")
        was=""
        if [ -n "$prev_state" ] && [ -f "$prev_state" ]; then
            was=$(jq -r --arg t "$t" --argjson n "$d" '.threads[$t] // empty | . as $o
                | [("state","answered","comments","maintainer_comments","labels") as $k
                   | select($o[$k] != $n[$k]) | "\($k) \($o[$k]) → \($n[$k])"] | join("; ")' "$prev_state" 2> /dev/null)
        fi
        say "- [$t](https://github.com/$owner/$name/discussions/$num): $line${was:+ — **changed since last run:** $was}"
        threads=$(jq -c --arg t "$t" --argjson d "$d" '.[$t] = $d' <<< "$threads")
    done
    say ""
    put .threads "$threads"
}

# ── channels ─────────────────────────────────────────────────────────

section_channels() {
    local tag ver tap_repo tap_path tap wg_id wg_dir wg prs site_v demo dis='[]' lines=""
    tag=$(gh_get "repos/$repo_slug/releases/latest" | jq -r '.tag_name // empty' 2> /dev/null)
    ver="${tag#v}"
    say "## Release channels"
    say ""
    if [ -z "$tag" ]; then
        say "- the latest release of $repo_slug could not be read"
        say ""
        put .channels '{"disagree":["release unreadable"]}'
        return
    fi
    disagree() { lines+="- $1"$'\n'; dis=$(jq -c --arg s "$1" '. + [$s]' <<< "$dis"); }

    # (a) the Homebrew tap: the repository the bump workflow checks out
    # beside its own, and the Formula/*.rb it writes.
    local wf="$root/.github/workflows/bump-homebrew-tap.yml"
    tap_repo=$(grep -E '^[[:space:]]*repository:[[:space:]]*[^[:space:]$]+' "$wf" 2> /dev/null | head -1 | sed 's/.*repository:[[:space:]]*//')
    tap_path=$(grep -oE 'Formula/[A-Za-z0-9_.-]+\.rb' "$wf" 2> /dev/null | head -1)
    if [ -z "$tap_repo" ] || [ -z "$tap_path" ]; then
        disagree "Homebrew: could not find the tap repository and formula in bump-homebrew-tap.yml"
    else
        tap=$(gh_raw "repos/$tap_repo/contents/$tap_path" | grep -E '^[[:space:]]*version[[:space:]]+"' | head -1 | sed 's/.*"\(.*\)".*/\1/')
        if [ -z "$tap" ]; then disagree "Homebrew: $tap_repo/$tap_path has no readable version"
        elif [ "$tap" != "$ver" ]; then disagree "Homebrew: $tap_repo/$tap_path is $tap, the release is $ver"; fi
    fi

    # (b) winget: the identifier the releaser workflow publishes. Version
    # directories carry odd prefixes (v0.3.0, mnml-rs-v0.2.16): the version
    # is what follows the last non-digit run at the front.
    wg_id=$(grep -E '^[[:space:]]*identifier:' "$root/.github/workflows/winget-releaser.yml" 2> /dev/null | head -1 | sed 's/.*identifier:[[:space:]]*//; s/["'\'']//g')
    if [ -z "$wg_id" ]; then
        disagree "winget: no identifier in winget-releaser.yml"
    else
        local first="${wg_id:0:1}"
        first=$(tr '[:upper:]' '[:lower:]' <<< "$first")
        wg_dir="manifests/$first/${wg_id//.//}"
        wg=$(gh_get "repos/microsoft/winget-pkgs/contents/$wg_dir" | jq -r '.[] | select(.type == "dir") | .name' 2> /dev/null \
            | sed -E 's/^[^0-9]*//' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)
        if [ -z "$wg" ]; then disagree "winget: no manifest versions readable at microsoft/winget-pkgs/$wg_dir"
        elif [ "$wg" != "$ver" ]; then
            prs=$(gh_get "search/issues?q=$(jq -rn --arg q "repo:microsoft/winget-pkgs is:pr is:open $wg_id" '$q | @uri')" \
                | jq -r '.items[]? | "#\(.number) \(.title)"' 2> /dev/null | head -3 | paste -sd';' -)
            disagree "winget: newest $wg_id manifest is $wg, the release is $ver${prs:+ (open: $prs)}"
        fi
    fi

    # (c) the site: /download prints `<p class="version">Version X.Y.Z`.
    site_v=$(http_get "https://mnml.sh/download/" | grep -oE 'class="version">Version [0-9][0-9A-Za-z.-]*' | head -1 | sed 's/.*Version //')
    if [ -z "$site_v" ]; then disagree "site: mnml.sh/download printed no \`class=\"version\">Version …\`"
    elif [ "$site_v" != "$ver" ]; then disagree "site: mnml.sh/download says $site_v, the release is $ver"; fi

    # (d) the demo answers.
    demo=$(http_status "https://mnml.sh/demo")
    [ "$demo" = 200 ] || disagree "demo: https://mnml.sh/demo answered $demo"

    if [ -n "$lines" ]; then report+="$lines"; else say "- $tag everywhere: release, Homebrew, winget, mnml.sh/download; mnml.sh/demo answers 200"; fi
    say ""
    put .channels "$(jq -nc --argjson d "$dis" --arg t "$tag" '{disagree: $d, info: {release: $t}}')"
}

# ── ci (the workflow's own jobs) ─────────────────────────────────────

section_ci() {
    local any="${UW_CI_GHOSTTY_BUILD:-}${UW_CI_TERMINAL_TESTS:-}${UW_CI_RESIZE:-}${UW_CI_ZIG_NEXT:-}"
    [ -n "$any" ] || return 0
    local build tests resize zig sha="${UW_CI_GHOSTTY_SHA:-}"
    case "${UW_CI_GHOSTTY_BUILD:-}" in success) build=yes ;; failure) build=no ;; *) build="not run" ;; esac
    case "${UW_CI_TERMINAL_TESTS:-}" in
        success) tests=pass ;;
        failure) tests="fail (${UW_CI_TERMINAL_FAILED:-?} failed)" ;;
        *) tests="not run" ;;
    esac
    case "${UW_CI_RESIZE:-}" in
        broken) resize="still broken" ;;
        fixed) resize="FIXED upstream — the workaround in src/pty/common.zig can go" ;;
        unknown) resize="unknown — the repro did not reach its verdict" ;;
        *) resize="not run" ;;
    esac
    case "${UW_CI_ZIG_NEXT:-}:${UW_CI_ZIG_NEXT_VERSION:-}" in
        success:*) zig="builds with zig ${UW_CI_ZIG_NEXT_VERSION:-next}: yes" ;;
        failure:*) zig="builds with zig ${UW_CI_ZIG_NEXT_VERSION:-next}: no" ;;
        *:) zig="zig: no newer stable release to try" ;;
        *) zig="builds with zig $UW_CI_ZIG_NEXT_VERSION: not run" ;;
    esac
    say "## Against upstream (this run's jobs)"
    say ""
    say "- builds against ghostty main${sha:+ ($(short "$sha"))}: $build"
    say "- terminal tests: $tests"
    say "- resize redraw: $resize"
    say "- $zig"
    say ""
    put .ci "$(jq -nc --arg b "$build" --arg t "${UW_CI_TERMINAL_TESTS:-not run}" --arg f "${UW_CI_TERMINAL_FAILED:-}" \
        --arg r "${UW_CI_RESIZE:-not run}" --arg z "${UW_CI_ZIG_NEXT:-skipped}" --arg zv "${UW_CI_ZIG_NEXT_VERSION:-}" --arg s "$sha" \
        '{ghostty_build: $b, terminal_tests: $t, terminal_failed: $f, resize: $r, zig_next: $z, zig_next_version: $zv, info: {ghostty_sha: $s}}')"
}

# ── the decision ─────────────────────────────────────────────────────

signal() { jq -cS 'del(.generated) | walk(if type == "object" then del(.info) else . end)' "$@"; }
sha256() { if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi; }
fingerprint() { signal "$@" | sha256 | cut -c1-16; }

# `path = value` per scalar of the signal, for diffing.
flat() {
    signal "$@" | jq -r 'paths(scalars) as $p
        | "\($p | map(tostring) | join(".")) = \(getpath($p) | tojson)"' | LC_ALL=C sort
}

# Prints `unchanged`, or `changed` and the comment body (two or three
# lines saying what moved, then a pointer). OLD may be absent/empty: the
# first run is `changed` with no comment needed (the issue is new).
decide() { # old new (files; read once each, so a pipe or <(…) is fine)
    local oldj newj lines n
    oldj=$(cat "$1" 2> /dev/null)
    newj=$(cat "$2")
    if ! jq -e 'type == "object"' <<< "$oldj" > /dev/null 2>&1; then
        echo "changed"
        echo "First run: the tracking issue holds the report."
        return
    fi
    if [ "$(fingerprint <<< "$oldj")" = "$(fingerprint <<< "$newj")" ]; then
        echo "unchanged"
        return
    fi
    lines=$(LC_ALL=C join -t$'\t' -a1 -a2 -e '(none)' -o 0,1.2,2.2 \
        <(flat <<< "$oldj" | sed 's/ = /\t/' | LC_ALL=C sort -t$'\t' -k1,1) \
        <(flat <<< "$newj" | sed 's/ = /\t/' | LC_ALL=C sort -t$'\t' -k1,1) \
        | awk -F'\t' '$2 != $3 { printf "- %s: %s → %s\n", $1, $2, $3 }')
    n=$(printf '%s\n' "$lines" | grep -c '^- ')
    echo "changed"
    echo "Upstream watch: $n change(s) since the last run."
    printf '%s\n' "$lines" | head -3
    [ "$n" -le 3 ] || echo "- … and $((n - 3)) more; the issue body has the full report."
}

if [ "$mode" = decide ]; then
    decide "$decide_old" "$decide_new"
    exit 0
fi

# ── --publish: read the tracking issue's stored state first ─────────
# so the threads section can say what changed since it.

if [ "$mode" = publish ]; then
    [ -z "${UW_FIXTURES:-}" ] || { echo "upstream-watch: --publish is never run against fixtures" >&2; exit 64; }
    work=$(mktemp -d)
    # A failed lookup must not read as "no issue yet": that would open a
    # second one.
    num=$(gh issue list -R "$repo_slug" --label "$LABEL" --state open --limit 1 --json number --jq '.[0].number // empty') \
        || { echo "upstream-watch: could not list $repo_slug's issues" >&2; exit 1; }
    : > "$work/old.json"
    if [ -n "$num" ]; then
        gh issue view "$num" -R "$repo_slug" --json body --jq .body \
            | awk -v m="<!-- $STATE_MARK" 'index($0, m) == 1 { f = 1; next } f && /^-->/ { exit } f' > "$work/old.json"
        jq -e . "$work/old.json" > /dev/null 2>&1 || : > "$work/old.json"
    fi
    prev_state="$work/old.json"
fi

# ── run the sections ─────────────────────────────────────────────────

wants pins && section_pins
wants zig && section_zig
wants actions && section_actions
wants npm && section_npm
wants threads && section_threads
wants channels && section_channels
wants ci && section_ci
put .generated "\"${UW_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}\""
state=$(jq -cS . <<< "$state")
fp=$(fingerprint <<< "$state")

header="# Upstream watch"$'\n\n'"What mnml pins against what upstream has, as of $(jq -r .generated <<< "$state"). Pins move only through a deliberate branch gated by \`tools/gate/\` (docs/RELEASE.md, \"Dependencies\")."$'\n'
footer="${UW_RUN_URL:+"Run: ${UW_RUN_URL}"$'\n'}State fingerprint \`$fp\`."

if [ "$mode" = dry ] && [ -n "$json_only" ]; then
    jq -S . <<< "$state"
    exit 0
fi
if [ "$mode" = dry ]; then
    printf '%s\n%s%s\n\n' "$header" "$report" "$footer"
    echo "----- state -----"
    jq -S . <<< "$state"
    if [ -n "$prev_state" ]; then
        echo "----- decision against $prev_state -----"
        decide "$prev_state" <(printf '%s\n' "$state")
    fi
    exit 0
fi

# ── --publish: the one tracking issue ────────────────────────────────

printf '%s\n' "$state" > "$work/new.json"
body="$header"$'\n'"$report"$'\n'"$footer"$'\n\n'"<!-- $STATE_MARK"$'\n'"$state"$'\n'"-->"
printf '%s\n' "$body" > "$work/body.md"

gh label list -R "$repo_slug" --search "$LABEL" --json name --jq '.[].name' | grep -qx "$LABEL" \
    || gh label create "$LABEL" -R "$repo_slug" --color 5319e7 \
        --description "The weekly upstream dependency watch (tools/upstream-watch.sh)" \
    || { echo "upstream-watch: could not create the label" >&2; exit 1; }

if [ -z "$num" ]; then
    gh issue create -R "$repo_slug" --title "Upstream watch: dependencies behind upstream" \
        --label "$LABEL" --body-file "$work/body.md" || exit 1
    echo "upstream-watch: opened the tracking issue"
    exit 0
fi

decide "$work/old.json" "$work/new.json" > "$work/decision.txt"
if [ "$(head -1 "$work/decision.txt")" = unchanged ]; then
    echo "upstream-watch: #$num unchanged (fingerprint $fp); body and comments left alone"
    exit 0
fi
gh issue edit "$num" -R "$repo_slug" --body-file "$work/body.md" || exit 1
tail -n +2 "$work/decision.txt" > "$work/comment.md"
[ -z "${UW_RUN_URL:-}" ] || printf '\n%s\n' "Run: $UW_RUN_URL" >> "$work/comment.md"
gh issue comment "$num" -R "$repo_slug" --body-file "$work/comment.md" || exit 1
echo "upstream-watch: #$num updated and commented (fingerprint $fp)"
