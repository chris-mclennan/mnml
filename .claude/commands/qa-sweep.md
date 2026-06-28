---
description: Fire every relevant user-sim + design-critic agent in parallel against the current build, then run a serial drive-mnml visual pass on the real ghostty window, and aggregate findings into one report
allowed-tools: Bash(cargo build:*), Bash(date:*), Bash(ls:*), Bash(find:*), Bash(wc:*), Bash(mkdir:*), Bash(cat:*), Bash(uname:*), Bash(pgrep:*), Bash(./run.sh restart:*), Bash(./run.sh shot:*), Bash(scripts/shot.sh:*), Bash(scripts/click.sh:*), Bash(osascript:*), Read, Write, Glob, Agent
---

# /qa-sweep

Fire every relevant user-sim + design-critic agent against the current
mnml build in parallel, then run **one serial visual pass** over the real
ghostty window with `drive-mnml`, and aggregate everything into one
summary report. The goal is **comprehensive coverage on demand** — when
you've shipped a feature and want to know what real users would hit before
they hit it. The parallel headless agents cover behavior on the cell grid;
the serial visual pass covers what the grid can't encode — actual glyph /
icon / color / cursor rendering — which is where a different class of bugs
hides.

## Arguments

Optional. The default is "all". To narrow:
- `/qa-sweep dashboard` — just the agents that exercise the dashboard
- `/qa-sweep http` — just HTTP-track agents
- `/qa-sweep design <surface>` — just design-critic, scoped to that surface

## Steps

1. **Build first.** Run `cargo build` so every agent tests the latest
   code. If the build fails, stop and surface the error — there's no
   point firing agents against a broken binary.

2. **Set up the findings + design-reviews dirs** for today's date:
   ```
   findings/$(date +%Y-%m-%d)/
   design-reviews/$(date +%Y-%m-%d)/
   ```

3. **Dispatch agents in parallel.** Send one Agent tool block with
   multiple subagent invocations. Default fleet (the "all" run):

   - `claude-agents-power-user` — drives the Claude Agents dashboard
   - `multilang-dev-user` — non-Rust workspaces (npm/pytest/go)
   - `api-workflow-user` — HTTP / .curl / Request pane
   - `nvchad-user` — vim mode editing
   - `vscode-user` — standard-mode + palette + mouse mix
   - `vscode-user-keyboard` — modeless, no mouse
   - `vscode-user-mouse` — lives on the mouse
   - `design-critic` — UX consistency audit of the
     most-recently-shipped pane/feature (read recent git log to pick
     the target if the user didn't specify)

   Each agent prompt tells it WHAT to audit + WHERE to stage findings:

   ```
   Audit <surface or workflow>. Stage findings under
   findings/<DATE>/<agent-slug>-<finding-slug>.md or
   design-reviews/<DATE>/<surface>.md per your agent doc.
   Do NOT fix anything. Report back with: number of findings staged,
   their severities, and a one-line headline for each.
   ```

4. **Wait for completion.** Notifications arrive as each agent comes
   to rest. Do not poll their output files.

5. **Serial visual pass (`drive-mnml`) — the render-level layer the
   headless agents can't see.** macOS + ghostty only; needs mnml running
   via `./run.sh` (Screen Recording + Accessibility granted). If you're
   not on macOS/ghostty, or no `mnml — …` window is up, **SKIP** it and
   say so in Coverage notes — never fail the sweep over it.

   Run this **serially, in the main session — NEVER as parallel agents.**
   There is ONE real ghostty window and ONE global mouse/keyboard focus;
   a fan-out would have agents fighting over both (the same shared-window
   collision a shared working tree causes). One surface at a time.

   Walk the canonical UI surfaces, capturing each with `./run.sh shot`
   then `Read`-ing the PNG. Navigate **deterministically** — write to the
   running instance's IPC `command` mailbox (or send keys via the
   `drive-mnml` skill); don't pixel-hunt to get somewhere. Suggested
   tour: editor on a syntax-highlighted file · file tree (Nerd Font icons
   + git-status colors) · command palette · which-key · statusline (mode
   chip, git, chips) · each reachable pane (Pty / Request / Diff / …) ·
   settings overlay · any menus / dropdowns. For mouse-target checks use
   `scripts/click.sh` and re-shot.

   Look for what the cell grid **cannot** encode (so the headless agents
   structurally miss it): tofu / wrong Nerd Font glyphs, real theme
   colors, per-mode cursor shape, cell alignment / overflow / truncation,
   border off-by-ones, CJK / emoji double-width, icon correctness. Stage
   each as `findings/<DATE>/visual-<slug>.md` with the usual `severity:`
   + `agent: drive-mnml` frontmatter so it rolls into the summary. See the
   `drive-mnml` skill for the shot / pixel→point / keystroke mechanics.

6. **Aggregate.** Once all agents report back, glob the findings
   dirs:
   ```
   findings/<DATE>/**/*.md
   design-reviews/<DATE>/**/*.md
   ```

   For each, parse the frontmatter for `severity` and `agent`, then
   write a summary at:
   ```
   findings/<DATE>/SUMMARY.md
   ```
   with this shape:

   ```
   # QA sweep summary — <DATE>

   ## Counts
   - SEV-1: N        (critical, lost user work or broken core flow)
   - SEV-2: N        (real friction, broken feature path)
   - SEV-3: N        (cosmetic, label, polish)
   - Design issues: high N · medium N · low N

   ## SEV-1
   - [<slug>](<relative-path>): <one-line headline> — agent: <name>
   - ...

   ## SEV-2
   - ...

   ## SEV-3
   - ...

   ## Design findings
   - [<surface>](<path>): <high/medium/low count> — agent: design-critic
   - ...

   ## Coverage notes
   - <which agents ran>
   - <which agents skipped + why, if any>
   - visual pass (drive-mnml): ran (<N> surfaces shot) / skipped (<reason>)
   ```

   The visual-pass findings land in the same dir, so the glob picks them
   up and they bucket into SEV-1/2/3 by their own `severity:` like any
   other finding.

7. **Report to the user** in chat:
   - Top-line counts (N findings across X agents)
   - Top 3 highest-severity items by headline
   - The path to the SUMMARY.md
   - Any agents that errored or died — surface honestly, don't hide

## When to narrow

The full fleet takes real wall-clock time. If you ran `/qa-sweep` and
fixed the SEV-1s, a follow-up `/qa-sweep dashboard` is cheaper than
firing the full fleet again. Trust the user's narrow when given.

## What NOT to do

- Don't write or fix code. The agents stage findings; the user
  decides what to act on.
- Don't dispatch more than one design-critic per sweep — it does
  ONE surface deeply, not all of them. If the user wants multiple
  surfaces audited, ask which one is highest priority.
- Don't run the visual pass as parallel agents. It's ONE serial pass
  over the single real ghostty window in the main session — fanning it
  out makes agents fight over the window + global mouse/keyboard focus.
- Don't push to git or open PRs — this is a read-only sweep.
- Don't run against a dirty working tree without saying so. If
  `git status` shows uncommitted changes, mention it in the
  summary — those changes ARE what the agents are testing.
