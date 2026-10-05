#!/usr/bin/env python3
"""site-record: real-window recordings of mnml for the website.

One FLOW file → one launch of the tour's harness window (200x60, the
user's own ghostty font, decoration off), driven through the file
channel exactly as `tools/tour.sh` drives it, recorded window-only with
ScreenCaptureKit (`winrec.swift`), encoded to VP9 WebM with a PNG
poster. See `tools/site-record.sh --help` for the flow format.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "tour"))

import stamp  # noqa: E402
import tour  # noqa: E402
import workspace  # noqa: E402
from mnmlwin import CLEAN_PATH, DriveError, Window, now_ms  # noqa: E402

FFMPEG = shutil.which("ffmpeg", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin") or "ffmpeg"
FFPROBE = shutil.which("ffprobe", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin") or "ffprobe"
COLS, ROWS = 200, 60
MEDIA = os.path.join(REPO, "site", "public", "media")
MEDIA_JSON = os.path.join(REPO, "site", "src", "media.json")
# The stand-in `claude` — the one `mnml --demo` puts on PATH too.
SHIMS = os.path.join(REPO, "data", "demo", "bin")
WINREC_SRC = os.path.join(HERE, "winrec.swift")

# Nothing on screen may name the machine's owner or their work. Checked
# on every screen.txt the app writes while recording, and on the poster:
# the home path, the user name, and the contributor's own work-data
# patterns (the file tools/work-data-audit.sh reads — kept outside the
# repository, so they are never spelled here).
def forbidden_patterns():
    pats = [re.escape(os.path.expanduser("~")), r"/Users/"]
    user = os.environ.get("USER", "")
    if len(user) >= 4:
        pats.append(re.escape(user))
    wd = os.environ.get("MNML_WORK_DATA_PATTERNS", os.path.expanduser("~/.config/mnml/work-data-patterns"))
    try:
        with open(wd, encoding="utf-8") as f:
            pats += [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
    except OSError:
        pass
    out = []
    for p in pats:
        try:
            out.append(re.compile(p))
        except re.error:
            out.append(re.compile(re.escape(p)))
    return out


class SiteWindow(Window):
    """The tour's window with the data root written relative: the IPC
    dir is set through MNML_IPC_DIR and the running-instance marker lives
    under the run's private TMPDIR."""

    def _write_wrapper(self):
        path = super()._write_wrapper()
        with open(path, encoding="utf-8") as f:
            head, body = f.read().split("\n", 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(head + "\n" + self.relative_root_lines() + body)
        return path

    relative_root = False

    def relative_root_lines(self):
        """`relative_data_root: yes` — the data root spelled relative to
        the run, so a toast that names a file under it (an install's
        "wrote …") never paints the machine's absolute path. Only for a
        flow with no shell pane (the shell's rc directory hangs off the
        data root and resolves against the shell's cwd)."""
        if not self.relative_root:
            return ""
        return (f"cd {shlex.quote(self.run_dir)} || exit 70\n"
                "MNML_DATA_ROOT=data; export MNML_DATA_ROOT\n")


def log(msg):
    print(msg, flush=True)


# ─── the flow file ──────────────────────────────────────────────────────

def parse_flow(path):
    meta = {"name": os.path.splitext(os.path.basename(path))[0], "title": "", "flow": "",
            "fps": 30, "width": 1600}
    setup, steps, cur = [], [], None
    cur = setup
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = re.match(r"^(title|flow|fps|width|session_cwd|relative_data_root|tree_width):\s*(.*)$", line)
            if m:
                k, v = m.group(1), m.group(2).strip()
                meta[k] = int(v) if k in ("fps", "width", "tree_width") else v
                continue
            try:
                toks = shlex.split(line)
            except ValueError as e:
                raise SystemExit(f"{path}:{n}: {e}")
            op = toks[0]
            if op == "record":
                if cur is steps:
                    raise SystemExit(f"{path}:{n}: a second `record`")
                cur = steps
                continue
            cur.append((n, op, toks[1:]))
    if not meta["title"] or not meta["flow"]:
        raise SystemExit(f"{path}: needs `title:` and `flow:` lines")
    if not steps:
        raise SystemExit(f"{path}: nothing after `record`")
    return meta, setup, steps


def ms(v):
    return int(float(v))


def to_tour_step(op, a):
    """The tour's own step tuples, for the ops the two share."""
    if op == "reset":
        return ("reset",)
    if op in ("run", "key", "type", "open"):
        return (op, a[0])
    if op == "click":
        return ("click", int(a[0]), int(a[1]), a[2] if len(a) > 2 else "left")
    if op == "hover":
        return ("hover", int(a[0]), int(a[1]))
    if op == "wait":
        return ("wait", ms(a[0]))
    if op == "until":
        return ("until", a[0], ms(a[1])) if len(a) > 1 else ("until", a[0])
    if op == "heal":
        return ("heal", a[0], a[1], a[2])
    if op == "find-click":
        return ("find-click", a[0], int(a[1])) if len(a) > 1 else ("find-click", a[0])
    return None


class Player:
    def __init__(self, win, out_dir, flow_dir):
        self.flow_dir = flow_dir
        self.recording = False
        self.win = win
        self.out_dir = out_dir
        self.notes = []
        self.posters = []  # (label, path)

    def step(self, n, op, a):
        # While recording, time is the viewer's: no step waits for the
        # frame to settle (a ticking clock never lets it, and each wait
        # was up to 3 s of dead video). Pauses are the flow's own `wait`s.
        if self.recording and op in ("run", "key", "open", "type", "click", "hover", "wait", "until"):
            w = self.win
            if op == "run":
                w.send({"cmd": "run-command", "id": a[0]}, settle=False)
            elif op == "key":
                w.send({"cmd": "key", "key": a[0]}, settle=False)
            elif op == "open":
                w.send({"cmd": "open", "path": a[0]}, settle=False)
            elif op == "type":
                w.send({"cmd": "type", "text": a[0]}, settle=False)
            elif op in ("click", "hover"):
                c = {"cmd": op, "col": int(a[0]), "row": int(a[1])}
                if op == "click":
                    c["button"] = a[2] if len(a) > 2 else "left"
                w.send(c, settle=False)
            elif op == "wait":
                time.sleep(ms(a[0]) / 1000.0)
            elif op == "until":
                t_ms = ms(a[1]) if len(a) > 1 else 3000
                if not w.wait_for(a[0], timeout_ms=t_ms):
                    self.notes.append(f"line {n}: `{a[0]}` never appeared within {t_ms} ms")
            return
        t = to_tour_step(op, a)
        if t is not None:
            tour.play(self.win, [t], self.notes)
            return
        if op == "slowtype":
            # One character at a time, the way a person types: `type`
            # lands a whole string in one frame. `\n` is Enter.
            text = a[0].encode("utf-8").decode("unicode_escape")
            per = ms(a[1]) if len(a) > 1 else 55
            # Appended without waiting for each ack (an ack round trip
            # is ~100 ms, slower than anyone types); the acks are counted
            # once at the end.
            base = self.win._count_acks()
            for ch in text:
                c = {"cmd": "key", "key": "enter"} if ch == "\n" else {"cmd": "type", "text": ch}
                self.win._append([c])
                time.sleep(per / 1000.0)
            deadline = now_ms() + 5000
            while self.win._count_acks() < base + len(text) and now_ms() < deadline:
                time.sleep(0.03)
            if not self.recording:
                self.win.settle(quiet_ms=150, cap_ms=800)
        elif op == "keys":
            # Several chords with a pause between them (a menu walk).
            per = 350
            for spec in a:
                if spec.startswith("@"):
                    per = ms(spec[1:])
                    continue
                self.win.send({"cmd": "key", "key": spec}, settle=False)
                time.sleep(per / 1000.0)
        elif op == "sleep":
            time.sleep(ms(a[0]) / 1000.0)
        elif op == "poster":
            p = os.path.join(self.out_dir, f"poster-{len(self.posters)}.png")
            self.win.settle(quiet_ms=200, cap_ms=1500)
            self.win.shot(p)
            self.posters.append(p)
        elif op == "copy":
            # A file from beside the flow into the workspace.
            src = os.path.join(self.flow_dir, a[0])
            dst = os.path.join(self.win.ws, a[1] if len(a) > 1 else os.path.basename(a[0]))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        elif op == "note":
            log(f"    note: {' '.join(a)}")
        elif op == "shell":
            # A command in the run's workspace (planting a file mid-flow).
            subprocess.run(["/bin/sh", "-c", a[0]], cwd=self.win.ws, check=False,
                           env={"PATH": CLEAN_PATH, "HOME": self.win.home})
        else:
            raise SystemExit(f"line {n}: unknown step `{op}`")


# ─── the watcher: every screen the app wrote while recording ───────────

class Watcher(threading.Thread):
    def __init__(self, win):
        super().__init__(daemon=True)
        self.win = win
        self.stop_ev = threading.Event()
        self.changes = []  # monotonic seconds of each screen.txt change
        self.hits = []
        self.pats = forbidden_patterns()

    def run(self):
        last = None
        while not self.stop_ev.is_set():
            s = self.win.screen()
            if s != last:
                self.changes.append(time.monotonic())
                for p in self.pats:
                    m = p.search(s)
                    if m:
                        a = max(0, s.rfind("\n", 0, m.start()) + 1, m.start() - 70)
                        self.hits.append((p.pattern, s[a:m.end() + 50].replace("\n", " ⏎ ")))
                        dump = os.path.join(self.win.run_dir, f"privacy-hit-{len(self.hits)}.txt")
                        if len(self.hits) <= 3:
                            with open(dump, "w", encoding="utf-8") as f:
                                f.write(s)
                last = s
            time.sleep(0.02)


# ─── the recorder ───────────────────────────────────────────────────────

def swift_bin(name):
    src = os.path.join(HERE, name + ".swift")
    out = os.path.join(REPO, ".verify", "site-record", "bin", name)
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        log(f"site-record: compiling {name}.swift")
        subprocess.run(["swiftc", "-O", "-o", out, src], check=True)
    return out


def winrec_bin():
    return swift_bin("winrec")


def place(win):
    """Move our window where ghostty keeps drawing it (winplace.swift).
    Returns the uncovered fraction; 0 means every spot is covered."""
    r = subprocess.run([swift_bin("winplace"), "--pid", str(win.pid), "--window", str(window_id(win))],
                       capture_output=True, text=True)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])["uncovered"]
    except (ValueError, IndexError, KeyError):
        raise DriveError(f"winplace exited {r.returncode}: {r.stderr.strip()}")


class Placer(threading.Thread):
    """Every 2 s while recording: keep a sliver of our window uncovered
    (someone may move their own windows over it). Moving the window is
    invisible in a window-only capture."""

    def __init__(self, win):
        super().__init__(daemon=True)
        self.win = win
        self.stop_ev = threading.Event()
        self.least = 1.0

    def run(self):
        while not self.stop_ev.wait(2.0):
            try:
                self.least = min(self.least, place(self.win))
            except DriveError:
                pass


def window_id(win):
    with open(os.path.join(win.data_root, "drive.json"), encoding="utf-8") as f:
        d = json.load(f)
    for k in ("window_id", "windowId", "window", "wid"):
        if k in d:
            return int(d[k])
    raise DriveError(f"drive.json has no window id: {sorted(d)}")


def plant_sessions(home, ws, cwd=None):
    """Three earlier agent sessions of this workspace, as transcripts on
    disk — the only thing the sessions views read besides the live
    panes. Stand-in text; no AI runs."""
    enc = re.sub(r"[/.]", "-", ws)
    d = os.path.join(home, ".claude", "projects", enc)
    os.makedirs(d, exist_ok=True)
    # (id, minutes ago, ask, reply, input, output, cache-read tokens):
    # the usage makes the table's TOKENS and COST columns real numbers
    # rather than a row of zeros that reads as empty.
    rows = [
        ("3f9c1a02-5d1e-4c7a-9b20-6e81d4f0a113", 25, "add a max() helper to util.zig", "Added max() with a test for the empty slice.", 18400, 2150, 142000),
        ("a71e0b44-2c93-4f5d-8e1a-0b7c3d9e2f48", 70, "write the 0.1.0 changelog entry", "Drafted CHANGELOG.md from the last five commits.", 9600, 1320, 61000),
        ("c2d86e19-7a4b-4e02-a5f3-91d0c6b8e275", 180, "why does main print nothing for an empty list", "util.sum returns 0; main now prints a message.", 31200, 4870, 288000),
    ]
    now = time.time()
    cwd = cwd or ws
    for sid, age_min, user, reply, tin, tout, tcache in rows:
        p = os.path.join(d, sid + ".jsonl")
        with open(p, "w", encoding="utf-8") as f:
            f.write(json.dumps({"type": "user", "cwd": cwd, "gitBranch": "main",
                                "message": {"role": "user", "content": user}}) + "\n")
            f.write(json.dumps({"type": "assistant", "cwd": cwd, "gitBranch": "main",
                                "message": {"id": "msg_" + sid[:8], "role": "assistant", "model": "claude-sonnet-5",
                                            "usage": {"input_tokens": tin, "output_tokens": tout,
                                                      "cache_read_input_tokens": tcache},
                                            "content": [{"type": "text", "text": reply}]}}) + "\n")
        t = now - age_min * 60
        os.utime(p, (t, t))


def site_config(ws, tree_width=None):
    """The tour's workspace layer, trimmed for a visitor: no clock, no
    LSP chip for servers the fixture machine lacks, the Claude usage
    meter off (it reads a fixture's quota — stock mnml has the chip off),
    and optionally a wider sidebar. The tour's own config (and its pixel
    baselines) are untouched; only this run's copy changes."""
    p = os.path.join(ws, ".mnml", "config.zon")
    with open(p, encoding="utf-8") as f:
        text = f.read()
    ui_extra = "\n        .clock = false,"
    if tree_width:
        ui_extra += f"\n        .tree_width = {int(tree_width)},"
    for old, new in (
        (".editor = .{ .input_style = .standard },",
         ".editor = .{ .input_style = .standard, .lsp_missing_defaults = .ignore },"),
        (".ui = .{", ".ui = .{" + ui_extra),
        ('.label = "Claude Code", .enabled = true,', '.label = "Claude Code", .enabled = false,'),
    ):
        if old not in text:
            raise DriveError(f"site_config: the tour's config no longer has {old!r}")
        text = text.replace(old, new, 1)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)


def encode(mov, webm, width, fps):
    vf = f"fps={fps},scale={width}:-2:flags=lanczos" if width else f"fps={fps}"
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", mov, "-an", "-vf", vf,
           "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-b:v", "0", "-crf", "30",
           "-deadline", "good", "-cpu-used", "2", "-row-mt", "1", "-tile-columns", "2",
           "-g", str(fps * 4), webm]
    subprocess.run(cmd, check=True)


def encode_mp4(mov, mp4, width, fps):
    """The H.264 fallback beside the WebM (Safari before 17.4, some
    webviews): yuv420p, the same size, faststart so it plays while it
    loads."""
    vf = f"fps={fps},scale={width}:-2:flags=lanczos" if width else f"fps={fps}"
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", mov, "-an", "-vf", vf,
           "-c:v", "libx264", "-preset", "slow", "-crf", "23", "-profile:v", "high",
           "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-g", str(fps * 4), mp4]
    subprocess.run(cmd, check=True)


def poster_png(src, dst, width):
    vf = f"scale={width}:-2:flags=lanczos" if width else "null"
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-vf", vf,
                    "-frames:v", "1", "-compression_level", "9", dst], check=True)


def longest_hold(video, seconds):
    """The longest stretch the picture holds still, as a reviewer's
    `freezedetect` (noise 0.001, the default) sees it: one typed
    character is below that noise, so a slow-typed line counts as a
    hold. Returns (seconds, start)."""
    r = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", video, "-vf",
                        "freezedetect=n=0.001:d=0.3", "-map", "0:v", "-f", "null", "-"],
                       capture_output=True, text=True)
    best, at, start = 0.0, 0.0, None
    for m in re.finditer(r"freeze_(start|end): ([0-9.]+)", r.stderr):
        t = float(m.group(2))
        if m.group(1) == "start":
            start = t
        elif start is not None:
            if t - start > best:
                best, at = t - start, start
            start = None
    if start is not None and seconds - start > best:
        best, at = seconds - start, start
    return round(best, 2), round(at, 2)


def frame_times(mov):
    r = subprocess.run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "frame=pts_time", "-of", "csv=p=0", mov], capture_output=True, text=True, check=True)
    return [float(x.strip(",")) for x in r.stdout.split() if x.strip(",").strip()]


def timing_check(mov_times, rec_meta, changes, rec_start, rec_stop):
    """Every screen change mnml wrote must have a frame within 150 ms of
    it (the window was really captured while it moved), and no two
    frames may sit further apart than the screen stayed still."""
    first = rec_meta["first_pts"]
    abs_frames = [first + t for t in mov_times]
    missing = []
    j = 0
    for c in changes:
        if c < rec_start + 0.3 or c > rec_stop - 0.2:
            continue
        while j < len(abs_frames) and abs_frames[j] < c - 0.05:
            j += 1
        if j >= len(abs_frames) or abs_frames[j] - c > 0.15:
            missing.append(round(c - rec_start, 2))
    gaps = [b - a for a, b in zip(mov_times, mov_times[1:])]
    return missing, (max(gaps) if gaps else 0.0)


def record(flow_path, args):
    meta, setup, steps = parse_flow(flow_path)
    name = meta["name"]
    run = os.path.join(REPO, ".verify", "site-record", name)
    if os.path.exists(run):
        shutil.rmtree(run)
    os.makedirs(run)
    # The workspace sits under the app's private HOME, so any path the
    # app abbreviates reads `~/tour`, and none reads the machine's home.
    home = os.path.join(run, "home")
    ws = os.path.join(home, "tour")
    workspace.build(ws, home)
    # `session_cwd:` spells the transcripts' cwd — the sessions table
    # prints it verbatim, and the real one is under the machine's home.
    plant_sessions(home, ws, meta.get("session_cwd"))
    site_config(ws, meta.get("tree_width"))
    # The one-time ghost-text tip is a persistent toast; it is not what
    # any recording is about.
    os.makedirs(os.path.join(home, ".config", "mnml"), exist_ok=True)
    open(os.path.join(home, ".config", "mnml", "ghost-text-hint-shown"), "w").close()
    usage = os.path.join(run, "usage-fixture")
    shutil.copytree(os.path.join(REPO, "docs", "ui-spec", "usage-fixture"), usage)
    fakes = workspace.start_fakes(ws)
    env = workspace.app_env(ws, usage)
    env["PATH"] = SHIMS + ":" + CLEAN_PATH
    # The agents scan sees this app's own children and nothing else on
    # the machine (a process group nobody is in).
    env["MNML_AGENTS_PGID"] = "2147483000"
    if meta.get("session_cwd"):
        env["SITE_RECORD_CWD"] = meta["session_cwd"]
    win = SiteWindow(run, ws, exe=args.exe, cols=COLS, rows=ROWS, app_env=env, app_args=[])
    win.relative_root = meta.get("relative_data_root", "").lower() in ("yes", "true", "1")
    player = Player(win, run, os.path.dirname(flow_path))
    rec_proc = None
    watcher = None
    placer = None
    result = {"name": name}
    try:
        for f in ("jira.url", "bb.url"):
            deadline = now_ms() + 5000
            while not os.path.exists(os.path.join(ws, f)) and now_ms() < deadline:
                time.sleep(0.05)
        win.launch()
        u = place(win)
        if u <= 0:
            raise DriveError("the harness window is covered everywhere on every display — ghostty "
                             "stops drawing a covered window, so the recording would freeze")
        log(f"site-record {name}: window up ({u:.0%} uncovered); setup ({len(setup)} steps)")
        for n, op, a in setup:
            player.step(n, op, a)
        win.settle(quiet_ms=400, cap_ms=3000)
        tour.wait_toasts_gone(win, player.notes)
        win.run("toast.dismiss_all")
        mov = os.path.join(run, "capture.mov")
        rec_proc = subprocess.Popen([winrec_bin(), "--window", str(window_id(win)), "--out", mov,
                                     "--fps", str(meta["fps"])],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True)
        place(win)
        watcher = Watcher(win)
        watcher.start()
        placer = Placer(win)
        placer.start()
        time.sleep(0.6)  # the stream's first frame
        if rec_proc.poll() is not None:
            raise DriveError(f"winrec exited {rec_proc.returncode}: {rec_proc.stderr.read().strip()}")
        rec_start = time.monotonic()
        player.recording = True
        log(f"site-record {name}: recording ({len(steps)} steps)")
        for n, op, a in steps:
            player.step(n, op, a)
        rec_stop = time.monotonic()
        watcher.stop_ev.set()
        placer.stop_ev.set()
        rec_proc.stdin.close()
        out, err = rec_proc.communicate(timeout=60)
        if rec_proc.returncode != 0:
            raise DriveError(f"winrec exited {rec_proc.returncode}: {err.strip()}")
        rec_meta = json.loads(out.strip().splitlines()[-1])
        rec_proc = None
        if not player.posters:
            p = os.path.join(run, "poster-0.png")
            win.shot(p)
            player.posters.append(p)
    finally:
        if watcher:
            watcher.stop_ev.set()
        if placer:
            placer.stop_ev.set()
        if rec_proc and rec_proc.poll() is None:
            rec_proc.send_signal(signal.SIGINT)
            try:
                rec_proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                rec_proc.kill()
        win.quit()
        for p in fakes:
            try:
                p.kill()
            except OSError:
                pass
    # Encode, poster, checks.
    os.makedirs(MEDIA, exist_ok=True)
    webm = os.path.join(MEDIA, name + ".webm")
    png = os.path.join(MEDIA, name + ".png")
    mp4 = os.path.join(MEDIA, name + ".mp4")
    encode(mov, webm, meta["width"], meta["fps"])
    encode_mp4(mov, mp4, meta["width"], meta["fps"])
    poster_png(player.posters[0], png, meta["width"])
    mov_times = frame_times(mov)
    missing, max_gap = timing_check(mov_times, rec_meta, watcher.changes, rec_start, rec_stop)
    poster_txt = tour.read_text(os.path.splitext(player.posters[0])[0] + ".txt")
    for p in forbidden_patterns():
        if p.search(poster_txt):
            watcher.hits.append(("poster: " + p.pattern, ""))
    probe = json.loads(subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration,size:stream=codec_name,width,height,avg_frame_rate,nb_frames",
         "-of", "json", webm], capture_output=True, text=True, check=True).stdout)
    st = probe["streams"][0]
    seconds = round(float(probe["format"]["duration"]), 1)
    hold, hold_at = longest_hold(webm, seconds)
    result.update({
        "title": meta["title"], "seconds": seconds, "flow": meta["flow"],
        "longest_hold_s": hold, "longest_hold_at": hold_at, "mp4_bytes": os.path.getsize(mp4),
        "codec": st.get("codec_name"), "size": f"{st.get('width')}x{st.get('height')}",
        "fps": st.get("avg_frame_rate"), "bytes": int(probe["format"]["size"]),
        "captured": f"{rec_meta['width']}x{rec_meta['height']}", "capture_frames": rec_meta["frames"],
        "screen_changes": len(watcher.changes), "changes_without_a_frame": missing,
        "longest_still_s": round(max_gap, 2), "least_uncovered": placer.least, "privacy_hits": watcher.hits, "notes": player.notes,
    })
    with open(os.path.join(run, "result.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    update_media_json(result)
    if not args.keep_mov:
        os.unlink(mov)
    log(f"site-record {name}: {seconds}s {result['size']} {result['codec']} {result['bytes'] // 1024} KB, "
        f"{rec_meta['frames']} captured frames, {len(watcher.changes)} screen changes, "
        f"{len(missing)} without a frame, longest still {result['longest_still_s']}s, "
        f"longest hold {hold}s at {hold_at}s, mp4 {result['mp4_bytes'] // 1024} KB")
    if player.notes:
        log("  notes: " + "; ".join(player.notes))
    if watcher.hits:
        log(f"  PRIVACY: {len(watcher.hits)} hit(s): {watcher.hits[:5]}")
        return 1
    return 0


def update_media_json(result):
    try:
        with open(MEDIA_JSON, encoding="utf-8") as f:
            items = json.load(f)
    except (OSError, ValueError):
        items = []
    items = [i for i in items if i.get("name") != result["name"]]
    items.append({k: result[k] for k in ("name", "title", "seconds", "flow")})
    order = ["hero", "palette", "splits", "git", "terminal", "sessions", "lua", "jira", "marketplace"]
    items.sort(key=lambda i: (order.index(i["name"]) if i["name"] in order else len(order), i["name"]))
    os.makedirs(os.path.dirname(MEDIA_JSON), exist_ok=True)
    with open(MEDIA_JSON, "w", encoding="utf-8") as f:
        json.dump(items, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main(argv):
    ap = argparse.ArgumentParser(prog="site-record.sh")
    ap.add_argument("flows", nargs="+", help="FLOW files (tools/site-record/flows/*.flow)")
    ap.add_argument("--exe", help="the mnml-zig binary (default zig-out/bin/mnml-zig)")
    ap.add_argument("--keep-mov", action="store_true", help="keep the full-resolution capture.mov")
    args = ap.parse_args(argv)
    if not args.exe:
        stamp.warn_app("site-record")
    rc = 0
    for fl in args.flows:
        rc |= record(os.path.abspath(fl), args)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
