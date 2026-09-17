#!/usr/bin/env python3
"""Compare the reference tracker's screens with the port's, by content.

Both sides are text dumps of the same scripted session against the
offline Jira (tools/jira-diff.sh cuts them): the reference's as one
file per `snap` in a directory, the port's as one stream with `=== NAME`
separators (`mnml-jira --dump`). The two apps paint different chrome on
purpose — the port uses mnml's caps header, tab strip, mode chips and
row marker — so the comparison is not cell for cell. Every row is
reduced to its content:

  * box-drawing, markers and chevrons go (│ ┌ ▼ ▶ ▸ ▌ ⋯ ★ ✓ ⓧ ▾ …);
  * a reference chip `[ Assignee: Me ▾ ]` and a port chip
    ` assignee: Me ` both become `assignee: me`; `[ 🔍 Search ]` and
    `󰍉 / filter` both become `search`;
  * runs of blanks collapse to one; case is folded; a row clipped with
    an ellipsis on either side matches when one is a prefix of the other;
  * rows that are pure chrome on one side (the port's caps header and
    tab strip, the reference's hint strip) are dropped.

For every screen it prints the rows only the reference has and the rows
only the port has, and ends with a table of counts — the numbers the
report quotes. Exit 0 always: the diff is the deliverable, not a gate.

    tools/jira-diff-compare.py --rust DIR --zig FILE [--screens a,b,c]
"""

import argparse
import difflib
import os
import re
import sys
import unicodedata

STRIP = "│┌┐└┘─▼▶▸▌⋯★✓✗ⓧ▾▏┤├┬┴┼"
KEY_RE = re.compile(r"\b[A-Z][A-Z0-9]+-\d+\b")
CHIP_RE = re.compile(r"\[\s*([^\]]+?)\s*\]")
COUNT_RE = re.compile(r"^(.*?)\s*\((\d+)\)$")


def is_private_use(ch):
    o = ord(ch)
    return 0xE000 <= o <= 0xF8FF or 0xF0000 <= o <= 0x10FFFF


def normalise_chip(text):
    t = text.strip().rstrip("▾").strip()
    t = t.replace("🔍", "").strip()
    if t.lower() in ("search", "/ filter") or t.lower().startswith("/ filter"):
        return "search"
    return t


def normalise_row(row):
    # Chips first, while the brackets are still there.
    def chip(m):
        return " «" + normalise_chip(m.group(1)) + "» "
    row = CHIP_RE.sub(chip, row)
    out = []
    for ch in row:
        if ch in STRIP or is_private_use(ch):
            out.append(" ")
        elif unicodedata.category(ch) == "Cf":
            continue
        else:
            out.append(ch)
    row = "".join(out)
    row = re.sub(r"[ \t]+", " ", row).strip()
    row = row.replace("…", "").rstrip()
    return row.lower()


HINT_WORDS = ("esc cancel", "esc close", "enter commit", "· / filter ·", "· q", "type to filter", "type to edit", "j/k scroll", "enter run", "t transition ·", "· a assignee ·")


def is_chrome(row, side):
    r = row.strip()
    if not r:
        return True
    # A hint strip on either side: chords joined by " · ".
    if any(w in r for w in HINT_WORDS) and (" · " in r or r.startswith("1-9")):
        return True
    if side == "zig":
        if r.startswith("jira work") or r.startswith("jira fix versions") or r.startswith("jira boards"):
            return True
        if re.match(r"^\d+ (assigned|recently done|current release|sprint|backlog)", r):
            return True
    return False


def canonical_toolbar(row):
    """The reference's `[ Basic ] [ JQL ] [ 🔍 Search ] …` and the port's
    ` basic  jql  / filter  space: — …` become one shape: the chip names,
    a value only where one is set."""
    r = row.replace("«", "").replace("»", "")
    r = re.sub(r"⟳ refresh", "", r)
    r = re.sub(r"· \d+ tickets", "", r)
    r = r.replace("/ filter", "search")
    r = re.sub(r"\b(space|type|label|epic|version|board|sprint): —", r"\1", r)
    r = re.sub(r"\b(space|type|label|epic|version): all\b", r"\1", r)
    return re.sub(r"[ \t]+", " ", r).strip()


def content_rows(text, side):
    rows = []
    for raw in text.splitlines():
        n = normalise_row(raw)
        if is_chrome(n, side):
            continue
        if "basic" in n and "jql" in n or "search" in n and ("board" in n or "sprint" in n):
            n = canonical_toolbar(n)
        # A row with nothing but a lone chip fragment or a single glyph is noise.
        if len(n) < 2:
            continue
        rows.append(n)
    return rows


def matches(a, b):
    if a == b:
        return True
    if a.startswith(b) or b.startswith(a):
        return True
    # A reference row that carries a chip's value the port renders
    # elsewhere on the row: fall back to a high similarity.
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.9


def diff_rows(rust, zig):
    rust_only = []
    zig_left = list(zig)
    for r in rust:
        hit = None
        for i, z in enumerate(zig_left):
            if matches(r, z):
                hit = i
                break
        if hit is None:
            rust_only.append(r)
        else:
            zig_left.pop(hit)
    return rust_only, zig_left


def read_zig(path):
    screens = {}
    name = None
    buf = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("=== "):
                if name is not None:
                    screens[name] = "\n".join(buf)
                name = line[4:].strip()
                buf = []
            else:
                buf.append(line)
    if name is not None:
        screens[name] = "\n".join(buf)
    return screens


def read_rust(directory):
    screens = {}
    for fn in sorted(os.listdir(directory)):
        if not fn.endswith(".txt") or fn.startswith("_"):
            continue
        with open(os.path.join(directory, fn), encoding="utf-8", errors="replace") as f:
            screens[fn[:-4]] = f.read()
    return screens


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rust", required=True, help="the reference's snap directory")
    ap.add_argument("--zig", required=True, help="the port's --dump output")
    ap.add_argument("--screens", default="", help="comma-separated subset")
    ap.add_argument("--quiet", action="store_true", help="the table only")
    args = ap.parse_args()
    rust = read_rust(args.rust)
    zig = read_zig(args.zig)
    names = [n for n in rust if n in zig]
    if args.screens:
        names = [n for n in names if n in args.screens.split(",")]
    missing = sorted((set(rust) | set(zig)) - set(names))
    table = []
    for name in names:
        r_rows = content_rows(rust[name], "rust")
        z_rows = content_rows(zig[name], "zig")
        rust_only, zig_only = diff_rows(r_rows, z_rows)
        table.append((name, len(r_rows), len(z_rows), len(rust_only), len(zig_only)))
        if not args.quiet and (rust_only or zig_only):
            print(f"== {name}: {len(rust_only)} row(s) only in the reference, {len(zig_only)} only in the port")
            for r in rust_only:
                print(f"  ref  | {r}")
            for z in zig_only:
                print(f"  port | {z}")
    print()
    print(f"{'screen':<24} {'ref rows':>8} {'port rows':>9} {'ref only':>8} {'port only':>9}")
    for name, nr, nz, ro, zo in table:
        print(f"{name:<24} {nr:>8} {nz:>9} {ro:>8} {zo:>9}")
    if missing:
        print()
        print("only on one side (not compared): " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
