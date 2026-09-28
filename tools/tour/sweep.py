"""The corpus sweep: every `tests/e2e/**/*.test` run through the REAL
window, its last frame shot.

Coverage without authoring. The headless corpus already says what each
file's screen should contain; this puts the same steps through a real
ghostty window, via the file channel, and keeps a picture of where each
one ends. A reviewer (or a diff against last night's pictures) sees
what the grid cannot: glyphs as drawn, faded colours, the terminal's
own reflow.

The `.test` vocabulary maps onto the channel: `open` / `key` / `type` /
`command` / `ex` / `ghost` / `click` / `rightclick` / `doubleclick` /
`hover` / `scroll` / `drag` become IPC lines; `write` and `shell` run
here, in the file's workspace and environment (built the way
`src/e2e/runner.zig` builds it); `serve` binds a stdlib HTTP server at
the file's start; `wait` sleeps. An `expect` is not asserted — the
sweep judges nothing — but a `screen` / `status` one is used as a SOFT
WAIT: the script pauses until it holds (up to its `within` budget, or
`--soft-wait`), so a step that waits on a slow pane gets to see it.
One that never holds is counted: the file's `soft misses` are where the
real window and the headless grid disagree.

Serialized (one window), resumable (a file with a shot is skipped
unless `--all`), tolerant (a file that errors is logged and the sweep
goes on).
"""

import http.server
import json
import os
import re
import shutil
import signal
import socketserver
import subprocess
import threading
import time

import imgdiff
from mnmlwin import REPO, DriveError, Window, now_ms

E2E = os.path.join(REPO, "tests", "e2e")
BIN = os.path.join(REPO, "zig-out", "bin")


def log(msg):
    print(msg, flush=True)


# ─── the .test grammar (src/e2e/parser.zig) ────────────────────────────

def unescape(s):
    """One optional layer of quotes; `\\n \\t \\\\ \\"` unescaped, any
    other escape keeps its backslash (parser.zig `unescape`)."""
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        i += 1
        if i >= len(s):
            out.append("\\")
            break
        e = s[i]
        out.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"'}.get(e, "\\" + e))
        i += 1
    return "".join(out)


def split1(s):
    s = s.strip()
    parts = s.split(None, 1)
    if not parts:
        return "", ""
    return parts[0], (parts[1] if len(parts) > 1 else "")


def parse_header(text):
    h = {"env": [], "ascii": False, "width": None, "height": None, "requires": [], "shared_data_root": False}
    for raw in text.split("\n"):
        line = raw.strip()
        if not line:
            continue
        if not line.startswith("#"):
            break
        body = line[1:].strip()
        if body == "ascii":
            h["ascii"] = True
        elif body == "shared-data-root":
            h["shared_data_root"] = True
        elif body.startswith("env:"):
            kv = body[4:].strip()
            if "=" in kv:
                k, v = kv.split("=", 1)
                h["env"].append((k.strip(), v.strip()))
        elif body.startswith("width:"):
            h["width"] = int(body[6:].strip())
        elif body.startswith("height:"):
            h["height"] = int(body[7:].strip())
        elif body.startswith("requires:"):
            h["requires"].append(body[9:].strip())
    return h


def parse_steps(text):
    steps = []
    for ln, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        head, rest = split1(line)
        steps.append((ln, head, rest))
    return steps


def coalesce_clicks(steps):
    """A run of identical `click X Y` lines is ONE burst of presses.

    The corpus writes a double-click on a list row as two `click` lines
    (the git palette's rows, the stash row) — in the runner they are
    back-to-back steps, milliseconds apart, well inside the App's
    `double_click_ms` (450, `app.zig`), so `dispatch.clickCount` counts
    two. Here every step is paced (the frame settles for 150 ms of quiet
    or up to 1.2 s), and the channel is polled every 200 ms
    (`tui/loop.zig` `ipc_poll_ms`), so the second press landed past the
    window and counted as a first press again: the row was selected,
    never activated. So the run goes out as one append, the way
    `doubleclick` already does — `("clicks", "X Y N", ...)`."""
    out = []
    for ln, head, rest in steps:
        if head == "click" and out and out[-1][1] in ("click", "clicks") and out[-1][3] == rest:
            pln, _, prest, _, n = out[-1]
            out[-1] = (pln, "clicks", prest, rest, n + 1)
            continue
        out.append((ln, head, rest, rest if head == "click" else None, 1))
    return [(ln, head, f"{rest} {n}" if head == "clicks" else rest) for ln, head, rest, _, n in out]


def expand(value, env):
    def sub(m):
        name = m.group(1) or m.group(2)
        return env.get(name, "")
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", sub, value)


# ─── serve ─────────────────────────────────────────────────────────────

class _Serve:
    def __init__(self):
        self.status = 200
        self.delay_ms = 0
        self.text = ""
        self.live = False

    def respond(self, handler):
        if not self.live:
            handler.send_response(503)
            handler.end_headers()
            return
        length = int(handler.headers.get("Content-Length") or 0)
        body_in = handler.rfile.read(length) if length else b""
        if self.text == "@echo":
            lines = [f"{handler.command} {handler.path} {handler.request_version}"]
            lines += [f"{k}: {v}" for k, v in handler.headers.items()]
            payload = ("\n".join(lines) + "\n\n").encode() + body_in
            headers = [("Content-Type", "text/plain")]
        else:
            headers, payload = [], self.text
            if "\n\n" in self.text:
                top, rest = self.text.split("\n\n", 1)
                if all(re.match(r"^[A-Za-z0-9-]+: ", ln) for ln in top.split("\n")):
                    headers = [tuple(ln.split(": ", 1)) for ln in top.split("\n")]
                    payload = rest
            payload = payload.encode()
        handler.send_response(self.status)
        for k, v in headers:
            handler.send_header(k, v)
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        if self.delay_ms:
            time.sleep(self.delay_ms / 1000.0)
        try:
            handler.wfile.write(payload)
        except OSError:
            pass


def start_server(spec):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _any(self):
            spec.respond(self)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _any

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    srv = Server(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# ─── one file ──────────────────────────────────────────────────────────

def shot_name(path):
    rel = os.path.relpath(path, E2E)
    return rel[:-len(".test")].replace(os.sep, "__")


def runner_exports():
    """What `mnml-zig test` exports for the scripts (runner.zig
    `kept_vars`): the fakes and helpers beside the exe."""
    return {
        "MNML_SHIMS": os.path.join(REPO, "tools", "shims"),
        "MNML_LAUNCHERS": os.path.join(REPO, "launchers"),
        "MNML_REPO": REPO,
        "MNML_FAKE_DAP": os.path.join(BIN, "mnml-fake-dap"),
        "MNML_FAKE_LSP": os.path.join(BIN, "mnml-fake-lsp"),
        "MNML_FAKE_COPILOT": os.path.join(BIN, "mnml-fake-copilot"),
        "MNML_SAMPLE_INTEGRATION": os.path.join(BIN, "mnml-sample"),
        "MNML_BITBUCKET_INTEGRATION": os.path.join(BIN, "mnml-bitbucket"),
        "MNML_FAKE_BITBUCKET": os.path.join(BIN, "mnml-fake-bitbucket"),
        "MNML_JIRA": os.path.join(BIN, "mnml-jira"),
        "MNML_FAKE_JIRA": os.path.join(BIN, "mnml-fake-jira"),
    }


class FileRun:
    def __init__(self, path, out, args, tmp_root):
        self.path = path
        self.name = shot_name(path)
        self.out = out
        self.args = args
        self.run_dir = os.path.join(tmp_root, self.name)
        self.ws = os.path.join(self.run_dir, "ws")
        self.soft_misses = []
        self.notes = []
        self.servers = []
        self.leader = None
        self.win = None
        self.tmp_root = tmp_root

    # The file's process group: every `shell` step joins it, the file's
    # end kills it — nothing a file starts outlives it (runner.zig).
    def start_group(self):
        # A group of its own in THIS session: a `shell` step can only
        # join a group of its own session (setpgid refuses across).
        self.leader = subprocess.Popen(["/bin/sleep", "100000"], preexec_fn=os.setpgrp,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def end_group(self):
        if self.leader:
            try:
                os.killpg(self.leader.pid, signal.SIGKILL)
            except OSError:
                pass
            self.leader.wait()
            self.leader = None

    def build_env(self, header):
        data_root = os.path.join(self.run_dir, "data")
        env = dict(runner_exports())
        env.update({
            "MNML_E2E_WORKSPACE": self.ws,
            "GIT_CEILING_DIRECTORIES": self.tmp_root,
            "JIRA_RATELIMIT_STATE": os.path.join(data_root, "JIRA-ratelimit.json"),
            "BITBUCKET_RATELIMIT_STATE": os.path.join(data_root, "BITBUCKET-ratelimit.json"),
            "MNML_AGENTS_PGID": str(self.leader.pid),
            # No usage reader reaches the keychain or the wire: an empty
            # fixture is the not-linked state (a file sets its own).
            "MNML_CLAUDE_USAGE_FIXTURE": os.path.join(self.run_dir, "no-usage"),
        })
        # The SESSIONS scan reads the file's data root unless the file
        # names a HOME to seed (then that HOME, as the runner leaves it).
        names_home = any(k == "HOME" for k, _ in header["env"])
        env["MNML_SESSIONS_HOME"] = "" if names_home else data_root
        for i, srv in enumerate(self.servers, 1):
            env["SERVE_PORT" if i == 1 else f"SERVE_PORT_{i}"] = str(srv[0].server_address[1])
        # `# env:` values expand against the run's environment as the
        # runner's do: the shell-visible base plus what came before.
        from mnmlwin import base_env
        base = base_env(os.path.join(self.run_dir, "home"), os.path.join(self.run_dir, "tmp"))
        scope = dict(base)
        scope.update(env)
        for k, v in header["env"]:
            val = expand(v, scope)
            env[k] = val
            scope[k] = val
        # `$MNML_DATA_ROOT` in a `shell` step is where the APP reads —
        # the runner exports the file's own root. The driver starts the
        # app with `MNML_DATA_ROOT=<run>/data` under `MNML_PROFILE=dev`,
        # which the app resolves to `<run>/data-dev`; a shell that wrote
        # to `<run>/data` was writing where nothing reads (the REQUESTS
        # view found no files). Shell scope only: the app's own comes
        # through the driver, and a second copy would suffix it twice.
        scope["MNML_DATA_ROOT"] = data_root + "-dev"
        self.shell_env = scope
        return env

    def run(self):
        try:
            text = open(self.path, encoding="utf-8").read()
        except UnicodeDecodeError:
            # The script holds bytes that are not text on purpose (an
            # invalid-UTF-8 fixture); the channel carries JSON text, so
            # the real window cannot be fed them. Headless covers these.
            return "skip", "script is not UTF-8 (a raw-byte fixture); headless only"
        header = parse_header(text)
        for req in header["requires"]:
            if req in ("network", "linux", "windows"):
                return "skip", f"requires: {req}"
        # `serve 0` servers are bound before the App, as the runner does,
        # and `${SERVE_PORT}` / `${SERVE_PORT_<n>}` name them anywhere in
        # the file — steps as well as `# env:` lines.
        n_serve = sum(1 for _, head, _ in parse_steps(text) if head == "serve")
        specs = []
        for _ in range(n_serve):
            spec = _Serve()
            specs.append((start_server(spec), spec))
        for i in range(n_serve, 0, -1):
            port = str(specs[i - 1][0].server_address[1])
            text = text.replace("${SERVE_PORT_%d}" % i, port)
            if i == 1:
                text = text.replace("${SERVE_PORT}", port)
        header = parse_header(text)
        steps = parse_steps(text)
        serve_lines = [ln for ln, head, _ in steps if head == "serve"]
        self.servers = [(srv, spec, ln) for (srv, spec), ln in zip(specs, serve_lines)]
        if os.path.exists(self.run_dir):
            shutil.rmtree(self.run_dir)
        os.makedirs(self.ws)
        os.makedirs(os.path.join(self.run_dir, "no-usage"))
        # The `.test` runner's App config (`e2e_defaults`): the breadcrumb
        # off, and `# ascii` as the `--ascii` switch. Handed to the app as
        # its explicit `--config` layer, beside the run — NOT written into
        # `<ws>/.mnml/`: the headless runner plants nothing in the
        # workspace, so a script that acts on "the first row of the tree"
        # means the first file it wrote, and `.mnml/` would be that row.
        # Trust comes from `MNML_E2E_WORKSPACE` (the app takes the named
        # workspace as trusted at launch, as the runner does), so a DAP
        # adapter or LSP server a script writes into the workspace config
        # after launch is read. No broker besides: the terminal loop
        # hosts one by default, headless hosts nothing unless a script
        # asks, and the REQUESTS view says which. (The menu bar is NOT
        # pinned: headless draws it too.)
        cfg = ".{ .editor = .{ .breadcrumb = false }, .integrations = .{ .broker = false }"
        if header["ascii"]:
            cfg += ", .ui = .{ .ascii_icons = true }"
        cfg += " }"
        e2e_cfg = os.path.join(self.run_dir, "e2e-config.zon")
        with open(e2e_cfg, "w", encoding="utf-8") as f:
            f.write(cfg + "\n")
        cols = max(80, header["width"] or 120)
        rows = max(24, header["height"] or 40)
        if (header["width"] and header["width"] < 80) or (header["height"] and header["height"] < 24):
            # Clamped up, the script's rows and columns are somebody
            # else's: every click lands off and every narrow-layout
            # expectation misses (integrations_jira_narrow_keeps_key,
            # `# width: 60`, missed all seven). Headless covers these.
            return "skip", f"size {header['width']}x{header['height']} is under the driver's 80x24 floor; headless only"
        self.start_group()
        try:
            env = self.build_env(header)
            self.win = Window(self.run_dir, self.ws, exe=self.args.exe, cols=cols, rows=rows, app_env=env,
                              app_args=["--config", e2e_cfg])
            self.win.launch()
            quit_seen = False
            for ln, head, rest in coalesce_clicks(steps):
                if quit_seen:
                    break
                try:
                    self.step(ln, head, rest)
                except DriveError as e:
                    if not self.win.alive():
                        quit_seen = True
                        self.notes.append(f"line {ln}: the app exited ({e})")
                        break
                    self.notes.append(f"line {ln}: {e}")
            if not self.win.alive():
                return "quit", "the app exited before the last frame; no shot"
            self.win.settle(quiet_ms=300, cap_ms=2500)
            png = os.path.join(self.out, self.name + ".png")
            self.win.shot(png)
            return "shot", png
        finally:
            if self.win:
                self.win.quit()
            self.end_group()
            for srv, _, _ in self.servers:
                srv.shutdown()

    def pace(self):
        self.win.settle(quiet_ms=150, cap_ms=1200)

    def step(self, ln, head, rest):
        w = self.win
        if head == "write":
            rel, content = split1(rest)
            p = os.path.join(self.ws, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(unescape(content))
        elif head == "open":
            w.send({"cmd": "open", "path": rest.strip()}, settle=False)
            self.pace()
        elif head == "key":
            w.send({"cmd": "key", "key": rest.strip()}, settle=False)
            self.pace()
        elif head == "type":
            w.send({"cmd": "type", "text": unescape(rest)}, settle=False)
            self.pace()
        elif head in ("command", "command!"):
            w.send({"cmd": "run-command", "id": rest.strip()}, settle=False)
            self.pace()
        elif head == "ex":
            w.send({"cmd": "ex", "text": rest.strip()}, settle=False)
            self.pace()
        elif head == "ghost":
            w.send({"cmd": "ghost", "text": unescape(rest)}, settle=False)
            self.pace()
        elif head in ("click", "clicks", "rightclick", "doubleclick", "hover", "scroll"):
            parts = rest.split()
            x, y = int(parts[0]), int(parts[1])
            if head == "click":
                w.send({"cmd": "click", "col": x, "row": y}, settle=False)
            elif head == "clicks":
                # `click X Y` repeated on consecutive lines (`coalesce_clicks`):
                # one append, so the presses share a poll the way the
                # runner's back-to-back steps share a clock.
                n = int(parts[2])
                w.send(*([{"cmd": "click", "col": x, "row": y}] * n), settle=False)
            elif head == "rightclick":
                w.send({"cmd": "click", "col": x, "row": y, "button": "right"}, settle=False)
            elif head == "doubleclick":
                w.send({"cmd": "click", "col": x, "row": y}, {"cmd": "click", "col": x, "row": y}, settle=False)
            elif head == "hover":
                w.send({"cmd": "hover", "col": x, "row": y}, settle=False)
            else:
                w.send({"cmd": "scroll", "col": x, "row": y, "dy": 1 if parts[2] == "up" else -1}, settle=False)
            self.pace()
        elif head == "drag":
            p = [int(v) for v in rest.split()[:4]]
            w.send({"cmd": "drag", "from_col": p[0], "from_row": p[1], "col": p[2], "row": p[3]}, settle=False)
            self.pace()
        elif head == "wait":
            time.sleep(int(rest.strip()) / 1000.0)
        elif head == "shell":
            try:
                r = subprocess.run(["/bin/sh", "-c", rest.strip()], cwd=self.ws, env=self.shell_env,
                                   preexec_fn=lambda: os.setpgid(0, self.leader.pid),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=120)
                if r.returncode != 0:
                    self.notes.append(f"line {ln}: shell exited {r.returncode}")
            except subprocess.TimeoutExpired:
                self.notes.append(f"line {ln}: shell timed out")
        elif head == "serve":
            for srv, spec, sln in self.servers:
                if sln == ln:
                    status_s, rest1 = split1(split1(rest)[1])
                    spec.status = int(status_s)
                    if rest1.startswith("delay="):
                        d, rest1 = split1(rest1)
                        spec.delay_ms = int(d[6:])
                    spec.text = unescape(rest1)
                    spec.live = True
        elif head == "snippet":
            self.notes.append(f"line {ln}: `snippet` has no channel line; skipped")
        elif head == "shot":
            w.shot(os.path.join(self.out, f"{self.name}--{rest.strip()}.png"))
        elif head == "expect":
            self.soft_wait(ln, rest)
        else:
            self.notes.append(f"line {ln}: unknown statement `{head}`")

    def soft_wait(self, ln, rest):
        budget = self.args.soft_wait
        first, after = split1(rest)
        if first == "within":
            ms, rest = split1(after)
            budget = min(int(ms), 15000)
        kind, after = split1(rest)
        if kind not in ("screen", "status"):
            return
        op, text = split1(after)
        if op not in ("contains", "lacks"):
            return
        if not self.win.wait_for(unescape(text), present=(op == "contains"), timeout_ms=budget, where=kind):
            self.soft_misses.append(f"line {ln}: expect {kind} {op} {text[:60]}")
            # The frame the miss was judged on, beside the shot: a miss
            # with no frame is a number to argue about, one with its
            # frame is a drift or a wait you can read. The last shot
            # is the END of the script, which is not this moment.
            try:
                frame = self.win.screen() if kind == "screen" else self.win.status()
                with open(os.path.join(self.out, f"{self.name}.miss-{ln}.txt"), "w", encoding="utf-8") as f:
                    f.write(f"# line {ln}: expect {kind} {op} {text}\n")
                    f.write(frame if isinstance(frame, str) else json.dumps(frame, indent=1))
            except Exception as e:  # never turns a miss into an error
                self.notes.append(f"line {ln}: could not keep the missed frame ({type(e).__name__})")


# ─── the sweep ─────────────────────────────────────────────────────────

def collect(paths):
    out = []
    for p in paths or [E2E]:
        p = os.path.abspath(p)
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                if os.sep + "fixtures" in root:
                    continue
                out += [os.path.join(root, f) for f in files if f.endswith(".test")]
        elif p.endswith(".test"):
            out.append(p)
    return sorted(out)


def run(args):
    if not args.exe:
        import stamp
        stamp.warn_app("tour.sh sweep")
    out_root = os.path.abspath(args.out)
    out = os.path.join(out_root, "sweep")
    tmp_root = os.path.join(out_root, "runs")
    os.makedirs(out, exist_ok=True)
    os.makedirs(tmp_root, exist_ok=True)
    files = collect(args.files)
    record = os.path.join(out_root, "sweep.jsonl")
    started = now_ms()
    done = skipped = errors = 0
    log(f"sweep: {len(files)} file(s) → {out}")
    for path in files:
        if args.limit is not None and done >= args.limit:
            break
        name = shot_name(path)
        if not args.all and os.path.exists(os.path.join(out, name + ".png")):
            skipped += 1
            continue
        t0 = now_ms()
        fr = FileRun(path, out, args, tmp_root)
        try:
            verdict, detail = fr.run()
        except Exception as e:  # tolerant: one file never ends the sweep
            verdict, detail = "error", f"{type(e).__name__}: {e}"
        ms = int(now_ms() - t0)
        done += 1
        if verdict == "error":
            errors += 1
        entry = {"file": os.path.relpath(path, REPO), "verdict": verdict, "detail": detail if verdict != "shot" else "",
                 "ms": ms, "soft_misses": fr.soft_misses, "notes": fr.notes}
        with open(record, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
        miss = f"  soft misses {len(fr.soft_misses)}" if fr.soft_misses else ""
        extra = "" if verdict == "shot" else f"  ({detail})"
        log(f"  {verdict:5} {ms:6d} ms  {name}{miss}{extra}")
        if verdict in ("shot", "skip"):
            shutil.rmtree(fr.run_dir, ignore_errors=True)
    total = int((now_ms() - started) / 1000)
    log(f"sweep: {done} run, {skipped} already shot, {errors} error(s), {total} s; record {record}")
    from tour import SWEEP_BASELINE, compare, load_masks
    if os.path.isdir(SWEEP_BASELINE):
        masks = load_masks()
        thr = args.threshold if args.threshold is not None else float(masks.get("threshold_pct", 0.02))
        tol = args.tolerance if args.tolerance is not None else int(masks.get("tolerance", 24))
        changed = 0
        for p in sorted(os.listdir(out)):
            if not p.endswith(".png"):
                continue
            base = os.path.join(SWEEP_BASELINE, p)
            if not os.path.exists(base):
                continue
            pct, bbox, ch = compare(p[:-4], os.path.join(out, p), base, masks, thr, tol)
            if ch:
                changed += 1
                log(f"  CHANGED {pct:7.3f}%  {p[:-4]}")
        log(f"sweep diff: {changed} changed against {os.path.relpath(SWEEP_BASELINE, REPO)}")
    return 1 if errors else 0
