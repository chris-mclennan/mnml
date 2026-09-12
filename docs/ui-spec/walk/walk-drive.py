#!/usr/bin/env python3
"""walk-drive.py — drive one binary headless over the file-IPC, keep a
screen / status.json / rects.json at every `snapshot` line.

    walk-drive.py --side rust|zig --bin BIN --ws WS --data DATA --ipc IPC \
        --steps FILE --out DIR --cols N --rows N --input vim|standard

A steps file is JSONL as tools/ui-diff.sh feeds it; a line starting with
`#` is a label for the next snapshot (never sent). Every JSON line is
appended to the command file and waited for (its ack in events.jsonl);
a `snapshot` line is then also waited for its next screen dump and the
three files are copied to DIR/NN-<label>.<side>.{txt,status.json,rects.json}.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time


def parse_args(argv):
    args = {}
    i = 1
    while i < len(argv):
        args[argv[i][2:]] = argv[i + 1]
        i += 2
    return args


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def mtime_ns(path):
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return 0


def count_lines(path):
    try:
        with open(path, "rb") as f:
            return f.read().count(b"\n")
    except OSError:
        return 0


def wait_until(pred, timeout_s, poll_s=0.002):
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(poll_s)
    return pred()


def stable_read(path, rows):
    last = None
    for _ in range(60):
        t = read_text(path)
        if t == last and t.count("\n") >= rows - 1:
            return t
        last = t
        time.sleep(0.01)
    return last or ""


def main():
    a = parse_args(sys.argv)
    side, binary, ws, data = a["side"], a["bin"], a["ws"], a["data"]
    ipc, steps_path, out = a["ipc"], a["steps"], a["out"]
    cols, rows = int(a["cols"]), int(a["rows"])
    style = a.get("input", "standard")
    extra = a.get("args", "")
    os.makedirs(out, exist_ok=True)
    shutil.rmtree(ipc, ignore_errors=True)
    env = dict(os.environ, MNML_DATA_ROOT=data, MNML_COLS=str(cols), MNML_ROWS=str(rows))
    if side == "zig":
        env["MNML_IPC_DIR"] = ipc
    cmd_path = os.path.join(ipc, "command")
    screen_path = os.path.join(ipc, "screen.txt")
    status_path = os.path.join(ipc, "status.json")
    rects_path = os.path.join(ipc, "rects.json")
    events_path = os.path.join(ipc, "events.jsonl")
    log = open(os.path.join(out, side + ".log"), "w")
    argv = [binary, "--headless", "--input", style] + (extra.split() if extra else []) + [ws]
    t0 = time.monotonic()
    proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, env=env)
    meta = {"side": side, "bin": binary, "argv": argv, "snaps": []}
    try:
        if not wait_until(lambda: '"start"' in read_text(events_path), 60):
            meta["error"] = "no start event in 60 s"
        meta["start_ms"] = round((time.monotonic() - t0) * 1000)
        wait_until(lambda: len(read_text(screen_path)) > 0, 60)
        meta["first_frame_ms"] = round((time.monotonic() - t0) * 1000)
        time.sleep(1.2)
        with open(steps_path, encoding="utf-8") as f:
            lines = [l.rstrip("\n") for l in f]
        label = "rest"
        n = 0
        for line in lines:
            s = line.strip()
            if not s:
                continue
            if s.startswith("#"):
                label = re.sub(r"[^A-Za-z0-9_.-]+", "-", s.lstrip("# ").strip()).strip("-")[:40] or "snap"
                continue
            n0 = count_lines(events_path)
            t_ns = time.time_ns()
            with open(cmd_path, "a", encoding="utf-8") as f:
                f.write(s + "\n")
            try:
                ms = json.loads(s).get("ms", 0) if '"wait_ms"' in s else 0
            except ValueError:
                ms = 0
            acked = wait_until(lambda: count_lines(events_path) > n0, 30 + ms / 1000)
            if not acked:
                print("%s: no ack for %s" % (side, s), file=sys.stderr)
            if '"snapshot"' in s:
                t_ack_ns = time.time_ns()
                wait_until(lambda: mtime_ns(screen_path) > t_ack_ns, 3)
                time.sleep(0.25)
                screen = stable_read(screen_path, rows)
                base = os.path.join(out, "%02d-%s.%s" % (n, label, side))
                with open(base + ".txt", "w", encoding="utf-8") as f:
                    f.write(screen)
                for src, ext in ((status_path, ".status.json"), (rects_path, ".rects.json")):
                    try:
                        shutil.copy(src, base + ext)
                    except OSError:
                        pass
                meta["snaps"].append({"n": n, "label": label, "ms": round((time.monotonic() - t0) * 1000)})
                n += 1
            else:
                time.sleep(0.05)
        with open(cmd_path, "a", encoding="utf-8") as f:
            f.write('{"cmd":"quit"}\n')
        try:
            proc.wait(timeout=8)
            meta["exit"] = proc.returncode
        except subprocess.TimeoutExpired:
            meta["exit"] = "killed"
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        log.close()
    try:
        shutil.copy(events_path, os.path.join(out, side + ".events.jsonl"))
    except OSError:
        pass
    with open(os.path.join(out, side + ".meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("%s: %d snapshots, first frame %s ms, exit %s" % (side, len(meta["snaps"]), meta.get("first_frame_ms"), meta.get("exit")))


if __name__ == "__main__":
    main()
