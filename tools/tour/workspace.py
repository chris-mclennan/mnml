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

MAIN_ZIG_V1 = """const std = @import("std");
const util = @import("util.zig");

pub fn main() !void {
    const total = util.sum(&.{ 1, 2, 3, 4 });
    std.debug.print("total: {d}\\n", .{total});
}
"""

MAIN_ZIG_V2 = """const std = @import("std");
const util = @import("util.zig");

/// The entry point: add a few numbers and print the total.
pub fn main() !void {
    // TODO: read the numbers from the command line.
    const numbers = [_]i64{ 1, 2, 3, 4, 5 };
    const total = util.sum(&numbers);
    std.debug.print("total: {d}\\n", .{total});
    // FIXME: an empty list should print a friendlier message.
    if (total == 0) std.debug.print("nothing to add\\n", .{});
}
"""

UTIL_ZIG = """const std = @import("std");

/// Sum a slice of integers.
pub fn sum(xs: []const i64) i64 {
    var total: i64 = 0;
    for (xs) |x| total += x;
    return total;
}

test "sum adds" {
    try std.testing.expectEqual(@as(i64, 6), sum(&.{ 1, 2, 3 }));
}
"""

UTIL_ZIG_DIRTY = UTIL_ZIG + """
/// The largest element, or null for an empty slice.
pub fn max(xs: []const i64) ?i64 {
    if (xs.len == 0) return null;
    var best = xs[0];
    for (xs[1..]) |x| best = @max(best, x);
    return best;
}
"""

README = """# tour

A small workspace for mnml's real-screen tour: a few commits, a dirty
working tree, TODO markers and a note.
"""

GITIGNORE = """# The tour's scaffolding for the integration panes, not the project.
sdk/
integrations/
market/
*.url
*.pid
*-bucket.json
*.jsonl
*.lock
*.sock
bitbucket.zon
.mnml/
"""

JIRA_MANIFEST = (
    '.{ .id = "jira_work", .label = "Jira Work", .version = "0.2.0", .binary = "%s", '
    '.category = "tracker", .commands = .{ .{ .id = "jira_work.open", .title = "Jira Work", '
    '.args = .{ "--only", "work" } } }, .statusline = .{ .{ .id = "assigned", .text = "\\u{f0303}", '
    '.color = "#1B5DCF", .click_command = "jira_work.open" } } }'
)
JIRA_CONFIG = (
    '.{ .jira_url = "https://jira.invalid", .email = "fake@acme.com", .refresh_interval_secs = 0, '
    '.rate = .{ .per_sec = 1000, .burst = 1000 }, .tabs = .{ .{ .name = "Assigned", .kind = .work_assigned }, '
    '.{ .name = "Recently Done", .kind = .work_recently_done } } }'
)
BB_CONFIG = (
    '.{ .email = "me@example.com", .workspace = "acme", .repos = .{ "api", "web" }, .refresh_interval_secs = 0, '
    '.rate = .{ .rate_per_sec = 1000, .capacity = 1000 }, .tabs = .{ .{ .name = "Open + Draft", .kind = .workspace_open_prs }, '
    '.{ .name = "Merged", .kind = .workspace_merged_prs }, .{ .name = "Pipelines", .kind = .workspace_pipelines } } }'
)
BB_MARKET = (
    '.{ .id = "bitbucket_prs", .label = "Bitbucket PRs", .version = "0.2.0", .binary = "%s", '
    '.args = .{ "--only", "prs" }, .description = "Bitbucket: open + merged pull requests across the workspace", '
    '.chip = .{ .glyph = "\\u{f00a8}", .fallback = "BP", .color = "blue", .in_palette_bar = false }, '
    '.commands = .{ .{ .id = "bitbucket_prs.open", .title = "Bitbucket PRs: open" } } }'
)

# The tour's own layer: the standard profile, line numbers, a pty cursor
# that does not blink (a blinking cell is noise in a pixel diff), and the
# Claude Code chip on so the usage meter paints in the statusline. The
# four first-party icons are spelled out because a list is whole-replace
# in a layer; the glyphs are `ui/bufferline.zig`'s.
WS_CONFIG = """.{
    .editor = .{ .input_style = .standard },
    .ui = .{
        .line_numbers = true,
        .pty_cursor = .{ .blink = false },
        .integration_icons = .{
            .{ .id = "browser", .glyph = "\\u{EB01}", .fallback = "B", .command = "browser.open", .color = "blue", .label = "Browser", .enabled = true, .in_palette_bar = true },
            .{ .id = "claude_code", .glyph = "\\u{F1E00}", .fallback = "\\u{2733}", .command = "ai.claude_code", .color = "#D97757", .label = "Claude Code", .enabled = true, .in_palette_bar = false },
            .{ .id = "codex", .glyph = "\\u{F1E01}", .fallback = "\\u{276F}_", .command = "ai.codex", .color = "cyan", .label = "Codex", .enabled = false, .in_palette_bar = false },
            .{ .id = "http", .glyph = "\\u{F1D8}", .fallback = "H", .command = "view.activity_http", .color = "teal", .label = "HTTP", .enabled = false, .in_palette_bar = false },
        },
    },
}
"""

NOTE = "# release checklist\n\n- tag the build\n- write the notes\n"
FINDING = """# Tour finding: the statusline clock

Severity: low

A sample finding so the FINDINGS section has a row.
"""

ZSHRC = "PROMPT='tour %# '\nRPROMPT=''\nunsetopt PROMPT_SP\n"


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
    write(os.path.join(ws, "docs", "notes.md"), "# notes\n\nThe tour's docs folder.\n")
    git(ws, "add", "-A")
    git(ws, "commit", "-q", "-m", "Add a docs folder", date="2026-09-05T16:00:00+0000")
    # The working tree: one modified file, one untracked.
    write(os.path.join(ws, "src", "util.zig"), UTIL_ZIG_DIRTY)
    write(os.path.join(ws, "CHANGELOG.md"), "# Changelog\n\n## 0.1.0\n\n- first cut\n")

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
