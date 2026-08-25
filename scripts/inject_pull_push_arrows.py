#!/usr/bin/env fontforge -script
"""Bake bold Pull / Push arrow glyphs into MnmlSymbols.ttf.

Why not use nf-cod-repo_pull (EB40) / nf-cod-repo_push (EB41)? Their
outlines pack an arrow + a "repo circle" into one cell. At terminal
font size (~12pt) the arrow head shrinks below the point of readable
detail and the whole silhouette reads as a book.

Solution: draw our own — a bold, cell-height arrow, NO circle. Same
stroke thickness as the tree-connector L (2026-08-24, injected by
`inject_tree_connectors.py`) so both feel like part of the same
family.

Codepoints:
    F1F10  arrow-down-bold  (Pull)
    F1F11  arrow-up-bold    (Push)

Both fall in the F1B00-F20FF range that a user's ghostty config
routes to MnmlSymbols via `font-codepoint-map`.

Usage
-----
    fontforge -script scripts/inject_pull_push_arrows.py \\
        --target ~/Library/Fonts/MnmlSymbols.ttf
"""

import argparse

import fontforge


# Match the tree-connector script's cell metrics so the two sets
# of custom glyphs feel like siblings.
V_TOP = 1000
V_BOTTOM = -200
GLYPH_WIDTH = 600

# Bar (arrow stem) — thicker than the tree connector's 100u stroke
# because these are stand-alone icons, not runs of contiguous rows.
BAR_STROKE = 160
BAR_CENTER = GLYPH_WIDTH // 2         # 300
BAR_LEFT = BAR_CENTER - BAR_STROKE // 2   # 220
BAR_RIGHT = BAR_CENTER + BAR_STROKE // 2  # 380

# Arrowhead — wide filled triangle. Half-width from stem center so
# the head is proportional and the entire glyph balances inside a
# monospace cell.
HEAD_HALF = 220     # head_left = 80, head_right = 520
HEAD_HEIGHT = 380   # tip extends 380u past the stem-end


def close_rect(pen, x0, y0, x1, y1):
    """Clockwise-wound filled rectangle (TrueType outer contour)."""
    pen.moveTo((x0, y1))
    pen.lineTo((x1, y1))
    pen.lineTo((x1, y0))
    pen.lineTo((x0, y0))
    pen.closePath()


def close_triangle(pen, a, b, c):
    """Clockwise-wound filled triangle. Caller supplies vertices in
    the correct order (a → b → c returning to a)."""
    pen.moveTo(a)
    pen.lineTo(b)
    pen.lineTo(c)
    pen.closePath()


def draw_pull(pen, _):
    """Arrow pointing DOWN. Stem in the upper half, arrowhead below
    it filling the lower portion of the cell.
    """
    # Stem top → bottom-of-stem.
    stem_top = V_TOP
    stem_bot = V_BOTTOM + HEAD_HEIGHT
    close_rect(pen, BAR_LEFT, stem_bot, BAR_RIGHT, stem_top)
    # Head — clockwise from top-left of the head base.
    head_left = BAR_CENTER - HEAD_HALF
    head_right = BAR_CENTER + HEAD_HALF
    head_tip = V_BOTTOM
    close_triangle(
        pen,
        (head_left, stem_bot),
        (head_right, stem_bot),
        (BAR_CENTER, head_tip),
    )


def draw_push(pen, _):
    """Arrow pointing UP. Mirror of `draw_pull` around the cell's
    horizontal midline.
    """
    stem_bot = V_BOTTOM
    stem_top = V_TOP - HEAD_HEIGHT
    close_rect(pen, BAR_LEFT, stem_bot, BAR_RIGHT, stem_top)
    head_left = BAR_CENTER - HEAD_HALF
    head_right = BAR_CENTER + HEAD_HALF
    head_tip = V_TOP
    # Clockwise: top (tip) → right-base → left-base.
    close_triangle(
        pen,
        (BAR_CENTER, head_tip),
        (head_right, stem_top),
        (head_left, stem_top),
    )


def install_glyph(font, cp, name, draw_fn):
    if cp in font:
        font[cp].clear()
    else:
        font.createChar(cp, name)
    g = font[cp]
    g.glyphname = name
    g.width = GLYPH_WIDTH
    pen = g.glyphPen()
    draw_fn(pen, None)
    pen = None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True)
    args = p.parse_args()

    tgt = fontforge.open(args.target)
    install_glyph(tgt, 0xF1F10, "arrow-pull-down", draw_pull)
    install_glyph(tgt, 0xF1F11, "arrow-push-up", draw_push)

    # Strip auto-hints so pixel-snapping doesn't asymmetrically
    # thicken one side vs the other (learned from the tree-connector
    # bake, 2026-08-24).
    for cp in (0xF1F10, 0xF1F11):
        g = tgt[cp]
        g.hhints = ()
        g.vhints = ()
        g.dhints = ()

    tgt.generate(args.target, flags=("omit-instructions", "round"))
    print(f"wrote {args.target} with F1F10 (pull ↓) + F1F11 (push ↑)")


if __name__ == "__main__":
    main()
