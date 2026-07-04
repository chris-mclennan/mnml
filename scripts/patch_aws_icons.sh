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
FONT_IN="$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"
FONT_OUT="$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular-mnml.ttf"

if [[ ! -d "$SVG_DIR" ]]; then
  echo "SVG dir not found: $SVG_DIR" >&2
  exit 1
fi
if [[ ! -f "$FONT_IN" ]]; then
  echo "Font input not found: $FONT_IN" >&2
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

ARGS=(--font "$FONT_IN" --output "$FONT_OUT")
for spec in "${GLYPHS[@]}"; do
  IFS=':' read -r svg cp name <<<"$spec"
  path="$SVG_DIR/$svg"
  if [[ ! -f "$path" ]]; then
    echo "skipping $svg — file not found at $path" >&2
    continue
  fi
  ARGS+=(--glyph "${path}:${cp}:${name}:width=1.0:height=0.85")
done

echo "→ patching $FONT_OUT with ${#GLYPHS[@]} AWS icons (width=1.0, fits cell)"
fontforge -script "$(dirname "$0")/patch_nerd_font.py" "${ARGS[@]}"

# Flush the user-level font cache so macOS re-reads the file we just
# wrote. `atsutil databases -removeUser` works without sudo on macOS
# 14+; on older systems it silently no-ops (harmless).
echo
echo "→ flushing font cache"
atsutil databases -removeUser >/dev/null 2>&1 || true

echo
echo "✓ done. Restart your terminal to pick up the refreshed font"
echo "  (Ghostty caches the loaded font in-process — a cache flush"
echo "   alone won't refresh already-open windows)."
