#!/usr/bin/env python3
"""Cut `docs/ui-spec/bitbucket/rust-*.txt` from the OFFLINE fake server.

The inventory the Zig integration is built from is the Rust reference's
own screens. They are cut here against `mnml-fake-bitbucket` — an
invented workspace (`acme`, repos `api` / `web`, people `Chris M` /
`Dana R` / `Sam K`, keys like `ENG-4210`) on the loopback — never
against the live Bitbucket API, so nothing captured from anyone's real
workspace can reach a committed file.

    tools/bitbucket-capture.py [--oracle BIN] [--fake BIN]
                               [--out docs/ui-spec/bitbucket] [--only NAME]...

The Rust side is `mnml-forge-bitbucket` built with a base-URL override
(`BITBUCKET_BASE_URL`); `--oracle` names it (`MNML_BB_ORACLE_BIN`
otherwise). Each run gets its own scratch HOME with a TOML of the fake
workspace, so the keys that rewrite the config (`x` `H` `s` `alt+↑↓`)
cannot touch anyone's real one, and its own rate-limit bucket.

Exit 0 when every screen was written.
"""
import argparse, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))

TOML = (
    'email = "me@example.com"\n'
    'workspace = "acme"\n'
    "refresh_interval_secs = 0\n"
    'repos = ["api", "web"]\n'
    "[[tabs]]\n"
    'name = "Open + Draft"\n'
    'kind = "workspace_open_prs"\n'
    "[[tabs]]\n"
    'name = "Merged"\n'
    'kind = "workspace_merged_prs"\n'
    "[[tabs]]\n"
    'name = "Pipelines"\n'
    'kind = "workspace_pipelines"\n'
)

PRS_PAINTED = "until:REPO / #PR"
PIPES_PAINTED = "until:REPO / BRANCH"

# One entry per oracle run: (only, size, steps). A run may snap more
# than once along its path; a screen that needs a clean start gets its
# own run. `--only` is the reference's family flag ("" keeps every tab).
RUNS = [
    # ─── the Open + Draft tree, 120x40, every tab ───────────────────
    ("", "120x40", [PRS_PAINTED, "snap:rust-full-open-collapsed-120x40",
                    "key:j", "key:j", "snap:rust-full-open-pr-focused-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:c", "key:enter", "snap:rust-full-open-repo-expanded-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:e", "snap:rust-full-open-expand-all-120x40",
                    "key:c", "snap:rust-full-open-collapse-all-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:G", "snap:rust-full-open-end-120x40",
                    "key:enter", "settle:800", "snap:rust-full-open-show-all-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:pgdn", "snap:rust-full-pgdn-120x40",
                    "key:home", "snap:rust-full-home-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:tab", "settle:1200", "snap:rust-full-tab-key-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:r", "settle:1500", "snap:rust-full-after-refresh-120x40"]),
    # ─── Merged ────────────────────────────────────────────────────
    ("", "120x40", [PRS_PAINTED, "key:m", "settle:1200", "snap:rust-full-merged-120x40",
                    "key:e", "snap:rust-full-merged-repo-expanded-120x40",
                    "key:j", "key:enter", "untilnot:fetching pipeline",
                    "snap:rust-full-merged-pr-pipeline-120x40"]),
    # ─── the detail ────────────────────────────────────────────────
    ("", "120x40", [PRS_PAINTED, "key:e", "key:j", "key:d", "until:comments (",
                    "snap:rust-full-detail-120x40",
                    "key:ctrl-d", "snap:rust-full-detail-scrolled-120x40"]),
    # ─── Pipelines ─────────────────────────────────────────────────
    ("", "120x40", [PRS_PAINTED, "key:3", PIPES_PAINTED, "settle:1200",
                    "snap:rust-full-pipelines-120x40",
                    "key:e", "snap:rust-full-pipelines-expand-all-120x40",
                    "key:c", "key:right", "snap:rust-full-pipelines-right-expands-120x40",
                    "key:left", "snap:rust-full-pipelines-left-collapses-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:3", PIPES_PAINTED, "settle:1200",
                    "key:c", "key:enter", "snap:rust-full-pipelines-repo-expanded-120x40"]),
    # ─── the toolbar chips (clicked, not keyed) ─────────────────────
    ("", "120x40", [PRS_PAINTED, "click:3,3", "settle:1500", "snap:rust-full-click-search-chip-120x40"]),
    ("", "120x40", [PRS_PAINTED, "click:21,3", "settle:1500", "snap:rust-full-click-status-chip-120x40"]),
    ("", "120x40", [PRS_PAINTED, "click:41,3", "settle:2500", "snap:rust-full-click-author-chip-120x40",
                    "click:41,3", "settle:2500", "snap:rust-full-click-author-chip-again-120x40"]),
    ("", "120x40", [PRS_PAINTED, "click:112,3", "settle:2000", "snap:rust-full-click-refresh-pill-120x40"]),
    # ─── the cursor screens (the `-c-` set) ────────────────────────
    ("", "120x40", [PRS_PAINTED, "key:g", "snap:rust-c-header-row-120x40",
                    "key:j", "snap:rust-c-open-pr-row-120x40",
                    "key:d", "until:comments (", "snap:rust-c-detail-120x40",
                    "key:ctrl-d", "snap:rust-c-detail-ctrl-d-120x40",
                    "key:ctrl-u", "snap:rust-c-detail-ctrl-u-120x40",
                    "key:j", "settle:1200", "snap:rust-c-detail-next-row-120x40",
                    "key:d", "snap:rust-c-detail-closed-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:pgdn", "snap:rust-c-pgdn-120x40",
                    "key:pgup", "snap:rust-c-pgup-120x40",
                    "key:G", "snap:rust-c-end-120x40"]),
    # the keys that rewrite the config — each on its own scratch HOME
    ("", "120x40", [PRS_PAINTED, "key:g", "key:x", "settle:1500", "snap:rust-c-hide-repo-120x40",
                    "key:H", "settle:1500", "snap:rust-c-unhide-all-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:s", "settle:1500", "snap:rust-c-scope-cycle-1-120x40",
                    "key:s", "settle:1500", "snap:rust-c-scope-cycle-2-120x40",
                    "key:s", "settle:1500", "snap:rust-c-scope-cycle-3-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:g", "key:alt-down", "settle:800", "snap:rust-c-reorder-down-120x40",
                    "key:alt-up", "settle:800", "snap:rust-c-reorder-up-120x40"]),
    ("", "120x40", [PRS_PAINTED, "key:3", PIPES_PAINTED, "settle:1200", "key:g",
                    "key:x", "settle:1500", "snap:rust-c-pipelines-hide-120x40",
                    "key:H", "settle:1500", "snap:rust-c-pipelines-unhide-120x40"]),
    # ─── the mine-only launch (the statusline chip's click) ─────────
    ("prs-mine", "120x40", [PRS_PAINTED, "snap:rust-mine-120x40",
                            "key:j", "snap:rust-mine-pr-row-120x40",
                            "key:G", "snap:rust-mine-end-120x40",
                            "key:enter", "settle:1200", "snap:rust-mine-show-all-120x40"]),
    # ─── 80x24 ─────────────────────────────────────────────────────
    ("", "80x24", ["until:STATE", "settle:1200", "snap:rust-prs-80x24",
                   "key:j", "key:d", "until:comments (", "snap:rust-prs-detail-80x24",
                   "key:d", "key:m", "settle:1200", "snap:rust-prs-merged-80x24"]),
    ("", "80x24", ["until:STATE", "key:3", "until:BUILD", "settle:1200",
                   "snap:rust-pipelines-80x24",
                   "key:c", "snap:rust-pipelines-collapsed-80x24"]),
]

# The headless surfaces, as one file: (heading, argv after the binary).
HEADLESS = [
    ("--values", ["--values"]),
    ("--list-prs --json", ["--list-prs", "--json"]),
    ("--find-pipeline-for-pr --owner acme --repo api --branch main --json",
     ["--find-pipeline-for-pr", "--owner", "acme", "--repo", "api", "--branch", "main", "--json"]),
    ("--check", ["--check"]),
]


def scratch_home(tmp, n):
    home = os.path.join(tmp, f"home-{n}")
    os.makedirs(os.path.join(home, ".config"), exist_ok=True)
    with open(os.path.join(home, ".config", "mnml-forge-bitbucket.toml"), "w") as f:
        f.write(TOML)
    return home


def oracle_env(tmp, home, fake_url):
    return [
        "--env", "MNML_PANE=1",
        "--env", f"HOME={home}",
        "--env", f"MNML_SHARED_STATE_DIR={os.path.join(home, 'rl')}",
        "--env", f"BITBUCKET_BASE_URL={fake_url}",
        "--env", "BITBUCKET_API_TOKEN=x",
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oracle", default=os.environ.get(
        "MNML_BB_ORACLE_BIN",
        os.path.expanduser("~/Projects/mnml-integrations/target/release/mnml-forge-bitbucket-oracle")))
    ap.add_argument("--fake", default=os.path.join(ROOT, "zig-out", "bin", "mnml-fake-bitbucket"))
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "ui-spec", "bitbucket"))
    ap.add_argument("--only", action="append", default=[],
                    help="capture just these screen names (repeatable)")
    args = ap.parse_args()
    for b in (args.oracle, args.fake):
        if not os.access(b, os.X_OK):
            print(f"bitbucket-capture: not executable: {b}", file=sys.stderr)
            return 64
    os.makedirs(args.out, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="bb-capture-")
    url_file = os.path.join(tmp, "bb.url")
    fake = subprocess.Popen([args.fake, "--port", "0", "--url-file", url_file,
                             "--lifetime-secs", "3600"], stdout=subprocess.DEVNULL)
    written, missing = [], []
    try:
        for _ in range(50):
            if os.path.exists(url_file) and open(url_file).read().strip():
                break
            time.sleep(0.1)
        fake_url = open(url_file).read().strip()
        for n, (only, size, steps) in enumerate(RUNS):
            names = [s.split(":", 1)[1] for s in steps if s.startswith("snap:")]
            if args.only and not any(x in args.only for x in names):
                continue
            home = scratch_home(tmp, n)
            only_args = ["--arg=--only", f"--arg={only}"] if only else []
            cmd = ([sys.executable, os.path.join(HERE, "rust-capture.py"), "--bin", args.oracle]
                   + only_args + oracle_env(tmp, home, fake_url)
                   + ["--size", size, "--out-dir", args.out] + steps + ["key:q", "wait:300"])
            subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for name in names:
                p = os.path.join(args.out, name + ".txt")
                ok = os.path.exists(p) and os.path.getsize(p) > 0
                (written if ok else missing).append(name)
                print(("wrote " if ok else "MISSING ") + name)
        if not args.only or "rust-headless-json" in args.only:
            home = scratch_home(tmp, "headless")
            env = dict(os.environ, HOME=home, BITBUCKET_BASE_URL=fake_url,
                       BITBUCKET_API_TOKEN="x",
                       MNML_SHARED_STATE_DIR=os.path.join(home, "rl"))
            out = ["# the headless surfaces, against the fake server "
                   "(tools/bitbucket-capture.py)\n"]
            for heading, argv in HEADLESS:
                r = subprocess.run([args.oracle] + argv, env=env, capture_output=True, text=True)
                text = r.stdout.strip().replace(home, "<scratch home>")
                out.append(f"\n$ mnml-forge-bitbucket {heading}\n{text}\n")
            with open(os.path.join(args.out, "rust-headless-json.txt"), "w") as f:
                f.write("".join(out))
            written.append("rust-headless-json")
            print("wrote rust-headless-json")
    finally:
        if fake.poll() is None:
            fake.terminate()
    print(f"== wrote {len(written)} screens to {args.out}")
    if missing:
        print("== missing: " + ", ".join(missing), file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
