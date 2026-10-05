# tools/wt-lib.sh — the worktree lookups tools/wt.sh and the gate scripts
# share. Sourced, never run; every function takes the repo it asks about,
# so a caller in any checkout (the main one or a worktree) gets the same
# answer.
#
#   wt_main REPO         the main checkout of REPO's repository
#   wt_root REPO         where its worktrees live: <parent>/.worktrees/<repo>
#   wt_old_root REPO     where they lived before: <main>-worktrees
#   wt_of REPO BRANCH    the worktree that has BRANCH checked out, from
#                        git's own list — at the new root, the old one or
#                        anywhere else; empty when there is none
#   wt_valid_name NAME   a worktree name: one segment of a-z 0-9 - . _,
#                        at most 100 characters, and a legal branch name

wt_main() {
    local common
    common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    (cd "$common/.." && pwd -P)
}

wt_root() {
    local main
    main=$(wt_main "$1") || return 1
    printf '%s/.worktrees/%s\n' "$(dirname "$main")" "$(basename "$main")"
}

wt_old_root() {
    local main
    main=$(wt_main "$1") || return 1
    printf '%s-worktrees\n' "$main"
}

wt_of() {
    git -C "$1" worktree list --porcelain 2>/dev/null |
        awk -v want="branch refs/heads/$2" '/^worktree /{p=substr($0, 10)} $0 == want {print p; exit}'
}

wt_valid_name() {
    local n=$1
    [ ${#n} -ge 1 ] && [ ${#n} -le 100 ] || return 1
    case $n in
        # spelled out: a [a-z] range follows the locale's collation and
        # can let capitals through
        *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1 ;;
        .* | -*) return 1 ;;
    esac
    git check-ref-format --branch "$n" >/dev/null 2>&1
}
