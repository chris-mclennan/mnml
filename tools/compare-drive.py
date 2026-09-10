#!/usr/bin/env python3
"""The navigation harness's driver and report writer (see tools/compare.sh).

    compare-drive.py run --side rust|zig --bin BIN --ws WS --data DATA \
        --ipc IPC_DIR --steps FILE --out DIR --cols N --rows N --input vim|standard
    compare-drive.py report --out DIR --steps FILE --cols N --rows N

`run` starts one binary headless on WS, feeds the steps file one line at
a time, and after EVERY line waits for the ack in events.jsonl and then
for the next screen dump, copying screen.txt and status.json to
DIR/step-NNN.<side>.txt / .status.json. Timing is measured from the
moment the line is appended: `ack_ms` is when the ack landed in
events.jsonl (the command has been applied), `dump_ms` is when
screen.txt was next written after that (the frame that shows it) — both
polled at 1 ms. Both editors dump every frame whether or not anything
changed, so the dump's mtime alone would not say when a command landed;
the ack is what anchors it. Resident memory is `ps -o rss` sampled every
50 ms on a thread; the peak is reported. `first_frame_ms` is from spawn
to the first non-empty screen.txt.

`report` reads both sides' snapshots and writes diff.md and timing.md.
The rail (columns 0–3) diverges by design (docs/ui-spec/README.md), so
the per-step count is of rows whose columns 4+ differ, as
tools/ui-diff.sh counts. status.json carries the cursor (1-based line /
col) and the mode; neither side exposes a scroll offset or frame timing
there, so the top visible line is read off the gutter — the first
line-number cell on the first text row — and `dump_ms` stands in for
frame time.
"""
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import unicodedata


# ─── run ────────────────────────────────────────────────────────────────

def parse_args(argv):
    args = {"_": []}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            args[a[2:]] = argv[i + 1]
            i += 2
        else:
            args["_"].append(a)
            i += 1
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


class RssSampler(threading.Thread):
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid = pid
        self.peak_kb = 0
        self.samples = 0
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            try:
                out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.pid)], capture_output=True, text=True, timeout=2).stdout.strip()
                if out:
                    self.peak_kb = max(self.peak_kb, int(out))
                    self.samples += 1
            except (subprocess.SubprocessError, ValueError):
                pass
            self.stop.wait(0.05)


def wait_until(pred, timeout_s, poll_s=0.001):
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(poll_s)
    return pred()


def stable_read(path, rows):
    """screen.txt is truncated then written; a read mid-write is short.
    Re-read until two reads agree and the row count looks whole."""
    last = None
    for _ in range(40):
        t = read_text(path)
        if t == last and t.count("\n") >= rows - 1:
            return t
        last = t
        time.sleep(0.005)
    return last or ""


def run(args):
    side, binary, ws, data = args["side"], args["bin"], args["ws"], args["data"]
    ipc_dir, steps_path, out = args["ipc"], args["steps"], args["out"]
    cols, rows = int(args["cols"]), int(args["rows"])
    input_style = args.get("input", "vim")
    os.makedirs(out, exist_ok=True)
    shutil.rmtree(ipc_dir, ignore_errors=True)
    env = dict(os.environ, MNML_DATA_ROOT=data, MNML_COLS=str(cols), MNML_ROWS=str(rows))
    if side == "zig":
        env["MNML_IPC_DIR"] = ipc_dir
    cmd_path = os.path.join(ipc_dir, "command")
    screen_path = os.path.join(ipc_dir, "screen.txt")
    status_path = os.path.join(ipc_dir, "status.json")
    events_path = os.path.join(ipc_dir, "events.jsonl")

    log = open(os.path.join(out, side + ".log"), "w")
    t_spawn = time.monotonic()
    proc = subprocess.Popen([binary, "--headless", "--input", input_style, ws], stdout=log, stderr=subprocess.STDOUT, env=env)
    sampler = RssSampler(proc.pid)
    sampler.start()
    timing = {"side": side, "bin": binary, "pid": proc.pid, "steps": []}
    try:
        if not wait_until(lambda: '"start"' in read_text(events_path), 20):
            timing["error"] = "no start event in 20 s"
        timing["start_event_ms"] = round((time.monotonic() - t_spawn) * 1000, 1)
        wait_until(lambda: len(read_text(screen_path)) > 0, 20)
        timing["first_frame_ms"] = round((time.monotonic() - t_spawn) * 1000, 1)
        # Let the first paint settle (session restore, git, the tree).
        time.sleep(0.8)

        with open(steps_path, encoding="utf-8") as f:
            lines = [l.strip() for l in f if l.strip()]
        for i, line in enumerate(lines):
            n0 = count_lines(events_path)
            t0 = time.monotonic()
            t0_ns = time.time_ns()
            with open(cmd_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
            try:
                ms = json.loads(line).get("ms", 0) if '"wait_ms"' in line else 0
            except ValueError:
                ms = 0
            acked = wait_until(lambda: count_lines(events_path) > n0, 30 + ms / 1000)
            t_ack = time.monotonic()
            t_ack_ns = time.time_ns()
            dumped = wait_until(lambda: mtime_ns(screen_path) > t_ack_ns, 5)
            t_dump = time.monotonic()
            # One more frame so a command whose effect lands a tick later
            # (a deferred layout, a scroll settling) is in the copy too.
            time.sleep(0.12)
            screen = stable_read(screen_path, rows)
            status = read_text(status_path)
            ack_line = ""
            try:
                ack_line = read_text(events_path).split("\n")[n0]
            except IndexError:
                pass
            base = os.path.join(out, "step-%03d.%s" % (i, side))
            with open(base + ".txt", "w", encoding="utf-8") as f:
                f.write(screen)
            with open(base + ".status.json", "w", encoding="utf-8") as f:
                f.write(status)
            timing["steps"].append({
                "i": i, "cmd": line, "acked": acked, "dumped": dumped,
                "ack_ms": round((t_ack - t0) * 1000, 1),
                "dump_ms": round((t_dump - t0) * 1000, 1),
                "wait_ms": ms, "ack": ack_line,
            })
            if not acked:
                print("%s: step %d got no ack: %s" % (side, i, line), file=sys.stderr)
        with open(cmd_path, "a", encoding="utf-8") as f:
            f.write('{"cmd":"quit"}\n')
        try:
            proc.wait(timeout=5)
            timing["exit_code"] = proc.returncode
        except subprocess.TimeoutExpired:
            timing["exit_code"] = "killed"
    finally:
        sampler.stop.set()
        sampler.join(timeout=1)
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        log.close()
    timing["peak_rss_kb"] = sampler.peak_kb
    timing["rss_samples"] = sampler.samples
    with open(os.path.join(out, side + ".timing.json"), "w", encoding="utf-8") as f:
        json.dump(timing, f, indent=1)
    print("%s: %d steps, first frame %.0f ms, peak rss %.1f MB, exit %s" % (
        side, len(timing["steps"]), timing.get("first_frame_ms", 0), sampler.peak_kb / 1024.0, timing.get("exit_code")))


# ─── report ─────────────────────────────────────────────────────────────

GUTTER_RE = re.compile(r"(?<![\w.])(\d{1,6})(?=[ │▏▎▍▌▋▊▉█]|$)")


def find_text_col(screen_rows):
    """The column where the editor's gutter begins: the first column
    right of the rail where a body row shows a line number followed by a
    space. Falls back to 30 (the default tree width)."""
    for r in screen_rows[2:-3]:
        for m in re.finditer(r"(?<![\w])(\d{1,6}) ", r[4:]):
            c = m.start() + 4
            if c < 60:
                bar = r.rfind("│", 0, c)
                return bar + 1 if bar >= 0 else max(4, c - 6)
    return 30


def viewport(screen_rows, text_col, rows):
    """(top, sticky) for one screen. Walks the body rows: a leading row
    with no gutter number whose text starts right at the gutter is a
    pinned scope row without a number (the Rust editor's); a leading
    numbered row whose number is not consecutive with the next numbered
    row is a pinned scope row with a number (the Zig editor's). The
    first row after the pinned ones carries the first visible line;
    `top` is that minus the pinned count — the pinned rows overlay the
    viewport's first rows — so a wrapped continuation under a pinned row
    puts the estimate off by one. Neither side's status.json exposes the
    real scroll offset."""
    nums = []  # (row index, number or None, raw)
    for i in range(2, rows - 2):
        r = screen_rows[i] if i < len(screen_rows) else ""
        seg = r[text_col:text_col + 12]
        m = GUTTER_RE.search(seg)
        if m:
            nums.append((i, int(m.group(1))))
        elif seg.strip() and not seg.startswith(" ") and "›" not in seg:
            nums.append((i, None))  # a numberless row whose text starts at the gutter
    if not nums:
        return None, 0
    sticky = 0
    k = 0
    while k < len(nums) - 1:
        n, nxt = nums[k][1], nums[k + 1][1]
        if n is None or (nxt is not None and n + 1 < nxt):
            sticky += 1
            k += 1
        else:
            break
    first = next((n for _, n in nums[k:] if n is not None), None)
    if first is None:
        return None, sticky
    return first - sticky, sticky


def normalize_row(r, cols):
    """The comparable part of a screen row: columns 5..cols-2 (the rail,
    the tree's cursor cell and the last column — the Zig editor's
    scrollbar — are excluded), a wide glyph's spacer cell blanked
    (the Rust dump leaves a stale character there), trailing blanks
    dropped."""
    out = []
    prev_wide = False
    for ch in r[5:cols - 1]:
        if prev_wide:
            out.append(" ")
            prev_wide = False
            continue
        out.append(ch)
        prev_wide = unicodedata.east_asian_width(ch) in ("W", "F")
    return "".join(out).rstrip()


def rows_diff(a, b, cols, rows):
    """(raw, rail, text, text_rows): raw = rows differing at all, rail =
    those differing only in columns 0-3 (ui-diff's split), text = body
    rows (2..rows-3) still differing after normalize_row."""
    raw = rail = text = 0
    text_rows = []
    for i, (x, y) in enumerate(itertools.zip_longest(a, b, fillvalue="")):
        if x == y:
            continue
        raw += 1
        if x[4:] == y[4:]:
            rail += 1
        if 2 <= i <= rows - 3 and normalize_row(x, cols) != normalize_row(y, cols):
            text += 1
            text_rows.append(i)
    return raw, rail, text, text_rows


def load_status(path):
    try:
        return json.loads(read_text(path) or "{}")
    except ValueError:
        return {}


def classify(cur_r, cur_z, top_r, top_z, text_rows, sr, sz, cols, text_col):
    tags = []
    if top_r is not None and top_z is not None and top_r != top_z:
        tags.append("scroll offset")
    if cur_r != cur_z:
        tags.append("cursor placement")
    if text_rows:
        gutter_only = wrap = 0
        for i in text_rows:
            x = sr[i] if i < len(sr) else ""
            y = sz[i] if i < len(sz) else ""
            if normalize_row(x, cols)[text_col - 5 + 6:] == normalize_row(y, cols)[text_col - 5 + 6:]:
                gutter_only += 1
            elif "↪" in x or (x[text_col:text_col + 6].strip() == "" or y[text_col:text_col + 6].strip() == ""):
                wrap += 1
        if wrap:
            tags.append("wrap")
        if gutter_only:
            tags.append("gutter")
        if not wrap and not gutter_only and not tags:
            tags.append("highlight/other")
    return ", ".join(tags) if tags else "same"


def short_cmd(line):
    s = line.replace("|", "\\|")
    return s if len(s) <= 48 else s[:45] + "…"


def report(args):
    out, steps_path = args["out"], args["steps"]
    cols, rows = int(args["cols"]), int(args["rows"])
    with open(steps_path, encoding="utf-8") as f:
        lines = [l.strip() for l in f if l.strip()]
    tr = json.load(open(os.path.join(out, "rust.timing.json")))
    tz = json.load(open(os.path.join(out, "zig.timing.json")))
    md = []
    md.append("# %s — per-step diff (%dx%d)\n" % (os.path.basename(out), cols, rows))
    md.append("`rows`: rows whose columns 4+ differ (the rail excluded, as `tools/ui-diff.sh` counts). "
              "`text`: body rows (2..%d) still differing once the tree's cursor cell (column 4), the last column "
              "(the Zig editor's scrollbar), a wide glyph's spacer cell and trailing blanks are dropped — the number to read. "
              "`cur`: `status.json` cursor `line:col` (1-based). `top`: the first visible line, read off the gutter "
              "(neither side's `status.json` has a scroll offset); `+N` = N pinned scope rows above it. "
              "`class`: an automatic first guess — the research doc holds the reviewed one.\n" % (rows - 3))
    md.append("| # | step | rows | text | rust cur | zig cur | rust top | zig top | mode | class |")
    md.append("|---|------|-----:|-----:|---------:|--------:|---------:|--------:|------|-------|")
    per_step = []
    for i, line in enumerate(lines):
        base = os.path.join(out, "step-%03d" % i)
        sr = read_text(base + ".rust.txt").split("\n")
        sz = read_text(base + ".zig.txt").split("\n")
        st_r = load_status(base + ".rust.status.json")
        st_z = load_status(base + ".zig.status.json")
        cur_r = "%s:%s" % (st_r.get("cursor", {}).get("line", "?"), st_r.get("cursor", {}).get("col", "?"))
        cur_z = "%s:%s" % (st_z.get("cursor", {}).get("line", "?"), st_z.get("cursor", {}).get("col", "?"))
        tc = find_text_col(sr)
        (top_r, stk_r), (top_z, stk_z) = viewport(sr, tc, rows), viewport(sz, find_text_col(sz), rows)
        raw, rail, text, text_rows = rows_diff(sr, sz, cols, rows)
        cls = classify(cur_r, cur_z, top_r, top_z, text_rows, sr, sz, cols, tc)
        mode = st_r.get("mode", "?") if st_r.get("mode") == st_z.get("mode") else "%s / %s" % (st_r.get("mode", "?"), st_z.get("mode", "?"))
        fmt_top = lambda t, k: ("%s" % t if t is not None else "?") + ("+%d" % k if k else "")
        md.append("| %d | `%s` | %d | %d | %s | %s | %s | %s | %s | %s |" % (
            i, short_cmd(line), raw - rail, text, cur_r, cur_z, fmt_top(top_r, stk_r), fmt_top(top_z, stk_z), mode, cls))
        per_step.append({"i": i, "cmd": line, "rows": raw - rail, "text": text, "text_rows": text_rows,
                         "cur_r": cur_r, "cur_z": cur_z, "top_r": top_r, "top_z": top_z, "sticky_r": stk_r, "sticky_z": stk_z, "class": cls})
    worst = sorted(per_step, key=lambda d: (-d["text"], d["i"]))[:3]
    md.append("\n## Worst three steps by `text` (excerpts)\n")
    for d in worst:
        if d["text"] == 0:
            continue
        i = d["i"]
        base = os.path.join(out, "step-%03d" % i)
        sr = read_text(base + ".rust.txt").split("\n")
        sz = read_text(base + ".zig.txt").split("\n")
        md.append("### step %d — `%s` — %d text rows (%s)\n" % (i, d["cmd"], d["text"], d["class"]))
        md.append("```")
        for r in d["text_rows"][:6]:
            md.append("row %2d rust: %s" % (r, (sr[r] if r < len(sr) else "")[28:].rstrip()))
            md.append("row %2d zig:  %s" % (r, (sz[r] if r < len(sz) else "")[28:].rstrip()))
        if len(d["text_rows"]) > 6:
            md.append("… %d more rows" % (len(d["text_rows"]) - 6))
        md.append("```\n")
    with open(os.path.join(out, "diff.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")
    with open(os.path.join(out, "diff.json"), "w", encoding="utf-8") as f:
        json.dump(per_step, f, indent=0)

    tm = []
    tm.append("# %s — timing (%dx%d)\n" % (os.path.basename(out), cols, rows))
    tm.append("| side | binary | start event | first frame | peak RSS | rss samples | exit |")
    tm.append("|------|--------|------------:|------------:|---------:|------------:|------|")
    for t in (tr, tz):
        tm.append("| %s | `%s` | %s ms | %s ms | %.1f MB | %d | %s |" % (
            t["side"], t["bin"], t.get("start_event_ms"), t.get("first_frame_ms"),
            t.get("peak_rss_kb", 0) / 1024.0, t.get("rss_samples", 0), t.get("exit_code")))
    tm.append("\nPer step, ms from the command's append: `ack` = the ack line in events.jsonl (applied), "
              "`dump` = the next screen.txt write after the ack (painted). A `wait_ms` step's ack includes its own sleep.\n")
    tm.append("| # | step | rust ack | rust dump | zig ack | zig dump |")
    tm.append("|---|------|---------:|----------:|--------:|---------:|")
    sum_r = sum_z = 0.0
    n = 0
    max_r = max_z = (0, -1)
    for i, line in enumerate(lines):
        a = tr["steps"][i] if i < len(tr["steps"]) else {}
        b = tz["steps"][i] if i < len(tz["steps"]) else {}
        flag_r = "" if a.get("acked", True) else " (no ack)"
        flag_z = "" if b.get("acked", True) else " (no ack)"
        tm.append("| %d | `%s` | %s%s | %s | %s%s | %s |" % (
            i, short_cmd(line), a.get("ack_ms", "?"), flag_r, a.get("dump_ms", "?"), b.get("ack_ms", "?"), flag_z, b.get("dump_ms", "?")))
        if a.get("wait_ms", 0) == 0 and "dump_ms" in a and "dump_ms" in b:
            sum_r += a["dump_ms"]
            sum_z += b["dump_ms"]
            n += 1
            max_r = max(max_r, (a["dump_ms"], i))
            max_z = max(max_z, (b["dump_ms"], i))
    if n:
        tm.append("\nOver the %d non-wait steps — mean dump latency: rust %.1f ms, zig %.1f ms; "
                  "slowest: rust %.0f ms (step %d), zig %.0f ms (step %d)." % (n, sum_r / n, sum_z / n, max_r[0], max_r[1], max_z[0], max_z[1]))
    with open(os.path.join(out, "timing.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(tm) + "\n")
    n_text = sum(1 for d in per_step if d["text"] > 0)
    n_cls = sum(1 for d in per_step if d["class"] != "same")
    print("== %s: %d/%d steps differ in the text area, %d/%d in cursor/top/class; diff.md + timing.md in %s" % (
        os.path.basename(out), n_text, len(lines), n_cls, len(lines), out))


def main(argv):
    if len(argv) < 2 or argv[1] not in ("run", "report"):
        print(__doc__, file=sys.stderr)
        sys.exit(64)
    args = parse_args(argv[1:])
    (run if argv[1] == "run" else report)(args)


if __name__ == "__main__":
    main(sys.argv)
