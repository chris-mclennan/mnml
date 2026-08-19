# Programmatic layout config (task #878)

Status: design draft — 2026-08-19. Implementation to follow after
review, alongside step-3 of the auto-update work.

## What we want

Right now mnml boots to either the saved session (`.mnml/session.json`)
or a bare welcome screen. Users who want a specific starting layout
— editor + terminal + notes split — have to build it by hand every
time, or rely on the session file which drifts as they work.

Add a **declarative startup layout** block in `config.toml` so users
can say "when I open mnml on this workspace, arrange the panes like
this." The session file still wins (a saved layout represents "where
I left off"); the declarative block is the *cold-start* baseline.

## Config shape (MVP)

```toml
[startup.layout]
# List of files/pty commands to open, in the order they should be
# added. First entry lands in the initial leaf; each subsequent
# entry opens in a split of the previously-added pane.
opens = [
  { kind = "editor", path = "src/main.rs" },
  { kind = "editor", path = "src/lib.rs",   split = "right" },
  { kind = "pty",    cmd  = "cargo watch",  split = "down"  },
]
```

Each `opens[]` entry is either an editor pane with a path or a Pty
pane with a shell command. `split` is one of `"right"` (horizontal
side-by-side) or `"down"` (vertical stacked). Absent on the first
entry (nothing to split against); required on subsequent entries.

The MVP is a **linear chain of splits** — each new pane splits the
most recently added leaf. That covers 80% of "declarative startup
layout" without needing a full recursive tree grammar. Complex
arrangements (split A, focus back to root, split A a second time
against a different sibling) stay session-restore territory.

## Fallbacks

- **Missing file** → open as a scratch buffer named after the path
  (no error toast — matches how `open_path` handles new files today).
- **Missing command** → drop the entry (no Pty), toast once.
- **Empty `opens` list** → fall through to the welcome screen.
- **Session file present** → session wins. The declarative block is
  the "no session yet" default, not an override. Users who want the
  declarative layout on every boot can `.mnml/session.json` to
  gitignore + skip session restore.

## When it runs

- After the workspace directory is resolved.
- After the session-restore attempt (which may set up its own
  layout).
- BEFORE the first paint — so users see the intended layout, not the
  welcome-then-flash sequence.

Skipped when:
- `--headless` (tests set their own state).
- `--demo` (demo mode owns the layout, per `src/app/demo.rs`).
- Session file was present and restored successfully.

## Non-goals (MVP)

- **Dock widgets** — bottom/right panels + corner overlays stay
  session-driven. Docked panes have their own design doc
  (`dockable-panes.md`); folding them into `[startup.layout]`
  is a follow-up once dockable-panes phase 1 lands (#906).
- **Recursive tree** — MVP is a linear chain. If a user needs a
  T-shaped or grid layout, they build it once + let session restore
  reproduce it.
- **Per-workspace override** — `[startup.layout]` lives in the
  user's global config for now. A workspace-scoped `.mnml/config.toml`
  could carry a per-workspace override later; not required for MVP.
- **Interactive designer** — no drag-drop UI for building the config
  block. Users write TOML.

## Implementation sketch

Small typed struct on `Config`:

```rust
pub struct StartupLayoutEntry {
    pub kind: String,           // "editor" | "pty"
    pub path: Option<String>,   // required for kind = editor
    pub cmd:  Option<String>,   // required for kind = pty
    pub split: Option<String>,  // "right" | "down"; None for first entry
}

impl Config {
    pub startup_layout: Vec<StartupLayoutEntry>,  // empty = disabled
}
```

Applied in a new `App::apply_startup_layout()` method called after
`App::new` but before the first `ui::draw`:

```rust
fn apply_startup_layout(&mut self) {
    for (i, entry) in self.config.startup_layout.clone().iter().enumerate() {
        if i > 0 {
            let dir = match entry.split.as_deref() {
                Some("right") => SplitDir::Horizontal,
                Some("down") => SplitDir::Vertical,
                _ => { self.toast("startup.layout: entry {i} missing `split`"); continue; }
            };
            self.split_active(dir);
        }
        match entry.kind.as_str() {
            "editor" => if let Some(p) = &entry.path { self.open_path(p); }
            "pty"    => if let Some(cmd) = &entry.cmd { self.open_pty_with_cmd(cmd); }
            other    => { self.toast("startup.layout: unknown kind {other}"); continue; }
        }
    }
}
```

Gate on:

- `self.session_was_restored` (existing signal from session load) —
  skip if true.
- `--headless` / `--demo` — skip in main.rs before calling
  `apply_startup_layout`.

## Order of operations for shipping

1. Add `StartupLayoutEntry` + `Config::startup_layout` + raw shape
   + tests for the resolver (invalid entries, empty list, all-editor,
   mixed with pty). Merge.
2. Add `App::apply_startup_layout` + gate points. Tests headless-mode
   exercise it with a synthesized config. Merge.
3. Manual UX check across:
   - Fresh workspace with no session → declarative layout appears.
   - Workspace with saved session → session wins.
   - Missing file → falls back to scratch buffer named after path.
   - Missing pty command → toasts + continues.

Split into two merges so the schema piece is reversible on its own
if UX surfaces something the sketch missed.

## Open questions

- **Ratio control.** MVP always uses `ratio = 50`. Should the config
  allow `ratio = 30` on a per-entry basis? Adds a knob; users could
  tune "editor 60% / terminal 40%" out of the box. Small addition,
  likely worth including in v1.
- **`view.reset_to_startup_layout` palette command.** Would let
  users blow away the current session state and re-apply the
  declarative block. Handy escape hatch. Add as v1.5 if users ask.
- **Env-var expansion in paths / commands.** `path = "$HOME/notes.md"`
  should probably work (matches how `[[tasks]]` treats
  `cmd = "$MY_TOOL"`). Include for v1.
