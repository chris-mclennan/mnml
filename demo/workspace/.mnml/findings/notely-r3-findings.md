# Notely R3 findings — 2026-08-05

3 SEV-2 · 4 SEV-3.

## SEV-2

- `POST /notes` silently 500s when body is >64KB. Nginx buffer
  limit — needs `client_max_body_size 1m` at least.
  Reproduces via `curl -X POST -d "$(head -c 70000 /dev/urandom | base64)"`.
- Search returns hits from soft-deleted notes. `Store.list()`
  walks the fs before the deletion tombstone is checked.
- Sync retry loop backs off exponentially without a ceiling; after
  a long offline session the retry interval crosses 10 min and
  users think sync is broken.

## SEV-3

- Note titles with trailing whitespace render as `"kickoff "` in the
  sidebar (list widget doesn't trim).
- `?q=` with empty string returns everything instead of nothing.
- Store benchmark suite has been flaky since bun 1.2 (bun issue #17421).
- Landing tagline `"fast, keyboard-first team notes"` doesn't
  mention offline — 3 of the 4 R3 testers asked "does this work
  offline?" in feedback.
