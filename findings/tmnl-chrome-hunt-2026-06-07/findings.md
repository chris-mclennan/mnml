# tmnl bug-hunt — 2026-06-07

Headless exploration of `tmnl --headless --app` (~45 min, branch `main`, binary at `~/Projects/tmnl/target/release/tmnl`).

## Executive summary

**8 findings: 1 SEV-1, 3 SEV-2, 4 SEV-3.** Stability is high — no panics, no hangs, no leaked tmnl processes across 200-tab, 500-churn, 200-random-click stresses, NaN/Inf coord fuzzing, or quit-after-last-close. But the harness itself is fundamentally broken for what it's advertised to do: it can't exercise chip / `+` / palette clicks at all, because chips populate only inside `App::tick()` and the headless loop can't call `tick`.

**Explored**: 30/100/200/500-tab churn, alternating new/close, wrap (next/prev across boundaries), click + hover + wheel at edge / negative / NaN / Inf / out-of-window coords, vertical-layout config, palette-vs-chip overlap routing, drag-state cleanup on close, bad-command tolerance, close-last-tab-then-quit cleanup.

**Did not drive**: real chip clicks (impossible — see #2), real drag-to-reorder (same reason), key events into panes (no harness command), native blit tabs, fd-handoff, font zoom changes, window resize.

---

## [SEV-1] `tabs.swap(src, dst)` panics if a tab close removes the dragging tab

`tmnl/src/app.rs:2482-2486`

```rust
if let Some(dst) = dst
    && dst != src
    && dst < self.tabs.len()
{
    self.tabs.swap(src, dst);
```

`dst < self.tabs.len()` is checked but **`src < self.tabs.len()` is NOT**. `src` is `self.dragging_tab`, set when a left-press lands on a chip. Sequence to panic:

1. User left-clicks chip idx=5 → `dragging_tab = Some(5)`.
2. Any close-tab event (chord, OSC, future `close_tab_at` call) removes tab 5. `close_tab_at` does NOT clear `dragging_tab` (line 539 clears only `renaming_tab`).
3. User moves cursor (still holding LMB) → `handle_cursor_moved` swap branch runs with `src=5`, `tabs.len()=5`.
4. `self.tabs.swap(5, dst)` → `index out of bounds: the len is 5 but the index is 5` → panic.

**Fix**: in `close_tab_at` clear `dragging_tab` and `dragging_divider` alongside the existing `renaming_tab = None`; also guard the swap with `src < self.tabs.len()`.

**Bonus**: when a tab LEFT of the dragged tab is closed, `close_tab_at` shifts `self.active` down by 1 but `dragging_tab` stays — now points at a different tab than the user is dragging. Silent UX corruption, SEV-3 on top.

---

## [SEV-2] Headless `--app` cannot exercise chip / `+` / palette clicks

`tmnl/src/headless.rs:130-162` + `tmnl/src/app.rs:1319`

`populate_hit_rects()` re-runs `strip_chip_instances()` + `strip_palette_chip_instances()`, but `strip_chip_instances` bails at `self.strip_chips.len() <= 1`, and `set_strip_chips` is **only called inside `App::tick()`** (line 1319). `App::tick` takes `&ActiveEventLoop`, so the headless harness can't call it.

Effect: no matter how many tabs are open, `gpu.strip_chips` stays empty → `strip_chip_rects` stays empty → every click on a tab chip, `+` button, close badge, or palette cluster silently goes nowhere.

7 of the 8 click-routing scenarios in the brief cannot be tested. Only direct App-method commands (`tab.new`, `tab.close`, `tab.next`, `tab.prev`) actually work.

**Fix**: factor the chrome-refresh block of `App::tick` (lines 1314-1338) into an event-loop-free method, then call it from the headless loop before every `click`/`hover`/`wheel`. Add a `headless.rs` test asserting a chip click flips `app.active`.

---

## [SEV-2] `config.toml` and `recents.toml` live in different directories on macOS

`tmnl/src/config.rs:109-111` (uses `dirs::config_dir()` → `~/Library/Application Support/tmnl/`)
`tmnl/src/recents.rs:171-183` (hardcodes `~/.config/tmnl/`)

On macOS:

```
~/Library/Application Support/tmnl/config.toml      (real config — read at startup)
~/.config/tmnl/recents.toml                         (real recents)
~/.config/tmnl/config.toml                          (silently ignored)
```

`CLAUDE.md` says `~/.config/tmnl/config.toml`. Doc at `src/config.rs:92` says `~/.config/tmnl/config.toml`. Doc at `src/recents.rs:4` says `~/.config/tmnl/recents.toml`. Every claim is XDG; the actual filesystem layout disagrees.

**Fix**: pick one. Either change `recents.rs` to use `dirs::config_dir()`, or change `config.rs` to use the explicit `$XDG_CONFIG_HOME` / `~/.config` path the docs claim. Update CLAUDE.md.

---

## [SEV-2] `app_state_json` panics if `tabs` is empty

`tmnl/src/headless.rs:250`

```rust
let active_tab = &app.tabs[app.active.min(app.tabs.len().saturating_sub(1))];
```

If `tabs.is_empty()`, `len().saturating_sub(1) = 0`, `min(0) = 0`, then `app.tabs[0]` panics. Currently unreachable because `close_tab_at` early-returns at `tabs.len() <= 1` (setting `should_quit` instead of removing), and the headless loop checks `should_quit` and breaks before the next stdin line. But one stray code change away.

**Fix**: explicit `app.tabs.get(app.active).or_else(|| app.tabs.first())` and emit `{"tabs":0,...,"panes":[]}` on None.

---

## [SEV-3] Middle-click on the palette cluster can close the chip underneath

`tmnl/src/app.rs:2589-2636`

The palette hit-test runs for ALL buttons, but the early-return is gated on `button == MouseButton::Left`. So a middle-click in the palette area returns `palette_key = Some(..)` and falls THROUGH to the chip-close hit-test.

**Fix**: `return` whenever `palette_key.is_some()`, regardless of button.

---

## [SEV-3] `new_shell_tab` / `new_native_tab` skip `on_tab_focused`

`tmnl/src/app.rs:515`, `:308`

Both push a tab and `self.active = self.tabs.len() - 1` but don't call `on_tab_focused()`. `switch_to_tab` and `close_tab_at` (active-was-closed branch) both do. `on_tab_focused` clears `attention` and runs `relayout_all_panes`. Inconsistent.

**Fix**: call `self.on_tab_focused()` at the end of both functions.

---

## [SEV-3] `synthetic_click` sets `self.mods` AFTER `handle_cursor_moved`

`tmnl/src/app.rs:215-219`

```rust
self.handle_cursor_moved(position);
self.mods = mods;
self.handle_mouse_input(Pressed, button);
self.handle_mouse_input(Released, button);
```

`handle_cursor_moved` packs `mods: pack_mods(self.mods)`. With mods set *after* the move, the hover-as-drag uses stale modifiers. A synthetic `click 100 100 left ctrl` sends a Moved-without-Ctrl, then Down-Ctrl, then Up-Ctrl. Real winit flow doesn't have this issue.

**Fix**: set `self.mods = mods` BEFORE `handle_cursor_moved`.

---

## [SEV-3] `state-json` schema is too thin to verify chrome state

Currently: `tabs`, `active`, `panes`, `should_quit`, `tab_layout`, `altscreen`. Missing for bug-hunting:

- `cursor_cell` / `cursor_px` — can't verify hover/click landed.
- `buttons_down` — can't verify a press/release pair was clean.
- `strip_chips.len()`, `strip_chip_rects.len()`, `strip_new_tab_rect.is_some()` — would have surfaced SEV-2 #2 in 30 seconds.
- `dragging_tab`, `dragging_divider`, `renaming_tab` — needed to verify SEV-1 drag-state cleanup.
- `sidebar_w_px`, `strip_h` — can't verify vertical-layout chrome.

**Fix**: extend `app_state_json` additively.
