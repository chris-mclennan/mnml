#!/usr/bin/env python3
"""walk-report.py OUT COLS ROWS — per-snapshot diff of the rust/zig pairs in OUT.
Writes OUT/diff.md and OUT/summary.json. Counts as tools/ui-diff.sh does:
`rows` = rows whose columns 4+ differ (the rail is accepted); `text` =
those still differing once column 4 (the tree cursor cell), the last
column, wide-glyph spacer cells and trailing blanks are dropped."""
import glob
import itertools
import json
import os
import sys
import unicodedata

out, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])


def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def norm(r):
    o = []
    wide = False
    for ch in r[5:cols - 1]:
        if wide:
            o.append(" ")
            wide = False
            continue
        o.append(ch)
        wide = unicodedata.east_asian_width(ch) in ("W", "F")
    return "".join(o).rstrip()


def status_summary(p):
    try:
        d = json.loads(read(p) or "{}")
    except ValueError:
        return "?"
    keys = ["focus", "mode", "cursor", "active_pane", "panes", "layout", "overlay", "activity", "section"]
    parts = []
    for k in keys:
        if k in d:
            v = d[k]
            if isinstance(v, list):
                v = "[%d]" % len(v) + ("" if not v else " " + json.dumps(v[0])[:60])
            elif isinstance(v, dict):
                v = json.dumps(v)[:80]
            parts.append("%s=%s" % (k, v))
    return " ".join(parts) or json.dumps(d)[:120]


md = ["# %s (%dx%d)\n" % (os.path.basename(out), cols, rows)]
md.append("| # | snapshot | rows | text | rail | status |")
md.append("|---|----------|-----:|-----:|-----:|-------:|")
summary = []
details = []
for rp in sorted(glob.glob(os.path.join(out, "*.rust.txt"))):
    name = os.path.basename(rp)[:-9]
    zp = os.path.join(out, name + ".zig.txt")
    a = read(rp).split("\n")
    b = read(zp).split("\n")
    raw = rail = text = 0
    trs = []
    # the Zig config toast (a real finding, recorded once) sits on every Zig
    # screen of this workspace; blank its three rows so counts measure the rest
    for i, y in enumerate(b):
        if "config: /private/tmp/walk/" in y and 0 < i < len(b) - 1:
            for j in (i - 1, i, i + 1):
                if "┌" in b[j] or "└" in b[j] or j == i:
                    b[j] = b[j][:40].rstrip() if len(b[j]) > 40 and b[j][:40].strip() else ""
    status_diff = 0
    for i, (x, y) in enumerate(itertools.zip_longest(a, b, fillvalue="")):
        if x == y:
            continue
        if i == rows - 1:
            status_diff = 1
            continue
        raw += 1
        if x[4:] == y[4:]:
            rail += 1
            continue
        if norm(x) != norm(y):
            text += 1
            trs.append(i)
    body = raw - rail
    md.append("| %s | `%s` | %d | %d | %d | %d |" % (name.split("-")[0], name, body, text, rail, status_diff))
    sr = status_summary(os.path.join(out, name + ".rust.status.json"))
    sz = status_summary(os.path.join(out, name + ".zig.status.json"))
    summary.append({"snap": name, "rows": body, "text": text, "rail": rail, "status": status_diff, "text_rows": trs, "status_rust": sr, "status_zig": sz,
                    "missing_zig": not os.path.exists(zp)})
    d = ["## %s — %d rows beyond the rail, %d text\n" % (name, body, text)]
    d.append("status rust: `%s`" % sr)
    d.append("status zig:  `%s`\n" % sz)
    if trs:
        d.append("```")
        for i in trs[:40]:
            d.append("%2d R|%s" % (i, (a[i] if i < len(a) else "").rstrip()))
            d.append("%2d Z|%s" % (i, (b[i] if i < len(b) else "").rstrip()))
        if len(trs) > 40:
            d.append("… %d more rows" % (len(trs) - 40))
        d.append("```\n")
    details.append("\n".join(d))
md.append("")
md.extend(details)
open(os.path.join(out, "diff.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=0)
for s in summary:
    print("  %-40s rows %3d  text %3d  rail %2d%s" % (s["snap"], s["rows"], s["text"], s["rail"], "  (NO ZIG)" if s["missing_zig"] else ""))
