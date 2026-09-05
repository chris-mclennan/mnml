---
severity: SEV-2
status: fixed
---
# Launch appends `.mnml/` to the workspace `.gitignore` even when `.mnml/*` + `!.mnml/findings/` already cover it — the negation stops working

**Command id:** none (startup side effect). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
# workspace .gitignore already contains:
#   .mnml/*
#   !.mnml/findings/
mnml-zig --headless --input standard <workspace>
# then, in the workspace:
git diff .gitignore
touch .mnml/findings/probe.md && git check-ignore -v .mnml/findings/probe.md
```

**Observed diff** right after `events.jsonl` `start`:
```
+# Added by mnml — workspace state: IPC, session, and HTTP
+# history / captured traffic / env values (these carry secrets)
+.mnml/
```
`git check-ignore -v .mnml/findings/probe.md` → `.gitignore:11:.mnml/	.mnml/findings/probe.md` (rc 0). With the original file the probe is *not* ignored (rc 1).

**Expected**: no write to a user file the app was not asked to edit; at minimum, detect an existing `.mnml` rule (`.mnml/*`, `.mnml`, `/.mnml/`) and leave the file alone.
**Actual**: three lines are appended on every launch until they exist; because a trailing `.mnml/` excludes the whole directory, git can no longer re-include `.mnml/findings/` — this repo's own findings carve-out (the mnml-zig repo ships exactly this pair of lines) is silently defeated and the tracked file shows as modified.

**Source pointer**: the startup gitignore writer — grep `Added by mnml` (`src/app/*.zig`); the existence check only matches the literal `.mnml/` line.

## Fix

`a1a44dd` on branch `fix-git-tree` — launch: an existing rule about .mnml in .gitignore is the user's decision. `gitignoreCovers` reads the first path segment of every rule (`!`, `/`, `**/` stripped), so `.mnml/*`, `!.mnml/findings/` and `.mnml/ipc/` all keep the file untouched. The writer runs from `Channel.init`, which the `.test` runner never reaches, so the regression is the unit test in `src/ipc/channel.zig` (seven bodies kept byte-for-byte, two that still grow); break-checked.
