# Pane-chrome drift audit — 2026-09-19

Every official integration is supposed to paint out of one toolkit
(`sdk/mnml-sdk/src/pane/`), so that a reader who learns one pane can
read the next one. This is the audit-and-close pass over that promise:
what the six pane families actually paint today, element by element,
and which of the differences are drift to close versus a decision
nobody has taken yet.

The screens below were captured from the real mounted panes, driven by
the e2e harness against the deterministic fakes
(`mnml-fake-jira --extra-issues 40`, `mnml-fake-bitbucket --extra-prs
30`) at 120×40 and 80×24. No live service was contacted and no real
issue, repo or person appears anywhere in this file.

## Families audited

| Family | Binary | Scope |
| --- | --- | --- |
| Jira Work | `mnml-jira --only work` | `work_open`, `work_reported`, `jql_editable` |
| Jira Boards | `mnml-jira --only boards` | `board_active_sprint`, `board_backlog` |
| Jira Fix Versions | `mnml-jira --only fix-versions` | `work_assigned`, `fix_version_tree` |
| Bitbucket PRs | `mnml-bitbucket --only prs` | `workspace_open_prs`, `workspace_merged_prs` |
| Bitbucket Pipelines | `mnml-bitbucket --only pipelines` | `workspace_pipelines` |
| sample | `mnml-sample` | the SDK's own worked example |

## 0. The audit could not be run as written, first

`tests/e2e` files that declare `# width:` or `# height:` were running
with every assertion evaluated once and thrown away — the runner shared
one rule between a file's own declared size and the `--gate --sizes`
sweep, and the sweep is deliberately silent. Four corpus files were
affected, 33 checks between them, and two of the four were wrong. Fixed
in `730f680` before this audit was written, because without it the
80×24 half of the table could not be captured at all.

That is the same shape as the recurring lesson: the mechanism ran, the
verdict was never read, and the runner printed `ok`.

## 1. The table

`✓` present and painted through the SDK toolkit · `~` present but
painted locally · `✗` absent · `n/a` the family has no such thing.

| # | Standard element | Jira Work | Jira Boards | Jira FixV | BB PRs | BB Pipelines | sample |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Host palette roles, never ANSI indices | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 2 | App-colour left gutter | ✓ | ~ | ✓ | ✓ | ✓ | ✓ |
| 3 | Caps header title | ~ | ~ | ~ | ~ | ~ | ✓ |
| 4 | Right-hand chip ladder | ~ | ~ | ~ | ~ | ~ | n/a |
| 5 | Refresh chip | ~ | ~ | ~ | ~ | ~ | ✗ |
| 6 | `?` chip on the header | ~ | ~ | ~ | ✗ | ✗ | ✗ |
| 7 | Tab strip | ✓ | ✓ | ✓ | ✓ | ✗ (1 tab) | n/a |
| 8 | Filter pill | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 9 | Row ground / two-row gutter | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 10 | Hit registered with the paint | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 11 | Cursor-row highlight (`Theme.cursorLine`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 12 | Clickable hint row | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 13 | `?` key sheet | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| 14 | Detail panel `×` | ✓ | ✓ | ✓ | ✓ | ✓ | n/a |
| 15 | Detail panel scrollbar | ✓ | ✓ | ✓ | ✓ | ✓ | n/a |
| 16 | **List** scrollbar | ✗ | ✗ | ✗ | ✓ | ✓ | n/a |
| 17 | `Show more (N)` fold row | ✓ | n/a | ✓ | ~ | n/a | n/a |
| 18 | Status colours off the theme | ✓ | ✓ | ✓ | ✓ | ✓ | n/a |
| 19 | Action buttons, word in role colour | ✓ | ✓ | ✓ | ✓ | n/a | n/a |
| 20 | Button order | ✓ | ✓ | ✓ | ✓ | n/a | n/a |
| 21 | Spinner / state on a button | ✓ | ✓ | ✓ | ✓ | n/a | n/a |
| 22 | Build lines under a PR row | ✓ | ✓ | ✓ | ~ | n/a | n/a |
| 23 | Chevrons, mouse-expandable | ~ | n/a | ~ | ✓ | ✓ | n/a |
| 24 | "Awaiting my approval" chip | ✗ | ✗ | ✗ | ✓ | n/a | n/a |
| 25 | Actionable toasts | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 26 | `as of Nm ago` freshness | ✓ | ✓ | ✓ | ✓ | ✓ | n/a |
| 27 | `r` / `R` refresh keys | ✓ | ✓ | ✓ | ✓ | ✓ | n/a |
| 28 | Statusline figures + hover detail | ~ | ~ | ~ | ✓ | ✓ | ~ |
| 29 | Tab icon from the manifest chip | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

## 2. The rows that differ, with the screens

### D1 — the caps title is a different colour in each family

The toolkit's `capsTitle` paints the title in `Theme.label()` (muted,
bold). Nobody calls it. Bitbucket happens to match it by hand; Jira
paints `Theme.accentText()` instead, so the two families' headers are
different colours on the same theme.

```
Jira Work      ▌JIRA WORK (43)  as of 13s ago                                     ?
               ^^^^^^^^^  accentText()  — accent, bold

Bitbucket PRs  ▌BITBUCKET PRS  (2 repos · 33 PRs)  as of 9s ago     author: all   awaiting: 1
               ^^^^^^^^^^^^^  label()  — muted, bold

sample         ▌SAMPLE · theme onedark · mood calm · 120×36
               ^^^^^^  capsTitle → label()
```

`integrations/jira/src/screen.zig:269` (`p.s.accent`) versus
`integrations/bitbucket/src/screen.zig:141` (`th.label()`).

**Standard is clear** — the toolkit and two of three panes already say
`label()`. Close it: both call `capsTitle`.

### D2 — the chip ladder is hand-rolled twice

`Painter.rightChips` exists, is tested by `consistency_test.zig`, and
is called by NO integration. Both panes carry their own right-to-left
"drop the chip whole when it would cross the title" loop:
`integrations/jira/src/screen.zig:296-307` and
`integrations/bitbucket/src/screen.zig:174-222`. Two copies of the same
geometry is drift by construction — the next change moves one.

**Standard is clear.** Close it.

### D3 — the refresh chip wears two different clothes

Same glyph, two styles, and Bitbucket keeps its own copy of the
constant rather than the toolkit's.

```
Jira           …                            ?      ← `` in Theme.chip()   (chip ground)
Bitbucket      …   author: all   awaiting: 1         ← `` in Theme.refresh() (accent ink, no ground)
```

`integrations/bitbucket/src/screen.zig:46-47` redeclares
`refresh_glyph_nerd` / `refresh_glyph_ascii`, which are
`chrome.refresh_nerd` / `chrome.refresh_ascii` verbatim.
`Painter.refreshChipText()` is the toolkit's answer and neither uses it.

**Standard is clear** — the chip ladder's other chips are all
`Theme.chip()`, and a refresh that is a chip should look like one.
Close it.

### D4 — Bitbucket's header has no `?`

Jira's header ladder ends in a clickable ` ? ` that opens the key
sheet. Bitbucket's does not; its only door to the sheet is the `? keys`
entry on the hint row, which is dropped first when the row is narrow.
At 80 columns the Bitbucket hint row still carries it, but it is the
next to go.

**Standard is clear** — the sheet exists in both, the door should too.
Close it.

### D5 — the list has a scrollbar in one family and not the other

Bitbucket paints `Painter.scrollbar` down the list's right edge when
the rows outrun the pane (`screen.zig:368`). Jira paints one only on
the detail panel; its list, at 43 issues in a 30-row body, says nothing
about where you are.

```
Bitbucket PRs @80×24        Jira Work @80×24
▌ ▾ api      … cache ( █    ▌    ENG-101   In Progress …  Checkout follow-up 1
▌   ▸ #9000  … cache ( █    ▌        MERGED              …  Checkout follow-up
▌   ▸ #9001  … cache ( █    ▌    ENG-102   In Progress …  Checkout follow-up 2
▌   ▸ #9004  … cache ( │    ▌        MERGED              …  Checkout follow-up
                       ^                                                      ^
                       thumb over track                                       nothing
```

**Standard is clear** — the toolkit has one scrollbar and one
`scrollAt` to turn a press back into a position, and Jira already uses
both for its detail panel. Close it.

### D6 — the fold row's `⋯` sits in two places

Both panes paint the words `Show more (N)` bright, in the last column.
Jira puts the dim `⋯` at the pane's left edge (`showMoreRow` paints it
at `rect.x + 1`); Bitbucket puts it immediately before the words.

```
Bitbucket PRs  ▌                                        ⋯  Show more (7)
Jira (code)    ▌ ⋯                                         Show more (N)
```

**Standard is clear** — `⋯  Show more (N)` reads as one phrase; a `⋯`
forty columns away from its own words reads as a second, empty column.
Close it on the toolkit's side so both panes get the same row.

### D7 — build lines take two routes to the same output

Jira calls `Painter.buildRow` / `Painter.buildNote`. Bitbucket builds
the same string through `sdk.pane.build.caption` + `styleOf` inside its
table renderer (`view.zig:407`). The LINE is identical — that part was
already converged — but the row's hit is the generic row hit rather
than `buildRow`'s, so "click a build line to open that run" is wired
once in each pane rather than once in the toolkit.

**Recommend, do not pick.** Bitbucket's build line has to live inside
its column lay-out (it is a table cell, not a free row), so moving it
onto `buildRow` means teaching `buildRow` about columns. Listed in §4.

### D8 — `Painter.chevron` has a private twin

`integrations/jira/src/screen.zig:165` is a byte-for-byte copy of
`chrome.Painter.chevron`. Harmless today; it is the shape every one of
the drifts above started as.

**Standard is clear.** Delete the copy.

### D9 — the gutter stops at the board

Jira Boards paints the toolkit gutter down the header rows and then
hands the body to the kanban columns, which draw their own per-card
`▌`. The pane's identity stripe therefore ends a third of the way down:

```
▌ board: Checkout board   sprint: Sprint 4   󰍉 / filter   JP   LZ   …
▌ quick filters   unassigned   settings
┌ To Do (1) ─────────────┐┌ In Progress (41) ──────┐┌ Testing (1) ───────────┐
│▌  ENG-5              ││▌  ENG-1              ││▌  ENG-2              │
```

The `--only <scope>` error screen has no gutter at all:

```
 No tabs for this scope.

 None of the config's tabs has a kind that belongs to `--only work`.
```

**Recommend, do not pick.** A full-height stripe behind a board of
boxed columns may be right or may be noise, and the answer is the
same question for any future column-shaped pane. Listed in §4.

### D10 — the statusline says one number on one side and two on the other

```
Bitbucket   󰂨 12(11)      ← open PRs, and how many are mine
Jira Work   󰌃 43          ← one figure
Jira Boards 󰌃             ← no figure at all on a board-only scope
```

Jira publishes a second segment (`jira_work.qa_actionable`) only when a
tab is configured as the QA-actionable one, and no figure at all when
the mounted scope has no work tab. Both panes carry a hover tooltip
with the breakdown.

**Recommend, do not pick.** "Two numbers" is a Bitbucket fact (`open`
and `mine`); the Jira equivalent would be a policy choice about which
second figure a tracker owes. Listed in §4.

### D11 — actionable toasts exist nowhere

The wire's `toast` carries a level and a text and nothing else
(`sdk/mnml-sdk/src/wire.zig:286`). No official integration posts a
toast with an action on it. This is not drift between the families —
it is a listed standard element with no implementation on either side.

**Recommend, do not pick.** Listed in §4.

## 3. Chrome painted outside the toolkit

Greps that would find drift by construction:

| Check | Jira | Bitbucket | sample |
| --- | --- | --- | --- |
| `.{ .index = N }` in a painter | none | none | none |
| `.{ .rgb = … }` in a painter | none¹ | none¹ | none |
| local `Theme` definition | none | alias only² | none |
| local hint row | none | none | none |
| local scrollbar | none | none | none |
| local chip-ladder loop | **yes** (D2) | **yes** (D2) | n/a |
| local caps-title paint | **yes** (D1) | **yes** (D1) | none |
| duplicated toolkit constant | **yes** (D8) | **yes** (D3) | none |
| local fold-row paint | none | **yes** (D6) | n/a |

¹ Both `main.zig` files carry an onedark literal palette as the
fallback for a host that sends none, and `jira/src/screen.zig:2121` is
a test fixture. Neither is a painter.

² `integrations/bitbucket/src/theme.zig` is `pub const Theme =
sdk.pane.Theme;` plus the name the pane has always called it by.

## 4. Open decisions — recommendations, not choices

### O1 — the PR row's action buttons, and the column budget

Bitbucket offers `[ Open ] [ Merge ]` only on the CURSOR row, and only
when the title column can give up their cells and keep 16 for itself
(`rowButtonsWidth`, `title_floor = 16`). Jira offers its buttons on
EVERY row, always, taking the cells out of the summary.

Measured, on the fakes, with the cursor on a pull-request row:

| Pane width | Bitbucket TITLE column | Buttons need | Shown? |
| --- | --- | --- | --- |
| 80 | 24 | 18 + 16 = 34 | no |
| 120 | 22 | 18 + 16 = 34 | no |
| 140 (detail closed) | 42 | 34 | yes |

So the practical threshold is ~135 columns for the two-button row and
the buttons are simply never available at the two sizes the corpus
runs at. Jira's row, at 120 columns, shows
`[ Triage ] [ Implement ]` on every row and clips the summary to do it.

Neither rule is obviously right, and they are not the same rule:

* Bitbucket's says *a clipped title is worse than no button*, which is
  true of a dense five-column table.
* Jira's says *the button is the point of the row*, which is true of a
  tracker you are working out of.

**Recommendation** (for the user to take or refuse): one rule for
both — **the cursor row always gets its buttons; a non-cursor row gets
them only when the text column keeps `title_floor` cells.** That makes
Bitbucket's cursor row usable at 80 columns (where it is the only row
that can act) and stops Jira clipping 40 summaries to show 40 copies of
a button only one of which can be pressed by the keyboard. It is one
rule, it moves both families, and it is a behaviour change on both —
which is why it is here and not in the closed list.

### O2 — the gutter under a column-shaped body (D9)

Recommendation: keep the stripe full height and let the kanban columns
start one cell in. The stripe is the pane's identity, and a pane that
loses it halfway down reads as two panes. But this is a look call on a
body nobody else has yet.

### O3 — the second statusline figure (D10)

Recommendation: state the standard as *"a figure the segment is named
for, and a parenthesised subset when the pane has one"* — Bitbucket's
`12(11)` already reads that way, and Jira's assigned count would become
`43(2)` for "assigned, of which N need me today" only if a tracker
actually has such a subset. If it does not, one figure is the honest
answer and the standard should say so.

### O4 — build lines inside a table (D7)

Recommendation: leave Bitbucket's build cell where it is, and instead
move the *hit* into the toolkit — a `buildHit` the table renderer can
call with the run — so the click behaviour converges even where the
lay-out cannot.

### O5 — actionable toasts (D11)

Recommendation: this belongs in the wire before it belongs in a pane.
Not a backfill item; a protocol item.

## 5. What is closed in this pass

### The table, after

| # | Standard element | Jira Work | Jira Boards | Jira FixV | BB PRs | BB Pipelines | sample |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | Caps header title | ~ → ✓ | ~ → ✓ | ~ → ✓ | ~ → ✓ | ~ → ✓ | ✓ |
| 4 | Right-hand chip ladder | ~ → ✓ | ~ → ✓ | ~ → ✓ | ~ → ✓ | ~ → ✓ | n/a |
| 5 | Refresh chip | ~ → ✓ | ~ → ✓ | ~ → ✓ | ~ → ✓ | ~ → ✓ | ✗ |
| 6 | `?` chip on the header | ~ → ✓ | ~ → ✓ | ~ → ✓ | ✗ → ✓ | ✗ → ✓ | ✗ |
| — | The header's two runs clipped against each other (D12) | ✗ → ✓ | ✗ → ✓ | ✗ → ✓ | ✗ → ✓ | ✗ → ✓ | n/a |
| 16 | **List** scrollbar | ✗ → ✓ | n/a | ✗ → ✓ | ✓ | ✓ | n/a |
| 17 | `Show more (N)` fold row | ✓ | n/a | ✓ | ~ → ✓ | n/a | n/a |
| 23 | Chevrons | ~ → ✓ | n/a | ~ → ✓ | ✓ | ✓ | n/a |

Every other row is unchanged from §1.

The screens, after, at 120×40:

```
▌JIRA WORK (43)  as of 13s ago                                                     ?
▌BITBUCKET PRS  (2 repos · 33 PRs)  as of 9s ago      author: all   awaiting: 1      ?
```

— the refresh glyph and `?` at columns 113 and 117 on both, both on
`chip_bg`, which is what `tests/e2e/integrations_pane_chrome.test`
pins with `expect color` rather than with the glyph's text.

```
▌    ENG-101     In Progress Ada Lovelace  2026-09-15 Checkout follow-up 1     █
▌   ▸ #9000      OPEN       2026-09-19   Tidy the widget cache (           █
```

— the same bar, from the same `Painter.scrollbar`, on both.

```
▌                                                      ⋯  Show more (7)
```

— one phrase, on both, where the tracker pane used to put the `⋯` at
column 1.

### D12 — found while closing D4: the header's two runs collide

Adding the `?` chip made the forge pane's header four cells narrower
on the left, and at 80 columns that was enough to turn it into

```
▌BITBUCKET PRS  (2 repos · 33 PRs)  as of 9s agohor: all   awaiting: 1      ?
```

— `author: all` with its head eaten. The bug was not the chip. Both
panes painted one run and then the other, so whichever went second
won the overlap; the old ladder was simply four cells narrower and
missed. `Painter.capsHeader` now lays the ladder FIRST, against the
title's width, and clips everything after it at the cell the ladder
reached; `as of …` is dropped whole rather than clipped, and the count
gives way to the ladder before the title does.

Worth recording because the audit's own table would have scored the
header `✓` on both families and missed it: the element was present
and shared. It took looking at 80 columns after the change.

### The guards

Each closed drift has three:

1. `sdk.pane.expect` — one assertion, in the SDK, so the two families
   cannot check two different things;
2. each integration's own unit suite, pointing that assertion at its
   own painted frame;
3. `tests/e2e/integrations_pane_chrome.test` — both panes really
   mounted against the fakes.

Each was break-checked: the fix reverted on a scratch copy, the
failure read, the file restored from the copy rather than from git.

### Not closed

D7, D9, D10, D11 and O1 are the recommendations in §2 and §4,
unimplemented and waiting on a call.

### One more thing the audit turned up

The e2e runner shared one rule between a file's own `# width:` /
`# height:` and the `--gate --sizes` sweep, so every assertion in a
file that declared its own size was evaluated once and discarded.
Thirty-three checks across four corpus files had never been read, and
two of the four were wrong. Fixed in `730f680`, which is why this pass
could capture the 80×24 half of the table at all.

## 6. After O1–O5 — the five decisions, taken

The user took all five. What §4 listed as recommendations is now
shipped, and §2's D7, D9, D10 and D11 are closed with them.

### O1 — the row's action buttons

The user's rule, and it is neither of the two the panes had:

> we always reduce to icon when tight on space and when more available
> we do icon and label.

So the buttons are on every row that has them, at every width, and
what the width decides is how much of themselves they show.

```
140+   ▌    #1234   OPEN   …   Fix the login redirect   [󰏌 Open] [󰘭 Merge]
80/120 ▌    #1234   OPEN   …   Fix the login redir 󰏌 󰘭
```

```
140+   ▌       OPEN   …  Follow-up: trim the whitespace   [󰏌 Open] [ Review] [󰘭 Merge]
80     ▌       OPEN   …  Follow-up: tr…  󰏌    󰘭
```

`sdk.pane.action.formFor` picks the widest form that still leaves
`text_floor` (16) cells of the text column for the row's own words,
and below that the run reduces to its glyphs and never past them.
`[󰏌 Open]` is exactly as wide as the `[ Open ]` it replaces, so no row
got narrower for growing a glyph.

One glyph per KIND, not one per word, so the set is four and both
families wear the same four — `󰏌` navigation, `` review, ``
dispatch, `󰘭` final — each with an ascii twin (`>` `?` `*` `&`), and
`zig build glyph-audit` now walks the SDK so a fifth cannot arrive
without one.

What this cost, and it is the trade the decision names: the forge
pane's TITLE column gives up cells it used to keep. At 120 columns
`Fix the login redirect` is now `Fix the login redir`. A clipped title
with a reachable action beats a whole title with none — and the
alternative the audit measured was no buttons at all at either of the
two sizes the corpus runs at.

The hover names the action when the glyph is all there is
(`action.hoverText`), and both panes read the FORM off the painted hit
rect — one cell wide IS the icon form — so nothing has to be
remembered between frames.

### O2 — the gutter under a board (closes D9)

The board starts one cell in and the stripe runs the whole height. The
bad-scope error screen already had it (fixed between the audit's
capture and this pass); it is now asserted rather than assumed.

### O3 — the statusline figure (closes D10)

The standard, written into `docs/SDK.md`: **one named figure per
segment, plus a bracketed subset only when the pane genuinely has
one.** The bracket is a subset OF the figure beside it, never a second
count; a pane with two things to say publishes two segments.

Bitbucket keeps `󰂨 12(11)`. Jira stays `󰌃 43` — a tracker has no
subset of "assigned to me" it can name, and `43(2)` invented for
symmetry would be a number nobody could believe.

`sdk.pane.figure` makes it true by construction (one `n`, one optional
`subset`) and `figure.check` makes it true of a string, which is what
`expect.statuslineFigure` asserts from both suites.

### O4 — the build line's door (closes D7)

Not the layout, the HIT — which is what the audit recommended, and it
turned out to be worth more than recorded: **neither** pane opened the
run when you clicked a build line. The tracker pane's free row and the
forge pane's table cell both fell through to the generic row hit,
which selects. The line read as a link in two panes and behaved as one
in neither.

`sdk.pane.buildHit` is the one rect both register — the whole line,
indent and trailing air included, clipped at the first column the pane
does not own. The forge pane calls it itself after its table paints;
the map's last-painted-wins rule puts the door over the row. The page
is `sdk.pane.build.pageUrl` on both sides now (the forge pane had two
copies of the same string).

### O5 — actionable toasts (closes D11)

In the wire before the pane, as recommended. `wire.toast` gains an
optional `action`: a label, and either a command id the host runs or a
page it opens. Protocol 2 → 3.

The field defaults to none and the encoder omits it, so a sibling
built against 2 is unchanged on the wire; the version is bumped
anyway, because a sibling that NEEDS the button can now refuse a host
below 3 rather than posting a message with nothing to press.

Neither door is a free hand. `command` is an id the host already knows
— its own, or one the integration registered — resolved through the
registry a key or the palette uses; a sibling cannot name a shell
line. `url` is a page and the host applies its own http(s) rule.
Exactly one of the two.

Both cases the audit named are in use:

```
  Bitbucket PRs: merge finished: api#1234     [ Open PR ]
  Bitbucket PRs: error: 2 repos errored       [ Retry ]
```

A `command` offer carries the pane that made it and focuses it before
running, so a `Retry` lands on the pane that failed rather than on
whichever one is in front. `integrations.retry_refresh` is the host
command behind it: it sends `r`, the refresh key every pane in the
family binds, to the focused integration pane. Command-id pins 1100 →
1101.

### The table, after O1–O5

| # | Standard element | Jira Work | Jira Boards | Jira FixV | BB PRs | BB Pipelines |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | App-colour left gutter | ✓ | ~ → ✓ | ✓ | ✓ | ✓ |
| 19 | Action buttons | ✓ | ✓ | ✓ | ~ → ✓ | n/a |
| 22 | Build lines under a PR row | ✓ | ✓ | ✓ | ~ → ✓ | n/a |
| 25 | Actionable toasts | ✗ → ✓ | ✗ → ✓ | ✗ → ✓ | ✗ → ✓ | ✗ → ✓ |
| 28 | Statusline figures | ~ → ✓ | ~ → ✓ | ~ → ✓ | ✓ | ✓ |

Row 19 changed meaning as well as score: it used to read "the word is
in its role colour", which both families already did. It now reads
"the buttons are there, in the form the row can afford".

### The guards

The same three shapes as §5:

1. `sdk.pane.expect` gained `actionRun`, `gutterFullHeight`,
   `buildLineHit` and `statuslineFigure` — four assertions, in the
   SDK, called from BOTH integration suites;
2. unit tests on `std.testing.allocator` for the width ladder
   (`action.zig`), the statusline rule (`figure.zig`), the build hit
   (`hit.zig`) and the wire codec (`wire.zig`);
3. four `.test` scripts really mounted against the fakes —
   `integrations_row_buttons_narrow.test` (`# width: 80`) and
   `integrations_row_buttons_wide.test` (`# width: 140`) on both
   families, `integrations_jira_boards_gutter.test`, and
   `integrations_toast_action.test`, which kills the service under the
   pane (a short `--lifetime-secs`, so nothing is killed by name) and
   presses `R`.

Each was break-checked: the fix reverted on a scratch copy, the
failure read, the file restored from the copy rather than from git.

### What is NOT covered by an e2e

The merge half of O5 — `Open PR` after a merge session ends — needs a
real Claude Code session to produce the `session_state` edge the toast
hangs off, which the headless harness cannot make. It is asserted by a
unit test in each pane's own suite instead (the effect carries the
`Open PR` offer with the pull request's URL), and the `Retry` half is
what the e2e drives end to end.
