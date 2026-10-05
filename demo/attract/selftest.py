#!/usr/bin/env python3
"""The web demo's self-test: run inside the image (demo/selftest.sh).

Starts a headless `mnml --demo` at the page's grid (200x60) with the
kiosk layer, drives it through the file channel the way the attract
runner does, and checks what a visitor would see:

  * the Jira and Bitbucket integrations are there: their manifests in the
    sandbox's data root, their statusline segments published, their
    launchers on the activity rail, and both panes opening against the
    offline fakes;
  * every private-use glyph the app put on screen — the statusline, the
    rail, the panes — is drawn by a font the page serves: the page's
    @font-face rules (demo/web/index.html) resolved the way the browser
    does, against the cmaps of the served files (fonts/coverage.json,
    written when the image was built). A private-use codepoint no served
    font carries paints as nothing, and no other font on the visitor's
    machine can stand in for it.

Exit 0 when everything holds; 1 with one line per failure otherwise.
Stdlib only, like the runner.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.environ.get("MNML_DEMO_WEB", os.path.join(ROOT, "web"))
KIOSK = os.path.join(ROOT, "attract", "kiosk.zon")
COLS, ROWS = 200, 60
# What `mnml --demo` installs (src/config/demo.zig) and the page must show.
JIRA = ["jira_work", "jira_boards", "jira_fix_versions"]
BITBUCKET = ["bitbucket_prs", "bitbucket_pipelines"]

failures = []


def fail(msg):
    failures.append(msg)
    print("FAIL " + msg, flush=True)


def ok(msg):
    print("ok   " + msg, flush=True)


def is_pua(cp):
    return 0xE000 <= cp <= 0xF8FF or 0xF0000 <= cp <= 0xFFFFD or 0x100000 <= cp <= 0x10FFFD


# ─── fonts: what the page can draw ──────────────────────────────────────


def parse_ranges(spec):
    out = []
    for part in spec.split(","):
        m = re.match(r"\s*U\+([0-9A-Fa-f]+)(?:-([0-9A-Fa-f]+))?\s*$", part)
        if m:
            lo = int(m.group(1), 16)
            out.append((lo, int(m.group(2), 16) if m.group(2) else lo))
    return out


def page_fonts():
    """The page's terminal font stack: [(family, [(file, ranges|None)])]
    in the order the terminal's font-family lists them."""
    page = open(os.path.join(WEB, "index.html"), encoding="utf-8").read()
    faces = {}
    for body in re.findall(r"@font-face\s*\{([^}]*)\}", page):
        fam = re.search(r'font-family:\s*"([^"]+)"', body)
        src = re.search(r"url\(([^)]+)\)", body)
        rng = re.search(r"unicode-range:\s*([^;]+);", body)
        if not (fam and src):
            continue
        faces.setdefault(fam.group(1), []).append(
            (os.path.basename(src.group(1).strip("'\"")), parse_ranges(rng.group(1)) if rng else None))
    m = re.search(r"const FAMILY = '([^']+)'", page)
    order = re.findall(r'"([^"]+)"', m.group(1)) if m else list(faces)
    return [(f, faces[f]) for f in order if f in faces]


def load_coverage():
    path = os.path.join(WEB, "fonts", "coverage.json")
    cov = json.load(open(path, encoding="utf-8"))
    return {name: ranges for name, ranges in cov.items()}


def has(ranges, cp):
    return any(lo <= cp <= hi for lo, hi in ranges)


def drawn_by(stack, cov, cp):
    """The served file that draws `cp`, as the browser picks it: each
    family in order; inside a family, the faces whose unicode-range
    covers `cp`; the first of those whose cmap has it. None: nothing."""
    for _family, faces in stack:
        for file, ranges in faces:
            if ranges is not None and not has(ranges, cp):
                continue
            if file not in cov:
                continue
            if has(cov[file], cp):
                return file
    return None


# ─── the app ────────────────────────────────────────────────────────────


class Demo:
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="mnml-selftest-")
        self.ipc = os.path.join(self.tmp, "ipc")
        os.makedirs(self.ipc)
        env = dict(os.environ, MNML_IPC_DIR=self.ipc, MNML_COLS=str(COLS), MNML_ROWS=str(ROWS))
        self.err_path = os.path.join(self.tmp, "stderr")
        self.err = open(self.err_path, "w")
        self.proc = subprocess.Popen(["mnml", "--demo", "--headless", "--config", KIOSK],
                                     cwd=os.path.expanduser("~"), env=env,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=self.err)

    def send(self, *cmds):
        with open(os.path.join(self.ipc, "command"), "a", encoding="utf-8") as f:
            for c in cmds:
                f.write(json.dumps(c) + "\n")

    def read(self, name):
        try:
            return open(os.path.join(self.ipc, name), encoding="utf-8").read()
        except OSError:
            return ""

    def screen(self):
        return self.read("screen.txt").split("\n")

    def until(self, pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if self.proc.poll() is not None:
                return False
            if pred():
                return True
            time.sleep(0.2)
        return False

    def home(self):
        m = re.search(r"HOME=(\S+)", open(self.err_path, encoding="utf-8").read())
        return m.group(1) if m else None

    def close(self):
        self.send({"cmd": "quit"})
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.err.close()
        shutil.rmtree(self.tmp, ignore_errors=True)


def chip_glyph(path):
    text = open(path, encoding="utf-8").read()
    m = re.search(r"\.chip\s*=\s*\.\{(.*?)\}", text, re.S)
    g = re.search(r'\.glyph\s*=\s*"((?:[^"\\]|\\.)*)"', m.group(1)) if m else None
    if not g:
        return None
    return zig_string(g.group(1)) or None


def zig_string(body):
    """A Zig string literal's body as text: `\\xNN` bytes, `\\u{…}`
    codepoints, the one-letter escapes."""
    out, i = bytearray(), 0
    simple = {"n": b"\n", "t": b"\t", "r": b"\r", "\\": b"\\", '"': b'"', "'": b"'"}
    while i < len(body):
        c = body[i]
        if c != "\\":
            out += c.encode("utf-8")
            i += 1
        elif body[i + 1] == "x":
            out.append(int(body[i + 2:i + 4], 16))
            i += 4
        elif body[i + 1] == "u":
            end = body.index("}", i)
            out += chr(int(body[i + 3:end], 16)).encode("utf-8")
            i = end + 1
        else:
            out += simple.get(body[i + 1], body[i + 1].encode("utf-8"))
            i += 2
    return out.decode("utf-8", "replace")


def main():
    stack = page_fonts()
    cov = load_coverage()
    if not stack or not cov:
        fail("the page's font stack or fonts/coverage.json is empty")
        return
    seen = {}  # codepoint -> where it was first seen

    def collect(where, rows):
        for r, line in enumerate(rows):
            for ch in line:
                if is_pua(ord(ch)) and ord(ch) not in seen:
                    seen[ord(ch)] = f"{where}, row {r}: {line.strip()[:70]}"

    demo = Demo()
    try:
        if not demo.until(lambda: len(demo.screen()) >= ROWS - 2, 30):
            fail("mnml --demo did not paint a screen in 30 s: " + open(demo.err_path).read().strip()[-300:])
            return
        ok("mnml --demo is up at %dx%d" % (COLS, ROWS))

        # Their manifests, in the sandbox's data root.
        home = demo.home()
        manifests = {}
        if home:
            for p in glob.glob(os.path.join(home, "*", "mnml", "integrations", "*.zon")):
                manifests[os.path.basename(p)[:-4]] = p
        glyphs = {}
        for mid in JIRA + BITBUCKET:
            if mid not in manifests:
                fail(f"{mid}: no manifest installed in the sandbox's data root ({home})")
            elif not chip_glyph(manifests[mid]):
                fail(f"{mid}: its manifest has no chip glyph")
            else:
                glyphs[mid] = chip_glyph(manifests[mid])
                for ch in glyphs[mid]:
                    if is_pua(ord(ch)):
                        seen.setdefault(ord(ch), f"{mid}'s chip glyph")

        # Their statusline chips (the Jira Work and Bitbucket PRs counts,
        # once the fakes answer the first poll) and their launchers on the
        # activity rail (the leftmost cells of every row).
        def statusline():
            rows = demo.screen()
            return next((line for line in reversed(rows) if "\ue0b0" in line), "")

        on_bar = [m for m in ("jira_work", "bitbucket_prs") if m in glyphs]
        demo.until(lambda: all(glyphs[m] in statusline() for m in on_bar), 30)
        bar = statusline()
        for mid in on_bar:
            if glyphs[mid] in bar:
                ok(f"{mid}: its chip is on the statusline")
            else:
                fail(f"{mid}: its chip (U+{ord(glyphs[mid][0]):05X}) is not on the statusline in 30 s: {bar.strip()[:160]}")
        start = demo.screen()
        collect("start", start)
        rail = "".join(line[:4] for line in start)
        for mid, g in glyphs.items():
            if g in rail:
                ok(f"{mid}: its launcher U+{ord(g[0]):05X} is on the activity rail")
            else:
                fail(f"{mid}: its launcher (U+{ord(g[0]):05X}) is not on the activity rail")

        # Both panes open against the offline fakes.
        demo.send({"cmd": "run-command", "id": "integrations.open_as_tab"})
        for cmd, header in (("jira_work.open", "JIRA WORK ("), ("bitbucket_prs.open", "BITBUCKET PRS")):
            demo.send({"cmd": "run-command", "id": cmd})
            if demo.until(lambda: any(header in line for line in demo.screen()), 20):
                ok(f"{cmd}: the pane shows {header!r}")
                time.sleep(0.5)
                collect(cmd, demo.screen())
            else:
                fail(f"{cmd}: no {header!r} on screen in 20 s")
    finally:
        demo.close()

    # Every private-use glyph seen, against the served fonts.
    missing = [(cp, where) for cp, where in sorted(seen.items()) if drawn_by(stack, cov, cp) is None]
    for cp, where in missing:
        fail(f"U+{cp:05X} is drawn by no served font ({where})")
    if not missing:
        ok(f"{len(seen)} private-use glyphs on screen, every one in a served font")


if __name__ == "__main__":
    main()
    print(f"selftest: {'FAILED, ' + str(len(failures)) + ' problem(s)' if failures else 'passed'}", flush=True)
    sys.exit(1 if failures else 0)
