# mnml-aws-* sibling apps — bug hunt (2026-06-07)

**Scope:** 7 standalone Rust TUI siblings — codebuild, cloudwatch-logs, amplify, lambda, eventbridge, sqs. The 8th planned sibling (`mnml-aws-dynamodb`) does NOT exist — only `mnml-db-dynamodb` under a different family. Left out per scope.

**Method:** read `src/main.rs` + `src/keys.rs` + `src/app.rs` + service module for each. Ran `cargo clippy --all-targets` + `cargo test` per app. Drove `--check` against fresh install (no config) and against bad-creds env.

All 6 apps build clean. All 118 tests pass across the 6 apps. Only cloudwatch-logs has clippy warnings (CWL-1).

**Total findings: 21**

| Severity | Count |
|----------|------:|
| SEV-1    | 0     |
| SEV-2    | 4 distinct (XCUT-1, XCUT-3, EB-1 + XCUT-3 replicated as LAM-1/LAM-2/AMP-1/EB-2) |
| SEV-3    | 17    |

### Worst 3 across all 7

1. **EB-1** — EventBridge per-cursor synchronous `aws` shell-out. The only finding that makes a feature **unusable** in normal navigation. Up to ~2s freeze per `j`/`k` press. Highest impact, clearly fixable (thread + channel, already the pattern in codebuild/amplify).
2. **XCUT-3** — cross-sibling handoff inherits TUI stdio. The headline "Lambda's `l` opens logs in CloudWatch Logs sibling" silently fails. Affects lambda (2 chords), amplify (1), eventbridge (1). Status line lies.
3. **XCUT-1** — `--check` first-run UX. New user trying `mnml-aws-X --check` sees a 30-line Rust backtrace instead of "wrote template to ~/...". Trivial fix (reorder check-vs-load in `main.rs`), ugly first impression.

---

## Cross-cutting

### XCUT-1  SEV-2  `--check` fails with a 30-line backtrace on first run
All 6 `main.rs` files call `let cfg = config::load()?;` **before** the `if cli.check` branch. On first run there's no config; `load()` writes the template and returns `Err(anyhow!(...))`. With `RUST_BACKTRACE=1` (cargo default), a 30+ line backtrace dumps to stderr alongside the actual message. Process exits 1.
- Repro: `rm ~/.config/mnml-aws-X.toml && cargo run -- --check` (any sibling)
- Expected: friendly "wrote template, please edit" one-liner, exit 0
- Actual: looks like a panic
- Source: `src/main.rs` line ~30-50 in every sibling
- Affects: codebuild, cloudwatch-logs, amplify, lambda, eventbridge (sqs only escapes because its config already exists on disk)

### XCUT-2  SEV-3  `--check` claims to print "auth state" but doesn't probe auth
Doc-comments say `Print the resolved config + auth state and exit.` The actual output is a single hard-coded line `(auth: defers to the aws CLI's own credential chain)`. With `AWS_ACCESS_KEY_ID=AKINVALID` the line still prints unchanged. No actual `aws sts get-caller-identity` probe.

### XCUT-3  SEV-2  Cross-sibling handoffs inherit parent's stdio → broken in TUI
Lambda's `l` (tail_logs), Lambda's `L` (handoff_dlq), Amplify's `L` (handoff_logs), and EventBridge's `L` (handoff_target) all do `std::process::Command::new("mnml-aws-X").spawn()` with no stdio redirect. The parent TUI owns the alternate screen + raw mode; the child spawns into the same TTY and either fails immediately or scrambles both UIs. Status line lies ("launched mnml-aws-sqs — navigate to my-queue").
- Source: `mnml-aws-lambda/src/app.rs:264, 311`, `mnml-aws-amplify/src/app.rs:384`, `mnml-aws-eventbridge/src/app.rs:334`
- Fix: OS-level "open in new terminal window" or detach-and-tell-mnml-to-host-it
- Affects: lambda, amplify, eventbridge. codebuild's `L` opens an in-process Logs tab — correct pattern.

---

## mnml-aws-codebuild  (clean: 18 tests, no clippy warnings)

### CB-1  SEV-3  Logs tab that errored never re-spawns on `r`
`refresh_active` (`src/app.rs:209-235`) only spawns when `l.pane.is_none()`. When `LogTailEvent::Failed(e)` arrives, `drain` sets `last_error` but leaves `pane = Some(...)`. Pressing `r` is a no-op forever.

### CB-2  SEV-3  Logs tab `switch_tab` stomps useful status with a lie
`refresh_active` writes `self.status = "starting {name}…"` unconditionally before the `needs_spawn` gate. For an already-running Logs tab, that briefly displays a wrong status. Source: `src/app.rs:207-215`

### CB-3  SEV-3  Manual scroll position drifts when capacity hits
`App::drain` calls `p.lines.drain(0..drop)` to cap at 5000 lines but doesn't adjust `p.scroll`. A user scrolled to a fixed line watching new logs stream past 5000 silently watches their viewport slide off. Source: `src/app.rs:289-294`

### CB-4  SEV-3  Stream-name byte-slice can panic on Unicode
`src/log_tail.rs:194` — `&s[..s.len().min(8)]` is a byte slice on stream name. Lambda streams are ASCII so safe in practice; a Unicode stream name would panic at "byte index is not a char boundary". Fix: `.chars().take(8).collect()`.

---

## mnml-aws-cloudwatch-logs  (18 tests pass; **3 clippy warnings**)

### CWL-1  SEV-3  Clippy warnings on `LogTailPane`
```
warning: fields `title`, `exited`, and `capacity` are never read
warning: field `0` is never read   (LogTailEvent::Exited(i32))
```
Per project policy ("clippy warning-free"), pre-commit would fail with `-D warnings`. Source: `src/log_tail.rs:78,89,93,105`

### CWL-2  SEV-3  Stream-name byte-slice panic on Unicode (mirror of CB-4)
`src/log_tail.rs:210` — same `&s[..s.len().min(8)]` pattern.

### CWL-3  SEV-3  Manual scroll drifts on buffer-cap drop (mirror of CB-3)
`src/app.rs:173-176` does the same hardcoded `> 5000` drain without scroll adjustment.

### CWL-4  SEV-3  Status hint omits `g`/`G`/`PgUp`/`PgDn`
`src/ui.rs:146` — hint is `" 1-9 tab · ↑↓/jk scroll · o console · y line · q quit "` — but `keys.rs` binds Home/End/`g`/`G`/PageUp/PageDown.

---

## mnml-aws-amplify  (clean: 12 tests, no clippy warnings)

### AMP-1  SEV-2  Cross-sibling handoff stdio bug
See XCUT-3. `src/app.rs:384`.

### AMP-2  SEV-3  No pagination — silent truncation at 100 apps / 100 branches / 50 jobs
`src/amplify.rs:101,124,162` hardcode `--max-results`. Response structs don't even have a `NextToken` field so no loop. Accounts >100 apps see silent truncation.

### AMP-3  SEV-3  Amplify build-log group name unverified
`src/app.rs:376` constructs `/aws/amplify/{app_id}/{branch_name}`. Amplify Hosting's actual access-log convention is `/aws/amplifyhosting/<app_id>/<branch>`, and build logs aren't in CloudWatch by default. So `L` likely lands on a nonexistent log group → `aws logs tail` returns `ResourceNotFoundException`.

### AMP-4  SEV-3  `AmplifyBranch.url` always `None`
`src/amplify.rs:131` — `let default_domain = None::<String>;` is hardcoded. The branch URL constructed on line 137 is never populated. Field docstring lies.

---

## mnml-aws-lambda  (clean: 24 tests, no clippy warnings)

### LAM-1  SEV-2  `l` chord (TailLogs) stdio bug
See XCUT-3. `src/app.rs:264`.

### LAM-2  SEV-2  `L` chord (HandoffDlq) stdio bug
See XCUT-3. `src/app.rs:311`.

### LAM-3  SEV-3  Partial `watched`-tab failures silently dropped
`src/app.rs:138-152` — errors collected into `errs` but only surfaced when **every** function failed. 4 good + 1 bad → user sees "watched: 4 functions", no indication anything was lost.

### LAM-4  SEV-3  Console URL doesn't URL-encode function name
`src/app.rs:215`. Lambda names are `[a-zA-Z0-9-_]{1,64}` so safe today. If alias/version syntax flows through (`function:my-fn:PROD`), the `:` breaks the URL.

---

## mnml-aws-eventbridge  (clean: 24 tests, no clippy warnings)

### EB-1  SEV-2  Every j/k cursor move triggers a SYNCHRONOUS `aws events list-targets-by-rule`
`src/app.rs:122-135` — `move_selection` always calls `ensure_focused_targets_loaded`, which at line 161 makes a **synchronous** shell-out. AWS CLI cold-start is 500ms-2s. Holding `j`/`k` to scroll 20 rules = up to 40 seconds of UI freeze. The codebuild/amplify pattern (worker thread + mpsc + drain) is the right fix.

### EB-2  SEV-2  `L` chord (handoff_target) stdio bug
See XCUT-3. `src/app.rs:334`.

### EB-3  SEV-3  `App::new` makes 2 synchronous shell-outs before TUI shows
`refresh_active()` + `ensure_focused_targets_loaded()`. 2-4 seconds of "nothing happens" on launch with cold creds.

### EB-4  SEV-3  Rule/bus name not URL-encoded in console URL
`src/app.rs:251-260`. Constraint isn't enforced anywhere in the code.

---

## mnml-aws-sqs  (freshest — commit c7328c6; clean: 22 tests, no clippy warnings)

### SQS-1  SEV-3  Status hint omits `L` (the new chord shipped in c7328c6)
`src/ui.rs:320-321` — hint is `" 1-9 tab · ↑↓/jk move · o console · y URL · Y ARN · A all+DLQ · r refresh · q quit "`. The `L` chord (JumpToDlq), the headline feature of c7328c6, is missing.

### SQS-2  SEV-3  `tick` auto-refresh blows away the focused-attribute cache
`App::tick` calls `refresh_active` every 60s. `refresh_active` rebuilds `t.data.queues` from list_queues, wiping `attributes: Some(...)` and `redrive_sources: vec![...]` on every queue. So 60s after the user pressed `A`, the rebuild silently nukes everything. Pressing `L` after that toasts "attributes not loaded — press A first". Source: `src/app.rs:147-168`.

### SQS-3  SEV-3  `open_console` builds dead local `name` then discards it
`src/app.rs:231,236` — computes `let name = q.name();` then `let _ = name;`. Noise.
