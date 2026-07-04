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
    """Convert a skia-pathops Path back into an SVG `d` string."""
    out: list[str] = []
    for verb, pts in path.segments:
        if verb == "moveTo":
            out.append(f"M{pts[0][0]:.3f},{pts[0][1]:.3f}")
        elif verb == "lineTo":
            out.append(f"L{pts[0][0]:.3f},{pts[0][1]:.3f}")
        elif verb == "quadTo":
            out.append(
                f"Q{pts[0][0]:.3f},{pts[0][1]:.3f} "
                f"{pts[1][0]:.3f},{pts[1][1]:.3f}"
            )
        elif verb == "cubicTo":
            out.append(
                f"C{pts[0][0]:.3f},{pts[0][1]:.3f} "
                f"{pts[1][0]:.3f},{pts[1][1]:.3f} "
                f"{pts[2][0]:.3f},{pts[2][1]:.3f}"
            )
        elif verb == "closePath":
            out.append("Z")
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
