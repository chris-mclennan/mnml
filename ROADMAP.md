# mnml ROADMAP

Where the next year of effort should go, and why.

This is not [`TODO.md`](TODO.md). TODO.md is the deferred-work queue:
1,300-odd lines of items whose shape is already settled and which only
need a session to land. This file is the layer above it — the small
number of tracks that are *not* represented in that queue at all, and
the argument for each.

Written 2026-09-03, against post-v0.2.21.

---

## The situation

mnml is ~290,000 lines across 339 Rust files. It has a pluggable input
layer with two first-class keymaps, LSP, DAP, CDP, an HTTP client, AI
panes, a file manager with background transfers, git down to per-hunk
staging, 39 tree-sitter languages, a headless harness with 193 `.test`
scripts, and a marketplace of ~30 sibling integrations.

The feature surface is not the constraint. The backlog reflects that:
almost every open item is polish on a surface that already exists —
a sort chip, a right-click menu, a padding cell, a toast affordance.
That work is real and it is why mnml feels finished in the places it
feels finished.

But four classes of work have stopped appearing in the queue entirely.
They are what this file is for.

---

## 1. Column correctness — display width

**Status: not started. Highest priority.**

`unicode-width` is a dependency of the crate. It is used in exactly two
files: `src/ui/bufferline.rs` and `src/ui/mod.rs`. The editor render
path (`src/ui/editor_view.rs`) expands tabs against
`config.editor.tab_width` but otherwise assumes one character occupies
one terminal cell.

So: open a file containing an emoji, or any CJK text, and every glyph
after it on that line is drawn one cell to the left of where it belongs,
and the cursor lands in the wrong place. Selection, visual-block, the
color column, the git gutter alignment, and mouse click-to-position are
all wrong on that line too, because they all count characters.

`CLAUDE.md` files this as "a P2 refinement." That undersells it. For a
published editor it is a correctness bug, and it is the first thing a
non-English-language user encounters.

It also gets cheaper if done now rather than later. The v0.2.20 perf
work introduced a `LineRender` pre-pass that builds a per-line character
vector once per frame instead of once per visual row. A width column
belongs in exactly that structure. Every month that passes adds more
call sites that index by character.

**Shape:** widths computed once in `LineRender`; a `col ⇄ cell` mapping
pair on `Editor` alongside the existing `line_starts` index; every
consumer of "column" audited to say which of the two it meant. Tabs fold
into the same mechanism rather than staying a special case.

## 2. The client/server split — panes that outlive the process

**Status: not started. The only track here that fixes something you hit
several times a day.**

### First, what is NOT the reason to do this

**mnml already runs over SSH, unmodified.** `docs/design/mnml-over-ssh.md`
(task #1163, verified 2026-08-23) checked this surface by surface:
editing, panes, layout, chords, mouse, file I/O, LSP, git, the HTTP
client and Pty panes all work verbatim on a remote box, and it calls
the SSH scenario "the natural fit". A TUI's transport *is* the terminal.
So "mnml can't do remote" is false, and it is not an argument for this
track. The one real defect the note found — `open_url_external` firing
`xdg-open` on the remote box — is an afternoon's fix at four call
sites, not an architecture.

### The actual reason

**Panes outlive the mnml process.** `./run.sh restart` is in the core
dev loop — a `PostToolUse` hook fires it after every successful build —
and every restart kills every terminal, every AI session, every
integration and every in-flight build. Neither SSH nor tmux can fix
this, because the restart kills the binary on purpose; that is the
point of it. This is the daily pain and the prize.

Detach / reattach and crash-survival come with it. tmux already gives
you detach-from-terminal for free, so treat that as a bonus rather than
a justification.

The split also leaves the door open to the VS Code Remote shape — local
terminal, local clipboard and browser, remote files — which is a
genuinely different product from `ssh box && mnml` and the only version
of "remote" this track actually unlocks. Not a v1 goal.

### mnml is already reimplementing a piece of this, once per application

`src/app/session.rs:208`, dated 2026-08-23:

> snapshot every open Claude Code Pty so the next launch can `--resume`
> each one and restore the user's cluster without a manual step. **Skip
> non-Claude Ptys (Codex, bare shells) — they have no `--resume`
> protocol to hook into.**

And TODO.md:1255 asks for a second one:

> resume mixr playback across an mnml restart. Losing the mix position
> on every `./run.sh restart` is a real cost while developing mnml and
> mixr together. Needs mixr to persist position + mnml to hand it back
> on relaunch.

That is the same feature filed twice, solved per-application, each
solution requiring the child's cooperation — which most children cannot
give. The root cause is stated plainly at `src/pty_pane.rs:8`:
*"Dropping the session kills the child."* mnml owns every PTY child
directly through `portable_pty`, so process lifetime is welded to UI
lifetime.

tmux's real insight is not the detach gesture. It is that the process
outlives the thing displaying it. That solves both of the above
generically, with zero cooperation from Claude Code, Codex, or mixr —
and it solves the ones nobody has filed yet: `htop`, a ten-minute
`cargo build`, a shell with an hour of scrollback.

### Be precise about which half tmux already gives you

You can run mnml under tmux today and get detach-from-terminal for free,
no code. Say that out loud, because it disposes of half the feature.

What tmux cannot do is keep mnml's children alive across *mnml's own*
death, and `./run.sh restart` kills the binary deliberately — that is
the point of it. So the framing is not "mnml can detach." It is **panes
outlive the mnml process.**

### Why Tier 2 and not the cheap version

There is a cheaper shape — a PTY supervisor process that owns the
masters and children, with mnml holding only fds. It is bounded, lands
sooner, and retires the `--resume` special case and the mixr TODO. It
does not get you remote, and it does not get you a client that can
reattach from elsewhere.

Going straight to the full split — `App` is the server, the terminal
renderer is a thin attachable client — costs more and takes longer, but
one architecture yields restart-survival, detach, crash-survival and a
path to local-client/remote-files, instead of only the first. Decided
2026-09-03: take the full split.

**Headless mode is already the server half.** `mnml --headless` runs the
real `App` and `ui::draw` against a `TestBackend` and publishes
`screen.txt` / `status.json` / `events.jsonl` while taking commands on
`command`, at `<workspace>/.mnml/ipc/`. What is missing is an attach
client and a real transport — a unix socket; the file-IPC channel is a
test harness and is too lossy for interactive use. The shape is proven
and tested, which is the whole reason this is affordable at all.
`libghostty-vt` already models terminal state, so replaying a screen on
reattach fits the layer that exists.

**Scope discipline.** Version one is: survive `./run.sh restart` with
shells and AI sessions intact, and detach / reattach locally. Remote
files over the socket are explicitly NOT v1 — SSH already covers the
remote case well enough that it earns no urgency.

**Explicitly not built:** a tmux clone inside mnml — its own session
multiplexing and window model. mnml already has splits, tab pages and a
layout tree; a second competing model would be redundant, and anyone who
wants tmux will run tmux. `src/key_doctor.rs:222` already detects
`$TMUX` / `$STY` for keyboard passthrough; coexistence is the
established posture and should stay it.

## 3. Rope buffer

**Status: not started. The architecture was designed for it; that design
has never been tested.**

`Editor` still stores `text: String` with a byte cursor
(`src/editor/mod.rs:803`). The v0.2.20 performance work fixed *reading*
— the `line_starts` index, the `LineRender` pre-pass, the cached
breadcrumb outline — and took a 13k-line file from 300ms to 9ms per
frame. Writing was not touched. Every keystroke is still an O(n) memmove
through the whole buffer, already measured at ~2.9ms on a 5 MB file.

CLAUDE.md's spine says: "all mutation goes through `apply` so a rope can
slide in later without touching call sites." That is a load-bearing
claim about the architecture that has never been cashed. Either it is
true — in which case this is a contained change and worth doing — or it
has quietly stopped being true, in which case we want to know now rather
than in a year with another 100k lines layered on top.

Do this one *after* display width (track 1), because rope column arithmetic and
display-width column arithmetic touch the same call sites, and doing
them in the other order means visiting those sites twice.

## 4. Settings v2 — and the pattern underneath it

**Status: v1 shipped (discrete-choice rows only, by design).**

Look at what has been accumulating in the backlog as a consequence:

- "make `[ui] external_browser` reachable from the UI — probably
  right-click on the relevant icon rather than TOML-only"
- "let the user set the CURRENT-ROW colour, the way session colour is set"
- "bell right-click — Notify level: Errors only / Warnings+ / All,
  persisted"
- the tree-width / gutter-width questions

Those are not four separate items. They are one missing capability —
number, text, and colour rows in the settings overlay — filed four
times, each time as a bespoke right-click menu on whichever surface the
user happened to be looking at. Shipping v2 retires the class. Building
the four menus individually guarantees a fifth.

The family settings-UI convention in CLAUDE.md already reserves this:
"Number / Text / Color rows are v2."

**Adjacent, same argument:** the design-system component sweep the
2026-09-01 audit started. Seven distinct `Sort` types exist
(`file_browser::Sort`, `SessionsSortMode`, `InstalledSort`,
`MarketplaceSort`, `TestsSort`, `SpendSortKey`, `claude_agents::SortBy`).
Most should stay distinct — their variants are genuinely domain-specific
— but the *presentation* of a sort is now written seven times. Same for
filter rows, count-in-parens subtitles, and empty states. This is the
work that keeps the UI from drifting while everything else lands.

---

## Explicitly not on the roadmap

**More panes, more integrations.** That surface is the most complete
part of mnml and the least starved. A new `Pane` variant is cheap by
design, which is exactly why the discipline has to come from somewhere
other than the cost.

---

## Not roadmap, but blocking

**Issue #34 — 5 mouse/file-tree e2e tests failing on `main` since
v0.2.17.** 193 `.test` scripts are worth much less when red is the
normal state of the suite; a red baseline is how a real regression gets
waved through. Fix or delete them, but do not leave them red.

**Adoption — a decision, not a task.** 6 stars, 4 forks, 68 downloads on
the latest release. Every item in TODO.md and most of this file improves
the tool for someone who already knows it. Nothing anywhere touches the
first five minutes after `brew install mnml`.

If mnml is meant to reach other people, the highest-leverage single
feature on this page is a guided first run: pick a keymap, pick a theme,
detect the languages in the workspace and offer to install their servers
through the Tools picker that already exists, then a short tour. That
converts downloads into users, and nothing else here does.

If mnml is meant to stay a personal daily driver — which is a completely
legitimate answer — then delete this section and re-rank everything
above it accordingly. This is the one item on the page that cannot be
decided from inside the code.
