#!/usr/bin/env bash
# Example mnml plugin — "Insert timestamp".
#
# Out-of-process: it talks to a running mnml over the file-IPC channel at
# <workspace>/.mnml/ipc/ (see docs/PLUGINS.md). On start it registers a command
# (so it appears in the palette / which-key as `plugin.timestamp`, bound to
# `<leader>i t` and ctrl+alt+t), then tails events.jsonl; when its command is
# invoked it asks mnml to `type` an ISO-8601 timestamp at the cursor.
#
# Usage:  ./insert-timestamp.sh [WORKSPACE_DIR]   (default: $PWD)
set -euo pipefail

ws="${1:-$PWD}"
ipc="$ws/.mnml/ipc"
cmd_file="$ipc/command"
events_file="$ipc/events.jsonl"

if [[ ! -d "$ipc" ]]; then
  echo "no $ipc — is mnml running on $ws? (./run.sh $ws)" >&2
  exit 1
fi

send() { printf '%s\n' "$1" >> "$cmd_file"; }

# Register our command. `keys` is optional; an unparseable spec is just ignored.
send '{"cmd":"register-command","id":"plugin.timestamp","title":"Insert timestamp","group":"plugin","keys":["ctrl+alt+t"]}'
echo "registered plugin.timestamp — invoke it from the palette (or ctrl+alt+t)"

# React to invocations. `tail -F` survives mnml restarting (it truncates events.jsonl).
tail -n0 -F "$events_file" 2>/dev/null | while IFS= read -r line; do
  case "$line" in
    *'"event":"plugin-command"'*'"id":"plugin.timestamp"'*)
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      send "{\"cmd\":\"type\",\"text\":\"$ts\"}"
      ;;
  esac
done
