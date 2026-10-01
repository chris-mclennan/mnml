#!/usr/bin/env python3
"""The web demo's attract runner: the one process the container runs.

It does four things, all in this file, all stdlib:

  * starts ttyd on a private unix socket, one `session.sh` (a real
    `mnml --demo`) per websocket connection, one connection at a time;
  * serves the page on MNML_DEMO_PORT: `/` (demo/web/index.html: the
    window frame, the controls, and the terminal — xterm.js speaking
    ttyd's websocket protocol), `/vendor/*` (xterm.js), `/fonts/*`, a
    small JSON API under `/api/`, and every other path (`/term/token`,
    `/term/ws`) passed through to ttyd byte for byte — the websocket
    included;
  * plays the tour: the flows in demo/flows/ (the site recorder's flow
    format) as lines appended to mnml's IPC `command` file;
  * watches mnml's `events.jsonl` for `{"event":"input"}` — written by
    the app itself when the person at the terminal presses a key, clicks,
    scrolls or pastes (`ipc.report_input`, on in kiosk.zon) and never for
    the runner's own channel input — and stops the tour at that moment.
    After MNML_DEMO_IDLE_S without input the tour resumes; after
    MNML_DEMO_CAP_S the session ends.

Python because the job is files, sockets and a clock: no build step, no
second toolchain in the image, and the recorder it borrows its flow
format from is Python too.
"""

import glob
import html
import json
import os
import re
import selectors
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FLOWS = os.environ.get("MNML_DEMO_FLOWS", os.path.join(ROOT, "flows"))
WEB = os.environ.get("MNML_DEMO_WEB", os.path.join(ROOT, "web"))
PORT = int(os.environ.get("MNML_DEMO_PORT", "7681"))
CAP_S = float(os.environ.get("MNML_DEMO_CAP_S", "600"))
IDLE_S = float(os.environ.get("MNML_DEMO_IDLE_S", "180"))
IPC = os.environ.get("MNML_IPC_DIR", "/tmp/mnml-demo/ipc")
# /tmp/mnml-demo: the session marker, ttyd's socket, and one IPC directory
# per session (ipc-<session.sh pid>, made by session.sh).
STATE = os.path.dirname(IPC)
TTYD_SOCK = os.path.join(STATE, "ttyd.sock")
# ttyd answers under this path: its page, /term/token, /term/ws.
BASE = "/term"
SESSION_MARK = os.path.join(STATE, "session")
ENDED_MARK = os.path.join(STATE, "ended")
EXITED_MARK = os.path.join(STATE, "exited")
# Input this soon after the session started is the terminal answering
# the app's startup queries, not a visitor.
STARTUP_GRACE_S = 4.0
# The order the site shows them in; a flow not listed plays after these.
ORDER = ["hero", "palette", "splits", "git", "terminal", "sessions", "lua", "jira"]


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, file=sys.stderr, flush=True)


# ─── flows ───────────────────────────────────────────────────────────────

def parse_flow(path):
    meta = {"name": os.path.splitext(os.path.basename(path))[0], "title": "", "flow": ""}
    steps = []
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = re.match(r"^(title|flow):\s*(.*)$", line)
            if m:
                meta[m.group(1)] = m.group(2).strip()
                continue
            toks = shlex.split(line)
            steps.append((n, toks[0], toks[1:]))
    return meta, steps


def load_flows():
    out = []
    for p in glob.glob(os.path.join(FLOWS, "*.flow")):
        meta, steps = parse_flow(p)
        meta["steps"] = steps
        out.append(meta)
    out.sort(key=lambda m: (ORDER.index(m["name"]) if m["name"] in ORDER else len(ORDER), m["name"]))
    return out


class Stopped(Exception):
    pass


# ─── the app, through its file channel ───────────────────────────────────

class App:
    """mnml's IPC directory: append to `command`, read the rest."""

    def __init__(self, ipc):
        self.ipc = ipc

    def send(self, *cmds):
        data = "".join(json.dumps(c, ensure_ascii=False) + "\n" for c in cmds)
        with open(os.path.join(self.ipc, "command"), "a", encoding="utf-8") as f:
            f.write(data)

    def screen(self):
        try:
            with open(os.path.join(self.ipc, "screen.txt"), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def status(self):
        try:
            with open(os.path.join(self.ipc, "status.json"), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}


def find_text(screen, text, row=None):
    for y, line in enumerate(screen.split("\n")):
        if row is not None and y != row:
            continue
        x = line.find(text)
        if x >= 0:
            return x, y
    return None


def workspace():
    """The demo's workspace: `<sandbox>/tour`, the one sandbox here."""
    hits = sorted(glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "mnml-sandbox-*", "tour")),
                  key=os.path.getmtime)
    return hits[-1] if hits else None


class Player:
    """Plays flows until stopped. Every wait checks the stop flag, so a
    visitor's key stops the tour within one poll (50 ms), mid-step."""

    def __init__(self, app, stop):
        self.app = app
        self.stop = stop
        self.notes = []

    def sleep(self, ms):
        if self.stop.wait(ms / 1000.0):
            raise Stopped()

    def check(self):
        if self.stop.is_set():
            raise Stopped()

    def until(self, text, ms=3000):
        deadline = time.monotonic() + ms / 1000.0
        while time.monotonic() < deadline:
            if text in self.app.screen():
                return True
            self.sleep(50)
        self.notes.append(f"`{text}` never appeared within {ms} ms")
        return False

    def reset(self):
        """Back to the start surface (the tour's own `reset`): overlays
        shut, every split and buffer closed, the explorer showing."""
        self.app.send({"cmd": "key", "key": "esc"}, {"cmd": "key", "key": "esc"})
        self.sleep(150)
        for _ in range(8):
            if not self.app.status().get("panes"):
                break
            self.app.send({"cmd": "run-command", "id": "view.only"},
                          {"cmd": "run-command", "id": "view.close_others"},
                          {"cmd": "run-command", "id": "buffer.close"})
            self.sleep(250)
        self.app.send({"cmd": "run-command", "id": "view.activity_explorer"})
        self.app.send({"cmd": "run-command", "id": "toast.dismiss_all"})
        self.sleep(300)

    def play(self, flow):
        for _n, op, a in flow["steps"]:
            self.check()
            self.step(op, a)

    def step(self, op, a):
        app = self.app
        if op == "reset":
            self.reset()
        elif op == "home":
            self.home()
        elif op == "run":
            app.send({"cmd": "run-command", "id": a[0]})
        elif op == "key":
            app.send({"cmd": "key", "key": a[0]})
        elif op == "type":
            app.send({"cmd": "type", "text": a[0]})
        elif op == "open":
            # mnml resolves `open` against its own cwd (the sandbox home),
            # the recorder's app ran in the workspace: spell it absolute.
            ws = workspace()
            path = a[0] if os.path.isabs(a[0]) or not ws else os.path.join(ws, a[0])
            app.send({"cmd": "open", "path": path})
        elif op in ("click", "hover"):
            c = {"cmd": op, "col": int(a[0]), "row": int(a[1])}
            if op == "click":
                c["button"] = a[2] if len(a) > 2 else "left"
            app.send(c)
        elif op in ("wait", "sleep"):
            self.sleep(int(float(a[0])))
        elif op == "until":
            self.until(a[0], int(float(a[1])) if len(a) > 1 else 3000)
        elif op == "heal":
            bad, key, good = a[0], a[1], a[2]
            for _ in range(3):
                if bad not in app.screen():
                    break
                app.send({"cmd": "key", "key": key})
                self.until(good, 8000)
        elif op == "find-click":
            at = find_text(app.screen(), a[0], int(a[1]) if len(a) > 1 else None)
            if at:
                app.send({"cmd": "click", "col": at[0], "row": at[1], "button": "left"})
            else:
                self.notes.append(f"`{a[0]}` not on screen to click")
        elif op == "slowtype":
            text = a[0].encode("utf-8").decode("unicode_escape")
            per = int(float(a[1])) if len(a) > 1 else 55
            for ch in text:
                app.send({"cmd": "key", "key": "enter"} if ch == "\n" else {"cmd": "type", "text": ch})
                self.sleep(per)
        elif op == "keys":
            per = 350
            for spec in a:
                if spec.startswith("@"):
                    per = int(float(spec[1:]))
                    continue
                app.send({"cmd": "key", "key": spec})
                self.sleep(per)
        elif op == "copy":
            ws = workspace()
            if ws:
                dst = os.path.join(ws, a[1] if len(a) > 1 else os.path.basename(a[0]))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(FLOWS, a[0]), dst)
        else:
            self.notes.append(f"unknown step `{op}`")

    def home(self):
        """The demo's first screen — util.zig, a Claude Code session on the
        right, a shell under it (the demo's init.lua) — rebuilt when it is
        not what is showing."""
        s = self.app.screen()
        if "pub fn sum" in s and "tour %" in s and "Both tests pass." in s and len(self.app.status().get("panes", [])) <= 3:
            return
        self.reset()
        self.step("open", ["src/util.zig"])
        self.until("pub fn sum", 4000)
        self.app.send({"cmd": "run-command", "id": "ai.claude_code_new_right"})
        self.until("Both tests pass.", 12000)
        self.app.send({"cmd": "run-command", "id": "term.shell_bottom"})
        self.until("tour %", 6000)
        self.sleep(400)


# ─── the session: one visitor's mnml ─────────────────────────────────────

class Session:
    """Phases: idle (no visitor) → starting → tour ⇄ live → ended."""

    BANNER_ID = "web-demo-tour"

    def __init__(self):
        self.flows = load_flows()
        self.app = App(IPC)  # replaced per session (new_session)
        self.lock = threading.RLock()
        self.phase = "idle"
        self.flow = None
        self.started = 0.0
        self.last_input = 0.0
        self.mark_mtime = None
        self.ev_offset = 0
        self.player_thread = None
        self.stop_ev = threading.Event()
        self.inputs = 0

    def state(self):
        with self.lock:
            now = time.monotonic()
            left = max(0.0, CAP_S - (now - self.started)) if self.started else CAP_S
            idle_left = max(0.0, IDLE_S - (now - self.last_input)) if self.phase == "live" else None
            return {"phase": self.phase, "flow": self.flow, "cap_s": CAP_S, "remaining_s": round(left),
                    "idle_s": IDLE_S, "resume_in_s": None if idle_left is None else round(idle_left),
                    "inputs": self.inputs,
                    "flows": [{"name": f["name"], "title": f["title"], "flow": f["flow"]} for f in self.flows]}

    # ── the tour ──
    def start_tour(self, names=None, why=""):
        with self.lock:
            if self.phase in ("idle", "ended"):
                return False
            self.stop_player()
            self.stop_ev = threading.Event()
            self.phase = "tour"
            self.last_input = time.monotonic()
            seq = [f for f in self.flows if names is None or f["name"] in names]
            log(f"tour: {', '.join(f['name'] for f in seq)}{' (' + why + ')' if why else ''}")
            t = threading.Thread(target=self.run_tour, args=(seq, self.stop_ev, names is None), daemon=True)
            self.player_thread = t
            t.start()
            return True

    def stop_player(self):
        # Not joined: the player checks its flag before every line it
        # sends and at every wait, and leaves on its own.
        self.stop_ev.set()
        self.player_thread = None

    def run_tour(self, seq, stop, loop):
        p = Player(self.app, stop)
        first = True
        try:
            while True:
                for f in seq:
                    with self.lock:
                        if stop.is_set():
                            return
                        self.flow = f["name"]
                    self.banner(f["title"])
                    if not first:
                        p.sleep(1200)
                    first = False
                    p.play(f)
                    if p.notes:
                        log(f"flow {f['name']}: " + "; ".join(p.notes))
                        p.notes.clear()
                    p.sleep(2500)
                if not loop:
                    break
        except Stopped:
            return
        except Exception as e:  # a broken flow must not take the server down
            log(f"tour: {type(e).__name__}: {e}")
        with self.lock:
            if self.phase == "tour" and not stop.is_set():
                # A single flow picked from the page ends with the app
                # live: the visitor carries on from there.
                self.phase = "live"
                self.last_input = time.monotonic()
                self.flow = None
        self.unbanner()

    def banner(self, title):
        text = f"▶ Guided tour: {title} — press any key or click to take over"
        self.app.send({"cmd": "statusline-set-segment", "id": self.BANNER_ID, "text": text,
                       "side": "left", "priority": 255, "max_width": len(text) + 2, "min_width": 10})

    def unbanner(self):
        self.app.send({"cmd": "statusline-clear-segment", "id": self.BANNER_ID})

    def take_over(self, how):
        """The visitor touched it: the tour stops where it is."""
        with self.lock:
            self.inputs += 1
            self.last_input = time.monotonic()
            if self.phase != "tour":
                return
            if how != "page" and time.monotonic() - self.started < STARTUP_GRACE_S:
                # xterm.js answers the app's startup queries (cursor
                # position, modes); a late `ESC[1;1R` reads as F3. Nobody
                # has typed in the first seconds of a session.
                log(f"input ({how}) in the first {STARTUP_GRACE_S:.0f} s: ignored")
                return
            log(f"input ({how}): tour stopped in {self.flow}")
            self.phase = "live"
            self.flow = None
            self.stop_player()
        self.unbanner()

    # ── the watcher: the session marker, events.jsonl, the clocks ──
    def watch(self):
        while True:
            time.sleep(0.05)
            try:
                self.watch_once()
            except Exception as e:
                log(f"watch: {type(e).__name__}: {e}")

    def watch_once(self):
        try:
            m = os.stat(SESSION_MARK).st_mtime
        except OSError:
            m = None
        if m is not None and m != self.mark_mtime:
            self.mark_mtime = m
            self.new_session()
        self.read_events()
        if self.session_exited() or not self.visitor_alive():
            with self.lock:
                if self.phase not in ("ended", "idle"):
                    code = self.session_exited() or "?"
                    log(f"session: mnml exited ({code}) in {self.flow or self.phase}" if code != "?" else
                        f"session: the visitor left (ttyd ended the session) in {self.flow or self.phase}")
                    self.stop_player()
                    self.phase = "idle"
                    self.flow = None
                    self.started = 0.0
        now = time.monotonic()
        with self.lock:
            phase = self.phase
            if phase in ("starting", "tour", "live") and self.started and now - self.started >= CAP_S:
                self.end()
            elif phase == "starting" and now - self.started > 1.0 and "tour %" in self.app.screen():
                self.start_tour(why="session start")
            elif phase == "starting" and now - self.started > 25:
                self.start_tour(why="first screen never settled")
            elif phase == "live" and now - self.last_input >= IDLE_S:
                self.start_tour(why=f"idle {int(IDLE_S)} s")

    def session_exited(self):
        """The exit status session.sh wrote for the CURRENT session (an
        older session hung up by a reload writes its own pid), or None."""
        try:
            pid, code = open(EXITED_MARK).read().split()
            cur = open(SESSION_MARK).read().strip()
        except (OSError, ValueError):
            return None
        return code if pid == cur else None

    def visitor_alive(self):
        """session.sh's pid is in the marker; ttyd ends it (SIGHUP) when the
        visitor's websocket closes."""
        try:
            pid = int(open(SESSION_MARK).read().strip())
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            return False

    def new_session(self):
        try:
            pid = open(SESSION_MARK).read().strip()
        except OSError:
            pid = ""
        with self.lock:
            self.stop_player()
            self.app = App(os.path.join(STATE, f"ipc-{pid}"))
            self.phase = "starting"
            self.started = time.monotonic()
            self.last_input = self.started
            self.ev_offset = 0
            self.flow = None
            self.inputs = 0
        log("session: a visitor connected; mnml --demo starting")

    def read_events(self):
        p = os.path.join(self.app.ipc, "events.jsonl")
        try:
            size = os.path.getsize(p)
        except OSError:
            return
        if size < self.ev_offset:
            self.ev_offset = 0  # the channel was truncated: a new mnml
        if size == self.ev_offset:
            return
        with open(p, "rb") as f:
            f.seek(self.ev_offset)
            data = f.read()
        end = data.rfind(b"\n")
        if end < 0:
            return
        self.ev_offset += end + 1
        for line in data[:end].split(b"\n"):
            if b'"event":"input"' in line:
                m = re.search(rb'"kind":"(\w+)"', line)
                self.take_over(m.group(1).decode() if m else "?")
            elif line.startswith(b'{"event":"exit"'):
                with self.lock:
                    if self.phase not in ("ended", "idle"):
                        log("session: mnml exited")
                        self.stop_player()
                        self.phase = "idle"
                        self.flow = None
                        self.started = 0.0

    def end(self):
        """The cap: the tour stops, the app quits the way a person's quit
        does (the sandbox removed), and `session.sh` paints the last
        screen."""
        log(f"session: the {int(CAP_S)} s cap; ending")
        self.stop_player()
        self.phase = "ended"
        open(ENDED_MARK, "w").close()
        self.unbanner()
        self.app.send({"cmd": "quit"})


# ─── HTTP: the page, the fonts, the API, and ttyd behind them ────────────

SESSION = None
LIVE_WS = {"lock": threading.Lock(), "pair": None}
FONT_TYPES = {".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".txt": "text/plain"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mnml-demo"

    def log_message(self, fmt, *args):
        pass

    def send_body(self, code, body, ctype, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, obj, code=200):
        self.send_body(code, json.dumps(obj), "application/json", {"Cache-Control": "no-store"})

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            with open(os.path.join(WEB, "index.html"), encoding="utf-8") as f:
                page = f.read()
            # The app's own start-page wordmark (src/ui/welcome.zig `logo`,
            # extracted at image build into web/wordmark.txt).
            try:
                with open(os.path.join(WEB, "wordmark.txt"), encoding="utf-8") as f:
                    mark = html.escape(f.read().rstrip("\n"))
            except OSError:
                mark = ""
            page = page.replace("<!-- WORDMARK -->", mark, 1)
            return self.send_body(200, page, "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if u.path == "/favicon.ico":
            return self.send_body(204, b"", "image/x-icon")
        if u.path.startswith("/vendor/"):
            # xterm.js and two of its addons, fetched at image build time.
            name = os.path.basename(u.path)
            p = os.path.join(WEB, "vendor", name)
            if not os.path.isfile(p):
                return self.send_body(404, "not here", "text/plain")
            with open(p, "rb") as f:
                data = f.read()
            ctype = "text/css" if name.endswith(".css") else "text/javascript"
            return self.send_body(200, data, ctype, {"Cache-Control": "public, max-age=86400"})
        if u.path.startswith("/fonts/"):
            name = os.path.basename(u.path)
            p = os.path.join(WEB, "fonts", name)
            if not os.path.isfile(p):
                return self.send_body(404, "no such font", "text/plain")
            with open(p, "rb") as f:
                data = f.read()
            ctype = FONT_TYPES.get(os.path.splitext(name)[1], "application/octet-stream")
            return self.send_body(200, data, ctype, {"Cache-Control": "public, max-age=86400"})
        if u.path == "/api/state":
            return self.json(SESSION.state())
        return self.proxy()

    def do_POST(self):
        u = urlparse(self.path)
        if not u.path.startswith("/api/"):
            return self.proxy()
        q = parse_qs(u.query)
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        if u.path == "/api/replay":
            return self.json({"ok": SESSION.start_tour(why="replay")})
        if u.path == "/api/play":
            want = (q.get("flow") or [""])[0]
            names = [f["name"] for f in SESSION.flows]
            if want.isdigit() and 0 <= int(want) < len(names):
                want = names[int(want)]
            if want not in names:
                return self.json({"ok": False, "error": f"no flow {want!r}", "flows": names}, 404)
            return self.json({"ok": SESSION.start_tour([want], why="picked")})
        if u.path == "/api/stop":
            SESSION.take_over("page")
            return self.json({"ok": True})
        return self.json({"ok": False, "error": "unknown"}, 404)

    def proxy(self):
        """Everything else is ttyd's: the request is re-sent over its
        socket and the two connections are spliced until either closes —
        an HTTP exchange or the terminal's whole websocket."""
        try:
            up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            up.connect(TTYD_SOCK)
        except OSError:
            return self.send_body(503, "the terminal is not up yet", "text/plain")
        upgrade = "upgrade" in (self.headers.get("Connection") or "").lower()
        head = f"{self.command} {self.path} HTTP/1.1\r\n"
        for k, v in self.headers.items():
            if not upgrade and k.lower() == "connection":
                continue
            head += f"{k}: {v}\r\n"
        if not upgrade:
            head += "Connection: close\r\n"
        up.sendall(head.encode("latin-1") + b"\r\n")
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            up.sendall(self.rfile.read(n))
        self.close_connection = True
        down = self.connection
        if upgrade:
            # One terminal per container, and the newest page wins: a
            # reload (or a second tab) ends the older websocket, so ttyd
            # hangs up the older session, instead of the new page waiting
            # forever behind a full slot.
            with LIVE_WS["lock"]:
                old = LIVE_WS["pair"]
                LIVE_WS["pair"] = (down, up)
            if old:
                for sk in old:
                    try:
                        sk.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        sel = selectors.DefaultSelector()
        sel.register(down, selectors.EVENT_READ, up)
        sel.register(up, selectors.EVENT_READ, down)
        try:
            while True:
                for key, _ in sel.select():
                    data = key.fileobj.recv(65536)
                    if not data:
                        return
                    key.data.sendall(data)
        except OSError:
            pass
        finally:
            sel.close()
            up.close()


class UnixHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        self.socket.bind(self.server_address)
        self.server_name, self.server_port = "localhost", PORT

    def get_request(self):
        sock, _ = self.socket.accept()
        return sock, ("relay", 0)


# ─── main ────────────────────────────────────────────────────────────────

def start_ttyd():
    os.makedirs(IPC, exist_ok=True)
    try:
        os.unlink(TTYD_SOCK)
    except OSError:
        pass
    argv = ["ttyd", "--interface", TTYD_SOCK, "--base-path", BASE, "--writable",
            "--terminal-type", "xterm-256color", "--ping-interval", "20"]
    argv += [os.path.join(HERE, "session.sh")]
    log("ttyd: " + " ".join(shlex.quote(a) for a in argv))
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL)
    for _ in range(100):
        if os.path.exists(TTYD_SOCK):
            break
        time.sleep(0.05)
    return p


def main():
    global SESSION
    SESSION = Session()
    ttyd = start_ttyd()

    def bye(sig, _frm):
        log(f"signal {sig}: stopping ttyd")
        ttyd.terminate()
        try:
            ttyd.wait(timeout=5)
        except subprocess.TimeoutExpired:
            ttyd.kill()
        os._exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    threading.Thread(target=SESSION.watch, daemon=True).start()
    listen = os.environ.get("MNML_DEMO_LISTEN", "")
    if listen.startswith("unix:"):
        # `--network none` (demo/run-local.sh): a socket for relay.py.
        path = listen[len("unix:"):]
        try:
            os.unlink(path)
        except OSError:
            pass
        srv = UnixHTTPServer(path, Handler)
        os.chmod(path, 0o666)
        where = path
    else:
        srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
        where = f":{PORT}"
    srv.daemon_threads = True
    log(f"web demo on {where}: cap {int(CAP_S)} s, idle {int(IDLE_S)} s, {len(SESSION.flows)} flows")
    srv.serve_forever()


if __name__ == "__main__":
    main()
