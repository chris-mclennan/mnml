#!/usr/bin/env bash
# tools/wt.sh — this repo's worktrees, kept outside every repo at
# <parent of the repo>/.worktrees/<repo>/<name> (for this checkout:
# ../.worktrees/mnml-zig/<name>). Never /tmp, never a home dot-folder,
# never inside a repo. <name> is one path segment of a-z 0-9 - . _, at
# most 100 characters, and is also the branch name.
#
#   tools/wt.sh root                    the root for this repo
#   tools/wt.sh path NAME               where NAME's worktree goes
#   tools/wt.sh add NAME [BASE]         new branch NAME from BASE (main) in
#                                       a new worktree; prints its path
#   tools/wt.sh remove NAME [--abandon] git worktree remove, then
#                                       git branch -d once merged
#   tools/wt.sh gc                      report only: each worktree safe or
#                                       not, and why; removes nothing
#   tools/wt.sh move NAME               a worktree still at the old
#                                       <repo>-worktrees/ to the root
#
# Whoever creates a worktree removes it. `remove` refuses a tree that is
# dirty, locked, has a process with its cwd or a file open inside it, or
# whose branch has commits main does not — unless --abandon says the
# branch is being given up, which leaves the branch in place (never
# `branch -D`). `move` refuses a locked tree or a live process; a dirty
# tree moves. Worktrees are found by BRANCH through
# `git worktree list --porcelain`, so both locations work.
#
# The repo is the one around the current directory (else the one this
# script sits in); WT_MAIN_BRANCH names the branch "merged" means
# (default main).
set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/wt-lib.sh"

die() { echo "wt: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }

if git rev-parse --git-dir >/dev/null 2>&1; then REPO=$(pwd -P); else REPO=$(cd "$HERE/.." && pwd -P); fi
MAIN=$(wt_main "$REPO") || die "not in a git repository: $REPO"
ROOT=$(wt_root "$MAIN")
OLD=$(wt_old_root "$MAIN")
BASE_BRANCH=${WT_MAIN_BRANCH:-main}

g() { git -C "$MAIN" "$@"; }

need_name() {
    [ -n "${1:-}" ] || usage
    wt_valid_name "$1" || die "bad name '$1': one segment of a-z 0-9 - . _ (at most 100), not starting with . or -, a legal branch name"
}

# ─── what sits inside a tree ───────────────────────────────────────────

# Every process's cwd and open files, as lsof -F lines (p<pid> c<cmd>
# n<path>), taken once. lsof runs from / under a 20 s alarm, so neither
# its own cwd nor a hung NFS mount counts. Without lsof (a bare Linux),
# /proc gives the same lines.
SNAP=; SNAP_OK=
snapshot() {
    [ -n "$SNAP_OK" ] && return 0
    if command -v lsof >/dev/null 2>&1; then
        SNAP=$(cd / && if command -v perl >/dev/null 2>&1; then
            perl -e 'alarm 20; exec @ARGV' lsof -w -n -P -Fpcn 2>/dev/null
        else
            lsof -w -n -P -Fpcn 2>/dev/null
        fi)
        # lsof exits 1 for files it could not stat; 142 is the alarm.
        [ $? -eq 142 ] && { SNAP_OK=timeout; return 1; }
    elif [ -d /proc/self ]; then
        SNAP=$(for d in /proc/[0-9]*; do
            p=${d#/proc/}; c=$(cat "$d/comm" 2>/dev/null) || continue
            printf 'p%s\nc%s\n' "$p" "$c"
            l=$(readlink "$d/cwd" 2>/dev/null) && printf 'n%s\n' "$l"
            for f in "$d"/fd/*; do l=$(readlink "$f" 2>/dev/null) && printf 'n%s\n' "$l"; done
        done)
    else
        SNAP_OK=none; return 1
    fi
    SNAP_OK=yes
}

# "pid command" for each process with its cwd or an open file inside $1;
# this script's own shell and its own files (bash holds them open) are
# not counted.
procs_in() {
    local real
    real=$(cd "$1" 2>/dev/null && pwd -P) || return 0
    printf '%s\n' "$SNAP" | awk -v root="$real" -v me="$$" -v s1="$HERE/wt.sh" -v s2="$HERE/wt-lib.sh" '
        /^p/ { pid = substr($0, 2); next }
        /^c/ { cmd = substr($0, 2); next }
        /^n/ { n = substr($0, 2)
               if (pid == me || n == s1 || n == s2) next
               if (n == root || index(n, root "/") == 1) print pid " " cmd }' | sort -u
}

# Reasons a tree is in use, one per line; empty means none. $3 = locked.
live_reasons() {
    local path=$1 locked=$3 ps
    [ -n "$locked" ] && echo "locked${locked#locked}"
    if ! snapshot; then
        echo "could not list processes ($SNAP_OK)"
    else
        ps=$(procs_in "$path")
        [ -n "$ps" ] && echo "a process inside it: $(printf '%s\n' "$ps" | head -3 | sed 's/^/pid /' | paste -sd, - | sed 's/,/, /g')"
    fi
    return 0
}

dirty_reason() {
    local n
    n=$(git -C "$1" --no-optional-locks status --porcelain 2>/dev/null | grep -c .)
    [ "$n" -gt 0 ] && echo "dirty ($n changed or untracked)"
    return 0
}

ahead() { g rev-list --count "$BASE_BRANCH..refs/heads/$1" 2>/dev/null || echo "?"; }

# One record per worktree: path, branch, locked, prunable — split by the
# unit separator (\037), not a tab, so an empty field stays a field.
US=$'\037'
records() {
    g worktree list --porcelain | awk '
        function out() { if (p != "") printf "%s\037%s\037%s\037%s\n", p, b, l, pr; p = b = l = pr = "" }
        /^worktree / { out(); p = substr($0, 10); next }
        /^branch refs\/heads\// { b = substr($0, 19); next }
        /^locked/ { l = $0; if (l == "locked") l = "locked "; next }
        /^prunable/ { pr = "prunable"; next }
        END { out() }'
}

record_of() { records | awk -F'\037' -v b="$1" '$2 == b { print; exit }'; }

# ─── verbs ─────────────────────────────────────────────────────────────

cmd_root() { echo "$ROOT"; }

cmd_path() { need_name "${1:-}"; echo "$ROOT/$1"; }

cmd_add() {
    local name=${1:-} base=${2:-$BASE_BRANCH} path
    need_name "$name"
    path=$ROOT/$name
    g show-ref --verify --quiet "refs/heads/$name" && die "branch $name exists (its worktree: $(wt_of "$MAIN" "$name"))"
    [ -e "$path" ] && die "$path exists"
    g rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "no such base: $base"
    mkdir -p "$ROOT" || die "cannot make $ROOT"
    g worktree add -q -b "$name" "$path" "$base" || die "git worktree add failed"
    echo "$path"
}

cmd_remove() {
    local name=${1:-} abandon=0 rec path locked why n merged=1
    [ $# -le 2 ] || usage
    if [ $# -eq 2 ]; then [ "$2" = --abandon ] || usage; abandon=1; fi
    [ -n "$name" ] || usage
    rec=$(record_of "$name"); [ -n "$rec" ] || die "no worktree has branch $name checked out"
    path=$(printf '%s' "$rec" | cut -d "$US" -f1); locked=$(printf '%s' "$rec" | cut -d "$US" -f3)
    [ "$path" = "$MAIN" ] && die "$name is checked out in the main checkout — not a worktree"
    why=$( { live_reasons "$path" "$name" "$locked"; dirty_reason "$path"; } )
    n=$(ahead "$name")
    if [ "$n" != 0 ]; then
        merged=0
        [ $abandon = 1 ] || why="${why:+$why
}$n commit(s) not in $BASE_BRANCH (pass --abandon to give the branch up)"
    fi
    if [ -n "$why" ]; then
        echo "wt: refusing to remove $path:" >&2
        printf '%s\n' "$why" | sed 's/^/  /' >&2
        exit 1
    fi
    g worktree remove "$path" || die "git worktree remove failed"
    echo "removed $path"
    if [ $merged = 1 ]; then
        g branch -d "$name"
    else
        echo "branch $name left in place: $n commit(s) not in $BASE_BRANCH (--abandon); delete it yourself once sure"
    fi
}

cmd_move() {
    local name=${1:-} rec path locked why dest
    [ -n "$name" ] || usage
    rec=$(record_of "$name"); [ -n "$rec" ] || die "no worktree has branch $name checked out"
    path=$(printf '%s' "$rec" | cut -d "$US" -f1); locked=$(printf '%s' "$rec" | cut -d "$US" -f3)
    case $path in
        "$OLD"/*) ;;
        "$ROOT"/*) die "$path is already at the root" ;;
        *) die "$path is not at the old location $OLD/ — move it by hand if it should be" ;;
    esac
    wt_valid_name "$name" || die "branch $name does not fit the name rule; rename the branch first"
    dest=$ROOT/$name
    [ -e "$dest" ] && die "$dest exists"
    why=$(live_reasons "$path" "$name" "$locked")
    if [ -n "$why" ]; then
        echo "wt: refusing to move $path:" >&2
        printf '%s\n' "$why" | sed 's/^/  /' >&2
        exit 1
    fi
    mkdir -p "$ROOT" || die "cannot make $ROOT"
    g worktree move "$path" "$dest" || die "git worktree move failed"
    echo "$dest"
}

cmd_gc() {
    local path branch locked prunable why n recent safe=0 unsafe=0
    echo "gc: report only — nothing is removed. root: $ROOT"
    snapshot || true
    while IFS=$US read -r path branch locked prunable; do
        [ "$path" = "$MAIN" ] && continue
        why=
        because() { why="${why:+$why; }$1"; }
        if [ -n "$prunable" ] || [ ! -d "$path" ]; then
            because "its directory is gone (git worktree prune)"
        else
            [ -n "$branch" ] || because "detached HEAD"
            r=$(dirty_reason "$path"); [ -n "$r" ] && because "$r"
            if [ -n "$branch" ]; then n=$(ahead "$branch"); [ "$n" != 0 ] && because "$n commit(s) not in $BASE_BRANCH"; fi
            # the first file or directory touched in the last 24 h; the
            # build cache is skipped (huge, and a live build shows as a
            # process anyway)
            recent=$(find "$path" -name .zig-cache -prune -o -mmin -1440 -print -quit 2>/dev/null)
            [ "$recent" = "$path" ] && recent=$path/.
            [ -n "$recent" ] && because "modified within 24 h (${recent#"$path"/})"
            while IFS= read -r r; do [ -n "$r" ] && because "$r"; done <<EOF
$(live_reasons "$path" "$branch" "$locked")
EOF
        fi
        if [ -z "$why" ]; then
            printf 'safe      %-24s %s\n' "${branch:-(detached)}" "$path"; safe=$((safe + 1))
        else
            printf 'not safe  %-24s %s\n          why: %s\n' "${branch:-(detached)}" "$path" "$why"; unsafe=$((unsafe + 1))
        fi
        case $path in
            "$OLD"/*) echo "          old location: $(basename "$OLD")/ predates the convention — tools/wt.sh move ${branch:-NAME}" ;;
        esac
    done <<EOF
$(records)
EOF
    echo "gc: $safe safe, $unsafe not safe"
}

verb=${1:-}; [ $# -gt 0 ] && shift
case $verb in
    root) cmd_root ;;
    path) cmd_path "$@" ;;
    add) cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    move) cmd_move "$@" ;;
    gc) cmd_gc ;;
    *) usage ;;
esac
