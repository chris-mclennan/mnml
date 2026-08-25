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


# Circle (the "repo target" mark) — sits below the arrow. Approximate
# a ring using an octagon; TrueType curves would work but octagons
# rasterise reliably at all terminal sizes without curve dropout.
CIRCLE_CY = V_BOTTOM + 80    # circle center — sit near bottom of cell
CIRCLE_R_OUT = 130           # outer radius
CIRCLE_R_IN = 60             # inner radius (ring thickness ≈ 70)
GAP_ABOVE_CIRCLE = 40        # empty space between arrow tip / tail base
                             # and the circle above/below it


def close_ring(pen, cx, cy, r_out, r_in, n=16):
    """Filled ring approximated with two n-gons (outer + inner
    counter-wound). TrueType interprets counter-clockwise-wound holes
    as removed area, giving us the ring silhouette.
    """
    import math
    # Outer contour — clockwise.
    pts_out = [
        (cx + r_out * math.cos(math.pi * 2 * i / n - math.pi / 2),
         cy + r_out * math.sin(math.pi * 2 * i / n - math.pi / 2))
        for i in range(n)
    ]
    # Reverse for clockwise winding in y-up coords.
    pts_out = list(reversed(pts_out))
    pen.moveTo(pts_out[0])
    for p in pts_out[1:]:
        pen.lineTo(p)
    pen.closePath()
    # Inner hole — counter-clockwise (opposite winding).
    pts_in = [
        (cx + r_in * math.cos(math.pi * 2 * i / n - math.pi / 2),
         cy + r_in * math.sin(math.pi * 2 * i / n - math.pi / 2))
        for i in range(n)
    ]
    pen.moveTo(pts_in[0])
    for p in pts_in[1:]:
        pen.lineTo(p)
    pen.closePath()


def draw_pull(pen, _):
    """Repo Pull — bold arrow pointing DOWN in the upper cell, with a
    small ring below it (the "into repo" target). Matches the
    nf-cod-repo_pull reference shape but sized for terminal
    legibility: thicker stem, wider arrowhead, ring instead of a
    filled dot so it doesn't merge with the head.
    """
    # Arrow head tip lands just above the ring.
    head_tip = CIRCLE_CY + CIRCLE_R_OUT + GAP_ABOVE_CIRCLE
    stem_bot = head_tip + HEAD_HEIGHT
    stem_top = V_TOP
    close_rect(pen, BAR_LEFT, stem_bot, BAR_RIGHT, stem_top)
    head_left = BAR_CENTER - HEAD_HALF
    head_right = BAR_CENTER + HEAD_HALF
    close_triangle(
        pen,
        (head_left, stem_bot),
        (head_right, stem_bot),
        (BAR_CENTER, head_tip),
    )
    # Ring at the bottom.
    close_ring(pen, BAR_CENTER, CIRCLE_CY, CIRCLE_R_OUT, CIRCLE_R_IN)


def draw_push(pen, _):
    """Repo Push — mirror of Pull: ring at the bottom (source), bold
    arrow above pointing UP away from it. Matches the
    nf-cod-repo_push reference: arrow leaves the repo mark heading
    up-and-away.
    """
    # Arrow tail base sits just above the ring.
    tail_base = CIRCLE_CY + CIRCLE_R_OUT + GAP_ABOVE_CIRCLE
    stem_bot = tail_base
    stem_top = V_TOP - HEAD_HEIGHT
    close_rect(pen, BAR_LEFT, stem_bot, BAR_RIGHT, stem_top)
    head_left = BAR_CENTER - HEAD_HALF
    head_right = BAR_CENTER + HEAD_HALF
    head_tip = V_TOP
    close_triangle(
        pen,
        (BAR_CENTER, head_tip),
        (head_right, stem_top),
        (head_left, stem_top),
    )
    close_ring(pen, BAR_CENTER, CIRCLE_CY, CIRCLE_R_OUT, CIRCLE_R_IN)


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
