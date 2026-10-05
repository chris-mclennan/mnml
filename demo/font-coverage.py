#!/usr/bin/env python3
"""font-coverage.py DIR — DIR/coverage.json: each served font's cmap.

Run in the image build (demo/Dockerfile, the fonts stage) over the web
fonts exactly as the page serves them (woff2), so the self-test
(attract/selftest.py) can tell which glyphs the page can draw without a
font library in the runtime image. One entry per file: its codepoints as
[lo, hi] runs.
"""

import glob
import json
import os
import sys

from fontTools.ttLib import TTFont


def runs(cps):
    out = []
    for cp in sorted(cps):
        if out and cp == out[-1][1] + 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


def main(d):
    cov = {}
    for path in sorted(glob.glob(os.path.join(d, "*.woff2")) + glob.glob(os.path.join(d, "*.ttf"))):
        cov[os.path.basename(path)] = runs(TTFont(path).getBestCmap().keys())
    if not cov:
        sys.exit(f"font-coverage: no fonts in {d}")
    with open(os.path.join(d, "coverage.json"), "w", encoding="utf-8") as f:
        json.dump(cov, f, separators=(",", ":"))
    for name, r in cov.items():
        print(f"{name}: {sum(hi - lo + 1 for lo, hi in r)} codepoints")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
