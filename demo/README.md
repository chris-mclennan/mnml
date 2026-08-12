# mnml demo mode

Populated workspace + mock API server for screenshots, videos, and
"try before install" onboarding.

- `workspace/` — filesystem contents mnml boots against with `--demo`.
  Sample source, requests, findings, per-workspace integration
  overrides. `workspace-git.tar.gz` beside it carries the fictional
  10-commit / 4-author / 2-branch history extracted into the cache
  copy on first `--demo` launch.
- `fixtures/{jira,bitbucket,github}/` — canned JSON that the mock
  server returns for live-API integration calls.
- `server/` — small local HTTP server (localhost:7071) serving the
  fixtures. Spawned on `mnml --demo` if not already running.

All data uses the fictitious product **Notely** (by Bloom Labs).
Never any real ticket / PR / customer data.

## Regenerating `workspace-git.tar.gz`

The tarball ships as an opaque binary (unreviewable in a PR diff by
content). When it changes, list its contents in the PR body so
review can verify no unexpected additions (e.g. non-`.sample` git
hooks that would execute during demo git operations):

```sh
tar tzf demo/workspace-git.tar.gz | sort
```

To regenerate after editing `demo/workspace/` history in place:

```sh
git -C demo/workspace gc --quiet && git -C demo/workspace repack -Ad --quiet
tar czf demo/workspace-git.tar.gz -C demo/workspace .git
```

## Boot

```sh
mnml --demo
```

Copies `demo/workspace/` into a per-user cache dir
(`<data-root>/demo-workspace/`), extracts `workspace-git.tar.gz`
into it if needed, spawns the mock server if 7071 is free, and
boots against the copy. The source tree is never mutated — safe
to autosave / edit / commit inside a `--demo` session.

Cache is refreshed when any file under `demo/workspace/` is newer
than the cache stamp (recursive max-mtime walk), so iterating on
fixtures still works.

Fixture iteration bypasses the copy: set `MNML_DEMO_WORKSPACE` to
the source path (or any other workspace).
