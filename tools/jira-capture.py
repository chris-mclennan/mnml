#!/usr/bin/env python3
"""Drive a full-screen terminal program in a pty and keep its screens as text.

The Jira tracker this repo's integration is measured against is a
terminal program with no headless mode, so the only way to read its
screen is to be its terminal: this script forks it on a pty of a given
size, plays a step script at it (keys, clicks, wheel notches, waits),
and runs a small VT emulator over what comes back — cursor moves,
erases, the alternate screen, SGR (ignored: the dumps are text) — so a
`snap NAME` writes the screen as NAME.txt, one line per row, trailing
blanks trimmed. `tools/jira-diff.sh` runs it against the offline server;
`docs/ui-spec/jira/` was cut with it against the author's real site.

    tools/jira-capture.py --bin BIN --out DIR [--size 120x40] [--home DIR]
                          [--env K=V]... [--steps FILE] -- PROGRAM-ARGS...

Steps (one per line; `#` comments):
    wait MS           sleep, feeding the emulator meanwhile
    settle [MS]       wait until the program has been quiet for MS (400)
    waitfor TEXT [MS] pump until TEXT is on the screen (up to MS, 20000)
    key SPEC          a, A, enter, esc, tab, backtab, up/down/left/right,
                      home, end, pgup, pgdn, space, backspace, delete,
                      ctrl+x, alt+x
    type TEXT         the characters, one by one
    click X Y         a left press+release at cell X,Y (0-based)
    rclick X Y        the same with the right button
    clickon TEXT      click the first cell of TEXT on the screen (rclickon: right)
    clickafter TEXT N click N cells past the end of TEXT, on its row
    waitsoft TEXT [MS] like waitfor, but a miss only logs
    scroll X Y up|down
    snap NAME         DIR/NAME.txt
    find TEXT         print the (x, y) of TEXT on the screen (for scripting)
    expect TEXT       abort the run unless TEXT is on the screen (settles first)
    quit              send q and wait for the program to end
"""
import argparse
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
import fcntl

# ─── a small VT emulator ────────────────────────────────────────────────

WIDE_SINGLETONS = {
    0x231A, 0x231B, 0x23E9, 0x23EA, 0x23EB, 0x23EC, 0x23F0, 0x23F3, 0x25FD, 0x25FE,
    0x2614, 0x2615, 0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4,
    0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705,
    0x270A, 0x270B, 0x2728, 0x274C, 0x274E, 0x2753, 0x2754, 0x2755, 0x2757, 0x2795,
    0x2796, 0x2797, 0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55,
}


def is_wide(cp):
    if cp in WIDE_SINGLETONS:
        return True
    if 0x2648 <= cp <= 0x2653:
        return True
    return (
        0x1100 <= cp <= 0x115F
        or (0x2E80 <= cp <= 0xA4CF and cp != 0x303F)
        or 0xAC00 <= cp <= 0xD7A3
        or 0xF900 <= cp <= 0xFAFF
        or 0xFE30 <= cp <= 0xFE4F
        or 0xFF00 <= cp <= 0xFF60
        or 0xFFE0 <= cp <= 0xFFE6
        or 0x1F300 <= cp <= 0x1F64F
        or 0x1F680 <= cp <= 0x1F6FF
        or 0x1F900 <= cp <= 0x1F9FF
        or 0x20000 <= cp <= 0x3FFFD
    )


class Term:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.grid = [[" "] * cols for _ in range(rows)]
        self.x = self.y = 0
        self.saved = (0, 0)
        self.top, self.bot = 0, rows - 1
        self.state = "ground"
        self.buf = ""
        self.pending = b""
        self.wrap_pending = False
        self.tabs = set(range(8, cols, 8))

    # ── feeding ──
    def feed(self, data):
        data = self.pending + data
        try:
            text = data.decode("utf-8")
            self.pending = b""
        except UnicodeDecodeError as e:
            text = data[: e.start].decode("utf-8", "replace")
            self.pending = data[e.start :] if len(data) - e.start < 4 else b""
        for ch in text:
            self._step(ch)

    def _step(self, ch):
        st = self.state
        if st == "ground":
            if ch == "\x1b":
                self.state = "esc"
            elif ch == "\r":
                self.x = 0
                self.wrap_pending = False
            elif ch == "\n" or ch == "\x0b" or ch == "\x0c":
                self._lf()
            elif ch == "\b":
                self.x = max(0, self.x - 1)
                self.wrap_pending = False
            elif ch == "\t":
                nxt = [t for t in sorted(self.tabs) if t > self.x]
                self.x = nxt[0] if nxt else self.cols - 1
            elif ch == "\x07" or ord(ch) < 0x20 or ch == "\x7f":
                pass
            else:
                self._put(ch)
        elif st == "esc":
            if ch == "[":
                self.state, self.buf = "csi", ""
            elif ch == "]":
                self.state, self.buf = "osc", ""
            elif ch in "()*+#%":
                self.state = "esc2"
            elif ch == "7":
                self.saved = (self.x, self.y)
                self.state = "ground"
            elif ch == "8":
                self.x, self.y = self.saved
                self.state = "ground"
            elif ch == "D":
                self._lf()
                self.state = "ground"
            elif ch == "M":
                self._rlf()
                self.state = "ground"
            elif ch == "E":
                self.x = 0
                self._lf()
                self.state = "ground"
            elif ch == "P" or ch == "_" or ch == "^" or ch == "X":
                self.state, self.buf = "str", ""
            else:
                self.state = "ground"
        elif st == "esc2":
            self.state = "ground"
        elif st == "csi":
            if "\x40" <= ch <= "\x7e":
                self._csi(self.buf, ch)
                self.state = "ground"
            else:
                self.buf += ch
        elif st == "osc" or st == "str":
            if ch == "\x07":
                self.state = "ground"
            elif ch == "\x1b":
                self.state = "str_esc"
            else:
                self.buf += ch
        elif st == "str_esc":
            # ESC \ ends the string; anything else starts a new ESC.
            self.state = "ground" if ch == "\\" else "esc"
            if self.state == "esc":
                self._step(ch)

    def _lf(self):
        if self.y == self.bot:
            self._scroll_up(1)
        elif self.y < self.rows - 1:
            self.y += 1
        self.wrap_pending = False

    def _rlf(self):
        if self.y == self.top:
            self._scroll_down(1)
        elif self.y > 0:
            self.y -= 1

    def _scroll_up(self, n):
        for _ in range(n):
            del self.grid[self.top]
            self.grid.insert(self.bot, [" "] * self.cols)

    def _scroll_down(self, n):
        for _ in range(n):
            del self.grid[self.bot]
            self.grid.insert(self.top, [" "] * self.cols)

    def _put(self, ch):
        w = 2 if is_wide(ord(ch)) else 1
        if self.wrap_pending or self.x + w > self.cols:
            self.x = 0
            self._lf()
            self.wrap_pending = False
        self.grid[self.y][self.x] = ch
        if w == 2 and self.x + 1 < self.cols:
            self.grid[self.y][self.x + 1] = ""
        self.x += w
        if self.x >= self.cols:
            self.x = self.cols - 1
            self.wrap_pending = True

    def _csi(self, buf, final):
        private = buf.startswith("?") or buf.startswith(">") or buf.startswith("=")
        raw = buf.lstrip("?>=")
        try:
            params = [int(p) if p else 0 for p in raw.split(";")] if raw else []
        except ValueError:
            params = []

        def p(i, default=1):
            v = params[i] if i < len(params) else 0
            return v if v else default

        self.wrap_pending = False
        if private:
            return  # DEC modes: alternate screen, mouse, cursor visibility — nothing to draw
        if final == "H" or final == "f":
            self.y = min(self.rows - 1, max(0, p(0) - 1))
            self.x = min(self.cols - 1, max(0, p(1) - 1))
        elif final == "A":
            self.y = max(0, self.y - p(0))
        elif final == "B":
            self.y = min(self.rows - 1, self.y + p(0))
        elif final == "C":
            self.x = min(self.cols - 1, self.x + p(0))
        elif final == "D":
            self.x = max(0, self.x - p(0))
        elif final == "E":
            self.x = 0
            self.y = min(self.rows - 1, self.y + p(0))
        elif final == "F":
            self.x = 0
            self.y = max(0, self.y - p(0))
        elif final == "G" or final == "`":
            self.x = min(self.cols - 1, max(0, p(0) - 1))
        elif final == "d":
            self.y = min(self.rows - 1, max(0, p(0) - 1))
        elif final == "J":
            mode = p(0, 0)
            if mode == 0:
                self._erase(self.y, self.x, self.cols)
                for yy in range(self.y + 1, self.rows):
                    self._erase(yy, 0, self.cols)
            elif mode == 1:
                for yy in range(0, self.y):
                    self._erase(yy, 0, self.cols)
                self._erase(self.y, 0, self.x + 1)
            else:
                for yy in range(self.rows):
                    self._erase(yy, 0, self.cols)
        elif final == "K":
            mode = p(0, 0)
            if mode == 0:
                self._erase(self.y, self.x, self.cols)
            elif mode == 1:
                self._erase(self.y, 0, self.x + 1)
            else:
                self._erase(self.y, 0, self.cols)
        elif final == "X":
            self._erase(self.y, self.x, min(self.cols, self.x + p(0)))
        elif final == "P":
            n = p(0)
            row = self.grid[self.y]
            del row[self.x : self.x + n]
            row.extend([" "] * (self.cols - len(row)))
        elif final == "@":
            n = p(0)
            row = self.grid[self.y]
            row[self.x : self.x] = [" "] * n
            del row[self.cols :]
        elif final == "L":
            for _ in range(p(0)):
                del self.grid[self.bot]
                self.grid.insert(self.y, [" "] * self.cols)
        elif final == "M":
            for _ in range(p(0)):
                del self.grid[self.y]
                self.grid.insert(self.bot, [" "] * self.cols)
        elif final == "S":
            self._scroll_up(p(0))
        elif final == "T":
            self._scroll_down(p(0))
        elif final == "r":
            top = p(0) - 1
            bot = p(1, self.rows) - 1
            if 0 <= top < bot < self.rows:
                self.top, self.bot = top, bot
            else:
                self.top, self.bot = 0, self.rows - 1
            self.x = self.y = 0
        elif final == "s":
            self.saved = (self.x, self.y)
        elif final == "u":
            self.x, self.y = self.saved
        # m (SGR), h/l, n, t, c, q: nothing to draw

    def _erase(self, y, x0, x1):
        for xx in range(max(0, x0), min(self.cols, x1)):
            self.grid[y][xx] = " "

    # ── reading ──
    def lines(self):
        return ["".join(row).rstrip() for row in self.grid]

    def text(self):
        return "\n".join(self.lines()) + "\n"

    def find(self, needle):
        for y, line in enumerate(self.lines()):
            i = line.find(needle)
            if i >= 0:
                # Column = cells before the match (a wide cell is one
                # char in the joined line, two cells on screen).
                x = sum(2 if is_wide(ord(c)) else 1 for c in line[:i])
                return x, y
        return None


# ─── the pty driver ─────────────────────────────────────────────────────

KEYS = {
    "enter": "\r", "esc": "\x1b", "tab": "\t", "backtab": "\x1b[Z", "up": "\x1b[A",
    "down": "\x1b[B", "right": "\x1b[C", "left": "\x1b[D", "home": "\x1b[H",
    "end": "\x1b[F", "pgup": "\x1b[5~", "pgdn": "\x1b[6~", "space": " ",
    "backspace": "\x7f", "delete": "\x1b[3~",
}


def key_bytes(spec):
    if spec in KEYS:
        return KEYS[spec].encode()
    if spec.startswith("ctrl+") and len(spec) == 6:
        return bytes([ord(spec[5].lower()) & 0x1F])
    if spec.startswith("alt+") and len(spec) == 5:
        return b"\x1b" + spec[4].encode()
    if spec.startswith("shift+") and len(spec) == 7:
        return spec[6].upper().encode()
    return spec.encode()


def mouse_bytes(x, y, button=0, release=True):
    seq = "\x1b[<%d;%d;%dM" % (button, x + 1, y + 1)
    if release:
        seq += "\x1b[<%d;%d;%dm" % (button, x + 1, y + 1)
    return seq.encode()


class ProgramGone(Exception):
    """The program went away under a step (it exited or crashed)."""


class Driver:
    def __init__(self, argv, cols, rows, env):
        self.term = Term(cols, rows)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, cols * 9, rows * 18))
        self.alive = True
        self.last_output = time.time()

    def pump(self, secs):
        end = time.time() + secs
        while True:
            left = end - time.time()
            if left <= 0:
                return
            r, _, _ = select.select([self.fd], [], [], min(left, 0.05))
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    self.alive = False
                    return
                if not data:
                    self.alive = False
                    return
                self.term.feed(data)
                self.last_output = time.time()

    def settle(self, quiet_ms=400, max_secs=8.0):
        end = time.time() + max_secs
        while time.time() < end:
            self.pump(0.05)
            if time.time() - self.last_output >= quiet_ms / 1000.0:
                return
            if not self.alive:
                return

    def send(self, data):
        try:
            os.write(self.fd, data)
        except OSError:
            self.alive = False
            raise ProgramGone()

    def wait_exit(self, secs=5.0):
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.1)
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return True
            if not self.alive:
                try:
                    os.waitpid(self.pid, 0)
                except ChildProcessError:
                    pass
                return True
        return False

    def kill(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
            time.sleep(0.2)
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


def run_steps(drv, steps, out_dir, log):
    for raw in steps:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        verb = parts[0]
        arg = parts[1] if len(parts) > 1 else ""
        if verb == "wait":
            drv.pump(int(arg) / 1000.0)
        elif verb == "settle":
            drv.settle(int(arg) if arg else 400)
        elif verb == "waitfor":
            m = re.match(r"^(.*?)(?:\s+(\d+))?$", arg)
            needle, ms = m.group(1), int(m.group(2) or 20000)
            end = time.time() + ms / 1000.0
            while time.time() < end and drv.term.find(needle) is None and drv.alive:
                drv.pump(0.1)
            if drv.term.find(needle) is None:
                path = os.path.join(out_dir, "_waitfor-failed.txt")
                with open(path, "w", encoding="utf-8") as f:
                    f.write(drv.term.text())
                log("waitfor %r: not on screen after %d ms (that screen is in %s) — giving up on this run" % (needle, ms, path))
                drv.kill()
                raise SystemExit(3)
        elif verb == "key":
            drv.send(key_bytes(arg))
            drv.pump(0.12)
        elif verb == "type":
            for ch in arg:
                drv.send(ch.encode())
                drv.pump(0.04)
        elif verb in ("click", "rclick"):
            x, y = (int(v) for v in arg.split()[:2])
            drv.send(mouse_bytes(x, y, 2 if verb == "rclick" else 0))
            drv.pump(0.15)
        elif verb == "clickafter":
            text, _, n = arg.rpartition(" ")
            at = drv.term.find(text)
            if at is None:
                log("clickafter %r: not on screen" % text)
                continue
            w = sum(2 if is_wide(ord(c)) else 1 for c in text)
            drv.send(mouse_bytes(at[0] + w + int(n), at[1], 0))
            drv.pump(0.15)
        elif verb == "waitsoft":
            m = re.match(r"^(.*?)(?:\s+(\d+))?$", arg)
            needle, ms = m.group(1), int(m.group(2) or 20000)
            end = time.time() + ms / 1000.0
            while time.time() < end and drv.term.find(needle) is None and drv.alive:
                drv.pump(0.1)
            if drv.term.find(needle) is None:
                log("waitsoft %r: not on screen after %d ms" % (needle, ms))
        elif verb in ("clickon", "rclickon"):
            at = drv.term.find(arg)
            if at is None:
                log("clickon %r: not on screen" % arg)
                continue
            drv.send(mouse_bytes(at[0], at[1], 2 if verb == "rclickon" else 0))
            drv.pump(0.15)
        elif verb == "scroll":
            x, y, d = arg.split()[:3]
            drv.send(mouse_bytes(int(x), int(y), 64 if d == "up" else 65, release=False))
            drv.pump(0.12)
        elif verb == "snap":
            drv.settle(300, 3.0)
            path = os.path.join(out_dir, arg + ".txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write(drv.term.text())
            log("snap %s" % path)
        elif verb == "expect":
            drv.settle(300, 3.0)
            if drv.term.find(arg) is None:
                path = os.path.join(out_dir, "_expect-failed.txt")
                with open(path, "w", encoding="utf-8") as f:
                    f.write(drv.term.text())
                log("expect %r: not on screen (that screen is in %s) — giving up on this run" % (arg, path))
                drv.kill()
                raise SystemExit(5)
        elif verb == "find":
            log("find %r -> %r" % (arg, drv.term.find(arg)))
        elif verb == "quit":
            drv.send(b"q")
            if not drv.wait_exit(5.0):
                drv.send(b"\x03")
                if not drv.wait_exit(2.0):
                    drv.kill()
            return
        else:
            log("unknown step: %s" % line)
    if drv.alive:
        drv.send(b"q")
        if not drv.wait_exit(5.0):
            drv.kill()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--size", default="120x40")
    ap.add_argument("--home")
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--steps")
    ap.add_argument("prog_args", nargs="*")
    args = ap.parse_args()
    cols, rows = (int(v) for v in args.size.lower().split("x"))
    os.makedirs(args.out, exist_ok=True)
    env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", LANG="en_US.UTF-8")
    if args.home:
        env["HOME"] = args.home
    for kv in args.env:
        k, _, v = kv.partition("=")
        env[k] = v
    steps = open(args.steps, encoding="utf-8").read().splitlines() if args.steps else sys.stdin.read().splitlines()
    log = lambda s: print("jira-capture: " + s, file=sys.stderr)
    drv = Driver([args.bin] + args.prog_args, cols, rows, env)
    try:
        run_steps(drv, steps, args.out, log)
    except ProgramGone:
        drv.pump(0.5)
        path = os.path.join(args.out, "_crash.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(drv.term.text())
        log("the program went away; its last screen is in %s" % path)
        raise SystemExit(4)
    finally:
        if drv.alive:
            drv.kill()


if __name__ == "__main__":
    main()
