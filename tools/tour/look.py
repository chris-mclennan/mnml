"""`tools/look.sh`: one agent, one real window, driven like the headless
harness — see docs/LOOK.md.

    look.sh launch WS [--exe PATH] [--cols N --rows N] [--root DIR]
    look.sh key SPEC | type TEXT | run ID | open PATH
    look.sh click X Y [right] | hover X Y | send JSON…
    look.sh shot NAME         → prints the PNG's path (Read it)
    look.sh pixel X Y [FX FY] → prints #rrggbb
    look.sh screen | status
    look.sh quit

The window's state lives under its root (default `.verify/look/<ws
name>/` in this checkout); `.verify/look/current` names the root the
other verbs act on, so an agent says `launch` once and then just verbs.
"""

import json
import os
import sys

from mnmlwin import REPO, DriveError, Window, base_env  # noqa: F401

LOOK = os.path.join(REPO, ".verify", "look")
CURRENT = os.path.join(LOOK, "current")


def die(msg, code=2):
    print(f"look.sh: {msg}", file=sys.stderr)
    return code


def open_window(root=None):
    if root is None:
        try:
            with open(CURRENT, encoding="utf-8") as f:
                root = f.read().strip()
        except OSError:
            return None
    try:
        with open(os.path.join(root, "look.json"), encoding="utf-8") as f:
            st = json.load(f)
    except OSError:
        return None
    w = Window(root, st["ws"], exe=st.get("exe"), cols=st["cols"], rows=st["rows"])
    with open(os.path.join(root, "data", "drive.json"), encoding="utf-8") as f:
        w.pid = json.load(f)["pid"]
    w._ack_seen = w._count_acks()
    return w


def run(args):
    verb = args.verb
    rest = args.rest
    if verb == "launch":
        if not rest:
            return die("launch needs a workspace")
        ws = os.path.abspath(rest[0])
        if not os.path.isdir(ws):
            return die(f"no such workspace: {ws}")
        root = os.path.abspath(args.root or os.path.join(LOOK, os.path.basename(ws.rstrip("/"))))
        cur = open_window()
        if cur and cur.alive():
            return die(f"a window is already up (pid {cur.pid}, root {cur.run_dir}); `look.sh quit` first — one window per agent")
        os.makedirs(root, exist_ok=True)
        w = Window(root, ws, exe=args.exe, cols=args.cols, rows=args.rows)
        with open(os.path.join(root, "look.json"), "w", encoding="utf-8") as f:
            json.dump({"ws": ws, "exe": w.exe, "cols": args.cols, "rows": args.rows}, f)
        try:
            w.launch()
        except DriveError as e:
            return die(str(e), 3)
        os.makedirs(LOOK, exist_ok=True)
        with open(CURRENT, "w", encoding="utf-8") as f:
            f.write(root)
        print(f"up: pid {w.pid}, {args.cols}x{args.rows}, root {root}")
        print(f"channel: {w.ipc}/command (input on)")
        return 0

    w = open_window(args.root)
    if w is None:
        return die("no window — `look.sh launch WS` first")
    if verb == "quit":
        w.quit()
        try:
            os.unlink(CURRENT)
        except OSError:
            pass
        print("quit")
        return 0
    if not w.alive():
        return die(f"the window's app (pid {w.pid}) is gone; `look.sh launch` again", 3)
    try:
        if verb == "key":
            w.key(" ".join(rest))
        elif verb == "type":
            w.type(" ".join(rest).replace("\\n", "\n"))
        elif verb == "run":
            w.run(rest[0])
        elif verb == "open":
            w.open(rest[0])
        elif verb == "click":
            w.click(int(rest[0]), int(rest[1]), rest[2] if len(rest) > 2 else "left")
        elif verb == "hover":
            w.hover(int(rest[0]), int(rest[1]))
        elif verb == "send":
            w.send(*[json.loads(r) for r in rest])
        elif verb == "shot":
            name = rest[0] if rest else "shot"
            if "/" in name or name.startswith("."):
                return die("shot takes a bare name")
            path = os.path.join(w.run_dir, "shots", name + ".png")
            w.shot(path)
            print(path)
        elif verb == "pixel":
            fx = float(rest[2]) if len(rest) > 2 else 0.5
            fy = float(rest[3]) if len(rest) > 3 else 0.5
            print(w.pixel(int(rest[0]), int(rest[1]), fx, fy))
        elif verb == "screen":
            sys.stdout.write(w.screen())
        elif verb == "status":
            print(json.dumps(w.status(), indent=1))
        else:
            return die(f"unknown verb `{verb}`")
    except DriveError as e:
        return die(str(e), 3)
    return 0
