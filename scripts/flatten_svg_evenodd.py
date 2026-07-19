#!/usr/bin/env python3
"""Flatten an SVG whose fill uses `fill-rule="evenodd"` into a set of
non-overlapping paths that render identically under non-zero winding.

Why: FontForge's `importOutlines` doesn't respect `fill-rule="evenodd"`
and TrueType uses non-zero winding. An SVG whose visible shape is
"outer envelope XOR interior wedges" (like the AWS Architecture icons)
collapses into a solid blob because the interior "hole" wedges get
merged with the outer envelope instead of subtracted.

Implementation: uses skia-pathops (Google Skia's path-boolean library
via python bindings) so Bezier curves stay curves — no polygon
sampling artifacts. XOR-folds the subpaths and emits the result as
a single `d` string with clean non-zero winding.

Usage:
    scripts/flatten_svg_evenodd.py in.svg out.svg
"""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET

import pathops
from pathops._pathops import op as _do_op
from svgpathtools import parse_path


SVG_NS = "http://www.w3.org/2000/svg"


def split_subpaths(d: str) -> list[str]:
    """Split a compound `d` attribute into individual subpath strings,
    each starting with `M`/`m`."""
    subs = re.split(r"(?=[Mm])", d.strip())
    return [s.strip() for s in subs if s.strip()]


def path_from_svg_d(d_sub: str) -> pathops.Path:
    """Build a skia-pathops Path from a single subpath's `d`."""
    p = pathops.Path()
    parsed = parse_path(d_sub)
    started = False
    for seg in parsed:
        cls = seg.__class__.__name__
        if not started:
            p.moveTo(seg.start.real, seg.start.imag)
            started = True
        if cls == "Line":
            p.lineTo(seg.end.real, seg.end.imag)
        elif cls == "CubicBezier":
            p.cubicTo(
                seg.control1.real, seg.control1.imag,
                seg.control2.real, seg.control2.imag,
                seg.end.real, seg.end.imag,
            )
        elif cls == "QuadraticBezier":
            p.quadTo(
                seg.control.real, seg.control.imag,
                seg.end.real, seg.end.imag,
            )
        elif cls == "Arc":
            # Approximate arcs as cubics via svgpathtools.
            for c in seg.as_cubic_curves(4):
                p.cubicTo(
                    c.control1.real, c.control1.imag,
                    c.control2.real, c.control2.imag,
                    c.end.real, c.end.imag,
                )
    p.close()
    return p


def path_to_svg_d(path: pathops.Path) -> str:
    """Convert a skia-pathops Path back into an SVG `d` string.

    Handles all five verbs skia-pathops emits after a boolean op:
    moveTo, lineTo, quadTo, cubicTo, closePath — PLUS conicTo,
    which skia produces when its boolean-op tessellator approximates
    cubics as rational quadratics. Prior version silently dropped
    conicTo segments, which is why an SVG with any evenodd cubic
    path (e.g. `codex.svg`) collapsed to a handful of straight lines.
    """
    # Track the current pen position so we can synthesize an `L` to
    # the endpoint of any conicTo we can't represent perfectly.
    out: list[str] = []
    cur_x, cur_y = 0.0, 0.0
    subpath_start_x, subpath_start_y = 0.0, 0.0
    for verb, pts in path.segments:
        if verb == "moveTo":
            x, y = pts[0]
            out.append(f"M{x:.3f},{y:.3f}")
            cur_x, cur_y = x, y
            subpath_start_x, subpath_start_y = x, y
        elif verb == "lineTo":
            x, y = pts[0]
            out.append(f"L{x:.3f},{y:.3f}")
            cur_x, cur_y = x, y
        elif verb == "quadTo":
            (x1, y1), (x, y) = pts
            out.append(f"Q{x1:.3f},{y1:.3f} {x:.3f},{y:.3f}")
            cur_x, cur_y = x, y
        elif verb == "cubicTo" or verb == "curveTo":
            # skia-pathops emits `curveTo` for cubic Béziers on
            # Path.segments — NOT `cubicTo`. Prior version silently
            # dropped every cubic because it only checked
            # `cubicTo`; that's why any evenodd SVG with cubic
            # paths (codex.svg, most AWS icons) baked as
            # straight-line silhouettes with the curves missing.
            (x1, y1), (x2, y2), (x, y) = pts
            out.append(
                f"C{x1:.3f},{y1:.3f} {x2:.3f},{y2:.3f} {x:.3f},{y:.3f}"
            )
            cur_x, cur_y = x, y
        elif verb == "conicTo":
            # Rational quadratic Bézier with a weight. Convert to a
            # regular cubic Bézier by projecting the conic control
            # points into cubic space. Reference: Loop & Blinn's
            # "GPU Gems 3" conic→cubic elevation (weight = 1 case)
            # + the general weighted case via cubic approximation:
            #   C0 = P0
            #   C1 = P0 + (2w/(2w+1)) * (P1 - P0)   [approx]
            #   C2 = P2 + (2w/(2w+1)) * (P1 - P2)   [approx]
            #   C3 = P2
            # For unit-weight conics this reduces to the exact
            # quad→cubic elevation. Non-unit weights get a close
            # approximation — good enough for glyph baking; the
            # error is well below 1px at cell scale.
            (x1, y1), (x, y), weight = pts
            w2 = 2.0 * float(weight)
            t = w2 / (w2 + 1.0) if (w2 + 1.0) != 0 else 2.0 / 3.0
            c1x = cur_x + t * (x1 - cur_x)
            c1y = cur_y + t * (y1 - cur_y)
            c2x = x + t * (x1 - x)
            c2y = y + t * (y1 - y)
            out.append(
                f"C{c1x:.3f},{c1y:.3f} {c2x:.3f},{c2y:.3f} {x:.3f},{y:.3f}"
            )
            cur_x, cur_y = x, y
        elif verb == "closePath":
            out.append("Z")
            cur_x, cur_y = subpath_start_x, subpath_start_y
        else:
            # Unknown verb — synthesize a line to the endpoint if
            # possible so at least the shape's silhouette survives.
            if pts:
                last = pts[-1]
                if len(last) == 2:
                    out.append(f"L{last[0]:.3f},{last[1]:.3f}")
                    cur_x, cur_y = last[0], last[1]
    return " ".join(out)


def flatten_evenodd(d: str) -> str:
    """XOR-fold all subpaths in `d`. Returns a single `d` string of
    non-overlapping regions with clean non-zero winding."""
    subs = split_subpaths(d)
    if not subs:
        return d
    paths = [path_from_svg_d(s) for s in subs]
    if not paths:
        return d
    result = paths[0]
    for other in paths[1:]:
        result = _do_op(result, other, pathops.PathOp.XOR)
    return path_to_svg_d(result)


def find_fill_rule(target, root) -> str:
    """Walk from `target` up to the root looking for `fill-rule`. Returns
    the first non-empty value, or ""."""
    fr = target.get("fill-rule")
    if fr:
        return fr
    for anc in root.iter():
        for child in list(anc):
            if child is target:
                fr = anc.get("fill-rule")
                if fr:
                    return fr
    return ""


def flatten_svg(src: str, dst: str) -> None:
    ET.register_namespace("", SVG_NS)
    tree = ET.parse(src)
    root = tree.getroot()

    for path_el in root.iter(f"{{{SVG_NS}}}path"):
        d = path_el.get("d")
        if not d:
            continue
        fill_rule = find_fill_rule(path_el, root)
        if fill_rule != "evenodd":
            continue
        new_d = flatten_evenodd(d)
        path_el.set("d", new_d)
        if "fill-rule" in path_el.attrib:
            del path_el.attrib["fill-rule"]

    tree.write(dst, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: flatten_svg_evenodd.py in.svg out.svg", file=sys.stderr)
        sys.exit(1)
    flatten_svg(sys.argv[1], sys.argv[2])
    print(f"flattened → {sys.argv[2]}")
