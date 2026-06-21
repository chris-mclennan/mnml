---
finding: history-picker-index-mismatch
severity: SEV-1
surface: http.history | http.history_global
---

**Repro**:
1. Fire 3 requests against any URL so `.rqst/history.jsonl` has 3 entries (A at t=0, B at t=1, C at t=2).
2. `:http.history` — picker opens; items are shown newest-first (C, B, A).
3. Accept the top item (displayed as C, newest).

**Expected**: the scratch `.curl` buffer contains C's method + URL.

**Actual**: `open_curl_scratch` is called with the entry at `pending_history_rows[i]`, where `i` comes from the picker `id`. The picker `id` is the `enumerate()` index **from the reversed iterator**. With 3 rows, `.rev()` yields `(2, C)`, `(1, B)`, `(0, A)`. The item for C gets `id = "2"`, B gets `id = "1"`, A gets `id = "0"`. `pending_history_rows` is stored in the *original* order (A=0, B=1, C=2). So accepting `id="2"` correctly resolves to `rows[2]` = C. Wait — this works.

Actually the bug direction is: `.iter().enumerate().rev()` produces items where the **displayed** top row has index `n-1`, the bottom row index `0`. So the top (newest) row's id string is "2" (for 3 rows), and `rows[2]` is indeed the newest. This is correct for the workspace history.

**BUT** for `:http.history_global` (`open_http_history_global`), `tail_global(100)` reverses the file lines then reverses again (`out.reverse()`), producing entries in insertion order (oldest-first). Then `.iter().enumerate().rev()` assigns the same id scheme. The same accept handler fires. This is also correct.

**The real SEV-1**: `pending_history_rows` is **shared** between `:http.history` (workspace) and `:http.history_global` (cross-workspace). If a user opens `:http.history_global`, closes it without picking (Esc), then opens `:http.history`, `pending_history_rows` still holds the global history snapshot. The accept handler for `PickerKind::HistoryRows` is the same enum variant for both pickers, so the **indexes resolve against the wrong snapshot**. The row count could differ (global caps at 100 while workspace might have 40), causing `rows.get(idx)` to silently return `None` for high-index picks, or return a different workspace's entry for low-index picks with no error feedback.

**Offending file:line**: `src/app/mod.rs:2732` (`pending_history_rows` is a single Vec shared by both picker kinds). `src/app/http.rs:1627` and `:1686` both assign to it. `src/app/picker.rs:640` accepts using whichever snapshot is current.

**Notes**: The fix is either two separate pending fields (`pending_history_workspace_rows` / `pending_history_global_rows`) or storing which flavor is active alongside the rows. The `CapturedRows` picker has its own `pending_captured_rows` field and is safe — it's only set from one place.
