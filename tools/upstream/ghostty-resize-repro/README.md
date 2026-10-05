# ghostty resize-redraw repro

A standalone program against libghostty-vt (ghostty's terminal library,
which mnml embeds for its terminal pane). It shows that a resize which
wraps an OSC 133 prompt marked `redraw=1` leaves the screen wrong after the
shell redraws its prompt: narrowed, a stale copy of the prompt's first row
stays above the redrawn prompt, and the cursor ends a row lower than a
terminal that had the new width all along.

No pty and no shell: after each `Terminal.resize` the program writes the
bytes zsh 5.9 writes on SIGWINCH at an idle prompt (recorded from a real
zsh with `shell-capture/capture.py`), then compares the screen row by row
with a fresh terminal of the new width. `src/main.zig`'s header says what
each scenario and mode does.

Upstream: ghostty discussions
[#13629](https://github.com/ghostty-org/ghostty/discussions/13629) (the
regression, from commit dde3d4d6b) and
[#13460](https://github.com/ghostty-org/ghostty/discussions/13460) (the
user-visible report). mnml's workaround is `keepCursorRow` in
`src/pty/common.zig`.

## Running it

```sh
tools/upstream/ghostty-resize-repro/check.sh pinned                # the commit mnml pins
tools/upstream/ghostty-resize-repro/check.sh main --main-sha <sha> # any ghostty commit
tools/upstream/ghostty-resize-repro/check.sh main --main-sha <sha> --expect broken
```

`check.sh` copies the three source files to `.verify/ghostty-resize-repro/`
(git-ignored) and runs `zig build run -Dghostty=pinned|main` there. Running
`zig build run -Dghostty=pinned|main` in this directory works too, but Zig
0.16 then leaves a `zig-pkg/` here, and `zig fmt --check tools` walks into
it — move it out before running the repo's fmt check.

`-Dghostty=main` builds against `ghostty_main` in `build.zig.zon`, a pin
like the other (5dc28bb8, main on 2026-10-04); `--main-sha` moves it with
`zig fetch --save=ghostty_main` in the scratch copy only.

## Reading the result

The last line is the verdict on the `lib` mode — the library with nothing
done by hand:

```
RESIZE-REDRAW: still broken      some resize left the screen wrong
RESIZE-REDRAW: FIXED upstream    every resize matched a fresh render
```

With `--expect broken|fixed` (`-Dexpect=` on `zig build run`) the exit code
is 0 when the verdict is the expected one and 1 when it is not; `check.sh`
exits 3 when the repro did not build or run. The weekly upstream watch
(`.github/workflows/upstream-watch.yml`) runs it against ghostty main with
`--expect broken`.

**Fixed** looks like this in the summary: every `lib` row at `0/N`.

```
  A: one-line prompt, narrow/widen x3
      lib              0/6
  B: two-line prompt (long first line), narrow/widen x3
      lib              0/6
  C: one-line prompt, narrowed step by step
      lib              0/4
```

On that day `keepCursorRow` and its tests in `src/pty/common.zig` can go,
in a branch that bumps the ghostty pin through `tools/gate/`.

## Recorded outputs

`recorded/` holds three runs from 2026-10-04, before the verdict line was
added:

- `out-pinned.txt` — `-Dghostty=pinned` (c81f0b26): `lib` wrong on 3/6, 3/6,
  3/4; `preclear-unwrap` (what mnml does) right on all.
- `out-main.txt` — `-Dghostty=main` (5dc28bb8): the same counts.
- `out-pinned-preclear-without-cursor-clamp.txt` — pinned, with the cursor
  half of the preclear left out: scenarios A and C stay wrong, which is why
  mnml also keeps the cursor on its row.
