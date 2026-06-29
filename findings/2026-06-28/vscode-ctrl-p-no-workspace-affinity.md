---
agent: vscode-user
severity: SEV-3
---

## SEV-3 Ctrl+P fuzzy picker has no workspace affinity — current-workspace files lose to global recent-files

**Reproduction**:
```
// In workspace /tmp/mnml-vscode-hunt with src/lib.rs and src/main.rs
{"cmd":"key","key":"ctrl+p"}
{"cmd":"wait_ms","ms":150}
{"cmd":"type","text":"lib"}
{"cmd":"wait_ms","ms":150}
{"cmd":"snapshot"}
```

Top of the picker results:
```
▌ lib.rs   /Users/chrismclennan/Projects/mnml/crates/mnml-bridge/src
  lib.rs   /Users/chrismclennan/Projects/mnml/findings/vscode-user-keyboard-2026-06-27/ws
  ... 6 more lib.rs entries from other projects ...
  src/lib.rs   src     ← THE LOCAL ONE, position 9 in the list
  LibraryAns…  /Users/chrismclennan/Projects/tattle-site/...
```

**Expected**: VS Code's Ctrl+P scores files in the current workspace much higher than recently-edited files in other workspaces. The local `src/lib.rs` should be position 1 (or top 3 at worst).

**Actual**: Local `src/lib.rs` ranks 9th. The picker treats workspace boundaries as decorative — every recent file globally is mixed in by recency / fuzzy match alone. For a user who hops between projects (which this codebase clearly does — multiple `mnml-*` siblings, `tattle-*`, `mixr-*`), this means typing `lib<Enter>` opens a file from the WRONG project most of the time.

**Source pointer**: the picker source-ranking lives in `src/app/picker.rs` (around the fuzzy-score function). The result row labels show that the recent-files list is multi-workspace by design; the absent piece is a workspace-affinity boost.

**Notes**: Workaround is to type the directory prefix (`src/lib`), which DOES narrow correctly. But that defeats the purpose of fuzzy search. VS Code's signature speed-feel of `Ctrl+P → 3 keys → Enter` doesn't survive contact with mnml's recent-files-first ordering.
