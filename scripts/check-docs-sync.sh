#!/usr/bin/env bash
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

# Find the repo root (handles being called from anywhere in the tree)
REPO_ROOT="$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null)" || exit 0
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
COMMITS="$(/usr/bin/git log --format='%H %s' "$LAST_SYNCED..HEAD" 2>/dev/null)"
[ -z "$COMMITS" ] && exit 0

# Count commits that:
#   - DON'T have [skip docs] / [no docs] in the message
#   - touch files outside site/, docs/, README, CHANGELOG, CONTRIBUTING, LICENSE,
#     CLAUDE.md, .github/, .gitignore, Cargo.lock
STALE_COUNT=0
SAMPLE_FILES=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  SHA="${line%% *}"
  MSG="${line#* }"

  # Skip tag check
  case "$MSG" in
    *"[skip docs]"*|*"[no docs]"*) continue ;;
  esac

  # Check files touched
  FILES="$(/usr/bin/git show --name-only --pretty=format: "$SHA" 2>/dev/null | /usr/bin/grep -v '^$' || true)"
  HAS_FEATURE_CHANGE=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      site/*|docs/*|README.md|CHANGELOG.md|CONTRIBUTING.md|LICENSE-*|CLAUDE.md|.github/*|.gitignore|Cargo.lock|*.lock)
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

/bin/cat <<EOF

📚 docs-sync: $STALE_COUNT commit(s) since last manual update may need site docs.
   Last synced: ${LAST_SYNCED:0:8}  →  HEAD: ${HEAD_SHA:0:8}
   Affected files (sample):
$SAMPLE
   Run \`manual-writer\` for the relevant area, or tag commits \`[skip docs]\` if trivial.

EOF

exit 0
