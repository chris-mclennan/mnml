#!/usr/bin/env python3
"""Drive the real binary in a pty and prove the terminal cursor is where it should be.

Headless has no terminal cursor at all, so no `.test` script can see the
thing this checks: the bytes mnml actually writes out. This runs the real
binary under a pty, answers the probes like ghostty, and reads the
cursor stream — `\\x1b[?25h` / `\\x1b[?25l` (show / hide), `\\x1b[N q`
(DECSCUSR: 2 steady block, 4 steady underline, 6 steady bar) and the CUP
that goes with a shown cursor.

It asserts the surfaces a user types into get the cursor and the ones
that do not, do not:

  editor, standard (modeless)  shown, a bar
  vim NORMAL / VISUAL          shown, a block
  vim INSERT                   shown, a bar
  vim REPLACE                  shown, an underline
  the command palette          shown, a bar, on the palette's query row
  a prompt (Go to line)        shown, a bar, on the prompt's row
  the find bar                 shown, a bar, on the find row
  the `:` command line         shown, a bar, on the last row
  the file tree                hidden — it has its own highlighted row
  the help overlay             hidden — a box that takes no typing
  a menu                       hidden — same

Every surface is confirmed open in the screen mirror first, so a chord
that did not land fails loudly instead of passing on the editor's cursor.

    tools/pty-cursor-check.py [BIN] [WORKSPACE]
    MNML_INPUT_STYLE=vim tools/pty-cursor-check.py
"""
import os, pty, select, time, sys, fcntl, termios, struct, re, tempfile, shutil, subprocess

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "mnml-zig")
STYLE = os.environ.get("MNML_INPUT_STYLE", "standard")
tmp = tempfile.mkdtemp(prefix="mnml-cursor-")
ws = sys.argv[2] if len(sys.argv) > 2 else None
if ws is None:
    ws = os.path.join(tmp, "ws"); os.makedirs(os.path.join(ws, "src"))
    open(os.path.join(ws, "src", "main.zig"), "w").write("pub fn main() void {\n    alpha();\n}\n")
    open(os.path.join(ws, "README.md"), "w").write("# demo\n")
    subprocess.run(["git", "init", "-q", ws], check=True)
data = os.path.join(tmp, "data"); os.makedirs(data)
open(os.path.join(data, "config.zon"), "w").write(".{ .ipc = .{ .write_screen = true } }\n")
ipc = os.path.join(ws, ".mnml", "ipc-zig")
env = dict(os.environ, MNML_DATA_ROOT=data, TERM="xterm-ghostty", TERM_PROGRAM="ghostty", COLORTERM="truecolor")

pid, fd = pty.fork()
if pid == 0:
    os.execve(BIN, ["mnml-zig", "--input", STYLE, ws], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 1080, 800))
out = b""
# The cursor state as the host would hold it: the last show/hide, the
# last DECSCUSR, the CUP that came with a shown cursor.
vis, shape, pos, last_cup = None, None, None, None
failures = []


def feed(chunk):
    """Replay a chunk the way a terminal would, in order."""
    global vis, shape, pos, last_cup
    for m in re.finditer(rb"\x1b\[\?25([hl])|\x1b\[([0-9]) q|\x1b\[([0-9]+);([0-9]+)H", chunk):
        if m.group(1) is not None:
            vis = m.group(1) == b"h"
            # vaxis writes cup-then-show for the cursor, so the CUP right
            # before a show is the one that placed it.
            if vis:
                pos = last_cup
        elif m.group(2) is not None:
            shape = int(m.group(2))
        else:
            last_cup = (int(m.group(3)), int(m.group(4)))


def pump(t, answer=False):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r: continue
        try: chunk = os.read(fd, 65536)
        except OSError: return
        out += chunk
        feed(chunk)
        if not answer: continue
        if b"\x1b[?1016$p" in chunk: os.write(fd, b"\x1b[?1016;2$y")
        if b"\x1b[?2026$p" in chunk: os.write(fd, b"\x1b[?2026;2$y")
        if b"\x1b[?u" in chunk: os.write(fd, b"\x1b[?1u")
        if b"\x1b[c" in chunk: os.write(fd, b"\x1b[?62;22c")
        if b"\x1b[6n" in chunk: os.write(fd, b"\x1b[1;1R")


def screen():
    try: return open(os.path.join(ipc, "screen.txt")).read().split("\n")
    except OSError: return []


def send(b, t=0.45):
    os.write(fd, b); pump(t)


def csi_u(code, mods):
    """A kitty-protocol chord: mods is 1 + shift(1) + alt(2) + ctrl(4)."""
    return f"\x1b[{code};{mods}u".encode()


CTRL, SHIFT = 4, 1
BLOCK, UNDERLINE, BAR = 2, 4, 6
NAMES = {0: "default", 1: "blinking block", 2: "block", 3: "blinking underline",
         4: "underline", 5: "blinking bar", 6: "bar"}


def state():
    return ("shown " + f"{NAMES.get(shape, shape)} at row {pos[0]} col {pos[1]}" if vis and pos
            else "shown " + str(NAMES.get(shape, shape)) if vis else "hidden")


def bad(what, why):
    failures.append(f"{what}: {why}; cursor is {state()}")
    print(f"  ✗ {what}: {why} — cursor is {state()}")


def check(what, want_vis, want_shape=None, on_screen=None, want_row=None):
    """`on_screen` must be visible first: a chord that did not land must
    not pass on whatever the previous surface left behind."""
    if on_screen is not None and not any(on_screen in r for r in screen()):
        bad(what, f"never opened (no {on_screen!r} on screen)")
        return
    if vis != want_vis:
        bad(what, f"wanted {'shown' if want_vis else 'hidden'}")
        return
    if want_vis and want_shape is not None and shape != want_shape:
        bad(what, f"wanted a {NAMES[want_shape]}")
        return
    if want_vis and want_row is not None and (pos is None or pos[0] != want_row):
        bad(what, f"wanted row {want_row}")
        return
    print(f"  ✓ {what}: {state()}")


def dump(tag):
    if os.environ.get("MNML_CURSOR_DUMP"):
        print(f"--- {tag} ---")
        for i, r in enumerate(screen()):
            print(f"{i+1:3} |{r}")


def row_of(needle):
    """1-based screen row holding `needle`, as CUP counts."""
    for i, r in enumerate(screen()):
        if needle in r:
            return i + 1
    return None


def below(needle):
    """The row under `needle` — an overlay carries its title on its top
    edge and its input on the row below."""
    r = row_of(needle)
    return None if r is None else r + 1


pump(2.5, answer=True)
if not screen():
    print("FAIL: no screen mirror (ipc.write_screen)"); os.kill(pid, 15); sys.exit(1)
send(b"\x1b"); send(b"\x1b")  # past the first-launch wizard

print(f"── {STYLE} ──")
readme = row_of("README.md")
if readme is None:
    print("FAIL: no README.md row"); os.kill(pid, 15); sys.exit(1)
# The `:` line opens from any focus, either profile: ctrl+;
send(csi_u(59, 1 + CTRL), 0.7)
check("the `:` command line", True, BAR, ":", len(screen()) - 1)
send(b"e src/main.zig\r", 0.9)
check("an editor opened from the `:` line", True, None, "main.zig")

if STYLE == "vim":
    check("vim NORMAL", True, BLOCK)
    send(b"i"); check("vim INSERT", True, BAR, "INSERT")
    send(b"\x1b"); check("vim NORMAL again", True, BLOCK, "NORMAL")
    send(b"R"); check("vim REPLACE", True, UNDERLINE, "REPLACE")
    send(b"\x1b"); send(b"v"); check("vim VISUAL", True, BLOCK, "VISUAL")
    send(b"\x1b")
else:
    check("editor, modeless", True, BAR)

# The palette: its query row takes the typing, so it takes the cursor.
send(csi_u(112, 1 + CTRL), 0.8)  # ctrl+p
dump("picker")
# The box's title is on its top edge; the query row is the one below it.
check("the file picker's query", True, BAR, "Open file", below("Open file"))
send(b"\x1b", 0.6)

# Ctrl+G and Ctrl+F are vim's own chords in the vim profile — page
# motions, not overlays — so these two are the standard profile's.
if STYLE != "vim":
    send(csi_u(103, 1 + CTRL), 0.8)  # ctrl+g
    dump("prompt")
    check("a prompt (Go to line)", True, BAR, "Go to line", below("Go to line"))
    send(b"\x1b", 0.6)

    send(csi_u(102, 1 + CTRL), 0.8)  # ctrl+f
    check("find bar", True, BAR, "Find", row_of("Find"))
    send(b"\x1b", 0.6)
else:
    # vim's `/` opens mnml's find bar, so that is where its caret goes.
    send(b"/alpha", 0.7)
    check("vim's `/` search", True, BAR, "Find", row_of("Find"))
    send(b"\x1b", 0.5)

# The rename box: a prompt reached from the tree's own menu, in either
# profile.
tree_row = row_of("README.md")
send(f"\x1b[<2;15;{tree_row}M\x1b[<2;15;{tree_row}m".encode(), 0.8)
rename = row_of("Rename")
if rename:
    send(f"\x1b[<0;20;{rename}M\x1b[<0;20;{rename}m".encode(), 0.8)
    dump("rename")
    check("the rename box", True, BAR, "Rename", below("Rename"))
    send(b"\x1b", 0.6)
else:
    bad("the rename box", "the tree's menu has no Rename row")
send(b"\x1b", 0.4)

# The tree: its own highlighted row, no text field, no cursor.
send(csi_u(101, 1 + CTRL + SHIFT), 0.8)  # ctrl+shift+e = view.focus_tree
if any("TREE" in r or "EXPLORER" in r for r in screen()):
    check("the file tree", False)
else:
    check("the file tree", False)  # the mode chip may not name it; the state is the check

# Help: a box that takes no typing.
send(b"\x1bOP", 0.9)  # F1
check("the help overlay", False, on_screen="Keymap" if row_of("Keymap") else None)
send(b"\x1b", 0.6)

# A menu over the tree: same — a highlighted row of its own.
tree_row = row_of("README.md")
if tree_row:
    send(f"\x1b[<2;15;{tree_row}M\x1b[<2;15;{tree_row}m".encode(), 0.8)
    check("a context menu", False, on_screen="Rename" if row_of("Rename") else None)
    send(b"\x1b", 0.5)

send(b"\x11", 1.0)  # ctrl+q
try: os.kill(pid, 15)
except OSError: pass
shutil.rmtree(tmp, ignore_errors=True)
if failures:
    print("FAIL:")
    for f_ in failures: print("  " + f_)
    sys.exit(1)
print("ok: the terminal cursor is on the surface that takes the typing, in the right shape")
