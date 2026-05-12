---
description: Rebuild mnml and bounce the running instance (./run.sh restart)
allowed-tools: Bash(cargo build:*), Bash(./run.sh:*)
---

Run `cargo build`. If it **succeeds**, run `./run.sh restart` so the user's
running mnml picks up the new code, then report (build OK + restarted, or the
build error). If the build fails, do **not** run `./run.sh restart` — just report
the error.
