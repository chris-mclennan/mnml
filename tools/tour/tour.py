#!/usr/bin/env python3
"""mnml's real-screen tour: the curated shots, their baselines, the pixel
asserts, and the corpus sweep. See `tools/tour.sh --help`.

Everything runs in ONE ghostty window at a time (`mnml-drive`), driven
through the file channel so the window never takes the keyboard.
"""

import argparse
import json
import os
import re
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import imgdiff  # noqa: E402
import stamp  # noqa: E402
import zonlite  # noqa: E402
from mnmlwin import REPO, DriveError, Window, hex_to_rgb, now_ms  # noqa: E402

TOUR_DIR = os.path.join(REPO, "tests", "tour")
BASELINE = os.path.join(TOUR_DIR, "baseline")
SWEEP_BASELINE = os.path.join(TOUR_DIR, "sweep-baseline")
MASKS = os.path.join(TOUR_DIR, "masks.zon")
ASSERTS = os.path.join(TOUR_DIR, "asserts.zon")
REVIEW = os.path.join(REPO, "tools", "tour-review.md")
# The tour's workspace lives HERE, not under --out: the sidebar header
# paints the workspace's path, abbreviated (`/Use…`), so a workspace
# under `--out /private/tmp/x` painted `/pr…` and flagged every shot
# with the tree open against baselines taken under the repo. The path
# is the same whichever --out the shots go to. (masks.zon masks the
# cell too, belt and braces.)
TOUR_WS = os.path.join(REPO, ".verify", "tour-ws")
COLS, ROWS = 120, 40
# A toast lives four seconds (`app.zig` `toast_ttl_ms`); a shot waits
# this long for the last one to go before it gives up and says so.
TOAST_WAIT_MS = 6000


def log(msg):
    print(msg, flush=True)


# ─── the curated states ────────────────────────────────────────────────
#
# Each state is (name, what it shows, steps). A step is a tuple the
# `play` function reads: ("run", id), ("key", spec), ("type", text),
# ("open", rel), ("click", col, row[, button]), ("hover", col, row),
# ("wait", ms), ("until", text[, ms]) — wait for text on screen —, and
# ("reset",) — Esc twice and back to the explorer, which every state that
# does not build on the previous one starts with.
#
# The standard profile throughout: where the vim and standard chords
# differ (which-key's leader), the standard one is shot.

RESET = ("reset",)

STATES = [
    ("start", "the start surface: the tree, the welcome body, the statusline", []),
    ("editor-selection", "src/main.zig open, three lines selected", [
        RESET, ("open", "src/main.zig"), ("until", "fn main"),
        ("key", "ctrl+home"), ("key", "down"), ("key", "down"), ("key", "down"),
        ("key", "shift+down"), ("key", "shift+down"), ("key", "shift+down"), ("key", "shift+end"),
    ]),
    ("split-shell", "a vertical split: the editor left, a shell focused right", [
        ("run", "term.shell"), ("until", "tour %"),
        # `ls src docs`, not `ls`: the workspace root gains lock and
        # socket files when the integrations' broker starts, on its own
        # clock, which reflowed the listing between two runs.
        ("type", "ls src docs\n"), ("until", "util.zig", 4000),
    ]),
    ("editor-refocused", "the same split with the editor focused again: the shell's rail steps back", [
        ("run", "view.focus_left"),
    ]),
    ("rail-search", "SEARCH with a query and hits", [
        RESET, ("run", "view.activity_search"), ("type", "total"), ("key", "enter"), ("wait", 800),
    ]),
    ("rail-git", "the GIT section beside the graph", [RESET, ("run", "view.activity_git"), ("wait", 1200)]),
    ("git-status", "the staging pane: one modified, one untracked", [
        RESET, ("run", "git.status_pane"), ("until", "util.zig", 4000),
    ]),
    ("rail-debug", "the DEBUG section", [RESET, ("run", "view.activity_debug")]),
    ("rail-integrations", "INTEGRATIONS: the Installed tab", [RESET, ("run", "view.activity_integrations"), ("wait", 800)]),
    ("rail-sessions", "SESSIONS (the vertical session tabs)", [RESET, ("run", "view.activity_sessions")]),
    ("rail-notes", "NOTES with the workspace's one note", [RESET, ("run", "view.activity_notes"), ("wait", 500)]),
    ("rail-todos", "TODOS: the TODO and FIXME in src/main.zig", [RESET, ("run", "view.activity_todos"), ("wait", 1200)]),
    ("rail-findings", "FINDINGS with the sample report", [RESET, ("run", "view.activity_findings"), ("wait", 500)]),
    ("rail-scripts", "SCRIPTS", [RESET, ("run", "view.activity_scripts"), ("wait", 500)]),
    ("rail-http", "HTTP", [RESET, ("run", "view.activity_http"), ("wait", 500)]),
    ("settings", "the Settings overlay", [RESET, ("run", "view.settings"), ("wait", 400)]),
    ("palette", "the command palette filtered on `git`", [RESET, ("key", "ctrl+shift+p"), ("type", "git"), ("wait", 400)]),
    ("which-key", "which-key on the standard leader Ctrl+K", [RESET, ("key", "ctrl+k"), ("wait", 1500)]),
    ("hover-help-focus", "the info panel holding the keys (help.focus)", [RESET, ("run", "help.focus"), ("wait", 300)]),
    ("hover-help-pinned", "the info panel pinned (help.pin_toggle)", [("run", "help.pin_toggle"), ("wait", 300)]),
    # No `help.pin_toggle` here: the reset's Esc leaves the HELP focus
    # and that unpins (`app/info_view.zig`), so a toggle after it pinned
    # the panel again — and its "info panel: pinned" toast was in the
    # baseline.
    ("sessions-table", "the sessions table", [RESET, ("run", "sessions.table"), ("wait", 1500)]),
    ("launcher-dock", "the launcher dock revealed (mode always)", [
        RESET, ("run", "view.dock_cycle_mode"), ("run", "view.dock_cycle_mode"), ("wait", 600),
    ]),
    ("context-menu", "the editor's right-click menu", [
        RESET, ("run", "view.dock_cycle_mode"), ("open", "src/util.zig"), ("until", "pub fn sum"),
        ("click", 70, 10, "right"), ("wait", 400),
    ]),
    ("usage", "the Claude usage pane on the three-account fixture", [RESET, ("run", "ai.claude_usage"), ("wait", 1500)]),
    ("cheatsheet", "the cheatsheet pane", [RESET, ("run", "view.cheatsheet"), ("wait", 600)]),
    ("help-overlay", "the keybindings help overlay (F1)", [RESET, ("key", "f1"), ("wait", 600)]),
    ("menu-file", "the File menu open", [RESET, ("find-click", "File", 0), ("wait", 400)]),
    # Last: installing an integration leaves files and chips behind that
    # would otherwise leak into every later shot.
    ("jira-work", "the Jira Work pane against the offline fake", [
        RESET, ("run", "integrations.show_in_dev"), ("until", "INTEGRATIONS"),
        ("until", "Jira Work", 4000), ("find-click", "Jira Work"), ("key", "i"),
        ("until", "installed jira_work", 15000), ("wait", 4500),
        ("run", "integrations.open_as_tab"), ("run", "jira_work.open"),
        ("until", "JIRA WORK", 15000), ("heal", "fetch failed", "r", "JIRA WORK (3)"), ("wait", 1500),
    ]),
    ("bitbucket-prs", "the Bitbucket PRs pane against the offline fake", [
        RESET, ("run", "integrations.show_marketplace"), ("wait", 1200), ("key", "i"),
        ("until", "installed bitbucket_prs", 15000), ("wait", 4500),
        ("run", "integrations.open_as_tab"), ("run", "bitbucket_prs.open"),
        ("until", "BITBUCKET PRS", 15000), ("until", "3 PRs", 15000),
        ("heal", "fetch failed", "r", "3 PRs"), ("wait", 1000),
    ]),
]


def play(win, steps, state_log):
    for st in steps:
        op = st[0]
        if op == "reset":
            # Back to the start surface: overlays shut, every split and
            # buffer closed, the explorer in the side column.
            win.send({"cmd": "key", "key": "esc"}, {"cmd": "key", "key": "esc"})
            for _ in range(6):
                if not win.status().get("panes"):
                    break
                win.send({"cmd": "run-command", "id": "view.only"},
                         {"cmd": "run-command", "id": "view.close_others"},
                         {"cmd": "run-command", "id": "buffer.close"})
            if win.status().get("panes"):
                state_log.append("reset: panes still open: " + ", ".join(
                    str(p.get("title", "?")) for p in win.status().get("panes", [])))
            win.run("view.activity_explorer")
        elif op == "run":
            win.run(st[1])
        elif op == "key":
            win.key(st[1])
        elif op == "type":
            win.type(st[1])
        elif op == "open":
            win.open(st[1])
        elif op == "click":
            win.click(st[1], st[2], st[3] if len(st) > 3 else "left")
        elif op == "hover":
            win.hover(st[1], st[2])
        elif op == "wait":
            time.sleep(st[1] / 1000.0)
            win.settle(cap_ms=1500)
        elif op == "until":
            ms = st[2] if len(st) > 2 else 3000
            if not win.wait_for(st[1], timeout_ms=ms):
                state_log.append(f"`{st[1]}` never appeared on screen within {ms} ms")
            win.settle(cap_ms=1500)
        elif op == "heal":
            # A pane whose first fetch failed (seen once in ~10 runs: both
            # offline fakes unanswered for one run) gets its own retry
            # key, and the note says so: the shot is then of the healed
            # pane, and the log keeps the flake visible.
            bad, key, good = st[1], st[2], st[3]
            for _ in range(3):
                if bad not in win.screen():
                    break
                state_log.append(f"`{bad}` on screen; pressed `{key}`")
                win.key(key)
                win.wait_for(good, timeout_ms=8000)
            win.settle(cap_ms=1500)
        elif op == "find-click":
            # Click the first cell of a label where the screen shows it:
            # layout-independent where a fixed cell would not be.
            text, row_hint = st[1], (st[2] if len(st) > 2 else None)
            at = find_text(win.screen(), text, row_hint)
            if at is None:
                state_log.append(f"`{text}` not on screen to click")
            else:
                win.click(at[0], at[1])
        else:
            raise ValueError(f"unknown step {st!r}")


def wait_toasts_gone(win, state_log, timeout_ms=TOAST_WAIT_MS):
    """Hold the shot until no toast is up (`status.json` `toasts`). A
    toast raised by this state or the one before rides its own clock into
    the next shot otherwise — the sessions table was baselined with the
    previous toggle's "info panel: pinned" in its corner. Nothing is sent
    to the app: a command would close the overlay some states shoot. A
    toast that outlives the wait (a sticky progress line) is named in the
    state's notes and the shot is taken anyway."""
    st = win.status()
    if "toasts" not in st:
        state_log.append("status.json has no `toasts` count (an app older than the tour); not waited for")
        return
    if not st["toasts"]:
        return
    rows = win.screen().rstrip("\n").split("\n")
    # The bottom row echoes the newest toast (under no overlay): its
    # words go in the note, so a warning the wait kept out of the shot
    # is still read by whoever reads the log.
    echo = rows[-1].strip().rstrip("⋯").strip() if rows else ""
    said = f" (`{echo}`)" if echo else ""
    t0 = now_ms()
    while now_ms() - t0 < timeout_ms:
        time.sleep(0.05)
        if not win.status().get("toasts"):
            win.settle(quiet_ms=300, cap_ms=1500)
            state_log.append(f"waited {int(now_ms() - t0)} ms for {st['toasts']} toast(s) to go{said}")
            return
    state_log.append(f"toast lingered: {win.status().get('toasts')} up after {timeout_ms} ms{said}")


def find_text(screen, text, row=None):
    for y, line in enumerate(screen.split("\n")):
        if row is not None and y != row:
            continue
        x = line.find(text)
        if x >= 0:
            return x, y
    return None


# ─── masks ─────────────────────────────────────────────────────────────

def load_masks():
    if not os.path.exists(MASKS):
        return {"default": {}, "shots": {}}
    m = zonlite.load(MASKS)
    m.setdefault("default", {})
    m.setdefault("shots", {})
    return m


def rects_of(entry):
    out = []
    for r in entry.get("rects") or []:
        out.append((r["col"], r["row"], r["w"], r["h"]))
    return out


def auto_masks(screen_text, patterns, pad=1):
    """Cell rectangles over every match of `patterns` in a screen dump:
    the clock, the version hash — anything that moves by itself. The
    dump is one character a cell for the ASCII these patterns match."""
    out = []
    for y, line in enumerate(screen_text.split("\n")):
        for pat in patterns:
            for m in re.finditer(pat, line):
                out.append((max(0, m.start() - pad), y, m.end() - m.start() + 2 * pad, 1))
    return out


def masks_for(name, masks, *screens):
    d = masks.get("default", {})
    s = masks.get("shots", {}).get(name, {})
    rects = rects_of(d) + rects_of(s)
    pats = list(d.get("patterns") or []) + list(s.get("patterns") or [])
    for scr in screens:
        if scr:
            rects += auto_masks(scr, pats)
    return rects


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def compare(name, fresh_png, base_png, masks, threshold_pct, tolerance):
    fresh_txt = read_text(os.path.splitext(fresh_png)[0] + ".txt")
    base_txt = read_text(os.path.splitext(base_png)[0] + ".txt")
    cells = masks_for(name, masks, fresh_txt, base_txt)
    a = imgdiff.load(base_png)
    b = imgdiff.load(fresh_png)
    changed, total, bbox = imgdiff.diff(a, b, COLS, ROWS, cells, tolerance=tolerance)
    pct = 100.0 * changed / total if total else 0.0
    return pct, bbox, pct > threshold_pct


# ─── asserts ───────────────────────────────────────────────────────────

def load_asserts():
    if not os.path.exists(ASSERTS):
        return []
    a = zonlite.load(ASSERTS)
    return a if isinstance(a, list) else []


def color_delta(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def check_asserts_live(win, name, asserts, results):
    """The `pixel` verb on the live window, right after the state's shot."""
    for a in asserts:
        if a.get("shot") != name:
            continue
        fx, fy = a.get("fx", 0.5), a.get("fy", 0.5)
        try:
            got = hex_to_rgb(win.pixel(a["col"], a["row"], fx, fy))
            ok, detail = judge(a, got, lambda c, r, x, y: hex_to_rgb(win.pixel(c, r, x, y)))
        except DriveError as e:
            ok, detail = False, str(e)
        results.append((name, a.get("why", ""), ok, detail))


def judge(a, got, sample):
    tol = a.get("tolerance", 24)
    if "expect" in a:
        want = hex_to_rgb(a["expect"])
        d = color_delta(got, want)
        return d <= tol, f"cell {a['col']},{a['row']} is #{bytes(got).hex()}, want {a['expect']} ±{tol} (off by {d})"
    if "unlike" in a:
        u = a["unlike"]
        other = sample(u["col"], u["row"], u.get("fx", 0.5), u.get("fy", 0.5))
        d = color_delta(got, other)
        need = u.get("min_delta", 40)
        return d >= need, (f"cell {a['col']},{a['row']} #{bytes(got).hex()} vs cell {u['col']},{u['row']} "
                           f"#{bytes(other).hex()}: apart by {d}, need ≥ {need}")
    return False, "an assert needs `expect` or `unlike`"


# ─── the tour ──────────────────────────────────────────────────────────

def take_ws_lock():
    """One tour at a time on TOUR_WS: a second run would rebuild the
    workspace under the first one's window. Returns the lock path, or
    None when a live tour holds it."""
    os.makedirs(os.path.dirname(TOUR_WS), exist_ok=True)
    lock = TOUR_WS + ".lock"
    try:
        with open(lock, encoding="utf-8") as f:
            pid = int(f.read().strip() or 0)
        if pid and pid != os.getpid():
            os.kill(pid, 0)
            return None
    except (OSError, ValueError):
        pass
    with open(lock, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
    return lock


def cmd_run(args):
    out = os.path.abspath(args.out)
    lock = take_ws_lock()
    if lock is None:
        log(f"tour.sh: another tour is running on {os.path.relpath(TOUR_WS, REPO)} — one at a time")
        return 64
    try:
        return run_tour(args, out)
    finally:
        try:
            os.unlink(lock)
        except OSError:
            pass


def run_tour(args, out):
    if not args.exe:
        stamp.warn_app("tour.sh")
    if os.path.exists(out) and not args.keep:
        shutil.rmtree(out)
    os.makedirs(out, exist_ok=True)
    run_dir = os.path.join(out, ".run")
    ws = os.path.join(TOUR_WS, "ws")
    if os.path.exists(TOUR_WS):
        shutil.rmtree(TOUR_WS)
    home = os.path.join(run_dir, "home")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import workspace
    workspace.build(ws, home)
    usage = os.path.join(run_dir, "usage-fixture")
    shutil.copytree(os.path.join(REPO, "docs", "ui-spec", "usage-fixture"), usage)
    fakes = workspace.start_fakes(ws)
    only = set(args.only.split(",")) if args.only else None
    states = [s for s in STATES if only is None or s[0] in only]
    app_args = ["--ascii"] if args.ascii else []
    win = Window(run_dir, ws, exe=args.exe, cols=COLS, rows=ROWS,
                 app_env=workspace.app_env(ws, usage), app_args=app_args)
    notes = []
    assert_results = []
    asserts = load_asserts()
    started = now_ms()
    try:
        # The fakes write their URL files once listening.
        for f in ("jira.url", "bb.url"):
            deadline = now_ms() + 5000
            while not os.path.exists(os.path.join(ws, f)) and now_ms() < deadline:
                time.sleep(0.05)
        win.launch()
        for i, (name, what, steps) in enumerate(states, 1):
            t0 = now_ms()
            state_log = []
            try:
                play(win, steps, state_log)
                win.settle(quiet_ms=400, cap_ms=3000)
                wait_toasts_gone(win, state_log)
                png = os.path.join(out, f"{i:02d}-{name}.png")
                win.shot(png)
                check_asserts_live(win, name, asserts, assert_results)
            except DriveError as e:
                state_log.append(f"error: {e}")
                if not win.alive():
                    notes.append((name, state_log))
                    log(f"  {i:02d} {name:22} FAILED — the app is gone")
                    break
            for fk in fakes:
                if fk.poll() is not None and not getattr(fk, "_reported", False):
                    fk._reported = True
                    state_log.append(f"{os.path.basename(fk.args[0])} exited {fk.returncode}")
            notes.append((name, state_log))
            flag = "" if not state_log else "  (" + "; ".join(state_log) + ")"
            log(f"  {i:02d} {name:22} {int(now_ms() - t0):5d} ms{flag}")
    finally:
        win.quit()
        for p in fakes:
            try:
                p.kill()
            except OSError:
                pass
    log(f"tour: {len(states)} states in {int((now_ms() - started) / 1000)} s → {out}")
    with open(os.path.join(out, "tour.json"), "w", encoding="utf-8") as f:
        json.dump({"states": [{"name": n, "notes": l} for n, l in notes],
                   "asserts": [{"shot": s, "why": w, "ok": ok, "detail": d} for s, w, ok, d in assert_results]},
                  f, indent=2)
    results = None
    if not args.no_diff and os.path.isdir(BASELINE):
        results = diff_results(out, BASELINE, args)
    return report(out, results, assert_results, args)


def shot_name(png):
    base = os.path.splitext(os.path.basename(png))[0]
    return re.sub(r"^\d+-", "", base)


def diff_results(out, baseline, args, names=None):
    """Every fresh shot against its baseline, without printing: a dict of
    the threshold, the tolerance and one (kind, name, pct, bbox, png) per
    shot — kind `ok`, `CHANGED` or `new`. Writes flagged.txt."""
    masks = load_masks()
    thr = args.threshold if args.threshold is not None else float(masks.get("threshold_pct", 0.02))
    tol = args.tolerance if args.tolerance is not None else int(masks.get("tolerance", 24))
    rows = []
    fresh = sorted(p for p in os.listdir(out) if p.endswith(".png")) if os.path.isdir(out) else []
    for p in fresh:
        name = shot_name(p)
        if names and name not in names:
            continue
        base = os.path.join(baseline, name + ".png")
        png = os.path.join(out, p)
        if not os.path.exists(base):
            rows.append(("new", name, 0.0, None, png))
            continue
        pct, bbox, changed = compare(name, png, base, masks, thr, tol)
        rows.append(("CHANGED" if changed else "ok", name, pct, bbox, png))
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "flagged.txt"), "w", encoding="utf-8") as f:
        f.write("".join(r[4] + "\n" for r in rows if r[0] == "CHANGED"))
    return {"baseline": baseline, "threshold": thr, "tolerance": tol, "rows": rows}


def summary_line(results, assert_results):
    """`N ok, M changed, K asserts ok` (plus the failed asserts and the
    shots with no baseline, when there are any) — printed before the
    per-shot lines so the verdict is the first thing read."""
    rows = results["rows"] if results else []
    ok = sum(1 for r in rows if r[0] == "ok")
    changed = sum(1 for r in rows if r[0] == "CHANGED")
    new = sum(1 for r in rows if r[0] == "new")
    a_ok = sum(1 for a in assert_results if a[2])
    a_bad = len(assert_results) - a_ok
    line = f"{ok} ok, {changed} changed, {a_ok} asserts ok"
    if a_bad:
        line += f", {a_bad} asserts FAILED"
    if new:
        line += f", {new} new"
    if results is None:
        line += " (no diff)"
    return line, changed + a_bad


def report(out, results, assert_results, args):
    """The summary line, then the asserts and the per-shot lines. Exit 1
    on a CHANGED shot or a failed assert and on nothing else — a stale
    app, a lingering toast or a missing baseline are notes, not
    failures."""
    line, bad = summary_line(results, assert_results)
    log(line)
    if assert_results:
        log("asserts:")
        for s, why, ok, detail in assert_results:
            log(f"  {'ok  ' if ok else 'FAIL'} {s:22} {why} — {detail}")
    if results is not None:
        log(f"diff vs {os.path.relpath(results['baseline'], REPO)} "
            f"(threshold {results['threshold']}%, tolerance {results['tolerance']}):")
        for kind, name, pct, bbox, _png in results["rows"]:
            if kind == "new":
                log(f"  new      {name}  (no baseline — `tour.sh accept {name}`)")
                continue
            where = f"  cells {bbox[0]},{bbox[1]}–{bbox[2]},{bbox[3]}" if bbox else ""
            if kind == "CHANGED":
                log(f"  CHANGED {pct:7.3f}%  {name}{where}")
            else:
                log(f"  ok      {pct:7.3f}%  {name}")
    summary(out)
    return 1 if bad else 0


def last_asserts(out, names=None):
    """The asserts the last run recorded (tour.json), as check_asserts_live
    returns them."""
    try:
        with open(os.path.join(out, "tour.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    return [(a["shot"], a.get("why", ""), a.get("ok", False), a.get("detail", ""))
            for a in data.get("asserts", []) if not names or a.get("shot") in names]


def summary(out):
    flagged = read_text(os.path.join(out, "flagged.txt")).split()
    log("")
    log(f"shots:   {out}")
    if flagged:
        log(f"flagged: {len(flagged)} shot(s) — listed in {os.path.join(out, 'flagged.txt')}")
    log(f"review:  read the shots with {REVIEW}")


def cmd_diff(args):
    out = os.path.abspath(args.out)
    names = set(args.names) if args.names else None
    results = diff_results(out, BASELINE, args, names)
    return report(out, results, last_asserts(out, names), args)


def cmd_accept(args):
    out = os.path.abspath(args.out)
    os.makedirs(BASELINE, exist_ok=True)
    fresh = {shot_name(p): p for p in os.listdir(out) if p.endswith(".png")}
    names = list(fresh) if args.all else args.names
    if not names:
        log("accept: name a shot, or --all")
        return 2
    for n in names:
        if n not in fresh:
            log(f"accept: no shot `{n}` in {out}")
            return 2
        src = os.path.join(out, fresh[n])
        # Re-encoded, not copied: RGB, level 9 (`imgdiff.save_png`).
        imgdiff.save_png(imgdiff.load(src), os.path.join(BASELINE, n + ".png"))
        shutil.copyfile(os.path.splitext(src)[0] + ".txt", os.path.join(BASELINE, n + ".txt"))
        kb = os.path.getsize(os.path.join(BASELINE, n + ".png")) // 1024
        log(f"accepted {n} ({kb} KB)")
    return 0


# ─── entry ─────────────────────────────────────────────────────────────

def main(argv):
    ap = argparse.ArgumentParser(prog="tour.sh", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    default_out = os.path.join(REPO, ".verify", "tour")

    def diff_opts(p):
        p.add_argument("--threshold", type=float, help="percent of changed pixels that flags a shot")
        p.add_argument("--tolerance", type=int, help="per-channel delta a pixel may move and stay unchanged")

    r = sub.add_parser("run", help="launch, walk the states, shoot, assert, diff against the baselines")
    r.add_argument("--out", default=default_out)
    r.add_argument("--exe", help="the mnml-zig binary (default zig-out/bin/mnml-zig)")
    r.add_argument("--only", help="comma-separated state names")
    r.add_argument("--ascii", action="store_true", help="launch with --ascii (a deliberate change)")
    r.add_argument("--no-diff", action="store_true")
    r.add_argument("--keep", action="store_true", help="do not clear --out first")
    diff_opts(r)

    d = sub.add_parser("diff", help="diff the last run's shots against the baselines")
    d.add_argument("names", nargs="*")
    d.add_argument("--out", default=default_out)
    diff_opts(d)

    a = sub.add_parser("accept", help="copy shots from the last run into tests/tour/baseline")
    a.add_argument("names", nargs="*")
    a.add_argument("--all", action="store_true")
    a.add_argument("--out", default=default_out)

    s = sub.add_parser("sweep", help="run every tests/e2e/*.test through the real window and shoot its last frame")
    s.add_argument("files", nargs="*", help="files or directories (default tests/e2e)")
    s.add_argument("--out", default=os.path.join(REPO, ".verify", "sweep"))
    s.add_argument("--exe")
    s.add_argument("--all", action="store_true", help="re-run files that already have a shot")
    s.add_argument("--limit", type=int, help="stop after N files (a sample)")
    s.add_argument("--soft-wait", type=int, default=2000, help="how long an `expect` may hold the script (ms)")
    diff_opts(s)

    lk = sub.add_parser("look", help="the agent recipe's verbs (tools/look.sh)")
    lk.add_argument("verb")
    lk.add_argument("rest", nargs="*")
    lk.add_argument("--exe")
    lk.add_argument("--cols", type=int, default=COLS)
    lk.add_argument("--rows", type=int, default=ROWS)
    lk.add_argument("--root")

    args = ap.parse_args(argv)
    if args.cmd == "run":
        return cmd_run(args)
    if args.cmd == "diff":
        return cmd_diff(args)
    if args.cmd == "accept":
        return cmd_accept(args)
    if args.cmd == "sweep":
        import sweep
        return sweep.run(args)
    if args.cmd == "look":
        import look
        return look.run(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
