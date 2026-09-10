# Scroll tuning — the wheel, per detent, on ghostty

How a wheel event becomes lines, in Rust mnml and now in mnml-zig, and
the numbers that say the two agree. The Rust side was dialled in over
#1236 (2026-08-29 → 09-02: `6e0bf9fb` … `965eae16`) against a Logitech
MX Master 3 in ghostty; the Zig side is a port of the arithmetic, not a
re-tuning. `src/app/scroll.zig` holds it; `tools/compare.sh
compare-mouse` measures it.

## What the terminal sends

ghostty ships `mouse-scroll-multiplier = precision:1,discrete:3`, so a
notched wheel's every detent arrives as **three** scroll events (a
trackpad's precision deltas arrive 1:1). macOS smooth scrolling adds
its own: a flick posts thirty-odd events. Nothing in mnml asked for
that; the count is a property of the (mouse × terminal) pair, and the
tuning below is written so that the count stops mattering where it
should (the tree) and is honoured where it should be (a text body).

## The pipeline (both editors)

1. **Coalesce.** Events queued together fold into one batch with a
   count (cap 40). Rust drains crossterm's queue at each read; Zig
   folds everything posted before the next tick (`Coalescer`). A bare
   motion report does not end a batch; any other event flushes it
   first, so a click after a flick lands after the scroll.
2. **Budget** (`budgeted_scroll_at` / `Accel.apply`): the batch, the
   gap since the last batch and `[editor] scroll_accel`:
   - a gap over **250 ms** starts a new gesture — no inherited speed,
     so one notch after a pause is 1:1 at every setting;
   - rate = batch ÷ gap (events/s); the multiplier ramps from 1.0 at
     **45/s** to the ceiling at **120/s** — `gentle` 1.5, `normal`
     2.5, `fast` 4.0, `off` 1.0;
   - a rate under half the gesture's peak is a **decaying** wheel (a
     free spin): the multiplier is dropped for the rest of the
     gesture, so the tail travels one line an event and dies with the
     wheel — nothing is discarded;
   - the sub-line remainder **carries** across the gesture, so
     `gentle`'s 1.5 is not floored back to `off`;
   - a leaky **bucket** of 40 × ceiling lines, refilled at 60/s,
     bounds a flick; a real event still moves **at least one line**
     (`965eae16`). `off` is the plain bucket and can spend 0 when dry.
3. **Per surface.** A text body — the editor, a markdown preview, a
   diff — moves `wheel_lines` (3, Rust's editor gain) lines per
   budgeted event. Every list — the panels, the git rail, the file
   pane — moves the budgeted count clamped to **8 × ceiling** rows a
   batch (`list_scroll_clamp_scaled`). The tree moves **one row per
   notch**: with accel off a batch inside 60 ms of the last step is
   the same notch; with it on the rows come from the factor,
   accumulated (2.5 alternates 2 and 3). A pty child tracking the
   mouse gets every event as its report, unbudgeted; one that does
   not scrolls a line an event. The Settings box, the help box and
   the info view move a row an event, the picker three, none budgeted
   — Rust's per-event paths.

## The accel table

Lines moved for the same run of events, per setting — the Rust
function's output (its arithmetic run over these timings), pinned by
`test "accel table"` in `src/app/scroll.zig`. Batch 1 unless said.

| run | off | gentle | normal | fast |
|---|---|---|---|---|
| 4 notches 400 ms apart | 4 | 4 | 4 | 4 |
| 10 events 120 ms apart (~8/s) | 10 | 10 | 10 | 10 |
| 10 events 8 ms apart (~125/s, a hard spin) | 10 | 14 | 23 | 37 |
| 10 events 10 ms apart (100/s) | 10 | 13 | 19 | 29 |
| 4 ghostty detents (3 events 8 ms apart, 150 ms between) | 12 | 13 | 15 | 18 |
| the same detents already folded (batch 3, 150 ms apart) | 12 | 12 | 12 | 12 |
| one batch of 30, then five batches of 30 16 ms apart | 44 | 64 | 104 | 164 |
| 8 events 8 ms apart, then a tail at 20/30/45/60/90/130/180 ms | 15 | 18 | 25 | 36 |
| 6 fast, three slowing, a 900 ms pause, 6 fast | 16 | 21 | 32 | 49 |
| 10 events with ±25 % jitter around 22 ms | 10 | 10 | 10 | 11 |
| 400 batches of 3, 10 ms apart (the tester's run) | 279 | 452 | 493 | 553 |
| 400 events 25 ms apart — the last 100 | 100 | 100 | 100 | 100 |

Per event, `normal` on the hard spin reads 1 2 3 2 3 2 3 2 3 2 and
`fast` 1 4 4 4 4 4 4 4 4 4; the detent run reads 1 2 3 then 1 1 1 … —
the 150 ms gap collapses the rate under half its peak, so only the
first detent's burst is amplified until a pause resets the gesture.
The list clamp of a 40-line batch: 8 / 12 / 20 / 32.

## Per detent on ghostty

A detent is three events 8 ms apart. Deliberate detents 150 ms apart,
`normal`:

| surface | Rust | Zig | per detent |
|---|---|---|---|
| editor / markdown / diff | 3 × 3 lines an event | the same | 9 lines (the first detent of a gesture: 6 + 9 + … per the table) |
| a list panel, the git rail | 3 rows a detent (clamped at 20 a batch) | the same | 3 rows |
| the tree | 1 row a notch (60 ms window) | the same | 1 row |
| a pty, not tracking | 1 line an event | the same | 3 lines |
| Settings / help / info view | 1 row an event | the same | 3 rows |
| the picker | 3 rows an event | the same | 9 rows |
| a context menu | 1 row an event (Rust: a batch) | 1 row an event | 3 rows |

## Measured: `tools/compare.sh compare-mouse`

The large-file fixture at 120×40, standard input, the IPC `scroll`
with `dy` events dispatched one by one as the Rust host applies them.
The top line read off the gutter after each step (the `+N` pinned
scope rows aside):

| notches | Rust top | Zig before | Zig after |
|---|---|---|---|
| 1 down | 4 | 4 | 4 |
| 3 down | 22 | 13 | 22 |
| 10 down | 91 | 43 | 91 |
| 30 down | 310 | 133 | 310 |
| 1 up | 307 | 130 | 307 |
| 3 up | 289 | 121 | 289 |
| 10 up | 220 | 91 | 220 |
| 30 up | 1 | 1 | 1 |

That is 3 / 18 / 69 / 219 lines for 1 / 3 / 10 / 30 notches on both
sides (the research doc's "4" for one notch was the top line, not the
delta).

## Scripts and hosts

A `.test` `scroll` step is one deliberate notch: the runner ends the
gesture before it (`Driver.wheelNotch`), so fifteen steps move 45
lines in the editor at every setting — as under the Rust runner,
whose 50 ms per step keeps its notches under the 45/s floor. A host's
IPC `scroll` with `dy` is a spin: its events are dispatched one batch
each and accelerate as one would at the terminal.
