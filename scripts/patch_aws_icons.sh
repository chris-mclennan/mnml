#!/usr/bin/env bash
# Batch-patch the 12 AWS Architecture icons into the user's JetBrainsMono
# Nerd Font, at codepoints U+F300-F30B (inverted variants).
#
# Usage:
#   scripts/patch_aws_icons.sh
#
# Always overwrites `JetBrainsMonoNerdFont-Regular-mnml.ttf` and then
# clears macOS's user font cache (`atsutil databases -removeUser`, no
# sudo on macOS 14+) so the reload picks up the new file. Restart your
# terminal after this runs — Ghostty caches the loaded font in-process,
# a font-cache flush alone won't refresh a running window.
#
# Each glyph is scaled with `width=1.0` (fits inside the cell — the earlier
# default of 1.4 overflowed by 20% on each side, eating the tab-icon
# padding). Height stays at 0.85 so the icon has visual headroom instead
# of touching the top of the em-square.

set -euo pipefail

SVG_DIR="$HOME/Downloads/mnml-aws-icon-preview-inverted"
# Patch BOTH the NF (Nerd Font) and NFM (Nerd Font Mono) variants of
# JetBrainsMono because Ghostty resolves the "…Mono" one by default
# and the plain "…NF" one when the app or user config asks for it. If
# only one is patched, U+F300 either renders as tofu (Ghostty picked
# the un-patched variant) or as the old stale glyph (Ghostty picked
# an older -mnml Mono file that wasn't updated).
FONT_INS=(
  "$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"
  "$HOME/Library/Fonts/JetBrainsMonoNerdFontMono-Regular.ttf"
)

if [[ ! -d "$SVG_DIR" ]]; then
  echo "SVG dir not found: $SVG_DIR" >&2
  exit 1
fi

# `<svg-basename>:<hex-codepoint>:<internal-glyph-name>` — U+F300 = amplify,
# then walking codepoints upward for the remaining AWS Architecture icons in
# the same directory order. Add more here as you patch new icons.
declare -a GLYPHS=(
  "amplify.svg:F300:aws-amplify-inv"
  "lambda.svg:F301:aws-lambda-inv"
  "ecs.svg:F302:aws-ecs-inv"
  "ecr.svg:F303:aws-ecr-inv"
  "rds.svg:F304:aws-rds-inv"
  "sqs.svg:F305:aws-sqs-inv"
  "sns.svg:F306:aws-sns-inv"
  "dynamodb.svg:F307:aws-dynamodb-inv"
  "cognito.svg:F308:aws-cognito-inv"
  "cloudwatch.svg:F309:aws-cloudwatch-inv"
  "codebuild.svg:F30A:aws-codebuild-inv"
  "eventbridge.svg:F30B:aws-eventbridge-inv"
)

patched_any=0
for font_in in "${FONT_INS[@]}"; do
  if [[ ! -f "$font_in" ]]; then
    echo "skipping (not installed): $font_in"
    continue
  fi
  # Output alongside the input, with the -mnml suffix inserted before .ttf.
  base="$(basename "$font_in" .ttf)"
  font_out="$HOME/Library/Fonts/${base}-mnml.ttf"

  args=(--font "$font_in" --output "$font_out")
  for spec in "${GLYPHS[@]}"; do
    IFS=':' read -r svg cp name <<<"$spec"
    path="$SVG_DIR/$svg"
    if [[ ! -f "$path" ]]; then
      echo "  skipping $svg — file not found at $path" >&2
      continue
    fi
    args+=(--glyph "${path}:${cp}:${name}:width=1.0:height=0.85")
  done

  echo "→ patching $(basename "$font_out") with ${#GLYPHS[@]} AWS icons (width=1.0)"
  fontforge -script "$(dirname "$0")/patch_nerd_font.py" "${args[@]}"
  patched_any=1
done

if (( patched_any == 0 )); then
  echo "no source fonts found; install JetBrainsMono Nerd Font first" >&2
  exit 1
fi

# Flush the user-level font cache so macOS re-reads the files we just
# wrote. `atsutil databases -removeUser` works without sudo on macOS
# 14+; on older systems it silently no-ops (harmless). Also kick the
# user font daemon so its in-memory registry re-scans immediately —
# without this, deleted -mnml{2,3}.ttf entries survive as zombies
# and Ghostty resolves the family name to the wrong (stale) file.
echo
echo "→ flushing font cache + kicking fontd"
atsutil databases -removeUser >/dev/null 2>&1 || true
killall fontd 2>/dev/null || true

echo
echo "✓ done. Restart your terminal to pick up the refreshed fonts."
echo "  Ghostty caches the loaded font in-process — cache flush"
echo "  alone won't refresh already-open windows."
