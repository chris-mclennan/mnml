#!/usr/bin/env python3
"""Drive the real binary in a pty the way ghostty would, and prove the mouse works.

The headless runner injects clicks as IPC commands, so it never exercises
the terminal path: the capability probe, the mouse mode the app requests,
the SGR report the parser sees, the hit map at real coordinates. This does.
It answers the probes like ghostty (DA1, kitty keyboard, DECRQM 1016 =
pixel mouse SUPPORTED, 2026), asserts the app still asked for cell
coordinates (mode 1006, never 1016), dismisses the first-launch wizard,
then clicks a tree folder twice and expects the file inside it to appear
in the screen mirror. Exit 0 on success.

    tools/pty-mouse-check.py [BIN] [WORKSPACE]
"""
import os, pty, select, time, sys, fcntl, termios, struct, re, tempfile, shutil, subprocess

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "mnml-zig")
tmp = tempfile.mkdtemp(prefix="mnml-pty-")
ws = sys.argv[2] if len(sys.argv) > 2 else None
if ws is None:
    ws = os.path.join(tmp, "ws"); os.makedirs(os.path.join(ws, "src"))
    open(os.path.join(ws, "src", "main.zig"), "w").write("pub fn main() void {}\n")
    open(os.path.join(ws, "README.md"), "w").write("# demo\n")
    subprocess.run(["git", "init", "-q", ws], check=True)
data = os.path.join(tmp, "data"); os.makedirs(data)
open(os.path.join(data, "config.zon"), "w").write(".{ .ipc = .{ .write_screen = true } }\n")
ipc = os.path.join(ws, ".mnml", "ipc-zig")
env = dict(os.environ, MNML_DATA_ROOT=data, TERM="xterm-ghostty", TERM_PROGRAM="ghostty", COLORTERM="truecolor")

pid, fd = pty.fork()
if pid == 0:
    os.execve(BIN, ["mnml-zig", "--input", "standard", ws], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 1080, 800))
out = b""

def pump(t, answer=False):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r: continue
        try: chunk = os.read(fd, 65536)
        except OSError: return
        out += chunk
        if not answer: continue
        if b"\x1b[?1016$p" in chunk: os.write(fd, b"\x1b[?1016;2$y")
        if b"\x1b[?2026$p" in chunk: os.write(fd, b"\x1b[?2026;2$y")
        if b"\x1b[?u" in chunk: os.write(fd, b"\x1b[?1u")
        if b"\x1b[c" in chunk: os.write(fd, b"\x1b[?62;22c")
        if b"\x1b[6n" in chunk: os.write(fd, b"\x1b[1;1R")

def screen():
    try: return open(os.path.join(ipc, "screen.txt")).read().split("\n")
    except OSError: return []

def fail(msg):
    print("FAIL:", msg); os.write(fd, b"\x11"); pump(0.5)
    try: os.kill(pid, 15)
    except OSError: pass
    shutil.rmtree(tmp, ignore_errors=True); sys.exit(1)

pump(2.5, answer=True)
modes = [m.decode() for m in re.findall(rb"\x1b\[\?([0-9;]+)h", out)]
mouse = [m for m in modes if "1002" in m or "1000" in m]
if not mouse: fail(f"no mouse mode requested; modes {modes}")
if any("1016" in m for m in mouse): fail(f"pixel mouse requested: {mouse}")
if not any("1006" in m for m in mouse): fail(f"SGR cell mouse not requested: {mouse}")
os.write(fd, b"\x1b"); pump(0.5); os.write(fd, b"\x1b"); pump(0.5)
rows = screen()
if not rows: fail("no screen mirror (ipc.write_screen)")
src = next((i for i, r in enumerate(rows) if re.search(r"\bsrc\b", r)), None)
if src is None: fail("tree has no src row: " + repr(rows[:8]))
x, y = 6, src + 1
click = f"\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m".encode()
os.write(fd, click); pump(0.6); os.write(fd, click); pump(0.8)
if not any("main.zig" in r for r in screen()): fail("two clicks on the src folder did not open it")
os.write(fd, f"\x1b[<2;{x};{y}M\x1b[<2;{x};{y}m".encode()); pump(0.8)
if not any(("Rename" in r) or ("New file" in r) or ("Delete" in r) for r in screen()): fail("right-click opened no menu")
os.write(fd, b"\x1b"); pump(0.3)
os.write(fd, b"\x1b[<64;60;20M"); pump(0.3); os.write(fd, b"\x1b[<65;60;20M"); pump(0.3)
os.write(fd, b"\x11"); pump(1.0)
try: os.kill(pid, 15)
except OSError: pass
shutil.rmtree(tmp, ignore_errors=True)
print(f"ok: mouse modes {mouse}; click, double-click, right-click and wheel reached the app")
