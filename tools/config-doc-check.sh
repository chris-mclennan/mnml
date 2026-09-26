#!/usr/bin/env bash
# config-doc-check.sh — docs/CONFIG.md's "The complete file" against
# src/config/Config.zig.
#
#   doc → schema  every key the ZON block writes is a field at that path
#                 (a `Map` section takes any key; a list of structs takes
#                 `.{ … }` elements); a value written without a comment
#                 saying otherwise is the field's default; a comment that
#                 lists enum literals (`.a | .b`) lists exactly the enum's
#                 members;
#   schema → doc  every field of `Config{}` is written in the block.
#
# Values are compared as written (`4 << 20` in the struct is 4194304 in a
# comment-free doc line); a doc value that differs from the default is only
# reported when its comment does not explain it (a comment naming the
# default, "e.g.", "example", "default" …).
#
# Exit 0 when clean; 1 with the list otherwise.
# Usage: tools/config-doc-check.sh [repo-root]
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
exec python3 - "$root" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
src = (root / "src/config/Config.zig").read_text()
doc = (root / "docs/CONFIG.md").read_text()

def strip_comment(l):
    out, q = [], False
    i = 0
    while i < len(l):
        c = l[i]
        if c == '"' and (i == 0 or l[i-1] != '\\'): q = not q
        if not q and l.startswith("//", i): break
        out.append(c); i += 1
    return "".join(out)

# ── schema ──────────────────────────────────────────────────────────────
lines = [strip_comment(l) for l in src.splitlines()]
text = "\n".join(lines)

def block_at(t, start):
    """text between the `{` at/after start and its matching `}`"""
    i = t.index("{", start); d = 0
    for j in range(i, len(t)):
        if t[j] == "{": d += 1
        elif t[j] == "}":
            d -= 1
            if d == 0: return t[i+1:j]
    raise ValueError

def top_fields(body):
    """`name: Type = default,` at depth 0 of a struct body"""
    out, d, cur = [], 0, []
    for ch in body:
        if ch in "{([": d += 1
        elif ch in "})]": d -= 1
        if ch == "," and d == 0:
            out.append("".join(cur)); cur = []
        elif ch == ";" and d == 0:
            cur = []  # a decl, not a field
        else: cur.append(ch)
    out.append("".join(cur))
    res = []
    for f in out:
        f = f.strip()
        m = re.match(r"^(?:pub )?(\w+|@\"[^\"]+\")\s*:\s*(.+?)\s*=\s*(.+)$", f, re.S)
        if m and not f.startswith(("pub const", "const", "pub fn", "fn")):
            res.append((m.group(1).strip('@"'), m.group(2).strip(), " ".join(m.group(3).split())))
    return res

structs, enums, unions = {}, {}, {}
for m in re.finditer(r"(?:pub )?const (\w+) = (struct|enum|union\(enum\))(?:\(\w+\))?\s*\{", text):
    name, kind = m.group(1), m.group(2)
    body = block_at(text, m.end() - 1)
    if kind == "struct":
        # drop nested decls before reading fields
        inner = re.sub(r"(?:pub )?(?:const|fn) [^;{]*\{", "\x00", body)
        structs[name] = top_fields(re.sub(r"(pub )?const \w+ = (struct|enum|union\(enum\))[^{]*\{[^{}]*\};", "", body))
    elif kind == "enum":
        enums[name] = [x.strip() for x in re.split(r",", re.split(r"\bpub fn\b|\bfn\b", body)[0]) if re.fullmatch(r"\s*\w+\s*", x)]
    else:
        unions[name] = [x.strip().split(":")[0].strip() for x in body.split(",") if x.strip()]
# `PtyCursor.Unfocused` and friends: nested enums are also found above by name.
# Aliases of enums declared elsewhere.
for alias, (path, name) in {"FocusCue": ("src/ui/focus_cue.zig", "Cue"),
                            "TerminalGlyph": ("src/ui/bufferline.zig", "TerminalMark"),
                            "ClaudeMark": ("src/ui/bufferline.zig", "ClaudeMark")}.items():
    t = (root / path).read_text()
    m = re.search(r"pub const " + name + r" = enum \{([^}]*)\}", t)
    enums[alias] = [x.strip() for x in m.group(1).split(",") if x.strip()]
# anonymous struct fields: `crates_keyword: struct { … }` (union payloads)
root_body = text[text.index("const Config = @This();"):]
root_body = root_body[:root_body.index("pub const")]
structs["Config"] = top_fields(root_body)

schema = {}   # path -> (type, default)
union_lists = {}   # list-of-union path -> union name
union_payload = {}  # (union, tag) -> payload field names
for m in re.finditer(r"(?:pub )?const (\w+) = union\(enum\)\s*\{", text):
    body = block_at(text, m.end() - 1)
    for tag, fields in re.findall(r"(\w+): struct \{([^}]*)\}", body):
        union_payload[(m.group(1), tag)] = [f.split(":")[0].strip() for f in fields.split(",") if ":" in f]
def walk(sname, prefix):
    for name, typ, default in structs[sname]:
        path = prefix + name
        t = typ.lstrip("?")
        m = re.fullmatch(r"Map\((.+)\)", t)
        if m:
            schema[path] = ("map", default); inner = m.group(1)
            m2 = re.fullmatch(r"Map\((.+)\)", inner)
            if m2:
                schema[path + ".*"] = ("map", ""); inner = m2.group(1); path += ".*"
            if inner in structs: walk(inner, path + ".*.")
            else: schema[path + ".*"] = (inner, "")
            continue
        m = re.fullmatch(r"\[\]const (\w+)", t)
        if m and m.group(1) in structs:
            schema[path] = ("list", default); walk(m.group(1), path + "[].")
            continue
        if m and m.group(1) in unions:
            schema[path] = ("list", default); union_lists[path] = m.group(1); continue
        if t in structs:
            schema[path] = ("struct", default); walk(t, path + "."); continue
        schema[path] = (typ, default)
walk("Config", "")

def is_map_prefix(path):
    return any(k.endswith(".*") and False for k in schema)

def resolve(path):
    """doc path → schema path, with map keys folded onto `*`"""
    parts = path.split(".")
    cur = ""
    for i, p in enumerate(parts):
        if cur and schema.get(cur, ("",))[0] == "Dynamic":
            return cur  # free-form JSON-ish subtree
        if cur.endswith("[]") and cur[:-2] in union_lists:
            u = union_lists[cur[:-2]]
            if p in unions[u] and i + 1 < len(parts):
                pay = union_payload.get((u, p), [])
                return cur + p if parts[i + 1] in pay else None
        base = p.replace("[]", "")
        lst = p.endswith("[]")
        cand = (cur + "." if cur else "") + base
        if cand in schema or any(k.startswith(cand + ".") or k.startswith(cand + "[]") for k in schema):
            cur = cand
        elif (cur + ".*") in schema or any(k.startswith(cur + ".*.") for k in schema):
            cur = cur + ".*"
        elif schema.get(cur + ".extra", ("",))[0] == "Dynamic":
            return cur + ".extra"  # the decoder's catch-all for unnamed keys
        else:
            return None
        if lst: cur += "[]"
    return cur

# ── doc ─────────────────────────────────────────────────────────────────
blk = doc[doc.index("## The complete file"):]
blk = blk[blk.index("```zon") + 6:]
blk = blk[:blk.index("```")]
doc_leaves = {}   # docpath -> (value, comment, lineno)
doc_nodes = set()
stack = []
KEY = r'\.(\w+|@"[^"]+")'
def key(k): return k[2:-1] if k.startswith('@"') else k
def inline_pairs(s):
    """`.a = 1, .b = .{ .c = 2 }` at depth 0 → [(k, v)]"""
    out, d, cur = [], 0, []
    for ch in s + ",":
        if ch in "{([": d += 1
        elif ch in "})]": d -= 1
        if ch == "," and d == 0:
            item = "".join(cur).strip(); cur = []
            m = re.match(KEY + r"\s*=\s*(.+)$", item, re.S)
            if m: out.append((key(m.group(1)), m.group(2).strip()))
        else: cur.append(ch)
    return out
def add_inline(path, val, cmt, n):
    inner = val.strip()[2:].rstrip().rstrip(",").rstrip()
    inner = inner[:-1] if inner.endswith("}") else inner
    pairs = inline_pairs(inner)
    doc_nodes.add(path)
    if pairs:
        for k, v in pairs:
            if v.startswith(".{"): add_inline(path + "." + k, v, cmt, n)
            else: doc_leaves[path + "." + k] = (v, cmt, n)
    elif inner.strip().startswith(".{") or inner.strip().startswith('"'):
        doc_leaves[path] = (val.strip().rstrip(","), cmt, n)  # a list of items
    else:
        doc_leaves[path] = (val.strip().rstrip(","), cmt, n)
base_line = doc[:doc.index("## The complete file")].count("\n") + doc[doc.index("## The complete file"):].split("```zon")[0].count("\n") + 1
for n, raw in enumerate(blk.splitlines(), base_line):
    code = strip_comment(raw).rstrip()
    cmt = raw[len(code):].strip()
    s = code.strip()
    if not s or s == ".{" and not stack and n == base_line + 1: 
        if s == ".{": stack.append(None)
        continue
    m = re.match(KEY + r"\s*=\s*(.*?)\s*$", s)
    if m:
        k, v = key(m.group(1)), m.group(2)
        path = ".".join(x for x in stack if x) + ("." if any(stack) else "") + k
        path = path.replace(".[]", "[]")
        if v == ".{":
            stack.append(k); doc_nodes.add(path)
        elif v.startswith(".{") and v.count("{") == v.count("}"):
            add_inline(path, v, cmt, n)
            # `.commands = .{}, // .{ .{ .id = "x.y", .title = "…" } }` shows
            # the element's fields in its comment
            if v.rstrip(",") == ".{}" and ".{ .{" in cmt:
                for ck in re.findall(r"\.(\w+) =", cmt):
                    doc_leaves[path + "[]." + ck] = ("", cmt, n)
        elif v.startswith(".{"):
            stack.append(k); doc_nodes.add(path)
        else:
            doc_leaves[path] = (v.rstrip(","), cmt, n)
            # `.commands = .{}, // .{ .{ .id = "x.y", .title = "…" } }` shows
            # the element's fields in its comment
            if v.rstrip(",") == ".{}" and ".{ .{" in cmt:
                for ck in re.findall(r"\.(\w+) =", cmt):
                    doc_leaves[path + "[]." + ck] = ("", cmt, n)
        continue
    if s.startswith(".{") and s.count("{") == s.count("}"):
        parent = ".".join(x for x in stack if x).replace(".[]", "[]")
        for k, v in inline_pairs(s[2:].rstrip(",").rstrip()[:-1]):
            p = parent + "[]." + k
            if v.startswith(".{"): add_inline(p, v, cmt, n)
            else: doc_leaves[p] = (v, cmt, n)
        continue
    if s == ".{":
        stack.append("[]"); continue
    if s.startswith("}"):
        for _ in range(s.count("}")): 
            if stack: stack.pop()
        continue

bad = 0
def report(msg):
    global bad; bad += 1; print(msg)

documented = set()
for path, (val, cmt, n) in sorted(doc_leaves.items(), key=lambda x: x[1][2]):
    sp = resolve(path)
    if sp is None:
        report(f"doc→schema  CONFIG.md:{n}  .{path} — no such field in Config.zig"); continue
    documented.add(sp)
    typ, default = schema.get(sp, ("?", ""))
    if typ in ("map", "struct", "list"): continue
    t = typ.lstrip("?")
    # enum members named in the comment
    if t in enums or t in unions:
        members = enums.get(t) or unions.get(t)
        segs = re.sub(r"\([^()]*\)", "", cmt).split("|")
        listed = []
        if len(segs) > 1:
            first = re.findall(r"(?<![\w`])\.(\w+)\b", segs[0])
            listed = first[-1:] + [m.group(1) for m in (re.search(r"^\s*\.(\w+)", x) for x in segs[1:]) if m]
        if "|" in cmt and listed and set(listed) != set(members) and not set(listed) <= set(members):
            report(f"enum        CONFIG.md:{n}  .{path}: comment lists {sorted(set(listed))}, {t} has {members}")
        elif "|" in cmt and listed and set(listed) < set(members):
            missing = [x for x in members if x not in listed]
            report(f"enum        CONFIG.md:{n}  .{path}: comment omits {missing} of {t}")
        v = val.strip()
        if v.startswith(".") and not v.startswith(".{") and v[1:] not in members:
            report(f"enum value  CONFIG.md:{n}  .{path} = {v}: not a member of {t} {members}")
    # default
    if "*" in sp or "[]" in sp or sp.endswith(".extra"): continue
    norm = lambda x: x.replace(".empty_object", ".{}").replace("&.{}", ".{}").replace("_", "").replace(" ", "")
    dv = default
    try: dv = str(eval(dv.replace("_", ""), {})) if re.fullmatch(r"[\d_ <>*]+", dv) else dv
    except Exception: pass
    if dv.startswith("&default_"):
        arr = re.search(r"const " + dv[1:] + r" = \[_\][^{]*\{([^}]*)\}", text)
        if arr: dv = ".{ " + arr.group(1).strip() + " }"
    if norm(val) != norm(dv) and norm(val) != norm(default):
        if not re.search(r"(?i)default|e\.g\.|example|for example|instead|set to|off by|shipped|here", cmt):
            report(f"default     CONFIG.md:{n}  .{path} = {val}   (Config.zig default: {default})")
        else:
            print(f"info        CONFIG.md:{n}  .{path} = {val}   (default {default}; comment: {cmt[:70]})")

for path, (typ, default) in schema.items():
    if typ in ("struct",): continue
    if "*" in path and typ != "map": continue
    if path in documented: continue
    # a list / map documented as a node (`.x = .{ … }`)
    dp = path.replace("[]", "")
    if typ in ("map", "list") and (any(d == path or d.startswith(path + ".") or d.startswith(path + "[]") for d in documented) or path in doc_nodes or any(resolve(x) == path for x in doc_nodes)):
        continue
    if "[]" in path:
        parent = path.split("[]")[0]
        if not any(d.startswith(parent + "[]") for d in documented):
            report(f"schema→doc  .{path} ({typ}) — its list is never shown with an element")
        else:
            report(f"schema→doc  .{path} ({typ} = {default}) — not in any element of the example")
        continue
    report(f"schema→doc  .{path} ({typ} = {default}) — not documented")
# Keys the code reads out of `.ai.extra` (no typed field) are written in
# the block too. `.ai.claude.accounts` is the 0.2.x migration's leftover
# and documented under "Coming from 0.2.x".
extra_keys = set()
for f in (root / "src").rglob("*.zig"):
    t = f.read_text()
    if "cfg.ai.extra" not in t and "extraString(" not in t: continue
    t = t.split("\ntest \"")[0]
    extra_keys |= set(re.findall(r'ai\.extra\.get\("(\w+)"\)|extra(?:String|Bool)\(app, "(\w+)"\)', t) and
                      [a or b for a, b in re.findall(r'ai\.extra\.get\("(\w+)"\)|extra(?:String|Bool)\(app, "(\w+)"\)', t)])
for k in sorted(extra_keys - {"claude"}):
    if "ai." + k not in doc_leaves:
        report(f"schema→doc  .ai.{k} (read from .ai.extra) — not documented")
# Prose references elsewhere on the page: `.ui.tree_width`, `ui.dock.pins`, …
tops = {n for n, _, _ in structs["Config"]}
for n, line in enumerate(doc.splitlines(), 1):
    if line.startswith("```"): continue
    for ref in re.findall(r"`\.((?:%s)(?:\.[a-z_0-9]+)+)(?=[`\s=\[])" % "|".join(sorted(tops)), line):
        if resolve(ref) is None:
            report(f"prose       CONFIG.md:{n}  `{ref}` — no such field in Config.zig")
print(f"checked: {len(doc_leaves)} doc keys, {len(schema)} schema paths; {bad} problems")
sys.exit(1 if bad else 0)
PY
