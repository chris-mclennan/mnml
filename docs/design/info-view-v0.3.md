# mnml learns itself — Info View v0.3

**Status**: design draft · 2026-08-09
**Target release**: v0.3
**Owner**: TBD
**Estimate**: ~4 days framework + first-draft copy · ongoing agent-maintained

## Problem

mnml today has **598 palette commands**, **229 `HoverChip` variants**, and **~1,164 distinct clickable/hoverable rects**. New users learn ~10% of that; power users learn ~30%. The other 70% may as well not exist — commands unbound, chips silent, features undocumented at point-of-use.

Existing surfaces (docs site, `view.help`, `view.commands_reference`, `view.welcome`) sit outside the workflow. Users don't stop editing to read a manual.

The hover-help footer strip (moved to a bottom-of-left-panel info box in v0.2.9, commit `bebaa274`) has the right *shape*, but the *content* is terse `id · state · workspace` output — reads like debug logs, not user-facing help.

**Ableton Live** solved this with an Info View: a persistent lower-left panel that describes literally anything the mouse is over, in 2-4 sentences of hand-crafted editorial copy. Users don't need to read the docs. It's a differentiator, not a nice-to-have.

## Product bet

The v0.3 flagship: **"mnml learns itself."**
- Every hoverable surface has a rich, editorial description in the info box.
- Descriptions include what the thing does, when to use it, related actions, and (uniquely to TUI) clickable palette-command links to try it.
- Copy is generated + maintained by an agent so we can afford 500+ entries without a full-time content team.
- On by default. Users can hide it, but shouldn't have to discover it.

If we ship this well, mnml becomes the TUI IDE where the app itself is the tutorial. The gap between "installed" and "productive" collapses.

## Design principles

1. **Every hoverable thing has copy.** No `id · state · workspace` fallback in the shipped product. Coverage is completeness, not optionality.
2. **Editorial voice, not template output.** 2-4 sentences per entry, written for a human. Templates are for first drafts, not shipped copy.
3. **State-aware.** The same knob describes itself differently when disabled, pending, in an error state, or being modulated.
4. **Actionable.** Where relevant, the entry lists 1-3 palette commands the user can fire (rendered as clickable links inside the panel).
5. **Self-explanatory.** The empty state (nothing hovered, no focus target) tells the user what the panel is and how to hide it. No first-launch modal.
6. **Agent-maintained.** Humans write the voice guide; the agent writes the entries and re-audits on drift.

## Runtime shape

### Layout — matches Ableton's Info View

Ableton's Info View is a two-section panel:

- **Top bar** with the topic name (distinct background, bold, own row).
- **Body area** below with prose description followed by a shortcut listing (`[Ctrl + Arrow Up/Down] Insert Clips...` style).

Reference: bottom-left of Ableton Live's main window.

mnml matches this. The `? Info` marker used in v0.2.9 gets replaced by a proper title bar so the reader always knows which topic they're looking at:

```
┌────────────────────────────┐
│ Main Lane                  │  ← title bar (bg + bold; the "topic")
├────────────────────────────┤
│                            │
│ Displays all clips that    │  ← prose body (word-wrapped)
│ normally play through the  │
│ track's mixer. Click and   │
│ drag to select time, then  │
│ use any available Edit     │
│ menu command to edit.      │
│                            │
│ [Ctrl+↑/↓] Insert Clips    │  ← shortcut listings (styled chord + label)
│ [Ctrl+Alt+Drag] Scroll     │
│ [Ctrl+Scroll] Zoom In/Out  │
│ [Alt+Scroll] Adjust Height │
│                            │
│ → Details in the manual    │  ← optional docs hyperlink
└────────────────────────────┘
```

### Data model

```rust
// src/ui/info_view.rs

pub struct InfoViewCopy {
    /// Title-bar text. The TOPIC the reader is looking at.
    /// Rendered on its own row with a distinct background, bold.
    /// 40-70 chars ideal. Reads as a noun phrase; NEVER paraphrases
    /// the label. e.g. "Claude Code session", "Vim insert mode",
    /// "HTTP Response Body".
    pub title: String,

    /// 2-4 sentence prose description (regular weight, word-wrapped).
    /// Empty string means "title is enough" — rare.
    pub body: String,

    /// Optional single-sentence context/caveat rendered in italics
    /// after the body. "This is the default." / "Only visible when
    /// N ≥ 2." / etc.
    pub aside: Option<String>,

    /// Zero-to-many keyboard-shortcut hints. Ableton renders these
    /// as `[Ctrl + Arrow Up/Down] Insert Clips…` — chord in
    /// bracketed accent color, label after in body color.
    ///
    /// Only listed when the shortcut is relevant to the hovered
    /// thing (e.g. hovering the tree shows tree-nav chords, not
    /// HTTP chords).
    pub shortcuts: Vec<ShortcutHint>,

    /// Zero-to-three "Try it →" chips. Rendered as underlined
    /// clickable text at the bottom of the body; firing executes
    /// the palette command. Distinct from `shortcuts` — try_it is
    /// for actions the user might want to take RIGHT NOW while
    /// hovering; shortcuts is educational reference material.
    pub try_it: Vec<PaletteLink>,

    /// Docs link — opens the corresponding manual page in the
    /// browser (or in-app md-preview when we ship it).
    pub docs: Option<String>,
}

pub struct ShortcutHint {
    /// Human-readable chord — e.g. "Ctrl+Alt+Drag", "Ctrl+↑",
    /// "double-click". Rendered in bracket-wrapped accent style.
    pub chord: String,

    /// Short label — what the chord does in this context.
    /// e.g. "Insert Clips from Previous/Next Take Lane".
    pub label: String,
}

pub struct PaletteLink {
    pub command_id: String,   // e.g. "view.toggle_hover_help"
    pub label: String,         // e.g. "Hide this panel"
}
```

### Rich content support

Text spans inside `body`, `aside`, and `label` fields can carry inline styles:

- **Chord glyphs**: text matching `[Chord]` pattern gets rendered with the accent chip style (matches the standalone `shortcuts` list — same visual treatment inline as in the shortcut listing so they're recognisable anywhere).
- **Palette-command hyperlinks**: `:cmd.id` inline references become clickable underlined text; click fires the command. Same underlying mechanism as `try_it`, just inline instead of at the bottom.
- **Manual-page hyperlinks**: `[[topic]]` inline references become clickable links to the corresponding site manual page (or in-app md-preview once wired).
- **Emphasis**: **bold** and *italic* markdown-style tokens render with the corresponding style.

Rendered via a small inline-token pass in `ui::info_view::render_span()`. Deliberately narrow — no images, no ASCII art, no tables. Text with typed styles + click-targets.

### Describe function

```rust
pub fn describe_info_view(app: &App, target: InfoViewTarget) -> InfoViewCopy {
    match target {
        InfoViewTarget::Chip(chip) => copy_for_chip(app, chip),
        InfoViewTarget::TreeRow(row) => copy_for_tree_row(app, row),
        InfoViewTarget::MenuItem { menu, item } => copy_for_menu_item(app, menu, item),
        InfoViewTarget::EditorSymbol { pane, sym } => copy_for_symbol(app, pane, sym),
        InfoViewTarget::None => empty_state_copy(app),
    }
}
```

`InfoViewTarget` is a new enum covering every hoverable-thing class. Populated by the existing hover/focus tracking; nothing changes about how mnml detects hover — only about what it says.

### Fallback ladder

1. **Curated copy** — entry in `info_view_copy.rs` matching this exact target.
2. **Agent-generated placeholder** — auto-derived from source docstrings + palette command titles. Shown with a subtle marker so we know it's not curated yet. Better than tofu; still learnable.
3. **Empty-state copy** — when nothing's hovered. Explains what the panel is, how to hide it, one interesting thing to try.

Never fall to raw `id · state`.

### Rendering (mostly unchanged from v0.2.9)

- Still a boxed panel at the bottom of the left panel.
- 1-cell separator rule + `? Info` header + word-wrapped body (see commit `<pending>` shipping the separator).
- Height defaults to 7 rows; grows to 12 if the copy is longer and there's room; scrolls if longer than that (mouse wheel; keyboard `Ctrl+Up`/`Ctrl+Down` when the panel has focus).
- `Try it →` links get a distinct color; clicking fires the palette command.

## Copy dictionary

### Layout

Single file: `src/ui/info_view_copy.rs`. Organized by section header comments:

```rust
// ── Chrome ───────────────────────────────────────────
fn chip__palette_search() -> InfoViewCopy { … }
fn chip__sidebar_toggle() -> InfoViewCopy { … }
fn chip__right_panel_toggle() -> InfoViewCopy { … }
fn chip__theme_toggle() -> InfoViewCopy { … }

// ── Menu bar ─────────────────────────────────────────
fn menu__file() -> InfoViewCopy { … }
fn menu__edit() -> InfoViewCopy { … }
…

// ── Statusline ───────────────────────────────────────
fn statusline__mode() -> InfoViewCopy { … }
fn statusline__ai_claude() -> InfoViewCopy { … }
…

// ── Tree ─────────────────────────────────────────────
fn tree__workspace_row() -> InfoViewCopy { … }
fn tree__file_row(ext: &str) -> InfoViewCopy { … }
…
```

Each entry is a plain fn. State-varying entries take state args (`ext`, `is_dirty`, `count`, etc.) and dispatch on them.

Why one file: easier to review + revise + audit voice consistency. If it hits 2k lines we split by section, but the sections themselves stay adjacent.

### Source-of-truth links

Every entry carries a `// src: src/ui/statusline.rs::draw_ai_claude_chip` comment linking to the code that renders the described widget. The drift-check agent parses these to correlate copy with source.

## Voice guide

Copy that gets written should sound like these examples:

**Bad (current state)**:
> Claude Code · workspace · Idle · session-id

**Bad (template output)**:
> This is the Claude Code chip. Click to open the Claude Code pane.

**Good (target voice)**:
> **Claude Code session**
> This chip shows the currently active Claude session for this workspace. Click to jump to it; right-click for actions like Kill, Continue, or Fork.
> *Green means running, grey means idle, red means the session ended with an error.*

Rules:
- **Headline** is a noun phrase — what the thing IS, not what it does. "Claude Code session" not "Show session".
- **Body** answers *what does hovering-this-thing-mean-in-context*. Assume the user is looking at it right now.
- **Aside** covers state-variance or edge cases in italics. Optional.
- **Never** repeat the label. If the chip says "Claude Code" the headline shouldn't say "Claude Code chip".
- **Present tense, active voice**: "Click to open" not "Can be clicked to open".
- **No hedging**: not "usually" or "typically". If it's usually true, state the rule and put the exception in the aside.
- **Domain terms** explained on first hover of the day: "session (a running Claude conversation)".

Length targets:
- Headline: ≤70 chars (fits one line at 28-col panel width)
- Body: 2-4 sentences, ~150-250 chars
- Aside: 1 sentence, ~80 chars
- `Try it` labels: ≤30 chars

## Agent-generated + maintained pipeline

### First-draft generation

**Trigger**: manual `/agent info-view-writer` invocation or as part of v0.3 milestone.

**Agent inputs**:
- The voice guide (this doc, `## Voice guide` section)
- The complete `InfoViewTarget` enum + list of every variant
- For each target: the source file/line that defines its rendering, its palette command (if any), its docstring, its state variants
- Existing curated entries as few-shot examples

**Agent outputs**:
- A `pub fn <target>() -> InfoViewCopy { … }` per target, following the voice guide
- Written into `src/ui/info_view_copy.rs` in the appropriate section

**Agent quality bar**:
- Each entry must NOT paraphrase the label
- Body length in-range
- If the source doesn't have enough info to write a real entry, leave a `// TODO: agent could not determine <what>` comment and fall back to a stub — never invent

**Post-generation human review**:
- Read every entry. Flag flat/generic ones. Rewrite 10-20% for editorial polish. The other 80-90% ship as agent-written.

### Drift maintenance

**Trigger**: on `main` commit hook or nightly cron.

**Agent inputs**:
- Diff since last drift-check run
- The full `info_view_copy.rs` with `// src:` comments

**Agent outputs**:
- A report at `.mnml/findings/info-view-drift-<timestamp>.md`:
  - Copy entries whose linked source file was touched → likely need a rewrite
  - Copy entries whose linked source no longer exists → orphan, safe to remove
  - New `InfoViewTarget` variants added since last run → missing entry
  - Entries that violate the voice guide (length, hedging, label repetition) → flag with reason
- **Never edits copy autonomously.** Reports only. Human reviews + approves the fix batch.

**CI gate** (optional, later): the drift check runs on PRs touching hover-target sources; a large drift report becomes a review comment.

## Defaults

### `[ui] hover_help` default flips `false → true`

Every user gets the info box on. If they don't want it, right-click on the box → "Hide info panel" or `:set nohh` — the copy in the empty state tells them how.

Config precedence unchanged; users who set `hover_help = false` explicitly keep that setting.

### Empty-state copy

When the mouse isn't over anything AND focus doesn't have a describable target:

```
? Info
─────────────────
The Info panel describes whatever
your mouse is over. Hover any chip,
tab, or tree row to learn about it.

Hide: right-click here, or :set nohh
```

### Height default

Bump `INFO_BOX_HEIGHT` from 7 → 9 in v0.3 to accommodate the richer copy. Users on small terminals still fall back to the "panel too short, skip" gate (already in place at `if hover_help && area.height >= INFO_BOX_HEIGHT + 8`).

## Phase plan

### Phase 1 — Framework + top 50 entries (v0.3 alpha)

**Ships**:
- New `InfoViewCopy` + `InfoViewTarget` + `describe_info_view` + fallback ladder in `src/ui/info_view.rs`
- `src/ui/info_view_copy.rs` seeded with agent-generated + human-polished entries for the top 50 hover-targets (see inventory below)
- Empty-state copy
- `try_it` link rendering + click handler
- Voice guide as `docs/style/info-view-voice.md`
- Drift-check agent as `.claude/agents/info-view-drift.md`

**Doesn't ship**:
- LSP hover integration (Phase 2)
- Rich state-variant coverage (Phase 3)
- Editor content descriptions (Phase 3)

### Phase 2 — LSP hover pipe (v0.3 beta)

Hovering a symbol in the editor while `hover_help` is on shows the LSP hover result in the info panel. Uses the existing `Ctrl+K Ctrl+I` code path but pipes into the panel instead of a popup.

### Phase 3 — Reach expansion + state variants (v0.3 GA)

Every remaining hover-target from the 229 `HoverChip` variants and 1,164 rects. State-aware copy for chips with meaningful state variance (LSP status, git branch state, Claude token state, DAP breakpoint state, etc.).

### Phase 4 — Analytics-informed refinement (v0.4)

Ship an opt-in `hover_stats` toggle that logs which entries are hovered how often. Rewrite the top-100 most-hovered entries with editorial polish. Prune entries that are never hovered (may indicate a chip nobody notices).

## Top-50 entry inventory (Phase 1 candidates)

Chosen by "shows up in almost every session" + "power-user often confused by it":

**Chrome (10)**: `palette_search_chip`, `sidebar_toggle`, `right_panel_toggle`, `theme_toggle`, `back_nav_button`, `forward_nav_button`, `bufferline_new_tab_button`, `menu_bar_words` (one entry per menu = File/Edit/…), `dropdown_chevron`.

**Menu bar rows (12)**: The 3 most-hovered items per menu that a user would open. File→New/Open/Save. Edit→Find/Replace. View→Toggle panels/hover-help/zen. Selection→Add cursor. Go→Go to file/line/definition. Run→Start debugging/breakpoint. Terminal→New. Window→Split R/D, Close, Merge. Help→Welcome/Keybindings.

**Statusline chips (8)**: `mode`, `git_branch`, `ai_claude`, `ai_codex`, `mixr`, `clock`, `filesize`, `language`.

**Tree rows (6)**: `workspace_root`, `folder_row`, `file_row` (with language-specific variants for TS/PY/GO/RS/MD), `git_branch_row`, `integration_chip`, `agent_row`.

**Tabs + pane chrome (7)**: `split_tab_chip` (editor / pty / request / md-preview / ai / mount variants), `tab_page_pip`, `close_button`.

**Marketplace + integrations (5)**: `marketplace_row`, `installed_row`, `official_badge`, `verified_badge`, `refresh_button`.

**Overlays (2)**: `settings_row`, `palette_row`.

Approximate: 50 first-draft entries covering ~70% of daily hover volume. Phase 3 sweeps the rest.

## Cost + risk

**Cost**:
- Framework: ~2 days (new module + wiring + rendering)
- Agent generation + prompt tuning: ~1 day
- Human polish pass on top 50: ~1 day
- Drift-check agent + CI hook: ~0.5 day
- **Total**: ~4-5 days to ship Phase 1

**Ongoing**:
- Human review of drift-check reports: ~30 min/week
- New-target copy for new features: agent generates as part of the feature landing

**Risks**:
- **Copy rot** — mitigated by drift-check agent + `// src:` links.
- **Wall-of-text feel** — mitigated by max-length rules in voice guide + wrap-at-4-rows rendering.
- **Agent-flat voice** — mitigated by human polish pass on top entries + "never paraphrase label" rule.
- **Bikeshed on copy** — mitigated by voice guide being the referee. First writer wins; rewrites require a specific reason.
- **On-by-default annoys users** — mitigated by empty-state copy showing how to hide + `:set nohh` being one command.

## Success criteria

Ship-blocking:
- 100% of Phase-1-inventory targets have a curated `InfoViewCopy` entry (no fallback rendering in Phase 1 targets)
- Every entry passes the voice-guide length + rule checks
- Drift-check agent runs cleanly on first execution
- `[ui] hover_help = true` is default in fresh config
- Empty-state copy renders correctly across `focus = Tree | Pane | RightPanel | BottomPanel`

Nice-to-have:
- Docs site adds an `/info-view` page that lists all entries (auto-generated from `info_view_copy.rs`)
- Screenshot in the CHANGELOG showing "before" vs "after" info panel

## Non-goals

- **Localization**: English only for v0.3. i18n is a separate architecture problem.
- **User-defined entries**: users can't add their own copy (yet). Plugins could later.
- **Voice/audio**: no read-aloud. TUI ≠ accessibility replacement.
- **Rich media**: no images, no ASCII art. Text only.

## Open questions

- Where does the docs link (per entry) go — the manual site page, or an in-app `md-preview` opening the same content? Prefer in-app once md-preview handles external URLs; site link for now.
- Do we want a "learning mode" that briefly highlights the info-panel border when new content lands, to draw attention? Ableton doesn't; probably distracting for a TUI.
- Should `Try it →` links show a keyboard chord if one exists? "Try it → Ctrl+B — Hide sidebar" is arguably nicer than "Try it → Hide sidebar". Ship without in Phase 1, add if users ask.

## Appendix: agent prompt sketch

For the first-draft generator, roughly:

```
You are writing 2-4 sentence descriptions for every hoverable
element in mnml, following the voice guide at
docs/style/info-view-voice.md. Every entry gets an InfoViewCopy
returned from a stub function I will provide.

For each target below:
- Read the source line I've quoted (`// src:`) to understand what
  it renders and what state variants exist.
- Read the palette command title (if applicable) for terminology.
- Write InfoViewCopy following the voice guide.
- If the source doesn't have enough context to write real copy,
  leave `// TODO: agent could not determine <what>` and stub.

Never paraphrase the label. Never hedge. State-variance goes in
the aside. Actionable follow-ups go in try_it.
```

The full prompt gets ~30 few-shot examples of curated entries so the agent has voice + shape to match.

---

**End of doc.** Ready for review + task creation when v0.3 planning starts.
