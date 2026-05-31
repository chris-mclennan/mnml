#!/bin/bash
# Reports whether commits since the last docs-sync marker have touched
# user-facing source areas, so the public manual at <site>.sh stays
# fresh. Runs as a Claude Code Stop hook — silent when clean,
# one-paragraph reminder when stale.
#
# Marker file: site/.docs-sync-marker  (contains the last-synced commit SHA)
# Bump the marker by writing the current HEAD SHA into it. The manual-writer
# agent does this automatically when it writes a page.
#
# Skip tags:
#   - Commits with `[skip docs]` or `[no docs]` in the message don't count
#   - Commits that only touch docs/ / site/ / README.md / CHANGELOG.md don't count
#
# Exits 0 always — never blocks anything.

# Permissive — never block the hook regardless of internal command exit codes.
set -u

# Find the repo root containing THIS SCRIPT (not the caller's cwd).
SCRIPT_DIR="$(/usr/bin/dirname "$(/usr/bin/realpath "$0" 2>/dev/null || echo "$0")")"
REPO_ROOT="$(/usr/bin/git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$REPO_ROOT"

MARKER="site/.docs-sync-marker"
SITE_DIR="site"

# If the repo doesn't have a site/ subdir, this script is a no-op
[ -d "$SITE_DIR" ] || exit 0

# If marker doesn't exist, suggest bootstrap and exit silently
if [ ! -f "$MARKER" ]; then
  exit 0
fi

LAST_SYNCED="$(/bin/cat "$MARKER" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
[ -n "$LAST_SYNCED" ] || exit 0

# If marker matches HEAD, fully synced — silent exit
HEAD_SHA="$(/usr/bin/git rev-parse HEAD)"
[ "$LAST_SYNCED" = "$HEAD_SHA" ] && exit 0

# Validate marker SHA still exists in history (might be stale after a force-push)
if ! /usr/bin/git cat-file -e "$LAST_SYNCED" 2>/dev/null; then
  exit 0
fi

# Find commits since marker. Filter out skip-tagged + docs-only commits.
# Use a record separator (`\037`) between SHA and full body so the body's
# newlines don't break parsing.
COMMITS="$(/usr/bin/git log --format=$'%H\037%B\036' "$LAST_SYNCED..HEAD" 2>/dev/null)"
[ -z "$COMMITS" ] && exit 0

# Count commits that:
#   - DON'T have [skip docs] / [no docs] in the message
#   - touch files outside site/, docs/, README, CHANGELOG, CONTRIBUTING, LICENSE,
#     CLAUDE.md, .github/, .gitignore, Cargo.lock
STALE_COUNT=0
SAMPLE_FILES=""
# Tracks whether CHANGELOG.md / FEATURES.md were updated alongside the
# stale feature commits. The script calls them out separately so a user
# who's editing the manual but forgot the CHANGELOG sees both reminders.
CHANGELOG_TOUCHED=0
FEATURES_TOUCHED=0
# Split on the record separator \036 — one record per commit.
while IFS= read -r -d $'\036' record; do
  [ -z "$record" ] && continue
  # Strip whitespace from SHA — `git log` puts a newline between record
  # boundaries which would otherwise corrupt the next SHA.
  SHA="$(echo "${record%%$'\037'*}" | /usr/bin/tr -d '[:space:]')"
  MSG="${record#*$'\037'}"
  [ -z "$SHA" ] && continue

  # Skip tag check — searches the full body, not just subject.
  case "$MSG" in
    *"[skip docs]"*|*"[no docs]"*) continue ;;
  esac

  # Check files touched
  FILES="$(/usr/bin/git show --name-only --pretty=format: "$SHA" 2>/dev/null | /usr/bin/grep -v '^$' || true)"
  HAS_FEATURE_CHANGE=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      CHANGELOG.md) CHANGELOG_TOUCHED=1; continue ;;
      FEATURES.md)  FEATURES_TOUCHED=1; continue ;;
      site/*|docs/*|README.md|CONTRIBUTING.md|LICENSE-*|CLAUDE.md|.github/*|.gitignore|Cargo.lock|*.lock|scripts/check-docs-sync.sh|.claude/*)
        continue ;;
      *)
        HAS_FEATURE_CHANGE=1
        # Sample first few unique source paths for the reminder
        case " $SAMPLE_FILES " in *" $f "*) ;; *) SAMPLE_FILES="$SAMPLE_FILES $f" ;; esac
        ;;
    esac
  done <<< "$FILES"

  [ "$HAS_FEATURE_CHANGE" = "1" ] && STALE_COUNT=$((STALE_COUNT + 1))
done <<< "$COMMITS"

[ "$STALE_COUNT" -eq 0 ] && exit 0

# Compact sample (first 3 files)
SAMPLE="$(echo "$SAMPLE_FILES" | /usr/bin/xargs -n1 2>/dev/null | /usr/bin/head -3 | /usr/bin/awk '{printf "    · %s\n", $1}')"

# Extra hints — if CHANGELOG.md / FEATURES.md weren't touched in the stale
# window AND they exist on disk, suggest updating them too.
EXTRAS=""
if [ "$CHANGELOG_TOUCHED" = "0" ] && [ -f CHANGELOG.md ]; then
  EXTRAS="$EXTRAS
   · CHANGELOG.md hasn't been updated since the last sync — bump it for the next release."
fi
if [ "$FEATURES_TOUCHED" = "0" ] && [ -f FEATURES.md ]; then
  EXTRAS="$EXTRAS
   · FEATURES.md hasn't been updated since the last sync — refresh if the surface changed."
fi

/bin/cat <<EOF

📚 docs-sync: $STALE_COUNT commit(s) since last manual update may need site docs.
   Last synced: ${LAST_SYNCED:0:8}  →  HEAD: ${HEAD_SHA:0:8}
   Affected files (sample):
$SAMPLE
   Run \`manual-writer\` for the relevant area, or tag commits \`[skip docs]\` if trivial.$EXTRAS

EOF

exit 0
