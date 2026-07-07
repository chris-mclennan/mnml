---
finding: git-dir-shown-and-auto-expanded-in-file-tree
severity: SEV-2
agent: multilang-dev-user
language: ts | py | go
repro: e2e (live headless, reproduced on both TS and Python fixtures)
---

## Summary

`.git/` is not filtered from the file tree at all, and because every
depth-0 directory auto-expands on open (`src/tree.rs:170-174`, and again on
`refresh()`), a **fresh `mnml <workspace>`** on any git repo — TypeScript,
Python, Go, doesn't matter — opens with `.git` pre-expanded, showing
`hooks/`, `info/`, `logs/`, `objects/`, `refs/`, `COMMIT_EDITMSG`, `config`,
`description`, `HEAD`, `index` as the first ~10 rows of the tree, pushing the
user's actual `src/`/`tests/`/config files further down (in a real repo,
below the fold in a typical terminal-height tree pane).

## Repro

Two independent fresh workspaces, `/tmp/ts-test-workspace` and
`/tmp/py-test-workspace`, both freshly `git init`'d with a normal `.gitignore`
(no explicit `.git` ignore rule — nobody writes one, since `.git` isn't
something `.gitignore` is expected to cover). First screen after opening
either workspace headless:

```
    ▼ ● ts-te…             no buffers
▌   .. tmp
     ▼  .git
      ▶  hooks
       ▶  info
 󰘬     ▶  logs
       ▶  objects
      ▶  refs
          COMMIT_EDITMSG
 󰐱        config
          description
 󰎒        HEAD
          index
 󰚩   ▼  src
          App.tsx
 󰅣        index.ts
```

Same shape on the Python fixture. `node_modules`, `dist`, `.next`,
`coverage`, `.venv`, `__pycache__` are all correctly hidden by the hardcoded
artifact-dir list in `tree.rs:207-228` — so the tree-hygiene work that
shipped for those is good — `.git` just isn't on that list, and isn't gated
by anything else either.

## Root cause

`Tree::show_hidden` defaults to `true` (`src/tree.rs:56`), so
`.hidden(!self.show_hidden)` passed to `ignore::WalkBuilder` is `.hidden(false)`
— dotfiles/dotdirs are walked and shown by default, `.git` included. The
depth-0 auto-expand logic (`entry.is_dir && entry.depth == 0` →
`self.expanded.insert(...)`) doesn't distinguish `.git` from `src`/`app`, so
it's not just *visible*, it's *pre-opened* on first paint with zero user
action.

## Why this matters beyond cosmetics

CLAUDE.md frames mnml as "a NvChad-style terminal IDE" — NvChad's own tree
(`nvim-tree`) excludes `.git` by default specifically because it's plumbing,
not project content. Every other mainstream editor (VS Code, IntelliJ, Zed)
either hides `.git` outright or keeps it collapsed-by-default. Here it's the
opposite: expanded by default, ahead of the user's own code. For a first-time
"open an unfamiliar repo and look around" moment — exactly the scenario a
polyglot dev hits constantly moving between throwaway/cloned repos — this
wastes the first ~10 visible rows of every fresh tree on `.git` internals
nobody asked to see.

Not language-specific (any git repo hits it), but it's the first thing a
"non-Rust" dev opening an unfamiliar TS/Python/Go clone would notice, so
flagging it from this angle.

## Suggested fix direction (not applied)

Exclude `.git` from the depth-0 auto-expand (keep it visible/browsable via
`show_hidden` if that's intentional for git-power-users who want raw access,
but don't force it open), or add `.git` to the same hardcoded-hide list as
`node_modules`/`target`/`.venv` given mnml already has a fully separate git
UI (status pane, GitGraph, branch/merge/rebase pickers) that makes manually
poking through `.git/objects` in the file tree a rare, opt-in need rather
than a default view.
