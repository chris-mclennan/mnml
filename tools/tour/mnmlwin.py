"""One real mnml window, driven through the file channel.

`mnml-drive` owns the window: it launches ghostty on a config of its
own, records the pid and the window id, and every verb it runs re-checks
that the window is still ITS window. What it does not do is type: `key`
and `type` need the harness to be the active application, which takes
the keyboard from the person at the machine. So this module drives the
app the other way — JSONL lines appended to `<run>/ipc/command` (`--ipc-dir`)
with `ipc.allow_input` on (`mnml-drive launch --allow-input`) — and
uses the driver only for what needs the window: launch, shot, pixel,
quit. The window's own mouse reporting is off (`--no-mouse`): the
person's pointer crossing it would otherwise steer the hover help in a
shot; clicks and hovers come through the channel instead.

The app does not run in the environment it is launched from. On macOS
ghostty starts its command through `login(1)`, which resets HOME to the
real one — measured: a harness launched with a private HOME read the
developer's own coverage trends (the artifacts home) into its
statusline. So the command ghostty runs is a small wrapper that
`exec env -i`s the app with exactly the environment given here: a
private HOME, a clean PATH, the terminal's own TERM variables, nothing
else. Nothing the developer has — tokens, `~/.claude`, their git
identity, their now-playing track — reaches the window.
"""

import json
import os
import shlex
import shutil
import signal
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DRIVE = os.path.join(REPO, "zig-out", "bin", "mnml-drive")

# The terminal's own variables pass through the wrapper: mnml reads them
# to know what it is running in, and they describe the harness window,
# not the developer.
TERMINAL_VARS = ("TERM", "TERMINFO", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM",
                 "GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR", "MNML_DATA_ROOT", "MNML_PROFILE", "MNML_IPC_DIR")

CLEAN_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


class DriveError(RuntimeError):
    pass


def now_ms():
    return time.monotonic() * 1000.0


def base_env(home, tmp):
    """The app's environment before a caller's additions: a private HOME
    and TMPDIR, a clean PATH with the AI shims first (the tab bar's AI
    chip shows only when a `claude` is on PATH; the shims are sleeping
    stand-ins, as in the `.test` runner), the user's locale."""
    shims = os.path.join(REPO, "tools", "shims")
    return {
        "HOME": home,
        "TMPDIR": tmp,
        "PATH": os.path.join(shims, "ai") + ":" + CLEAN_PATH,
        "USER": os.environ.get("USER", "tour"),
        "LOGNAME": os.environ.get("USER", "tour"),
        "LANG": os.environ.get("LANG", "en_US.UTF-8"),
        "SHELL": "/bin/zsh",
        # The now-playing chip's idle form, not whatever the machine is
        # playing (the live poller asks Music / Spotify otherwise).
        "MNML_NOW_PLAYING": "",
        # A developer's own coverage trends never paint a harness
        # statusline (`app/coverage.zig`).
        "MNML_ARTIFACTS_HOME": home,
        "MNML_SESSIONS_HOME": home,
        # A proxy that refuses, for anything that would reach the network.
        "HTTPS_PROXY": "http://127.0.0.1:9",
        "HTTP_PROXY": "http://127.0.0.1:9",
        "ALL_PROXY": "http://127.0.0.1:9",
        "NO_PROXY": "127.0.0.1,localhost",
        "GIT_CONFIG_NOSYSTEM": "1",
    }


def user_ghostty_config():
    """The developer's ghostty config — font lines, the codepoint map.
    The harness renders with it on purpose (docs/DRIVE.md); it is read,
    never written."""
    p = os.path.expanduser("~/.config/ghostty/config")
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


class Window:
    def __init__(self, run_dir, workspace, exe=None, cols=120, rows=40, app_env=None,
                 app_args=(), log=None, timeout_ms=30000):
        self.run_dir = os.path.abspath(run_dir)
        self.ws = os.path.abspath(workspace)
        self.exe = os.path.abspath(exe or os.path.join(REPO, "zig-out", "bin", "mnml-zig"))
        self.cols = cols
        self.rows = rows
        self.data_root = os.path.join(self.run_dir, "data")
        self.home = os.path.join(self.run_dir, "home")
        self.tmp = os.path.join(self.run_dir, "tmp")
        # Beside the run, never inside the workspace: a `.mnml/` planted
        # in the fixture is a tree row the script did not write (two
        # "delete the first row" scripts deleted the channel itself).
        self.ipc = os.path.join(self.run_dir, "ipc")
        self.app_env = dict(app_env or {})
        self.app_args = list(app_args)
        self.log = log or (lambda msg: None)
        self.timeout_ms = timeout_ms
        self.pid = None
        self._ack_seen = 0

    # ── launch / quit ──────────────────────────────────────────────────

    def _write_wrapper(self):
        env = base_env(self.home, self.tmp)
        env.update(self.app_env)
        parts = ["exec", "/usr/bin/env", "-i"]
        for k in TERMINAL_VARS:
            parts.append(f'{k}="${{{k}:-}}"')
        for k, v in env.items():
            parts.append(shlex.quote(f"{k}={v}"))
        parts.append(shlex.quote(self.exe))
        parts += [shlex.quote(a) for a in self.app_args]
        parts.append('"$@"')
        path = os.path.join(self.run_dir, "app.sh")
        with open(path, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\n# Written by tools/tour: the app's whole environment, nothing inherited.\n")
            f.write(" ".join(parts) + "\n")
        os.chmod(path, 0o755)
        return path

    def launch(self):
        for d in (self.data_root, self.tmp, os.path.join(self.home, ".config", "ghostty")):
            os.makedirs(d, exist_ok=True)
        # The driver reads the ghostty config from $HOME; a private HOME
        # gets a copy of the developer's, so the fonts are theirs.
        with open(os.path.join(self.home, ".config", "ghostty", "config"), "w", encoding="utf-8") as f:
            f.write(user_ghostty_config())
        wrapper = self._write_wrapper()
        drive_env = {
            "PATH": CLEAN_PATH,
            "HOME": self.home,  # no ~/.config/mnml there: the harness copies no layout keys
            "USER": os.environ.get("USER", "tour"),
            "LANG": os.environ.get("LANG", "en_US.UTF-8"),
            "TMPDIR": self.tmp,
        }
        cmd = [DRIVE, "launch", "--workspace", self.ws, "--data-root", self.data_root,
               "--ipc-dir", self.ipc,
               "--cols", str(self.cols), "--rows", str(self.rows), "--exe", wrapper,
               "--allow-input", "--no-mouse", "--timeout", str(self.timeout_ms)]
        r = subprocess.run(cmd, env=drive_env, capture_output=True, text=True)
        if r.returncode != 0:
            raise DriveError(f"mnml-drive launch exited {r.returncode}: {r.stderr.strip()}")
        with open(os.path.join(self.data_root, "drive.json"), encoding="utf-8") as f:
            self.pid = json.load(f)["pid"]
        self._ack_seen = self._count_acks()
        # The first frames settle (the tree scan, git status).
        self.settle(quiet_ms=500, cap_ms=6000)

    def alive(self):
        if not self.pid:
            return False
        try:
            os.kill(self.pid, 0)
            return True
        except OSError:
            return False

    def quit(self):
        """IPC `quit` first — mnml exits the way it would for a person —
        then the driver's own quit, which signals only the recorded pid."""
        if not self.pid:
            return
        try:
            self._append([{"cmd": "quit"}])
        except OSError:
            pass
        deadline = now_ms() + 4000
        while now_ms() < deadline and self.alive():
            time.sleep(0.1)
        if self.alive():
            subprocess.run([DRIVE, "quit", "--data-root", self.data_root],
                           capture_output=True, text=True, env={"PATH": CLEAN_PATH})
        deadline = now_ms() + 3000
        while now_ms() < deadline and self.alive():
            time.sleep(0.1)
        if self.alive():
            # Ours, recorded at launch: never a search by name.
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError:
                pass
        self.pid = None

    # ── the channel ────────────────────────────────────────────────────

    def _count_acks(self):
        p = os.path.join(self.ipc, "events.jsonl")
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                return sum(1 for line in f if '"event":"accepted"' in line or '"event":"unsupported"' in line
                           or '"event":"quit"' in line)
        except OSError:
            return 0

    def _append(self, cmds):
        data = "".join(json.dumps(c, ensure_ascii=False) + "\n" for c in cmds)
        with open(os.path.join(self.ipc, "command"), "a", encoding="utf-8") as f:
            f.write(data)

    def send(self, *cmds, settle=True):
        """Append the lines, wait until each is acknowledged, then let the
        frame settle. An `unsupported` ack is an error: it names the
        switch that was off."""
        cmds = [c for c in cmds if c]
        if not cmds:
            return
        want = self._ack_seen + len(cmds)
        self._append(cmds)
        deadline = now_ms() + 5000
        while True:
            n = self._count_acks()
            if n >= want:
                break
            if now_ms() > deadline:
                raise DriveError(f"no ack for {cmds!r} within 5 s (acks {n}/{want})")
            if not self.alive():
                raise DriveError("the app exited")
            time.sleep(0.03)
        self._ack_seen = n
        tail = self._events_tail(len(cmds))
        for line in tail:
            if '"unsupported"' in line:
                raise DriveError(f"the channel refused input: {line.strip()}")
        if settle:
            self.settle()

    def _events_tail(self, n):
        try:
            with open(os.path.join(self.ipc, "events.jsonl"), encoding="utf-8", errors="replace") as f:
                lines = [ln for ln in f if '"event":"accepted"' in ln or '"event":"unsupported"' in ln]
            return lines[-n:]
        except OSError:
            return []

    def key(self, spec):
        self.send({"cmd": "key", "key": spec})

    def type(self, text):
        self.send({"cmd": "type", "text": text})

    def run(self, command_id):
        self.send({"cmd": "run-command", "id": command_id})

    def open(self, path):
        self.send({"cmd": "open", "path": path})

    def click(self, col, row, button="left"):
        self.send({"cmd": "click", "col": col, "row": row, "button": button})

    def hover(self, col, row):
        self.send({"cmd": "hover", "col": col, "row": row})

    # ── reading back ───────────────────────────────────────────────────

    def screen(self):
        try:
            with open(os.path.join(self.ipc, "screen.txt"), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def status(self):
        try:
            return json.loads(self.status_text() or "{}")
        except ValueError:
            return {}

    def status_text(self):
        try:
            with open(os.path.join(self.ipc, "status.json"), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""

    def settle(self, quiet_ms=300, cap_ms=3000):
        """Until screen.txt has not changed for `quiet_ms` (or `cap_ms`
        passed — a ticking clock or a spinner never goes quiet)."""
        start = now_ms()
        last = self.screen()
        last_change = now_ms()
        while now_ms() - start < cap_ms:
            time.sleep(0.05)
            cur = self.screen()
            if cur != last:
                last = cur
                last_change = now_ms()
            elif now_ms() - last_change >= quiet_ms:
                return True
        return False

    def wait_for(self, text, present=True, timeout_ms=3000, where="screen"):
        deadline = now_ms() + timeout_ms
        while True:
            # The status is matched as the app WROTE it (compact, the
            # runner's key order), never re-serialised: `json.dumps` puts
            # a space after every colon, and `"cursorShape":"bar"` never
            # matched — 191 of the first sweep's 546 misses were that.
            hay = self.screen() if where == "screen" else self.status_text()
            if (text in hay) == present:
                return True
            if now_ms() > deadline:
                return False
            time.sleep(0.05)

    def shot(self, path):
        """The window's pixels (`mnml-drive shot`, one window by id), and
        the screen.txt of the same moment beside it."""
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        text = self.screen()
        r = subprocess.run([DRIVE, "shot", path, "--data-root", self.data_root],
                           capture_output=True, text=True, env={"PATH": CLEAN_PATH})
        if r.returncode != 0:
            raise DriveError(f"mnml-drive shot: {r.stderr.strip()}")
        with open(os.path.splitext(path)[0] + ".txt", "w", encoding="utf-8") as f:
            f.write(text)
        return text

    def pixel(self, col, row, fx=0.5, fy=0.5):
        r = subprocess.run([DRIVE, "pixel", str(col), str(row), "--fx", str(fx), "--fy", str(fy),
                            "--data-root", self.data_root],
                           capture_output=True, text=True, env={"PATH": CLEAN_PATH})
        if r.returncode != 0:
            raise DriveError(f"mnml-drive pixel: {r.stderr.strip()}")
        return r.stdout.strip()


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def copy_tree(src, dst):
    shutil.copytree(src, dst, dirs_exist_ok=True)
