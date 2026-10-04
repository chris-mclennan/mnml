#!/bin/bash
# tools/gate/check.sh — fails when a gate script still points at a session's scratch
# directory or a machine's home path. Every path in tools/gate/ derives from the
# script's own location, so the scripts run from any checkout.
cd "$(dirname "$0")" || exit 2
hits=$(grep -nE 'claude-501|scratchpad|/Users/' -- *.sh *.py 2>/dev/null | grep -v '^check\.sh:')
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | cut -c1-160
    echo "gate-scripts audit: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') line(s) point at a scratch or home path"
    exit 1
fi
echo "gate-scripts audit: 0 scratch or home paths"
