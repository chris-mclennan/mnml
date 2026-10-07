---
title: API Traffic
description: Who is spending an API's budget right now — mnml's panes, the statusline poller, your own loops and scripts — read from the files every process on the machine writes.
---

Jira and Bitbucket give each account a budget of requests an hour. On a
machine running mnml's panes, its statusline poller, a fleet of loops
and the odd script, they all spend the same budget, and when it runs
out every one of them slows down at once. The integration's statusline
chip says *that* the budget is low. The **API TRAFFIC** pane says
**who** is spending it.

Open it with `view.api_traffic` — `space i a` in the vim profile,
`ctrl+k i a` (or `space i a`) in the standard one — from **View → API
traffic**, or from the command palette. Its activity-bar row (a gauge,
under Scripts) starts hidden: the gear's *Show hidden sections ▸* puts
it on the bar, and `ui.rail.hidden` is where that is kept. It opens below the active pane; running the command again
brings the same pane back and reads the files again.

The pane only reads files. It never sends a request, so opening it in
the middle of a throttled morning costs nothing.

## Where the numbers come from

Three files per service, each a documented contract that any program
can write to (the [SDK reference](/docs/integrations/sdk) has the
exact shapes):

- **The draws file**, `<service>-draws.jsonl` beside the shared bucket.
  Every process that takes a token from the bucket appends one line:
  when, its pid, its program name, the reason it gave, how long it
  waited and how many tokens were left. mnml's integrations write it,
  and so can anything else — a Python loop, a shell script — by
  appending the same line. This is the file that makes traffic from
  outside mnml visible, so when it exists the timeline and the WHO
  table count it.
- **mnml's own request log**, `<data root>/requests/<service>.jsonl`.
  Only mnml's integrations write it, but it records what the draws file
  cannot: the status each request came back with, and the requests a
  local cache answered without spending a token. The header's `304`
  share and its 429 count come from here. For a service with no draws
  file, the request log is what the pane counts instead.
- **The shared bucket**, `<service>-ratelimit.json`: the tokens left,
  the refill rate, a cooldown after a 429, and the time of the last one.

Both logs rotate at 4 MB and keep one older generation; the pane reads
the older generation when it opens and follows the live file from there,
so a rotation in the middle of a session loses nothing. It keeps seven
days, and at most fifty thousand lines per log.

The files live where the SDK resolves them: `$MNML_SHARED_STATE_DIR`
when it is set, otherwise mnml's own data root. Point every program on
the machine that agrees to the format at the same directory and they
all land in one view.

## Reading the pane

A tab per service that has any of the files. The busiest service this
hour opens first; `Tab` (and `Shift+Tab`) walks the tabs.

### The header

```
BITBUCKET · last 1h · 412 requests · 89 % 304 · 2 429    window: 1h
```

The window's requests, the share of mnml's answered requests that came
back `304 Not Modified` (an unchanged listing — nearly free), the 429s
and the cache hits. The `window:` chip walks the last hour, day and
week; a right-click lists all three. `w` does the same from the keyboard,
and `1` / `2` / `3` jump straight to one.

### NOW

- **bucket** — the tokens left, refilled to this second at the rate in
  the file, out of the bucket's capacity; the refill rate; a cooldown
  after a 429 and how long it has left; when the last 429 was.
- **hour** — requests in the last hour by every program, against the
  hourly limit: the bucket's refill rate times 3600, the same figure an
  integration's budget chip paces itself to. `mnml today` is the
  budget's day tally, which counts mnml's own integrations only.
- **broker** — whether the [broker](/docs/integrations/sdk) is up (this
  mnml hosting it, or another process) and how many requests are
  queued in each class: interactive, refresh, warm, batch. *Down* means
  every program takes tokens first come, first served.
- **feed** — the integration's event feed, when its config names one:
  *live* while something has written the file inside its staleness
  limit, *stale* once it has gone quiet and the pane is polling again,
  *polling* when no feed is configured.
- **cache** — entries in the shared HTTP cache, when that directory
  exists.

### TIMELINE

Requests a minute over the window, stacked by program: the busiest at
the bottom, each in its own colour, with the seven busiest named and
everyone else stacked together as *other*. The legend above the strip
names the colours and marks mnml's own integrations with `(mnml)`.

On the hour, each column is one minute. On the day, minutes are grouped
to fit the pane, and each column's height is the average a minute
across it. The week counts in ten-minute buckets.

The dashed line is the hourly limit spread over a minute. A column above
it is spending faster than the bucket refills; a run of them is what
drains it. When every column is far below the limit, the line would
flatten the bars, so the limit is named under the strip instead.

Point at a column — or press `←` / `→` — and the line under the strip
reads it out: the minute, the count, and the split by program.

### WHO

One row per program that drew in the window, busiest first:

| column | what it says |
|---|---|
| program | the name each line gives, with its timeline colour; `(mnml)` marks mnml's own |
| requests | tokens it drew in the window |
| share | its part of the window's total |
| top reason | the reason it gave most often — `poll`, `pane_open`, `warm`… |
| worst wait | the longest one request was held waiting on the bucket |
| last seen | how long ago it last drew |
| pids | the pid that drew last, and how many others drew under the same name |

Hovering a row lists every reason it gave with its count, and every pid.
`y` copies the newest pid. A right-click opens **Open in REQUESTS** — the
REQUESTS view filtered to that program — and **Copy pid**. The REQUESTS
view reads mnml's own request log, so it shows rows for mnml's
integrations; for a program outside mnml it opens empty.

### Keys

| key | does |
|---|---|
| `Tab` / `Shift+Tab` | next / previous service |
| `w`, `1` `2` `3` | walk the window; jump to hour, day, week |
| `←` `→` (`h` `l`, `[` `]`) | pick a timeline column |
| `↑` `↓` (`j` `k`) | move in the WHO table |
| `y` | copy the program's pid |
| `r` | read the files again now |
| `Esc` / `q` | close (Esc first un-picks a column) |

## How often it reads

The pane follows the same cadence as the other dashboards: every two
seconds while it is on screen and something drew in the last minute,
every five while it is on screen and quiet, and not at all while it is
off screen — it reads the moment it comes back. **Settings →
Integrations → Dashboard refresh** (`ui.dashboard_refresh`) pins the
pace or turns it to manual, where only `r` and the refresh chip read.

**Settings → Integrations → API traffic window**
(`integrations.api_traffic_window`) is the window the pane opens on.

## Throttles

Every 429 an API sends anybody on the machine is counted on the NOW
line: `throttles  3 in the last hour · last 4m ago · widget.py (2),
mnml-bitbucket (1)`. The fleet writes each one to
`api-usage/<UTC day>.throttles.jsonl` beside the shared buckets, and
mnml's own 429s come from its request log; the pane reads today's file
and yesterday's, so nothing written around midnight is missed.

When new ones land, mnml raises one warning toast per service — *Bitbucket
throttled — 3 × 429 in the last 5 min (2 from widget.py, 1 from
mnml-bitbucket)* — and then stays quiet for five minutes however many
more arrive. Its **API traffic** button opens the pane on that service.
The 429s already in the files when mnml starts are history and never
toast. The toasts watch the files every 30 seconds even with the pane
closed. **Settings → Integrations → Toast on 429s**
(`integrations.throttle_toasts`) turns them, and that watching, off; the
NOW line still counts.

## Making your own programs show up

Anything that spends from the same budget can be counted: append one
line per request to `<service>-draws.jsonl` in the shared directory,
with the seven keys the SDK reference lists — `ts`, `pid`, `program`,
`service`, `reason`, `wait_ms`, `tokens_after`. A Python script can
write it with the standard library alone. Give the program a name you
will recognise in the WHO table, and a reason that says why it asked.
