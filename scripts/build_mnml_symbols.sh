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

FONT_OUT="$HOME/Library/Fonts/MnmlSymbols.ttf"

# Prefer the vendored SVGs shipped with the mnml repo; fall back to
# the design-assets Downloads dir so pre-vendored setups still work.
if [[ -d "$(dirname "$0")/../assets/glyphs/aws" ]]; then
  SVG_DIR="$(cd "$(dirname "$0")/../assets/glyphs/aws" && pwd)"
elif [[ -d "$HOME/Downloads/mnml-aws-icon-preview-inverted" ]]; then
  SVG_DIR="$HOME/Downloads/mnml-aws-icon-preview-inverted"
else
  echo "SVG dir not found: assets/glyphs/aws/ or ~/Downloads/mnml-aws-icon-preview-inverted/" >&2
  exit 1
fi
# Claude Code + Codex live under scripts/glyphs — they aren't AWS
# icons so they don't sit alongside the aws-inverted SVGs. Loaded
# with per-glyph paths below.
AI_SVG_DIR="$(cd "$(dirname "$0")/glyphs" && pwd)"
echo "using AWS SVG source: $SVG_DIR"
echo "using AI SVG source:  $AI_SVG_DIR"

# Codepoints match src/icon_catalog.rs. U+F1B00-F1B0B = inverted
# variants (transparent bg, colored lines — the default rail glyph).
# U+F1B10-F1B1B reserved for the color variant, patched when SVGs
# for those land.
declare -a GLYPHS=(
  "$SVG_DIR/amplify.svg:F1B00:aws-amplify-inv"
  "$SVG_DIR/lambda.svg:F1B01:aws-lambda-inv"
  "$SVG_DIR/ecs.svg:F1B02:aws-ecs-inv"
  "$SVG_DIR/ecr.svg:F1B03:aws-ecr-inv"
  "$SVG_DIR/rds.svg:F1B04:aws-rds-inv"
  "$SVG_DIR/sqs.svg:F1B05:aws-sqs-inv"
  "$SVG_DIR/sns.svg:F1B06:aws-sns-inv"
  "$SVG_DIR/dynamodb.svg:F1B07:aws-dynamodb-inv"
  "$SVG_DIR/cognito.svg:F1B08:aws-cognito-inv"
  "$SVG_DIR/cloudwatch.svg:F1B09:aws-cloudwatch-inv"
  "$SVG_DIR/codebuild.svg:F1B0A:aws-codebuild-inv"
  "$SVG_DIR/eventbridge.svg:F1B0B:aws-eventbridge-inv"
  # AI panes — codepoints match src/config.rs's default
  # `[[ui.integration_icon]]` entries (Claude / Codex).
  "$AI_SVG_DIR/claude_spark.svg:F8B0:claude-spark"
  "$AI_SVG_DIR/codex.svg:F8B1:codex"
)

args=(--output "$FONT_OUT")
for spec in "${GLYPHS[@]}"; do
  # Path may contain colons on other systems, but here it always
  # starts with $SVG_DIR/ or $AI_SVG_DIR/ — split on the LAST two
  # colons: those separate CODEPOINT and NAME.
  name="${spec##*:}"
  rest="${spec%:*}"
  cp="${rest##*:}"
  path="${rest%:*}"
  if [[ ! -f "$path" ]]; then
    echo "  skipping $(basename "$path") — file not found at $path" >&2
    continue
  fi
  args+=(--glyph "${path}:${cp}:${name}:width=1.25:height=0.80:center=0.36")
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
echo "  · kitty:    symbol_map U+F1B00-U+F20FF,U+F8B0-U+F8B1 MnmlSymbols"
echo "  · wezterm:  font = font_with_fallback({..., 'MnmlSymbols'})"
echo "  · iTerm2:   Preferences → Profiles → Text → Font (Non-ASCII Font)"
echo
echo "  See docs/tools.md#branded-icons for the exact snippets."
echo "  Restart your terminal after config changes to pick up the font."
