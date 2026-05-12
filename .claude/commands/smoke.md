---
description: Run the headless smoke test (build → drive mnml via file-IPC → dump screen/status)
allowed-tools: Bash(.claude/scripts/headless-smoke.sh:*), Bash(cargo build:*)
---

Run `.claude/scripts/headless-smoke.sh` and report: did it build, did the
rendered screen look right (tree rail, bufferline tabs, the opened file's text,
the statusline), did `status.json` reflect the open file, and did it quit
cleanly? If anything's off, dig in.
