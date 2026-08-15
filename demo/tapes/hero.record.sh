#!/usr/bin/env bash
# hero demo recorder — orchestrates the whole pipeline:
#
#   ┌──────────────────────────────────────────────────────────┐
#   │  Python pty.fork()                                       │
#   │    ├─ child : exec asciinema rec -c hero.runner.sh cast  │
#   │    │            └─ execs mnml --demo (in a real PTY)     │
#   │    │            └─ background driver feeds IPC commands  │
#   │    └─ parent: drains child pty (discards output)         │
#   │                sets winsize so mnml renders at hero dims │
#   └──────────────────────────────────────────────────────────┘
#
# Then agg converts the .cast to a GIF and we mirror it to
# site/public/media/hero.gif + assets/demo.gif.
#
# Why this exists rather than VHS:
#   VHS 0.11.0 on macOS 26.5.1 renders one keystroke and stops
#   (chromium-in-ttyd frame capture regression). asciinema + agg
#   is the standard TUI-recording stack and works reliably.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TAPE_DIR="$REPO/demo/tapes"
DRIVER="$TAPE_DIR/hero.driver.sh"

# Recording dimensions. Wider than a normal terminal to show all
# activity-bar tooltips + right-panel + statusline chips at once.
# 2026-08-15 — was 180x46, GIF landed at ~2548x921 (2.76:1) which
# reads as awkwardly wide on both the mnml.sh hero + README. 140x36
# lands ~1960x820 ≈ 2.4:1 (still wide but not letterbox-flat) and
# keeps enough room for the split-pane climax to be legible.
COLS="${MNML_DEMO_COLS:-140}"
ROWS="${MNML_DEMO_ROWS:-36}"

# Font size for agg. 14px keeps a 1600x900 GIF sane in file size
# while staying legible for a hero splash.
FONT_SIZE="${MNML_DEMO_FONT_SIZE:-14}"

CAST="$TAPE_DIR/hero.cast"
GIF_OUT="${1:-$REPO/site/public/media/hero.gif}"
GIF_MIRROR="$REPO/assets/demo.gif"

# ── Preflight ─────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || { echo "[demo-record] missing: $1"; exit 1; }; }
need asciinema
need agg
need python3

if [ ! -x "$REPO/target/release/mnml" ]; then
  echo "[demo-record] building release binary…"
  (cd "$REPO" && cargo build --release --quiet)
fi

# Kill any stale demo-mnml (from a prior run) so we own the IPC dir
pkill -f "target/release/mnml --demo" 2>/dev/null || true
# Reset the IPC state so the driver's wait-for-boot is deterministic.
rm -f "$REPO/demo/workspace/.mnml/ipc/command" \
      "$REPO/demo/workspace/.mnml/ipc/events.jsonl" \
      "$REPO/demo/workspace/.mnml/ipc/screen.txt" \
      "$REPO/demo/workspace/.mnml/ipc/status.json"
mkdir -p "$REPO/demo/workspace/.mnml/ipc"
: > "$REPO/demo/workspace/.mnml/ipc/command"

# Wipe the persisted session so mnml boots to its welcome view
# instead of restoring whatever tabs were open on the last dev
# launch. The driver's `open` command re-opens what we need.
rm -f "$REPO/demo/workspace/.mnml/session.json"

mkdir -p "$(dirname "$GIF_OUT")" "$(dirname "$GIF_MIRROR")"

# ── The inner shell command asciinema runs ───────────────────
# We use a heredoc so no third script file needs to exist. The
# driver runs in the background; mnml runs in the foreground so
# asciinema follows its stdout.
INNER_SCRIPT="$(mktemp -t mnml-hero-inner.XXXXXX.sh)"
trap 'rm -f "$INNER_SCRIPT"' EXIT
cat > "$INNER_SCRIPT" <<INNER
#!/usr/bin/env bash
set -euo pipefail
export MNML_DEMO_WORKSPACE="$REPO/demo/workspace"
# Start the driver in the background — it polls for mnml's IPC
# dir, then feeds JSONL commands with pacing.
"$DRIVER" &
DRIVER_PID=\$!
trap "kill \$DRIVER_PID 2>/dev/null || true" EXIT
# Exec mnml in the foreground so asciinema captures its output.
# The driver's final command is {"cmd":"quit"} — mnml exits, this
# process exits, asciinema finalizes the cast.
exec "$REPO/target/release/mnml" --demo
INNER
chmod +x "$INNER_SCRIPT"

# ── Record ────────────────────────────────────────────────────
rm -f "$CAST"
echo "[demo-record] recording ${COLS}x${ROWS} → $CAST"
python3 - <<PY
import os, sys, pty, struct, fcntl, termios, select

argv = ["asciinema", "rec",
        "-c", "$INNER_SCRIPT",
        "$CAST",
        "--overwrite",
        "--quiet"]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)

# Parent — set the pty winsize so mnml paints at demo dims,
# then drain the child stdout (discard; asciinema writes the
# cast file itself).
size = struct.pack("HHHH", int($ROWS), int($COLS), 0, 0)
fcntl.ioctl(fd, termios.TIOCSWINSZ, size)

while True:
    try:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            data = os.read(fd, 4096)
            if not data:
                break
    except OSError:
        break

_, status = os.waitpid(pid, 0)
sys.exit(0 if os.WIFEXITED(status) else 1)
PY

if [ ! -s "$CAST" ]; then
  echo "[demo-record] cast is empty — mnml never rendered"
  exit 1
fi

echo "[demo-record] cast size (raw): $(du -h "$CAST" | cut -f1)"

# ── Trim head + tail ─────────────────────────────────────────
# Two edits, both improve the final GIF:
#   * Head: drop the ~2s black-cursor dwell before mnml's first
#     paint. asciinema time-stamps the alt-screen setup at
#     ~0.3s but mnml's first real paint doesn't land for another
#     ~2s (release-build boot + backend init). Without trimming,
#     the GIF opens on a blank canvas.
#   * Tail: mnml's clean-shutdown sequence sends `\x1b[?1049l`
#     (leave alt screen) which wipes the terminal to blank in
#     the recording. Because the final frame drives the static
#     preview AND what viewers see between loop iterations, we
#     strip from the leave-alt-screen event onward and append a
#     long dwell on the last mnml-rendered frame.
python3 - <<PY
import json, sys
CAST = "$CAST"
with open(CAST) as f:
    header = f.readline()
    events = [line.rstrip("\n") for line in f if line.strip()]

def payload_of(line):
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        return ""
    return ev[2] if len(ev) >= 3 and isinstance(ev[2], str) else ""

# HEAD — find the first event that actually paints characters
# (not just a mode-set escape) and squash the delay-to-first-
# paint down to a small dwell so the GIF opens on real content.
FIRST_PAINT_MIN_LEN = 200  # characters — real mnml frames are large
head_cut = 0
for i, line in enumerate(events):
    p = payload_of(line)
    if len(p) >= FIRST_PAINT_MIN_LEN:
        head_cut = i
        break
if head_cut > 0:
    # Compress the delay on the first paint to 0.5s (short but
    # long enough that viewers register the transition).
    ev = json.loads(events[head_cut])
    ev[0] = 0.5
    events[head_cut] = json.dumps(ev)
    events = events[head_cut:]

# TAIL — cut at leave-alt-screen.
tail_cut = None
for i, line in enumerate(events):
    if "\x1b[?1049l" in payload_of(line):
        tail_cut = i
        break
if tail_cut is not None:
    events = events[:tail_cut]

# Long dwell on the last mnml frame.
events.append(json.dumps([2.5, "o", ""]))

with open(CAST, "w") as f:
    f.write(header)
    for e in events:
        f.write(e + "\n")
print(f"[demo-record] trimmed cast: {len(events)} events")
PY

echo "[demo-record] cast size (trimmed): $(du -h "$CAST" | cut -f1)"

# ── Convert cast → GIF via agg ────────────────────────────────
# --idle-time-limit clamps long pauses (the driver's sleep_ms
# waits) so the GIF loops in a reasonable time.
# --font-family prefers Nerd-Font-embedded monospace so the
# activity-bar icons + statusline glyphs render (falls back on
# platform monospaces if Nerd Font isn't installed).
echo "[demo-record] rendering GIF → $GIF_OUT"
agg --cols "$COLS" --rows "$ROWS" \
    --font-size "$FONT_SIZE" \
    --font-family "JetBrainsMono Nerd Font Mono,JetBrains Mono" \
    --theme monokai \
    --idle-time-limit 2 \
    --fps-cap 20 \
    "$CAST" "$GIF_OUT"

# Mirror to the GitHub README asset location.
cp "$GIF_OUT" "$GIF_MIRROR"

echo "[demo-record] done"
echo "  hero.cast          $CAST ($(du -h "$CAST" | cut -f1))"
echo "  site/public/media/ $GIF_OUT ($(du -h "$GIF_OUT" | cut -f1))"
echo "  assets/demo.gif    $GIF_MIRROR ($(du -h "$GIF_MIRROR" | cut -f1))"
