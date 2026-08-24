#!/usr/bin/env bash
# Git surface demo driver — walks mnml's Source Control experience:
# activity-bar rail (with polished GIT caps header + refresh chip),
# gutter signs on a modified file, the 3-mode Diff pane (Inline /
# Split / Hunk), per-hunk staging, and the coloured commit DAG with
# hover tooltip.
#
# Runs against demo/workspace, which is a real git repo carrying a
# handful of tracked-but-modified files (README.md, requests/notes.http,
# src/main.ts, src/server.ts, src/store.ts). Those make gutter signs +
# hunks + a status list visible without any live seeding.
#
# Output → site/public/media/git.gif via hero.record.sh's TAPE_NAME=git.
#
# Budget: ~40s. Density over leisure — same rhythm as hero.driver.sh.
set -euo pipefail

WS="${MNML_DEMO_WORKSPACE:-$(cd "$(dirname "$0")/../workspace" && pwd)}"
CMD="$WS/.mnml/ipc/command"

# ── Wait for mnml to boot ──────────────────────────────────────────
for _ in $(seq 1 60); do
  if [ -s "$WS/.mnml/ipc/screen.txt" ]; then
    break
  fi
  sleep 0.1
done
sleep 2.2

send() { echo "$1" >> "$CMD"; }
run()  { send "{\"cmd\":\"run-command\",\"id\":\"$1\"}"; }
key()  { send "{\"cmd\":\"key\",\"key\":\"$1\"}"; }
type() { send "{\"cmd\":\"type\",\"text\":\"$1\"}"; }
open() { send "{\"cmd\":\"open\",\"path\":\"$1\"}"; }
hover() { send "{\"cmd\":\"hover\",\"col\":$1,\"row\":$2}"; }
wait_ms() { local ms="$1"; awk "BEGIN{system(\"sleep \" $ms/1000)}"; }

# Standard keymap so single-letter chords inside the diff pane
# (`v` cycle mode, `n` next hunk, `s` stage) fire directly without
# vim's Normal-mode motions eating them.
run "editor.use_standard"
wait_ms 300

# Beats (target ~40s)
# t=00.0  1  welcome dwell
# t=01.4  2  activity_git       — Git rail: header chips + branches + changed files
# t=04.4  3  open src/store.ts  — editor with gutter signs (+ ~ -) visible
# t=07.0  4  jump through hunks — cursor moves past change bars
# t=09.0  5  git.diff_file      — 3-mode Diff pane opens (Inline default)
# t=11.5  6  v → Split          — side-by-side
# t=14.0  7  v → Hunk           — @@-headed per-hunk view
# t=16.5  8  n → next hunk      — cursor moves to hunk 2
# t=17.7  9  s → stage hunk     — Stage chip fires, hunk moves to staged
# t=19.7 10  Esc back to editor
# t=20.4 11  git.graph          — coloured-lane DAG opens
# t=23.4 12  down×3             — walk through recent commits
# t=27.0 13  hover commit       — author + subject tooltip
# t=29.0 14  hero shot dwell
# t=32.0 15  quit

# ── 1. Welcome dwell ─────────────────────────────────────────────
wait_ms 1400

# ── 2. Switch to the Git activity section ────────────────────────
# Left rail flips: "GIT" caps header on top with the six action
# chips at the right edge (↺ fetch, ↓ pull, ↑ push, + stage-all,
# ✓ commit, ⎇ graph — the refresh/fetch chip is the "recent polish"
# beat). Below: branches, worktrees, changed files.
run "view.activity_git"
wait_ms 3000

# ── 3. Open a modified file → editor shows gutter signs ──────────
# src/store.ts is tracked-but-modified in demo/workspace, so
# opening it renders green `+` (adds), yellow `~` (edits), red `-`
# (deletes) in the gutter on the changed lines.
open "src/store.ts"
wait_ms 2600

# ── 4. Jump through the file so the cursor passes the change bars ─
# `git.jump_next_change` walks to the next hunk in the current
# buffer — visually parks the cursor on a coloured gutter row so
# viewers see it isn't a static screenshot.
run "git.jump_next_change"
wait_ms 900
run "git.jump_next_change"
wait_ms 1100

# ── 5. Open the 3-mode Diff pane (default: Inline) ───────────────
# `git.diff_file` splits right with a Diff pane. Toolbar at the
# top: [ Hunk ] [ Inline ] [ Split ] · [ Wrap ] · [ × ]. Body is
# hunks with @@ headers + coloured +/- lines. Active-hunk chip
# banner sits sticky above the body with Stage / Discard chips.
run "git.diff_file"
wait_ms 2500

# ── 6. Cycle mode: Inline → Split ────────────────────────────────
# `v` inside the diff pane cycles Hunk → Inline → Split → Hunk;
# from the Inline default one press lands on Split (side-by-side
# with old on the left, new on the right).
key "v"
wait_ms 2500

# ── 7. Cycle mode: Split → Hunk ──────────────────────────────────
# Second `v` lands on Hunk (per-hunk @@-headed view with each hunk
# individually framed + its own Stage / Discard chip row).
key "v"
wait_ms 2500

# ── 8. Move to the next hunk ─────────────────────────────────────
# `n` walks the cursor to the next hunk in the pane (visually
# shifts the highlight down a hunk). Same chord as `]c` and the
# `Next hunk` toolbar chip.
key "n"
wait_ms 1200

# ── 9. Stage the hunk ────────────────────────────────────────────
# `s` fires `app.apply_cursor_hunk(false)` — same code path as the
# green Stage chip. After the stage, the hunk vanishes from the
# unstaged view (the buffer's actual +/- lines get written to the
# index via `git apply --cached`).
key "s"
wait_ms 2000

# ── 10. Back to editor ───────────────────────────────────────────
# Esc drops focus to the tree so the next beat is a clean cut.
key "escape"
wait_ms 700

# ── 11. Open the commit graph ────────────────────────────────────
# `git.graph` opens the GitGraph pane — coloured-lane DAG
# (one column of `● │ │`-style rail glyphs per branch), commit
# rows with `<sha7> <subject> · <author> · <relative-time>`, and
# a WIP header row for uncommitted work.
run "git.graph"
wait_ms 3000

# ── 12. Walk through recent commits ──────────────────────────────
# Each Down moves the row highlight; the rail lanes stay put so
# viewers see the DAG structure hold as the cursor traverses it.
key "down"; wait_ms 700
key "down"; wait_ms 700
key "down"; wait_ms 800
key "down"; wait_ms 800

# ── 13. Hover a commit → tooltip ─────────────────────────────────
# Hover on a commit row well below the toolbar. The graph pane is
# in the right leaf (post-split), so commit rows land around
# col ~50–140 depending on subject width. Row 6 is safely inside
# the commit list at the 160x42 demo geometry — the first commit
# rows start around row 3–4 after the toolbar.
hover 80 6
wait_ms 2200

# ── 14. Hero-shot dwell on the composite ─────────────────────────
# Left: git activity rail. Right: coloured-lane commit DAG with
# a commit selected + tooltip visible. This is the frame the GIF
# ends on before the trim → static-preview.
wait_ms 3000

# ── 15. Quit ─────────────────────────────────────────────────────
send '{"cmd":"quit"}'
