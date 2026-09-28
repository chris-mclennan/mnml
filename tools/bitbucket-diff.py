#!/usr/bin/env python3
"""Run the Rust Bitbucket reference and the Zig pane on the fake server and
print, per screen, the CONTENT that differs — the pull requests, repos,
branches, pipeline runs, states, chips, tabs and hint keys each side
shows — not the cells. The two apps paint in different chrome by design
(the Zig pane is mnml's panel shape); what must agree is what is there.

    tools/bitbucket-diff.py [--oracle BIN] [--zig BIN] [--fake BIN] [--size 120x40]

Exit 0 when every screen agrees, 1 otherwise. `tools/bitbucket-diff.sh`
is the wrapper that builds first.

The Rust side is `mnml-forge-bitbucket` built with a base-URL override
(the stock binary hard-codes api.bitbucket.org); `--oracle` names it.
It runs in a pty through `tools/rust-capture.py` with a scratch HOME
holding a TOML of the fake workspace. The Zig side is `mnml-zig
--headless` with the manifest installed into a scratch data root and
the pane opened by command; its screen is the IPC `screen.txt`.
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))

SCREENS = [
    # name, rust steps (after the first paint), zig keys, family, size
    # (the reference drops its right-hand pipeline chips below ~130
    # columns — its own overflow rule — so that screen runs wider),
    # the fact prefix to compare (None: every fact; the detail screen
    # compares the detail's own lines, since the reference squeezes the
    # list beside it to unreadable columns).
    ("open-tree", ["key:e"], ["e"], "prs", None, None),
    ("open-show-all", ["key:e", "key:G", "key:enter"], ["e", "shift+g", "enter"], "prs", None, None),
    ("merged-tree", ["key:m", "settle:800", "key:e"], ["m", "e"], "prs", None, None),
    ("merged-pr-pipeline", ["key:m", "settle:800", "key:e", "key:j", "key:enter", "untilnot:fetching pipeline"], ["m", "e", "j", "enter"], "prs", None, None),
    ("detail", ["key:e", "key:j", "key:d", "until:comments ("], ["e", "j", "d"], "prs", None, "detail:"),
    ("pipelines-tree", ["key:e"], ["e"], "pipelines", "160x40", None),
    ("mine", [], [], "mine", None, None),
]

STATE_WORDS = {"OPEN", "MERGED", "DECLINED", "SUPERSEDED", "DRAFT", "COMPLETED", "PENDING", "IN_PROGRESS", "SUCCESSFUL", "FAILED", "STOPPED", "HALTED", "ERROR"}


def facts(text):
    """The content of a screen as a set of tagged strings."""
    out = set()
    norm = text.replace("▶", ">").replace("▼", "v").replace("▸", ">").replace("▾", "v").replace("▌", " ")
    for line in norm.split("\n"):
        s = line.strip()
        if not s:
            continue
        m = re.match(r"^[>v]\s+(\S+)\s+(?:(\d+) (PRs|branches)|last merged|(429[^ ]*|auth failed|no such repo))", s)
        if m:
            out.add(f"repo:{m.group(1)}")
            if m.group(2):
                out.add(f"repo:{m.group(1)}:{m.group(2)} {m.group(3)}")
            continue
        m = re.match(r"^[>v ]*#(\d+)\s+(\w+)\s+(\S.*?)\s{2,}(\S+)\s+(\d{4}-\d{2}-\d{2})\s+(.*)$", s)
        if m:
            pid, state, author, branch, date, title = m.groups()
            out.add(f"pr:#{pid}")
            out.add(f"pr:#{pid}:{state}")
            out.add(f"pr:#{pid}:author={author.strip()}")
            out.add(f"pr:#{pid}:branch={branch[:18]}")
            out.add(f"pr:#{pid}:updated={date}")
            # The cursor's row carries its action chips at the right
            # end; they are not part of the title, and the reference
            # has no equivalent, so they come off before the compare.
            bare = re.sub(r"\s*\[ (Open|Merge|Review|view|.) \].*$", "", title).strip()
            out.add(f"pr:#{pid}:title={bare[:16]}")
            continue
        m = re.match(r"^(\S+)\s+(COMPLETED|PENDING|IN_PROGRESS|HALTED|STOPPED)\s+#(\d+)(?:\s+[✓✗⊘? ]*\s*(SUCCESSFUL|FAILED|STOPPED|ERROR))?\s*(\d{4}-\d{2}-\d{2})?", s)
        if m and "/" in m.group(1) or (m and m.group(1) in ("main", "master", "develop", "staging", "release")):
            br, st, build, res, date = m.groups()
            out.add(f"branch:{br}:{st}:#{build}:{res or ''}:{date or ''}")
            continue
        m = re.match(r"^(\S+)\s+—\s*$", s)
        if m and ("/" in m.group(1) or m.group(1) in ("main", "master", "develop", "staging")):
            out.add(f"branch:{m.group(1)}:none")
            continue
        m = re.search(r"\[ Show (\d+) more (older|merged) \]", s)
        if m:
            out.add(f"footer:show {m.group(1)} more {m.group(2)}")
        # The build line under a pull request. The reference writes
        # `✓ SUCCESSFUL #412 on main …`; the Zig pane writes the
        # toolkit's `✓ SUCCESSFUL · main · 4h · #412`. Same facts, two
        # orders — so the run's number is looked for anywhere on the
        # line rather than only right after the state.
        m = re.search(r"(✓|✗|⊘|⏵|→)\s*(SUCCESSFUL|FAILED|STOPPED|IN_PROGRESS|PENDING|no pipeline ran|no build ran|fetching pipeline|fetching builds)", s)
        if m and (s.startswith(("→", "✓", "✗", "⊘", "⏵")) or "on " in s):
            build = re.search(r"#(\d+)", s)
            out.add(f"subline:{m.group(2)}:{'#' + build.group(1) if build else ''}")
        # The tab strip is chrome: the reference hides it under --only,
        # the Zig pane shows it for two tabs. Not a content fact.
        m = re.match(r"^(?:[A-Za-z]+/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#(\d+)\s*$", s.strip("┌┐─ "))
        if m:
            out.add(f"detail:#{m.group(1)}")
        if "· updated:" in s:
            m = re.search(r"author:\s*([^·│]*)·\s*updated:\s*([^│ ]*)", s)
            if m:
                out.add(f"detail:author:{m.group(1).strip()}")
                out.add(f"detail:updated:{m.group(2).strip()}")
        for key in ("not approved", "you approved", "comments (", "(no description)"):
            if key in s:
                out.add(f"detail:{key}")
        # `[ Author ▾ ]` / `[ Author: Chris M ▾ ]` (the chevron is `v`
        # after the normalisation above) and the Zig `author: all`.
        if re.search(r"\[ Author(: [^\]]+?)? v \]", s) or re.search(r"\bauthor: \S", s):
            out.add("chip:author")
        if "Refresh" in s or "" in s or "󰑐" in s:
            out.add("chip:refresh")
        for chip in ("Run pipeline", "Schedules", "Caches", "Usage"):
            if chip.lower() in s.lower():
                out.add(f"chip:{chip.lower()}")
    return out


def run_rust(args, tmp, fake_url, family, steps, out_dir, name):
    home = os.path.join(tmp, "rust-home")
    os.makedirs(os.path.join(home, ".config"), exist_ok=True)
    with open(os.path.join(home, ".config", "mnml-forge-bitbucket.toml"), "w") as f:
        f.write('email = "me@example.com"\nworkspace = "acme"\nrefresh_interval_secs = 0\nrepos = ["api", "web"]\n'
                '[[tabs]]\nname = "Open + Draft"\nkind = "workspace_open_prs"\n[[tabs]]\nname = "Merged"\nkind = "workspace_merged_prs"\n[[tabs]]\nname = "Pipelines"\nkind = "workspace_pipelines"\n')
    only = {"prs": "prs", "pipelines": "pipelines", "mine": "prs-mine"}[family]
    first = "until:REPO / BRANCH" if family == "pipelines" else "until:REPO / #PR"
    cmd = [sys.executable, os.path.join(HERE, "rust-capture.py"), "--bin", args.oracle, "--arg=--only", f"--arg={only}",
           "--env", "MNML_PANE=1", "--env", f"HOME={home}", "--env", f"MNML_SHARED_STATE_DIR={os.path.join(tmp, 'rl')}",
           "--env", f"BITBUCKET_BASE_URL={fake_url}", "--env", "BITBUCKET_API_TOKEN=x", "--env", f"MNML_BB_ORACLE_LOG={os.path.join(tmp, 'oracle.log')}",
           "--size", args.size, "--out-dir", out_dir, first] + steps + [f"snap:rust-{name}", "key:q", "wait:300"]
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return open(os.path.join(out_dir, f"rust-{name}.txt")).read()


def run_zig(args, tmp, fake_url_file, family, keys, out_dir, name):
    ws = os.path.join(tmp, f"zig-ws-{name}")
    data = os.path.join(tmp, f"zig-data-{name}")
    os.makedirs(os.path.join(ws, ".mnml", "integrations", "bitbucket"), exist_ok=True)
    os.makedirs(os.path.join(data, "integrations"), exist_ok=True)
    with open(os.path.join(data, "config.zon"), "w") as f:
        f.write('.{ .editor = .{ .input_style = .standard }, .ui = .{ .first_launch_complete = true }, .ipc = .{ .write_screen = true } }\n')
    only = {"prs": ["--only", "prs"], "pipelines": ["--only", "pipelines"], "mine": ["--only", "prs-mine"]}[family]
    with open(os.path.join(data, "integrations", "bitbucket_prs.zon"), "w") as f:
        f.write(f'.{{ .id = "bitbucket_prs", .label = "Bitbucket PRs", .binary = "{args.zig_bb}", .args = .{{ "{only[0]}", "{only[1]}" }}, .commands = .{{ .{{ .id = "bitbucket_prs.open", .title = "open" }} }} }}\n')
    cfg = os.path.join(ws, "bitbucket.zon")
    with open(cfg, "w") as f:
        f.write('.{ .email = "me@example.com", .workspace = "acme", .repos = .{ "api", "web" }, .refresh_interval_secs = 0, .rate = .{ .rate_per_sec = 1000, .capacity = 1000 }, '
                '.tabs = .{ .{ .name = "Open + Draft", .kind = .workspace_open_prs }, .{ .name = "Merged", .kind = .workspace_merged_prs }, .{ .name = "Pipelines", .kind = .workspace_pipelines } } }\n')
    cols, rows = args.size.split("x")
    env = dict(os.environ, MNML_DATA_ROOT=data, MNML_COLS=cols, MNML_ROWS=rows, MNML_BITBUCKET_CONFIG=cfg,
               BITBUCKET_BASE_URL="@" + fake_url_file, BITBUCKET_API_TOKEN="x", BITBUCKET_RATELIMIT_STATE=os.path.join(tmp, "zig-bucket.json"))
    ipc = os.path.join(ws, ".mnml", "ipc-zig")
    p = subprocess.Popen([args.zig, "--headless", "--input", "standard", ws], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if os.path.exists(os.path.join(ipc, "events.jsonl")):
                break
            time.sleep(0.1)
        time.sleep(0.8)

        def cmd(obj):
            with open(os.path.join(ipc, "command"), "a") as f:
                f.write(json.dumps(obj) + "\n")

        for c in ({"cmd": "key", "key": "esc"}, {"cmd": "run-command", "id": "bitbucket_prs.open"}, {"cmd": "run-command", "id": "view.toggle_tree"}, {"cmd": "run-command", "id": "view.focus_pane"}):
            cmd(c)
            time.sleep(0.3)
        time.sleep(2.0)
        for k in keys:
            cmd({"cmd": "key", "key": k})
            time.sleep(0.6)
        time.sleep(1.0)
        cmd({"cmd": "snapshot"})
        time.sleep(0.6)
        text = open(os.path.join(ipc, "screen.txt")).read()
        with open(os.path.join(out_dir, f"zig-{name}.txt"), "w") as f:
            f.write(text)
        cmd({"cmd": "quit"})
        time.sleep(0.5)
    finally:
        if p.poll() is None:
            p.terminate()
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oracle", default=os.environ.get(
        "MNML_BB_ORACLE_BIN",
        os.path.expanduser("~/Projects/mnml-integrations/target/release/mnml-forge-bitbucket-oracle")))
    ap.add_argument("--zig", default=os.path.join(ROOT, "zig-out", "bin", "mnml-zig"))
    ap.add_argument("--zig-bb", default=os.path.join(ROOT, "zig-out", "bin", "mnml-bitbucket"))
    ap.add_argument("--fake", default=os.path.join(ROOT, "zig-out", "bin", "mnml-fake-bitbucket"))
    ap.add_argument("--size", default="120x40")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    for b in (args.oracle, args.zig, args.zig_bb, args.fake):
        if not os.access(b, os.X_OK):
            print(f"bitbucket-diff: not executable: {b}", file=sys.stderr)
            return 64
    tmp = tempfile.mkdtemp(prefix="bb-diff-")
    out_dir = args.out or os.path.join(tmp, "screens")
    os.makedirs(out_dir, exist_ok=True)
    url_file = os.path.join(tmp, "bb.url")
    # --parent-pid: a run killed half way leaves no server on the port.
    fake = subprocess.Popen([args.fake, "--port", "0", "--url-file", url_file, "--lifetime-secs", "600", "--parent-pid", str(os.getpid())], stdout=subprocess.DEVNULL)
    try:
        for _ in range(50):
            if os.path.exists(url_file) and open(url_file).read().strip():
                break
            time.sleep(0.1)
        fake_url = open(url_file).read().strip()
        total = 0
        for name, rsteps, zkeys, family, size, prefix in SCREENS:
            saved = args.size
            if size:
                args.size = size
            rust = run_rust(args, tmp, fake_url, family, rsteps, out_dir, name)
            zig = run_zig(args, tmp, url_file, family, zkeys, out_dir, name)
            args.size = saved
            rf, zf = facts(rust), facts(zig)
            if prefix:
                rf = {f for f in rf if f.startswith(prefix)}
                zf = {f for f in zf if f.startswith(prefix)}
            only_rust = sorted(rf - zf)
            only_zig = sorted(zf - rf)
            n = len(only_rust) + len(only_zig)
            total += n
            print(f"== {name}: {len(rf & zf)} facts agree, {n} differ")
            for f in only_rust:
                print(f"   rust only: {f}")
            for f in only_zig:
                print(f"   zig only:  {f}")
        print(f"== screens: {out_dir}")
        print(f"== total differing facts: {total}")
        return 0 if total == 0 else 1
    finally:
        if fake.poll() is None:
            fake.terminate()


if __name__ == "__main__":
    sys.exit(main())
