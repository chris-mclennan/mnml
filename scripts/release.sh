#!/usr/bin/env bash
# release.sh — cut a release locally, up to (not including) the push.
#
#   scripts/release.sh v0.3.0            # build, check, tag; prints the push
#   scripts/release.sh v0.3.0 --dry-run  # everything but the tag
#
# In order:
#   1. the tree is clean and on a commit (a dirty tree ships -dirty binaries)
#   2. CHANGELOG.md's top section exists, mentions the version, and has no
#      credential-shaped literal (the secret-scrub trap — see docs/RELEASE.md)
#   3. `zig build dist -Dversion=X` for all five targets — the same command
#      release.yml runs, so a build that fails here fails here and not on
#      the runner
#   4. the packaged binary for this machine prints the version
#   5. site/src/data/release.json names the previous release (the
#      site's fallback; pinned after each release — docs/RELEASE.md)
#   6. an annotated tag, locally
#
# It never pushes. The last line is the command that does; run it yourself,
# then watch the Release workflow, run scripts/dist-check.sh vX.Y.Z when
# it is done, and pin the site to it (node site/scripts/pin-release.mjs).
set -euo pipefail

tag=${1:?usage: release.sh vX.Y.Z [--dry-run]}
dry=0
[ "${2:-}" = "--dry-run" ] && dry=1
case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "release: tag must look like v0.3.0 or v0.3.0-rc0" >&2; exit 2 ;;
esac
version=${tag#v}

cd "$(dirname "$0")/.."

say() { printf '\n── %s ──\n' "$*"; }

say "tree"
if [ -n "$(git --no-optional-locks status --porcelain --untracked-files=no)" ]; then
    echo "release: the tree has uncommitted changes — commit or stash first" >&2
    git --no-optional-locks status --short --untracked-files=no
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "release: tag $tag already exists" >&2
    exit 1
fi
echo "clean, at $(git rev-parse --short HEAD) on $(git branch --show-current)"

say "changelog"
notes=$(scripts/release-notes.sh CHANGELOG.md "$version")
if printf '%s\n' "$notes" | grep -Eiq '(bearer |xox[bp]-|sk-[a-z0-9]{8,}|token\s*=\s*")'; then
    echo "release: CHANGELOG.md's top section has a credential-shaped literal:" >&2
    printf '%s\n' "$notes" | grep -Ein '(bearer |xox[bp]-|sk-[a-z0-9]{8,}|token\s*=\s*")' >&2
    echo "release: describe the shape in prose instead. GitHub scrubs secret matches inside the build manifest and the release ships one file." >&2
    exit 1
fi
printf '%s\n' "$notes" | head -n 12
[ "$(printf '%s\n' "$notes" | wc -l)" -gt 12 ] && echo "…"

say "site release data"
# The download page falls back to site/src/data/release.json when GitHub
# cannot be asked at build time; it must name the release before this one.
command -v node >/dev/null 2>&1 || { echo "release: node is needed to check site/src/data/release.json" >&2; exit 1; }
node site/scripts/pin-release.mjs --check

say "zig build dist -Dversion=$version"
start=$(date +%s)
zig build dist -Dversion="$version" --summary all
echo "built in $(( $(date +%s) - start ))s"
ls -la zig-out/dist/

say "the binary says"
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) host=aarch64-apple-darwin ;;
    Darwin-x86_64) host=x86_64-apple-darwin ;;
    Linux-x86_64) host=x86_64-unknown-linux-gnu ;;
    Linux-aarch64) host=aarch64-unknown-linux-gnu ;;
    *) host= ;;
esac
if [ -n "$host" ] && [ -x "zig-out/release/$host/mnml" ]; then
    got=$("zig-out/release/$host/mnml" --version)
    echo "$got"
    case "$got" in
        *"$version"*) ;;
        *) echo "release: --version does not print $version" >&2; exit 1 ;;
    esac
else
    echo "(no packaged binary for this host — skipping the --version check)"
fi

if [ "$dry" = 1 ]; then
    say "dry run"
    echo "not tagging. Without --dry-run this would run:"
    echo "  git tag -a $tag -m \"mnml $version\""
    echo "and then tell you to:"
    echo "  git push origin $tag"
    exit 0
fi

say "tag"
git tag -a "$tag" -m "mnml $version"
echo "tagged $tag at $(git rev-parse --short HEAD)"

say "next"
echo "push the tag to start the Release workflow:"
echo
echo "  git push origin $tag"
echo
echo "then, when it is green, count the assets — green is not enough:"
echo
echo "  scripts/dist-check.sh $tag"
echo
echo "then pin the site's fallback release and commit it (with the zon bump):"
echo
echo "  node site/scripts/pin-release.mjs $tag"
