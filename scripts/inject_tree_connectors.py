#!/usr/bin/env fontforge -script
"""Draw tree-connector glyphs directly into MnmlSymbols.ttf.

Rationale: rasterising SVGs at cell-edge coords leaves gaps between
rows. Copying JetBrainsMono's U+2502 / U+2514 renders their L visibly
thicker than the vertical, because font copy+paste drops hinting.

Construct both glyphs from a single 100u-wide rectangle primitive so
stroke thickness is guaranteed equal. Y-span matches JetBrainsMono's
box-drawing metrics (-400..1120) so the vertical links cell-to-cell
in ghostty.

Usage
-----
    fontforge -script scripts/inject_tree_connectors.py \\
        --target ~/Library/Fonts/MnmlSymbols.ttf \\
        --shift 100

`--shift` is in font design units (JetBrainsMono em = 1000; 100 ≈ 10%
of em ≈ 0.6 cell columns). Positive = right, from the U+2502 baseline
x=250..350 → x=350..450 with --shift 100.
"""

import argparse

import fontforge


# JetBrainsMono box-drawing metrics (from U+2502 / U+2514 outlines):
#   stroke thickness: 100 units
#   vertical span (│):  y = -400..1120
#   corner arms (└):    upper arm y = 320..1120 (drops to elbow)
#                       horizontal y = 320..420 (100u thick)
#   default x band:     x = 250..350 (before shift)
STROKE = 100
V_TOP = 1120
V_BOTTOM_FULL = -400   # extends into descender so │ links cell-to-cell
ELBOW_Y_TOP = 620      # top of horizontal arm — raised so the L
                       # turns near the row's vertical midpoint
                       # (icon center), not way down at descender.
ELBOW_Y_BOT = 520      # bottom of horizontal arm (unused for the
                       # single-contour L but kept for reference)
HORIZ_RIGHT = 620      # matches JetBrainsMono's U+2514 horizontal span
NATIVE_X_LEFT = 250
NATIVE_X_RIGHT = 350
GLYPH_WIDTH = 600      # advance width (mono cell)


def draw_rect(pen, x0, y0, x1, y1):
    """Emit a closed axis-aligned rectangle via a glyph pen. Wound
    CLOCKWISE (top-left → top-right → bottom-right → bottom-left) in
    the font's y-up coord system, which TrueType treats as a filled
    outer contour. Counter-clockwise would be a HOLE and rasterisers
    render those differently — that's what made the L's arm read
    thicker than the plain vertical bar (2026-08-24)."""
    pen.moveTo((x0, y1))
    pen.lineTo((x1, y1))
    pen.lineTo((x1, y0))
    pen.lineTo((x0, y0))
    pen.closePath()


def draw_vertical(pen, x_left):
    """Full-height vertical stroke — fills the em + descender so
    consecutive rows link with no gap."""
    draw_rect(pen, x_left, V_BOTTOM_FULL, x_left + STROKE, V_TOP)


def draw_corner(pen, x_left):
    """L-shape as one closed contour. CoreText's autohinter was
    snapping the arm's stem wider than the plain `│`. Narrow the
    vertical arm to `arm_stroke` and CENTER it on the `│`'s axis
    (x_left + STROKE/2), so both stems share the same column.
    Horizontal arm keeps 100u thickness. (2026-08-24)"""
    arm_stroke = 70
    stem_center = x_left + STROKE // 2
    arm_left = stem_center - arm_stroke // 2
    arm_right = stem_center + arm_stroke // 2
    # Match horizontal thickness to the arm so the L reads uniform.
    horiz_thick = arm_stroke
    horiz_bot = ELBOW_Y_TOP - horiz_thick
    horiz_right = HORIZ_RIGHT + (x_left - NATIVE_X_LEFT)
    # Trace clockwise from top-left of the vertical arm.
    pen.moveTo((arm_left, V_TOP))
    pen.lineTo((arm_right, V_TOP))
    pen.lineTo((arm_right, ELBOW_Y_TOP))
    pen.lineTo((horiz_right, ELBOW_Y_TOP))
    pen.lineTo((horiz_right, horiz_bot))
    pen.lineTo((arm_left, horiz_bot))
    pen.closePath()


def install_glyph(font, cp, name, draw_fn, x_left):
    if cp in font:
        font[cp].clear()
    else:
        font.createChar(cp, name)
    g = font[cp]
    g.glyphname = name
    g.width = GLYPH_WIDTH
    pen = g.glyphPen()
    draw_fn(pen, x_left)
    pen = None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True)
    p.add_argument("--shift", type=int, default=100)
    args = p.parse_args()

    tgt = fontforge.open(args.target)
    x_left = NATIVE_X_LEFT + args.shift

    install_glyph(tgt, 0xF1F04, "tree-line-vertical", draw_vertical, x_left)
    install_glyph(tgt, 0xF1F05, "tree-line-corner", draw_corner, x_left)

    # Clear any auto-generated hints on our two glyphs so fontforge
    # can't pixel-snap the L's arm to a different width than the
    # plain vertical bar (2026-08-24 — user reported L vertical arm
    # rendered ~1.5× the `│` above it despite identical geometry).
    for cp in (0xF1F04, 0xF1F05):
        g = tgt[cp]
        g.hhints = ()
        g.vhints = ()
        g.dhints = ()

    # `omit-instructions` drops TrueType bytecode hints so ghostty
    # rasterises straight from the outline. `round` snaps outlines to
    # integer coords → both stems fall on the same pixel boundary.
    tgt.generate(args.target, flags=("omit-instructions", "round"))
    print(f"wrote {args.target} with F1F04+F1F05 (stroke={STROKE}u, shift +{args.shift}u, no-hints)")


if __name__ == "__main__":
    main()
