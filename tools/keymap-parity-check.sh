#!/usr/bin/env bash
# keymap-parity-check.sh — docs/KEYMAP_PARITY.md against src/commands/specs.zig.
#
# Both directions, per profile (vim / standard):
#   doc → specs  every chord the doc says a profile binds to a command id is
#                bound to that id in specs.zig (`.vim` / `.standard` / `.both`,
#                plus `.vim_handler` for the vim profile);
#   specs → doc  every chord specs.zig binds in a profile is written down in the
#                doc for that profile — in (a) / (b) against an oracle, in the
#                "Applied" table, or in section (c)'s mnml-only list.
# Chords are compared in `Chord.format`'s canonical spelling: modifiers in
# ctrl / alt / shift / super order, an upper-case letter as shift+letter,
# shift+tab as backtab, named punctuation (minus, comma, …) as its character.
# Handler-only keys (vim's `dd`, the standard handler's Ctrl+A) have no spec
# row and the doc names them without an id, so they are not compared.
#
# Exit 0 when both directions are clean; 1 with the list otherwise.
# Usage: tools/keymap-parity-check.sh [repo-root]
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
exec python3 - "$root" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
specs = (root / "src/commands/specs.zig").read_text()
doc = (root / "docs/KEYMAP_PARITY.md").read_text()

PUNCT = {"minus": "-", "dash": "-", "underscore": "_", "plus": "+", "equal": "=",
         "equals": "=", "comma": ",", "period": ".", "dot": ".", "slash": "/",
         "backslash": "\\", "semicolon": ";", "quote": "'", "grave": "`",
         "backtick": "`", "bracketleft": "[", "bracketright": "]"}
NAMED = {"return": "enter", "cr": "enter", "escape": "esc", "bs": "backspace",
         "del": "delete", "ins": "insert", "pgup": "pageup", "pgdn": "pagedown",
         "pgdown": "pagedown", "leader": "space"}
MODS = ["ctrl", "alt", "shift", "super"]
MODALIAS = {"ctrl": "ctrl", "c": "ctrl", "shift": "shift", "s": "shift", "alt": "alt",
            "a": "alt", "meta": "alt", "super": "super", "cmd": "super", "win": "super"}

def canon_key(tok):
    mods = set()
    rest = tok
    while True:
        m = re.match(r"(?i)(ctrl|shift|alt|meta|super|cmd|win)\+(.+)$", rest) or \
            re.match(r"(?i)([csa])-(.+)$", rest)
        if not m: break
        mods.add(MODALIAS[m.group(1).lower()]); rest = m.group(2)
    low = rest.lower()
    if low in PUNCT: rest = PUNCT[low]
    elif low in NAMED: rest = NAMED[low]
    elif len(rest) > 1: rest = low
    if len(rest) == 1 and "A" <= rest <= "Z":
        mods.add("shift"); rest = rest.lower()
    if rest == "tab" and "shift" in mods: mods.discard("shift"); rest = "backtab"
    if rest == "backtab": mods.discard("shift")
    return "+".join([m for m in MODS if m in mods] + [rest])

def canon(chord):
    return " ".join(canon_key(t) for t in chord.split())

# ── specs side ──────────────────────────────────────────────────────────
spec = {"vim": set(), "standard": set()}
optional = {"vim": set(), "standard": set()}  # bound off macOS only
ids = set()
STR = r'"((?:[^"\\]|\\.)+)"'
def strs(body):
    return [canon(x.replace("\\\\", "\\")) for x in re.findall(STR, body)]
# `const nav_back_keys: … = if (macos) &.{…} else &.{…};` — the macOS list is
# required; the other OSes' extra chords may be written down as well.
consts = {}
for name, mac, other in re.findall(r"const (\w+_keys)\b[^=]*= if \([^)]*\.macos\) &\.\{([^}]*)\} else &\.\{([^}]*)\};", specs):
    consts[name] = (strs(mac), [c for c in strs(other) if c not in strs(mac)])
for line in specs.splitlines():
    m = re.search(r'\.id = "([^"]+)"', line)
    if not m: continue
    cid = m.group(1); ids.add(cid)
    k = re.search(r"\.keys = \.\{(.*)\}\s*\}", line)
    if not k: continue
    for field, body, const in re.findall(r"\.(vim_handler|vim|standard|both) = (?:&\.\{([^}]*)\}|(\w+_keys))", k.group(1)):
        req, opt = consts[const] if const else (strs(body), [])
        for bucket, chords in ((spec, req), (optional, opt)):
            for c in chords:
                if field in ("vim", "both", "vim_handler"): bucket["vim"].add((c, cid))
                if field in ("standard", "both"): bucket["standard"].add((c, cid))

# ── doc side ────────────────────────────────────────────────────────────
claims = {"vim": set(), "standard": set()}          # (chord, id)
chord_only = {"vim": set(), "standard": set()}      # chord named without an id
ID = r"[a-z_]+\.[a-z0-9_.]+|palette"
def ticks(cell):
    """Code spans, `x` and `` x` `` alike."""
    return [a or b for a, b in re.findall(r"``\s?(.+?)\s?``|`([^`]+)`", cell)]
section = None
lines = doc.splitlines()
for i, line in enumerate(lines):
    if line.startswith("## Applied"): section = "applied"
    elif line.startswith("## (a)"): section = "a"
    elif line.startswith("## (b)"): section = "b"
    elif line.startswith("## (c)"): section = "c"
    elif line.startswith("## (d)"): section = "c"
    elif line.startswith("## "): section = None
    if "<summary>vim profile" in line: cprof = "vim"
    if "<summary>standard profile" in line: cprof = "standard"
    if line.startswith("*vim profile"): cprof = "vim"
    if line.startswith("*standard profile"): cprof = "standard"
    if not line.startswith("|") or line.startswith("|---"): continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if section == "applied" and len(cells) >= 3 and cells[0] in ("vim", "standard"):
        prof = cells[0]
        chs = ticks(cells[1])
        cmds = re.findall(ID, cells[2])
        if len(chs) == 1 and len(cmds) == 1 and "…" not in cells[1]:
            claims[prof].add((canon(chs[0]), cmds[0]))
        elif len(chs) == len(cmds) and "…" not in cells[1]:
            for ch, cm in zip(chs, cmds): claims[prof].add((canon(ch), cm))
        elif "…" not in cells[1]:
            for ch in chs: chord_only[prof].add(canon(ch))
    elif section == "c" and len(cells) == 2 and cells[0].startswith("`"):
        ch = ticks(cells[0])[0]; cm = cells[1].strip("`")
        claims[cprof].add((canon(ch), cm))
    elif section == "b" and len(cells) == 5 and cells[2] in ("same", "different"):
        chs = ticks(cells[0])
        m = re.fullmatch(r"`(" + ID + r")`", cells[3])
        if len(chs) == 1 and m: claims["standard"].add((canon(chs[0]), m.group(1)))
    elif section == "a" and len(cells) == 5 and cells[2] in ("same", "different"):
        m = re.match(r"(?:``\s?(.+?)\s?``|`([^`]+)`) (" + ID + r")\b", cells[3])
        if m:
            claims["vim"].add((canon(m.group(1) or m.group(2)), m.group(3)))
        else:
            for ch in ticks(cells[3]): chord_only["vim"].add(canon(ch))

bad = 0
for prof in ("vim", "standard"):
    sp = spec[prof]; cl = claims[prof]
    spec_chords = {c for c, _ in sp}
    wrong = sorted(x for x in cl if x not in sp and x not in optional[prof])
    for ch, cm in wrong:
        now = sorted(i for c, i in sp if c == ch)
        why = "unknown id" if cm not in ids else ("bound to " + ", ".join(now) if now else "chord unbound")
        print(f"doc→specs  {prof:8} `{ch}` → {cm}   ({why})"); bad += 1
    for ch in sorted(chord_only[prof] - spec_chords):
        if "<" not in ch:
            print(f"note       {prof:8} `{ch}` named without an id and bound to nothing in specs (a handler key?)")
    documented = cl | {(c, i) for c, i in sp if c in chord_only[prof]}
    for ch, cm in sorted(sp - documented):
        print(f"specs→doc  {prof:8} `{ch}` → {cm}   (not in the doc)"); bad += 1
    c_rows = sum(1 for _ in cl)
print(f"checked: vim {len(claims['vim'])} doc claims / {len(spec['vim'])} spec bindings; "
      f"standard {len(claims['standard'])} / {len(spec['standard'])}; {bad} mismatches")
sys.exit(1 if bad else 0)
PY
