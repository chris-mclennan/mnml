# mnml demo mode

Populated workspace + mock API server for screenshots, videos, and
"try before install" onboarding.

- `workspace/` — filesystem contents mnml boots against with `--demo`.
  Real git repo, sample findings, `.mnml/session.json` with a
  dressed layout.
- `fixtures/{jira,bitbucket,github}/` — canned JSON that the mock
  server returns for live-API integration calls.
- `server/` — small local HTTP server (localhost:7071) serving the
  fixtures. Spawned on `mnml --demo` if not already running.

All data uses the fictitious product **Loop** (by Bloom Labs).
Never any real ticket / PR / customer data.

## Boot

```sh
mnml --demo
```

Copies `demo/workspace/` to a scratch path on first launch, spawns
the mock server if needed, boots against the copy.
