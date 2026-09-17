#!/usr/bin/env bash
# tools/work-data-audit.sh [REV]
#
# Fails when a tracked file holds text that belongs to somebody's day
# job rather than to mnml: an employer's name, its ticket keys, its
# hosts, its people. The patterns are the contributor's own and live
# OUTSIDE the repository, so the audit never has to spell them here:
#
#   ~/.config/mnml/work-data-patterns     one extended regex per line,
#                                         `#` comments, blank lines skipped
#   ~/.config/mnml/work-data-allow        optional: one extended regex per
#                                         line; a hit matching one is let go
#                                         (interop names a feature must spell)
#
# With no patterns file there is nothing to check: exit 0 with a note.
# REV defaults to the working tree; give a revision to audit a commit.
#
# Run it before every merge. Captures of a live system are never
# committed — screens are cut from the offline servers (see
# docs/ui-spec/jira/README.md).
set -u
cd "$(dirname "$0")/.." || exit 2
pats="${MNML_WORK_DATA_PATTERNS:-$HOME/.config/mnml/work-data-patterns}"
allow="${MNML_WORK_DATA_ALLOW:-$HOME/.config/mnml/work-data-allow}"
if [ ! -s "$pats" ]; then
    echo "work-data-audit: no patterns at $pats — nothing to check"
    exit 0
fi
re=$(grep -vE '^[[:space:]]*(#|$)' "$pats" | paste -sd'|' -)
[ -n "$re" ] || { echo "work-data-audit: $pats has no patterns"; exit 0; }
hits=$(git grep -nIE "$re" ${1:-} -- . 2>/dev/null)
if [ -s "$allow" ]; then
    ok=$(grep -vE '^[[:space:]]*(#|$)' "$allow" | paste -sd'|' -)
    [ -n "$ok" ] && hits=$(printf '%s\n' "$hits" | grep -vE "$ok")
fi
hits=$(printf '%s\n' "$hits" | sed '/^$/d')
if [ -n "$hits" ]; then
    n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
    printf '%s\n' "$hits" | cut -c1-160 | head -40
    echo "work-data-audit: $n line(s) hold work data"
    exit 1
fi
echo "work-data-audit: 0 lines hold work data"
