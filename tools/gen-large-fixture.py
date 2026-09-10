#!/usr/bin/env python3
"""Write the large navigation fixture: ~6000 lines of plausible Rust.

Deterministic (a fixed seed, no clock, no environment), so every machine
writes the same bytes and `tools/compare.sh` can regenerate it into each
private workspace copy instead of committing a quarter-megabyte file. The
shape is what a navigation harness wants to trip over: long lines, a few
over 300 cells, tab-indented blocks among the space-indented ones, CJK
and combining marks and emoji in strings and comments, doc comments,
generics, closures, and the word `needle` scattered through it for a
`/needle` search to land on.

    tools/gen-large-fixture.py [OUT] [--lines N]

OUT defaults to docs/ui-spec/fixtures/large.rs. Prints the line count and
the byte size.
"""
import os
import random
import sys

SEED = 0x6D6E6D6C  # "mnml"

TYPES = ["u8", "u16", "u32", "u64", "usize", "i32", "i64", "f32", "f64", "bool", "char",
         "String", "&str", "Vec<u8>", "Vec<String>", "Option<usize>", "Result<(), Error>",
         "HashMap<String, Vec<u32>>", "Box<dyn Fn(&str) -> bool>", "Rc<RefCell<Node>>",
         "&'a [T]", "impl Iterator<Item = (usize, &'a str)>", "Arc<Mutex<State>>"]
NAMES = ["cursor", "offset", "line", "col", "byte", "width", "height", "buffer", "editor",
         "layout", "pane", "rect", "glyph", "cell", "span", "style", "token", "scope",
         "needle", "haystack", "anchor", "selection", "fold", "gutter", "viewport", "frame",
         "tick", "event", "handler", "registry", "command", "palette", "theme", "config"]
VERBS = ["draw", "paint", "layout", "measure", "clamp", "scroll", "advance", "retreat",
         "resolve", "apply", "collect", "tokenize", "highlight", "wrap", "split", "merge",
         "render", "dispatch", "poll", "drain", "flush", "commit", "restore", "snapshot"]
STRINGS = [
    "hello, world", "needle in a haystack", "ünïcödé — dashes and quotes “like these”",
    "日本語のテキスト", "한국어 텍스트", "中文文本 wide cells", "emoji 🦀🔥✨ and more",
    "combining: é ä ô", "tabs\tinside\tstrings", "zero-width​joiner",
    "arabic نص عربي mixed with latin", "\\n\\t\\\\ escapes", "box drawing ─│┌┐└┘",
    "needle", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢 math letters", "Ω ≈ π × ∑ ∞",
]
COMMENTS = [
    "Fast path: the common case is a single ASCII line.",
    "TODO: this allocates once per frame; hoist the buffer.",
    "The cursor is a byte offset; columns are chars for now.",
    "Wide cells (CJK, emoji) take two columns; combining marks take none.",
    "needle: the search harness looks for this word.",
    "See the design notes before touching the layout tree.",
    "Tabs are rendered at the configured stop, never stored expanded.",
    "A fold hides lines but keeps their byte range addressable.",
    "Every mutation goes through apply(); no direct buffer writes.",
    "Ünïcödé in a comment — the highlighter must not split a code point.",
    "日本語コメント：全角文字の幅は二。",
]
KEYWORDS = ["let", "mut", "if", "else", "match", "for", "while", "loop", "return", "break",
            "continue", "pub", "fn", "struct", "enum", "impl", "trait", "where", "use", "mod",
            "const", "static", "unsafe", "async", "await", "move", "ref", "self", "Self",
            "type", "dyn", "as", "in"]


def gen(lines_wanted):
    rng = random.Random(SEED)
    out = []

    def pick(xs):
        return xs[rng.randrange(len(xs))]

    def ident():
        return pick(NAMES) + (("_" + pick(NAMES)) if rng.random() < 0.3 else "")

    def expr(depth=0):
        r = rng.random()
        if depth > 2 or r < 0.3:
            return pick([ident(), str(rng.randrange(0, 4096)), "%s.len()" % ident(),
                         "%s as usize" % ident(), '"%s"' % pick(STRINGS), "true", "None",
                         "Some(%s)" % ident(), "self.%s" % ident()])
        if r < 0.5:
            return "%s(%s)" % (pick(VERBS), ", ".join(expr(depth + 1) for _ in range(rng.randrange(0, 4))))
        if r < 0.7:
            return "%s %s %s" % (expr(depth + 1), pick(["+", "-", "*", "/", "%", "&&", "||", "==", "<", ">=", "<<"]), expr(depth + 1))
        if r < 0.85:
            return "%s.%s(|%s| %s)" % (ident(), pick(["map", "filter", "fold", "find", "any", "all", "take_while"]), ident(), expr(depth + 1))
        return "%s?.%s()" % (ident(), pick(VERBS))

    def stmt(indent, tab):
        pad = ("\t" * indent) if tab else ("    " * indent)
        r = rng.random()
        if r < 0.35:
            return "%slet %s%s: %s = %s;" % (pad, "mut " if rng.random() < 0.4 else "", ident(), pick(TYPES), expr())
        if r < 0.55:
            return "%s%s = %s;" % (pad, ident(), expr())
        if r < 0.65:
            return "%s// %s" % (pad, pick(COMMENTS))
        if r < 0.75:
            return "%s%s(%s);" % (pad, pick(VERBS), ", ".join(expr() for _ in range(rng.randrange(1, 4))))
        if r < 0.85:
            return "%sif %s { %s(%s); }" % (pad, expr(), pick(VERBS), ident())
        if r < 0.92:
            return "%sreturn %s;" % (pad, expr())
        return "%sdebug_assert!(%s, \"%s\");" % (pad, expr(), pick(STRINGS))

    def very_long_line(indent, tab):
        # > 300 cells: a chain of method calls, a giant match arm, or a
        # wide string literal — the wrap / horizontal-scroll trigger.
        pad = ("\t" * indent) if tab else ("    " * indent)
        kind = rng.randrange(3)
        if kind == 0:
            chain = ".".join("%s(%s)" % (pick(VERBS), expr(2)) for _ in range(18))
            return "%slet %s = %s.%s;" % (pad, ident(), ident(), chain)
        if kind == 1:
            arms = ", ".join("%d => \"%s\"" % (i, pick(STRINGS)) for i in range(16))
            return "%slet %s = match %s { %s, _ => \"needle\" };" % (pad, ident(), ident(), arms)
        body = " ".join(pick(STRINGS) for _ in range(24))
        return "%sconst %s: &str = \"%s\";" % (pad, ident().upper(), body)

    n_fn = 0
    out.append("//! A large, deterministic fixture for the navigation harness.")
    out.append("//! Generated by tools/gen-large-fixture.py — do not edit by hand.")
    out.append("#![allow(dead_code, unused_variables, unused_mut, clippy::all)]")
    out.append("")
    out.append("use std::collections::HashMap;")
    out.append("use std::rc::Rc;")
    out.append("use std::cell::RefCell;")
    out.append("use std::sync::{Arc, Mutex};")
    out.append("")
    long_lines_left = 6
    while len(out) < lines_wanted:
        tab = rng.random() < 0.2
        r = rng.random()
        if r < 0.15:
            out.append("/// %s" % pick(COMMENTS))
            out.append("#[derive(Debug, Clone, PartialEq)]")
            out.append("pub struct %s%d {" % (pick(NAMES).capitalize(), len(out)))
            for _ in range(rng.randrange(2, 9)):
                out.append("%spub %s: %s," % ("\t" if tab else "    ", ident(), pick(TYPES)))
            out.append("}")
            out.append("")
        elif r < 0.25:
            out.append("pub enum %s%d {" % (pick(VERBS).capitalize(), len(out)))
            for _ in range(rng.randrange(2, 7)):
                v = pick(NAMES).capitalize()
                out.append("%s%s%s," % ("\t" if tab else "    ", v, pick(["", "(usize)", "{ line: usize, col: usize }", "(String, Vec<u8>)"])))
            out.append("}")
            out.append("")
        else:
            n_fn += 1
            generic = pick(["", "<T>", "<'a>", "<T: Clone + 'static>", "<K, V>", "<F: Fn(usize) -> bool>"])
            args = ", ".join("%s: %s" % (ident(), pick(TYPES)) for _ in range(rng.randrange(0, 5)))
            out.append("/// %s" % pick(COMMENTS))
            out.append("pub fn %s_%s%d%s(%s) -> %s {" % (pick(VERBS), pick(NAMES), n_fn, generic, args, pick(TYPES)))
            depth = 1
            for _ in range(rng.randrange(3, 22)):
                rr = rng.random()
                if rr < 0.12 and depth < 4:
                    pad = ("\t" * depth) if tab else ("    " * depth)
                    out.append("%s%s %s {" % (pad, pick(["if", "while", "for _ in", "match"]), expr()))
                    depth += 1
                elif rr < 0.22 and depth > 1:
                    depth -= 1
                    out.append(("\t" * depth) if tab else ("    " * depth) + "}")
                elif rr < 0.26 and long_lines_left > 0 and len(out) > 400:
                    long_lines_left -= 1
                    out.append(very_long_line(depth, tab))
                else:
                    out.append(stmt(depth, tab))
            while depth > 1:
                depth -= 1
                out.append((("\t" * depth) if tab else ("    " * depth)) + "}")
            out.append("}")
            out.append("")
    # Sprinkle a few more very long lines if the budget was not spent.
    while long_lines_left > 0:
        long_lines_left -= 1
        out.insert(rng.randrange(500, len(out) - 1), very_long_line(1, False))
    return "\n".join(out[:lines_wanted]) + "\n"


def main(argv):
    out_path = None
    lines = 6000
    i = 1
    while i < len(argv):
        if argv[i] == "--lines":
            lines = int(argv[i + 1])
            i += 2
        else:
            out_path = argv[i]
            i += 1
    if out_path is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        out_path = os.path.join(root, "docs", "ui-spec", "fixtures", "large.rs")
    text = gen(lines)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    n_lines = text.count("\n")
    longest = max(len(l) for l in text.split("\n"))
    over300 = sum(1 for l in text.split("\n") if len(l) > 300)
    tabs = sum(1 for l in text.split("\n") if l.startswith("\t"))
    print("%s: %d lines, %d bytes, longest %d chars, %d lines over 300, %d tab-indented, needle x%d"
          % (out_path, n_lines, len(text.encode("utf-8")), longest, over300, tabs, text.count("needle")))


if __name__ == "__main__":
    main(sys.argv)
