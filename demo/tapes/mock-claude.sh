#!/usr/bin/env bash
# Mock Claude Code — a plausible-looking session for demo recordings.
#
# Used by the `sessions` demo (see demo/tapes/sessions.driver.sh),
# which writes a launcher override at
# `demo/workspace/.mnml/integrations/claude_code.toml` pointing at
# this script. Every "+ New session" click during the tape spawns a
# pty running THIS instead of the real `claude` — the sessions rail
# only cares about the pane's label + `integration_id`, both of
# which the mock inherits from `BinaryProfile::claude_code(...)`.
#
# Kept out-of-repo path-hardcoding by resolving `pwd` at runtime so
# each spawned session can print its own workspace name.
clear
printf '\n  \033[38;5;208m◆\033[0m claude code v1.14.2  \033[38;5;244m·\033[0m sonnet-4.5\n'
printf '  \033[38;5;244mworkspace:\033[0m %s\n' "$(basename "$(pwd)")"
printf '  \033[38;5;244msession:\033[0m  %s\n\n' "${MNML_MOCK_SLOT:-fresh}"
printf '  \033[38;5;244mTry: "explain this codebase"   ·  /help for commands\033[0m\n\n'
printf '  \033[38;5;208m>\033[0m '
# Hold open — the pty pane stays alive until mnml quits (which
# reaps the child) or the driver's `send {"cmd":"quit"}` tears
# the whole asciinema pipeline down.
exec tail -f /dev/null
