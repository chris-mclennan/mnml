#!/usr/bin/env python3
"""Drive a full-screen terminal program in a pty and dump its screen as text.

The Rust integrations paint through ratatui: absolute cursor moves, SGR,
erase, and printable runs. There is no tmux or terminal library on the
build machines, so this file carries the few escape sequences that
painter emits and renders them into a cell grid. It is what
`docs/ui-spec/bitbucket/rust-*.txt` were cut with, and what
`tools/bitbucket-diff.sh` runs the Rust side through.

    tools/rust-capture.py --bin BIN [--arg A]... [--env K=V]... [--size 120x40]
                          --out-dir DIR STEP...

Steps, in order:
    settle[:MS]    wait until the program has written nothing for MS
                   milliseconds (default 1500; 60 s ceiling)
    until:TEXT     wait until the screen contains TEXT (540 s ceiling)
    untilnot:TEXT  wait until the screen no longer contains TEXT
    wait:MS        sleep MS milliseconds
    key:NAME       send one key: a single character, or enter, esc, tab,
                   backtab, up, down, left, right, pgup, pgdn, home, end,
                   space, ctrl-<c>, alt-up, alt-down
    text:STRING    send the characters of STRING
    click:COL,ROW  left-click a cell (0-based), SGR mouse encoding
    rclick:COL,ROW right-click a cell
    wheel:COL,ROW,up|down
    snap:NAME      write DIR/NAME.txt — the screen, one row per line,
                   trailing blanks trimmed
    quit           send q and wait for exit

Exit status is 0 when every snap was written; the program is killed on
the way out if it is still running.
"""
import argparse, fcntl, os, pty, select, signal, struct, sys, termios, time, unicodedata


class Screen:
    """A cell grid driven by the subset of VT100 ratatui/crossterm emit."""

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.cells = [[" "] * cols for _ in range(rows)]
        self.x = self.y = 0
        self.buf = b""

    def clear(self, mode=2):
        if mode == 2:
            self.cells = [[" "] * self.cols for _ in range(self.rows)]
        elif mode == 0:
            for c in range(self.x, self.cols):
                self.cells[self.y][c] = " "
            for r in range(self.y + 1, self.rows):
                self.cells[r] = [" "] * self.cols

    def erase_line(self, mode=0):
        row = self.cells[self.y]
        if mode == 0:
            for c in range(self.x, self.cols):
                row[c] = " "
        elif mode == 1:
            for c in range(0, min(self.x + 1, self.cols)):
                row[c] = " "
        else:
            self.cells[self.y] = [" "] * self.cols

    def put(self, ch):
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if unicodedata.combining(ch):
            return
        if self.x + w > self.cols:
            self.x = 0
            self.y = min(self.y + 1, self.rows - 1)
        if 0 <= self.y < self.rows:
            self.cells[self.y][self.x] = ch
            if w == 2 and self.x + 1 < self.cols:
                self.cells[self.y][self.x + 1] = ""
        self.x += w

    def feed(self, data):
        self.buf += data
        text = self.buf.decode("utf-8", errors="ignore")
        # Keep an incomplete trailing escape for the next feed.
        cut = text.rfind("\x1b")
        if cut != -1 and self._incomplete(text[cut:]):
            self.buf = text[cut:].encode("utf-8")
            text = text[:cut]
        else:
            self.buf = b""
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                i = self._escape(text, i)
                continue
            if ch == "\r":
                self.x = 0
            elif ch == "\n":
                self.y = min(self.y + 1, self.rows - 1)
            elif ch == "\b":
                self.x = max(0, self.x - 1)
            elif ch == "\t":
                self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)
            elif ch == "\x07":
                pass
            elif ord(ch) >= 0x20:
                self.put(ch)
            i += 1

    @staticmethod
    def _incomplete(tail):
        if len(tail) < 2:
            return True
        if tail[1] == "[":
            return not any(0x40 <= ord(c) <= 0x7E for c in tail[2:])
        if tail[1] == "]":
            return "\x07" not in tail and "\x1b\\" not in tail
        return False

    def _escape(self, text, i):
        n = len(text)
        if i + 1 >= n:
            return n
        kind = text[i + 1]
        if kind == "[":
            j = i + 2
            while j < n and not (0x40 <= ord(text[j]) <= 0x7E):
                j += 1
            if j >= n:
                return n
            self._csi(text[i + 2 : j], text[j])
            return j + 1
        if kind == "]":
            end = text.find("\x07", i)
            end2 = text.find("\x1b\\", i)
            ends = [e for e in (end, end2) if e != -1]
            if not ends:
                return n
            e = min(ends)
            return e + (1 if e == end else 2)
        if kind in "()*+":
            return i + 3
        return i + 2

    def _csi(self, params, final):
        private = params.startswith("?")
        if private:
            body = params[1:]
        else:
            body = params
        nums = [int(p) if p.isdigit() else 0 for p in body.split(";")] if body else []
        a = nums[0] if nums else 0
        b = nums[1] if len(nums) > 1 else 0
        if private:
            if final in "hl" and a == 1049 and final == "h":
                self.clear(2)
                self.x = self.y = 0
            return
        if final in "Hf":
            self.y = max(0, min(self.rows - 1, (a or 1) - 1))
            self.x = max(0, min(self.cols - 1, (b or 1) - 1))
        elif final == "A":
            self.y = max(0, self.y - (a or 1))
        elif final == "B":
            self.y = min(self.rows - 1, self.y + (a or 1))
        elif final == "C":
            self.x = min(self.cols - 1, self.x + (a or 1))
        elif final == "D":
            self.x = max(0, self.x - (a or 1))
        elif final == "G":
            self.x = max(0, min(self.cols - 1, (a or 1) - 1))
        elif final == "d":
            self.y = max(0, min(self.rows - 1, (a or 1) - 1))
        elif final == "J":
            self.clear(a)
        elif final == "K":
            self.erase_line(a)
        elif final == "X":
            for c in range(self.x, min(self.cols, self.x + (a or 1))):
                self.cells[self.y][c] = " "
        # SGR (m), modes, scroll regions, cursor save/restore: nothing to paint.

    def text(self):
        return "\n".join("".join(r).rstrip() for r in self.cells) + "\n"


KEYS = {
    "enter": b"\r", "esc": b"\x1b", "tab": b"\t", "backtab": b"\x1b[Z",
    "up": b"\x1b[A", "down": b"\x1b[B", "right": b"\x1b[C", "left": b"\x1b[D",
    "pgup": b"\x1b[5~", "pgdn": b"\x1b[6~", "home": b"\x1b[H", "end": b"\x1b[F",
    "space": b" ", "alt-up": b"\x1b[1;3A", "alt-down": b"\x1b[1;3B",
    "backspace": b"\x7f", "delete": b"\x1b[3~",
}


def key_bytes(name):
    if name in KEYS:
        return KEYS[name]
    if name.startswith("ctrl-") and len(name) == 6:
        return bytes([ord(name[5].lower()) - 96])
    if len(name) == 1:
        return name.encode("utf-8")
    raise SystemExit(f"rust-capture: unknown key `{name}`")


def mouse(col, row, code, release=True):
    seq = f"\x1b[<{code};{col + 1};{row + 1}M".encode()
    if release:
        seq += f"\x1b[<{code};{col + 1};{row + 1}m".encode()
    return seq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--arg", action="append", default=[])
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--size", default="120x40")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("steps", nargs="*")
    args = ap.parse_args()
    cols, rows = (int(v) for v in args.size.split("x"))
    os.makedirs(args.out_dir, exist_ok=True)
    env = dict(os.environ, TERM="xterm-256color", COLUMNS=str(cols), LINES=str(rows))
    for kv in args.env:
        k, _, v = kv.partition("=")
        env[k] = v

    pid, fd = pty.fork()
    if pid == 0:
        os.execve(args.bin, [os.path.basename(args.bin)] + args.arg, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    screen = Screen(cols, rows)
    alive = [True]

    def pump(seconds):
        end = time.time() + seconds
        got = False
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], min(0.05, max(0.0, end - time.time())))
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                alive[0] = False
                return got
            if not chunk:
                alive[0] = False
                return got
            screen.feed(chunk)
            got = True
        return got

    def settle(ms):
        quiet_for = ms / 1000.0
        deadline = time.time() + 60
        last = time.time()
        while time.time() < deadline and alive[0]:
            if pump(0.1):
                last = time.time()
            elif time.time() - last >= quiet_for:
                return
        return

    def until(text, present, limit=540):
        deadline = time.time() + limit
        while time.time() < deadline and alive[0]:
            if (text in screen.text()) == present:
                return True
            pump(0.2)
        print(f"rust-capture: timed out waiting for {'' if present else 'no '}`{text}`", file=sys.stderr)
        return False

    def send(b):
        os.write(fd, b)
        pump(0.15)

    written = 0
    wanted = 0
    for step in args.steps:
        verb, _, rest = step.partition(":")
        if verb == "settle":
            settle(int(rest or 1500))
        elif verb == "wait":
            pump(int(rest) / 1000.0)
        elif verb == "until":
            until(rest, True)
        elif verb == "untilnot":
            until(rest, False)
        elif verb == "key":
            send(key_bytes(rest))
        elif verb == "text":
            for ch in rest:
                send(ch.encode("utf-8"))
        elif verb in ("click", "rclick"):
            c, r = (int(v) for v in rest.split(","))
            send(mouse(c, r, 0 if verb == "click" else 2))
        elif verb == "wheel":
            c, r, d = rest.split(",")
            send(mouse(int(c), int(r), 64 if d == "up" else 65, release=False))
        elif verb == "snap":
            wanted += 1
            pump(0.2)
            path = os.path.join(args.out_dir, rest + ".txt")
            with open(path, "w") as f:
                f.write(screen.text())
            written += 1
            print(f"snap {path}", file=sys.stderr)
        elif verb == "quit":
            send(b"q")
            pump(1.0)
        else:
            raise SystemExit(f"rust-capture: unknown step `{step}`")
    if alive[0]:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return 0 if written == wanted else 1


if __name__ == "__main__":
    sys.exit(main())
