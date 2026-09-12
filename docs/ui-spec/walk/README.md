# The walkthrough harness (2026-09-12)

The steps files and scripts behind `docs/research/rust-vs-zig-walkthrough-2026-09-12.md`.
They are a record of that run, not a maintained tool: every script hardcodes the
`/private/tmp/walk` layout `setup.sh` creates (`pristine/{ws,rs-data,zig-data}`,
`slot1..4`, `home`, `out`). `setup.sh` copies the author's real workspace and
`~/.config/mnml` and mirrors `~/.claude` read-only — adjust its three source paths
first. `run.sh SLOT NAME [COLSxROWS] [vim|standard]` drives one steps file through
both binaries (`FRESH=1` for an empty data root); `batch.sh JOBS` runs a jobs
file over four slots; `run-seeded.sh` is the SESSIONS run on a home seeded by
`tools/seed-sessions-home.sh`. A steps file is the IPC JSONL `tools/ui-diff.sh`
feeds, plus `# label` comments naming the next `{"cmd":"snapshot"}`;
`walk-drive.py` keeps `screen.txt` / `status.json` / `rects.json` at each one and
`walk-report.py` writes the per-snapshot `diff.md`. The `*2` steps files are the
corrected second passes named in the report.
