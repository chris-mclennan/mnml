---
agent: vscode-user
severity: SEV-3
---

## SEV-3 Ctrl+Tab doesn't act as MRU buffer toggle — first press no-ops, behavior depends on split state

**Reproduction**:
```
// Open three files in sequence
{"cmd":"open","path":"src/main.rs"}
{"cmd":"open","path":"README.md"}
{"cmd":"open","path":"src/lib.rs"}    // lib.rs active now
{"cmd":"wait_ms","ms":150}
{"cmd":"key","key":"ctrl+tab"}
{"cmd":"wait_ms","ms":150}
{"cmd":"snapshot"}
```

Status: `active = 0` (main.rs) — but the MRU partner of lib.rs should be README.md (the previous active before this one).

In a separate run (one editor leaf, three tabs `lib.rs / README.md / Cargo.toml`, active was `lib.rs`), `Ctrl+Tab` left `active` unchanged at the same pane index.

**Expected**: VS Code Ctrl+Tab opens a quick-pick of recently-used tabs; releasing Ctrl commits to the highlighted one. As a fallback for keyboard-only environments, a single Ctrl+Tab tap simply toggles between the two most-recently-used buffers — analogous to Alt+Tab in macOS.

**Actual**: First scenario jumped to `panes[0]` (which happened to be main.rs in a 4-pane list with main.rs duplicated across splits) — order looks like "first non-active pane in panes vector", not "previously active." Second scenario (single leaf, three panes, lib.rs active) leaves active unchanged — no jump at all. No quick-pick overlay appears in either case.

**Source pointer**: Ctrl+Tab is not registered as a command in `src/command.rs` (no hit on `"ctrl+tab"`). Either it's bound somewhere else (chord map) or it falls through to the default handler. Either way, the behavior I observe doesn't match VS Code's MRU-pair semantics.

**Notes**: VS Code's "Ctrl+Tab cycles the buffer list" is a daily-use chord. Right now an mnml-on-VS-Code-muscle-memory user types `Ctrl+Tab` to go back to the last file and ends up either nowhere or on a random tab. The split-aware behavior in scenario 1 is particularly confusing because `panes[]` includes duplicate entries for the same file shown in two leaves.
