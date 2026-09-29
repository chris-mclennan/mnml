---
severity: SEV-3
status: fixed
---
# Pasting a GitHub repo URL into "add a private source" is read as a workspace-relative folder and refused with a mangled path

**Command id / surface:** `marketplace.add_source` prompt (placeholder `a folder (~/my-integrations) or owner/repo[:apps]`).

**Reproduction** (fresh launch):
```
{"cmd":"run-command","id":"marketplace.add_source"}
{"cmd":"type","text":"https://github.com/someone/tools"}
{"cmd":"key","key":"enter"}
```
and the same with `github.com/someone/tools`.

**Expected:** the repo URL — what a browser's address bar hands you — is taken as `someone/tools`, or refused with a hint to type `owner/repo`.

**Actual:** the toast is
`marketplace: /Users/…/ws-66/https:/github.com/someone/tools is not a folder` (the `//` collapsed by path resolution) and
`marketplace: /Users/…/ws-66/github.com/someone/tools is not a folder` — a path the user never typed, with no pointer to the `owner/repo` form.

**Why:** `parseSourceInput` (`src/app/marketplace.zig:900`) only tries `repoShape` on a bare `owner/repo`; anything else falls through to `path.resolve(workspace, input)`.

**Reproduced:** 2/2 fresh launches.
