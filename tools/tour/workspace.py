"""The tour's private workspace: a small git repo with history, a dirty
working tree, TODO markers, a note and a finding, plus the scaffolding
the Jira and Bitbucket panes need against their offline fakes — the
same scaffolding `tests/e2e/integrations_jira_work_tree.test` and
`integrations_bitbucket_pane.test` write, so the panes have rows.

Everything is synthetic. Nothing here names a real host, ticket or
person; the fakes serve their own fixed data.
"""

import os
import subprocess

from mnmlwin import REPO

GIT_ENV = {
    "GIT_AUTHOR_NAME": "Tour Author",
    "GIT_AUTHOR_EMAIL": "tour@example.com",
    "GIT_COMMITTER_NAME": "Tour Author",
    "GIT_COMMITTER_EMAIL": "tour@example.com",
    "GIT_CONFIG_NOSYSTEM": "1",
}

# The fixture's files live in `data/demo/tour/`, which `mnml --demo`
# embeds (`data/root.zig`) — one fixture for the tour, the site
# recordings and the demo. `config.zon` is the tour's own layer: the
# standard profile, line numbers, a pty cursor that does not blink (a
# blinking cell is noise in a pixel diff), and the Claude Code chip on
# so the usage meter paints in the statusline.
FIXTURE = os.path.join(REPO, "data", "demo", "tour")


def fixture(name):
    with open(os.path.join(FIXTURE, name), encoding="utf-8") as f:
        return f.read()


MAIN_ZIG_V1 = fixture("main-v1.zig")
MAIN_ZIG_V2 = fixture("main-v2.zig")
UTIL_ZIG = fixture("util.zig")
UTIL_ZIG_DIRTY = fixture("util-dirty.zig")
README = fixture("README.md")
GITIGNORE = fixture("gitignore")
JIRA_CONFIG = fixture("jira-config.zon")
BB_CONFIG = fixture("bitbucket-config.zon")
WS_CONFIG = fixture("config.zon")
NOTE = fixture("note-release.md")
FINDING = fixture("finding-tour-clock.md")
ZSHRC = fixture("zshrc")

JIRA_MANIFEST = (
    '.{ .id = "jira_work", .label = "Jira Work", .version = "0.2.0", .binary = "%s", '
    '.category = "tracker", .commands = .{ .{ .id = "jira_work.open", .title = "Jira Work", '
    '.args = .{ "--only", "work" } } }, .statusline = .{ .{ .id = "assigned", .text = "\\u{f0303}", '
    '.color = "#1B5DCF", .click_command = "jira_work.open" } } }'
)
BB_MARKET = (
    '.{ .id = "bitbucket_prs", .label = "Bitbucket PRs", .version = "0.2.0", .binary = "%s", '
    '.args = .{ "--only", "prs" }, .description = "Bitbucket: open + merged pull requests across the workspace", '
    '.chip = .{ .glyph = "\\u{f00a8}", .fallback = "BP", .color = "blue", .in_palette_bar = false }, '
    '.commands = .{ .{ .id = "bitbucket_prs.open", .title = "Bitbucket PRs: open" } } }'
)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def git(ws, *args, date=None):
    env = dict(os.environ)
    env.update(GIT_ENV)
    env["HOME"] = os.path.dirname(ws)
    env["GIT_CEILING_DIRECTORIES"] = os.path.dirname(ws)
    if date:
        env["GIT_AUTHOR_DATE"] = date
        env["GIT_COMMITTER_DATE"] = date
    subprocess.run(["git", *args], cwd=ws, env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build(ws, home):
    """Create the workspace at `ws` and the fake home at `home`."""
    bin_dir = os.path.join(REPO, "zig-out", "bin")
    os.makedirs(ws, exist_ok=True)
    git(ws, "init", "-q", "-b", "main")
    git(ws, "config", "user.name", "Tour Author")
    git(ws, "config", "user.email", "tour@example.com")
    git(ws, "config", "commit.gpgsign", "false")
    write(os.path.join(ws, "README.md"), README)
    write(os.path.join(ws, ".gitignore"), GITIGNORE)
    write(os.path.join(ws, "src", "main.zig"), MAIN_ZIG_V1)
    git(ws, "add", "-A")
    git(ws, "commit", "-q", "-m", "Start the tour project", date="2026-09-01T09:00:00+0000")
    write(os.path.join(ws, "src", "util.zig"), UTIL_ZIG)
    git(ws, "add", "-A")
    git(ws, "commit", "-q", "-m", "Add util.sum with a test", date="2026-09-02T10:30:00+0000")
    git(ws, "checkout", "-q", "-b", "feature/numbers")
    write(os.path.join(ws, "src", "main.zig"), MAIN_ZIG_V2)
    git(ws, "add", "-A")
    git(ws, "commit", "-q", "-m", "Sum five numbers and mark the follow-ups", date="2026-09-03T14:15:00+0000")
    git(ws, "checkout", "-q", "main")
    git(ws, "merge", "-q", "--no-ff", "feature/numbers", "-m", "Merge feature/numbers", date="2026-09-04T08:45:00+0000")
    write(os.path.join(ws, "docs", "notes.md"), fixture("docs-notes.md"))
    git(ws, "add", "-A")
    git(ws, "commit", "-q", "-m", "Add a docs folder", date="2026-09-05T16:00:00+0000")
    # The working tree: one modified file, one untracked.
    write(os.path.join(ws, "src", "util.zig"), UTIL_ZIG_DIRTY)
    write(os.path.join(ws, "CHANGELOG.md"), fixture("CHANGELOG.md"))

    # mnml's own workspace state.
    write(os.path.join(ws, ".mnml", "config.zon"), WS_CONFIG)
    write(os.path.join(ws, ".mnml", "notes", "release.md"), NOTE)
    write(os.path.join(ws, ".mnml", "findings", "tour-clock.md"), FINDING)

    # The integration panes' scaffolding (see the module doc).
    write(os.path.join(ws, "sdk", "mnml-sdk", "build.zig"), "")
    write(os.path.join(ws, "integrations", "jira", "build.zig"), "")
    write(os.path.join(ws, "integrations", "jira", "manifest.zon"),
          JIRA_MANIFEST % os.path.join(bin_dir, "mnml-jira"))
    write(os.path.join(ws, ".mnml", "integrations", "jira", "config.zon"), JIRA_CONFIG)
    write(os.path.join(ws, "bitbucket.zon"), BB_CONFIG)
    write(os.path.join(ws, "market", "bitbucket_prs.zon"),
          BB_MARKET % os.path.join(bin_dir, "mnml-bitbucket"))

    write(os.path.join(home, ".zshrc"), ZSHRC)


def app_env(ws, usage_fixture):
    """What the app needs to reach the fakes and the usage fixture."""
    return {
        "JIRA_RATELIMIT_STATE": os.path.join(ws, "jira-bucket.json"),
        "JIRA_API_TOKEN": "fake-token",
        "JIRA_BASE_URL": "@" + os.path.join(ws, "jira.url"),
        "MNML_MARKETPLACE_LOCAL": os.path.join(ws, "market"),
        "MNML_BITBUCKET_CONFIG": os.path.join(ws, "bitbucket.zon"),
        "BITBUCKET_BASE_URL": "@" + os.path.join(ws, "bb.url"),
        "BITBUCKET_RATELIMIT_STATE": os.path.join(ws, "bb-bucket.json"),
        "BITBUCKET_API_TOKEN": "corpus-read-token",
        "MNML_WORKSPACE": ws,
        "MNML_CLAUDE_USAGE_FIXTURE": usage_fixture,
        "TZ": "UTC",
        "GIT_CEILING_DIRECTORIES": os.path.dirname(ws),
    }


def start_fakes(ws):
    """The offline Jira and Bitbucket, each in a session of its own; the
    caller kills the returned processes (and only those)."""
    bin_dir = os.path.join(REPO, "zig-out", "bin")
    procs = []
    procs.append(subprocess.Popen(
        [os.path.join(bin_dir, "mnml-fake-jira"), "--port", "0", "--url-file", "jira.url",
         "--life-secs", "900", "--quiet", "--pid-file", "fake-jira.pid"],
        cwd=ws, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
    procs.append(subprocess.Popen(
        [os.path.join(bin_dir, "mnml-fake-bitbucket"), "--port", "0", "--url-file", "bb.url",
         "--lifetime-secs", "900"],
        cwd=ws, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True))
    return procs
