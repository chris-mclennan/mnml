#!/usr/bin/env bash
# Build MnmlSymbols.ttf — a symbols-only font that layers under the
# user's preferred programming font. Only contains mnml's branded
# custom glyphs (AWS Architecture Icons, Claude Code, Codex, etc.).
#
# Usage:
#   scripts/build_mnml_symbols.sh
#
# The user's primary font (JetBrainsMono NF / Fira Code NF / whatever)
# keeps rendering standard Nerd Font glyphs; MnmlSymbols gets loaded
# as a fallback for codepoints U+F1B00 – U+F20FF that only mnml claims.
# See docs/tools.md#branded-icons for per-terminal fallback config.

set -euo pipefail

SVG_DIR="$HOME/Downloads/mnml-aws-icon-preview-inverted"
FONT_OUT="$HOME/Library/Fonts/MnmlSymbols.ttf"

if [[ ! -d "$SVG_DIR" ]]; then
  echo "SVG dir not found: $SVG_DIR" >&2
  echo "(expected the AWS architecture SVGs from the design assets)" >&2
  exit 1
fi

# Codepoints match src/icon_catalog.rs. U+F1B00-F1B0B = inverted
# variants (transparent bg, colored lines — the default rail glyph).
# U+F1B10-F1B1B reserved for the color variant, patched when SVGs
# for those land.
declare -a GLYPHS=(
  "amplify.svg:F1B00:aws-amplify-inv"
  "lambda.svg:F1B01:aws-lambda-inv"
  "ecs.svg:F1B02:aws-ecs-inv"
  "ecr.svg:F1B03:aws-ecr-inv"
  "rds.svg:F1B04:aws-rds-inv"
  "sqs.svg:F1B05:aws-sqs-inv"
  "sns.svg:F1B06:aws-sns-inv"
  "dynamodb.svg:F1B07:aws-dynamodb-inv"
  "cognito.svg:F1B08:aws-cognito-inv"
  "cloudwatch.svg:F1B09:aws-cloudwatch-inv"
  "codebuild.svg:F1B0A:aws-codebuild-inv"
  "eventbridge.svg:F1B0B:aws-eventbridge-inv"
)

args=(--output "$FONT_OUT")
for spec in "${GLYPHS[@]}"; do
  IFS=':' read -r svg cp name <<<"$spec"
  path="$SVG_DIR/$svg"
  if [[ ! -f "$path" ]]; then
    echo "  skipping $svg — file not found at $path" >&2
    continue
  fi
  args+=(--glyph "${path}:${cp}:${name}")
done

echo "→ building MnmlSymbols.ttf with ${#GLYPHS[@]} glyphs"
fontforge -script "$(dirname "$0")/build_mnml_symbols.py" "${args[@]}"

echo
echo "→ flushing font cache + kicking fontd"
atsutil databases -removeUser >/dev/null 2>&1 || true
killall fontd 2>/dev/null || true

echo
echo "✓ MnmlSymbols.ttf installed at $FONT_OUT"
echo
echo "  To use it, add a fallback line to your terminal config:"
echo "  · Ghostty (~/.config/ghostty/config): font-family = MnmlSymbols"
echo "  · Alacritty: extend the font.normal.family fallback chain"
echo "  · kitty:    symbol_map U+F1B00-U+F20FF MnmlSymbols"
echo "  · wezterm:  font = font_with_fallback({..., 'MnmlSymbols'})"
echo "  · iTerm2:   Preferences → Profiles → Text → Font (Non-ASCII Font)"
echo
echo "  See docs/tools.md#branded-icons for the exact snippets."
echo "  Restart your terminal after config changes to pick up the font."
