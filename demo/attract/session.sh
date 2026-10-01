#!/bin/sh
# One visitor's mnml: what ttyd runs for each websocket connection.
#
# `mnml --demo` makes its own throwaway home and workspace and removes
# them when it exits — a quit, or the SIGHUP ttyd sends when the visitor
# closes the tab. kiosk.zon turns on the file channel the attract runner
# drives (input allowed, input reported, screen written). The session
# marker's mtime tells the runner a new visitor arrived.
state=$(dirname "${MNML_IPC_DIR:-/tmp/mnml-demo/ipc}")
mkdir -p "$state"
rm -f "$state/ended"
date +%s > "$state/session"
cd "$HOME" || exit 70
mnml --demo --config /opt/mnml-demo/attract/kiosk.zon
code=$?
if [ -f "$state/ended" ]; then
  # The session cap: the last screen, until the visitor starts again.
  printf '\033[?1049l\033[2J\033[H\033[?25l'
  rows=$(stty size 2>/dev/null | cut -d' ' -f1); rows=${rows:-60}
  i=0; while [ $i -lt $((rows / 2 - 2)) ]; do printf '\n'; i=$((i + 1)); done
  printf '%*s\033[1mThat was ten minutes of mnml.\033[0m\n\n' 84 ''
  printf '%*sPress \033[1mStart again\033[0m above for a fresh session, or install it: https://mnml.sh\n' 62 ''
  exec sleep 3600
fi
exit $code
