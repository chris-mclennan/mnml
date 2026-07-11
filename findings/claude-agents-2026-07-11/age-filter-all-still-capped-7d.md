---
finding: age-filter-all-still-capped-7d
severity: SEV-2
agent: claude-agents-power-user
repro: jsonl-fixture
---

## What happened
The `A` chord cycles `AgeFilter` (`Today → 7d → 30d → All → Today`,
default `7d`/`Week`), and `AgeFilter::All.max_age_secs()` returns `None`
— documented as "no limit". But `collect_rows()` (the function that
builds the row set the age filter is later applied to) hard-drops any
transcript whose file **mtime** is more than 7 days old *before* the age
filter ever runs. So selecting `All` never actually restores sessions
older than 7 days — the option is a no-op past that ceiling, silently
contradicting its own label.

## Steps to reproduce
1. Seed 3 fixture transcripts under a fake `~/.claude/projects/<ws>/`:
   one fresh, one with mtime `-100h` (~4.2d), one with mtime `-200h`
   (~8.3d).
2. `HOME=<fakehome> mnml <ws> --headless`, open `:ai.dashboard`.
3. Default view (`7d`) shows 2 sessions (fresh + 100h); title chip
   omitted since 7d is default.
4. Press `A` three times to land on `All` (`Week→Month→All`). Title bar
   reads `Claude Agents · All`. Row count is **still 2** — the 200h
   session never appears.

## Expected
`AgeFilter::All` shows every session on disk regardless of age (that's
what "no limit" implies to the user, and it's the only escape hatch the
UI offers from the default 7-day window).

## Observed
`AgeFilter::All` is capped identically to the default — anything older
than 7 days is invisible via the dashboard no matter what age filter is
selected. The 7-day mtime cutoff is enforced upstream of the filter and
never revisited by it.

## Suspected cause
`src/claude_agents.rs:1188-1193` (the `age.as_secs() > 7 * 24 * 3600`
`continue` inside `collect_rows()`) runs unconditionally, independent of
`self.age_filter` in `src/claude_agents.rs:879-889` (`visible_indices()`).
The comment at 1185-1187 says "Last 7 days only... user can scroll older
transcripts via :ai.session_picker" — but the `A` chord's own help text
and `All` label promise otherwise from the same pane.
