#!/bin/sh
# release-notes.sh — CHANGELOG.md's top section, as the release body.
#
#   scripts/release-notes.sh CHANGELOG.md 0.3.0 > notes.md
#
# Prints everything from the first `## ` heading to the one after it, minus
# the heading line itself. Warns on stderr when the heading does not name
# the version being released (a `## v0.3.0 (unreleased)` heading shipped as
# v0.3.0-rc0 is fine and expected; a `## v0.2.0` heading shipped as v0.3.0
# is a changelog nobody updated). Fails when the section is empty.
set -eu

file=${1:?changelog path}
version=${2:-}

notes=$(awk '
    /^## / { if (seen) exit; seen = 1; heading = $0; next }
    seen { print }
' "$file")
heading=$(awk '/^## / { print; exit }' "$file")

[ -n "$heading" ] || { echo "release-notes: $file has no \`## \` section" >&2; exit 1; }
if [ -n "$version" ]; then
    bare=${version%%-*}
    case "$heading" in
        *"$version"*|*"$bare"*) ;;
        *) echo "release-notes: warning: top heading '$heading' does not mention $version" >&2 ;;
    esac
fi

# Trim leading and trailing blank lines.
notes=$(printf '%s\n' "$notes" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | awk 'NF { started = 1 } started')
[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] || { echo "release-notes: the top section of $file is empty" >&2; exit 1; }
printf '%s\n' "$notes"
