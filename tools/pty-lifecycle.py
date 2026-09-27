#!/usr/bin/env python3
"""Prove the terminal loop's marker + IPC lifecycle on a real pty.

The headless loop never writes the running-instance marker, so the
only way to test it is the terminal loop itself. This spawns BIN in a
pty on WORKSPACE, waits for `$TMPDIR/mnml-zig-running-$USER.workspace`
to appear, asserts it holds the workspace's real path with no trailing
newline, drops the named IPC command in `<ws>/.mnml/<subdir>/command`
and waits for the process to exit. Then:

    quit     → exit 0, the marker is gone
    restart  → exit 75, the marker is still there (the wrapper relaunches)

Set MNML_DATA_ROOT and TMPDIR before calling so nothing real is touched.
The pty is answered like a dumb xterm: every query gets no reply, which
the app tolerates. Prints one JSON line with what it saw; exit 0 when
every expectation held, 1 otherwise, 2 on a timeout.

    tools/pty-lifecycle.py BIN WORKSPACE quit|restart [IPC_SUBDIR]
"""
import json, os, pty, select, sys, time, fcntl, termios, struct

if len(sys.argv) < 4:
    sys.exit(__doc__)
BIN, WS, CMD = sys.argv[1], os.path.realpath(sys.argv[2]), sys.argv[3]
SUBDIR = sys.argv[4] if len(sys.argv) > 4 else "ipc-zig"
if CMD not in ("quit", "restart"):
    sys.exit("command must be quit or restart")

tmpdir = os.environ.get("TMPDIR") or "/tmp"
user = os.environ.get("USER") or "x"
marker = os.path.join(tmpdir, f"mnml-zig-running-{user}.workspace")
if os.path.exists(marker):
    os.unlink(marker)
ipc_cmd = os.path.join(WS, ".mnml", SUBDIR, "command")

pid, fd = pty.fork()
if pid == 0:
    # MNML_RUN_LOOP: this stands in for run.sh's loop, which catches the
    # restart's exit 75; without it the app relaunches itself.
    env = dict(os.environ, TERM="xterm-256color", MNML_RUN_LOOP="1")
    os.execvpe(BIN, [BIN, WS], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

seen = {"marker": marker, "cmd": CMD}


def drain(timeout):
    """Read whatever the app painted; the pty must not fill up."""
    r, _, _ = select.select([fd], [], [], timeout)
    if r:
        try:
            os.read(fd, 65536)
        except OSError:
            pass


def wait_for(pred, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if pred():
            return True
        drain(0.05)
    return False


def finish(ok, code):
    seen["ok"] = ok
    print(json.dumps(seen))
    sys.exit(code)


if not wait_for(lambda: os.path.exists(marker), 15):
    seen["error"] = "marker never appeared"
    finish(False, 2)
content = open(marker, "rb").read()
seen["content"] = content.decode("utf-8", "replace")
seen["content_ok"] = content == WS.encode()
# The channel is opened before the marker is written, so the command
# file exists by now; a line dropped there is what run.sh does.
if not wait_for(lambda: os.path.isdir(os.path.dirname(ipc_cmd)), 5):
    seen["error"] = "IPC dir never appeared: " + os.path.dirname(ipc_cmd)
    finish(False, 2)
drain(0.3)
with open(ipc_cmd, "a") as f:
    f.write('{"cmd":"%s"}\n' % CMD)

end = time.time() + 15
status = None
while time.time() < end:
    drain(0.1)
    p, st = os.waitpid(pid, os.WNOHANG)
    if p == pid:
        status = st
        break
if status is None:
    os.kill(pid, 9)
    seen["error"] = "process did not exit after " + CMD
    finish(False, 2)
code = os.waitstatus_to_exitcode(status)
seen["exit"] = code
seen["marker_after"] = os.path.exists(marker)
events = os.path.join(WS, ".mnml", SUBDIR, "events.jsonl")
seen["events_tail"] = open(events).read().strip().splitlines()[-2:] if os.path.exists(events) else []

want_code = 75 if CMD == "restart" else 0
want_marker = CMD == "restart"
ok = seen["content_ok"] and code == want_code and seen["marker_after"] == want_marker
finish(ok, 0 if ok else 1)
