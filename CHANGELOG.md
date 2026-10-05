# Changelog

What changed in **mnml**, release by release, for the people who run it.
Development history is `git log`; design and phasing are `docs/DESIGN.md`.

The top section is the body of the next GitHub release —
`scripts/release-notes.sh` cuts it out, `release.yml` posts it. Two rules for
anything written here: no credential-shaped literals (an auth header goes in
as "an auth header written as a `{{VAR}}` reference", never as the header
itself — GitHub scrubs secret-shaped substrings inside the build manifest and
the release ships one file), and one line per change a user can see.

## v0.3.3 (unreleased)

### Integrations add rows to each other's menus

- A manifest's `context_menu[]` rows now reach mnml's menus: a row
  aimed at `ticket`, `pr`, `pipeline`, `link` or one pane's rows
  (`pane:<id>:<kind>`) joins the right-click menu of a link of that
  kind anywhere and of a Jira ticket row, under a muted header with the
  contributing integration's name. Picking it runs that integration's
  command with the clicked row's `{key}`, `{repo}`, `{n}`, `{id}` and
  `{url}` filled in; a `when` (`state=OPEN`) narrows where it shows.
  Older manifests with a plain string target still load. The sample
  integration contributes *Echo ticket key* and *Echo pull request*.

### Integration panes: a confirm's chips click, and hover help names the key

- The SDK's confirm box (`confirmBox`) let a click on its OK or Cancel
  chip land on the box behind them, so neither did anything. Jira's
  and Bitbucket's merge confirms both had it. The chips now win.
- A mounted pane's hover can name the command its element's click
  runs, and the info view then ends with that command's `Key:` chord,
  as the host's own controls do. Panes set it with `Help.runs(id)` and
  `Mount.hoverHelp`; older panes and hosts are unaffected. The sample
  integration's header shows it.
### The setup wizard on a first launch

- A first launch from your home folder — the way a new terminal window
  opens — shows the setup wizard. It used to show the "where to?"
  picker instead, and the wizard never came; the picker returns on
  later launches once the setup is done.
- A dialog that is already up on a first launch, such as the workspace
  trust question, no longer cancels the wizard: it opens as soon as
  that dialog closes.

### Claude tokens renew on every system

- A Claude account whose token is turned down renews it with the
  account's own refresh token — every account, on macOS, Linux and
  Windows — and the new token is written back to that account's file.
  On macOS the keychain is tried first when it holds that account's
  login. The state line reads `expired — refreshing…` meanwhile; only a
  refused renewal shows `expired — Re-auth`.
- Re-auth works on Linux and Windows: after `claude login` the login is
  read from the CLI's credentials file (`~/.claude/.credentials.json`,
  or under `CLAUDE_CONFIG_DIR`).

### SESSIONS: names, states and verbs from Claude Code's registry

- EXTERNAL rows — sessions running in another terminal — read Claude
  Code's live-session registry (`~/.claude/sessions/<pid>.json`): a
  session the user named shows that name and its exact state (`busy`,
  `idle`, `waiting`) instead of `main (47c3b85c)`, and a running session
  with no transcript yet is listed too. The registry is undocumented and
  may change; an unreadable file is skipped and the transcripts stay the
  listing. `sessions.registry = false` turns it off (docs/API.md).
- *Ask what it is doing* (`sessions.ask_external`) sends the session one
  cross-session message asking what it is working on and whether it is
  safe to interrupt; its reply, read from its transcript, shows as a
  toast within 60 s. Not on Windows yet.
- *Take over…* (`sessions.take_over`) ends an idle or waiting session in
  its own terminal and resumes it in a pane here, after a confirm. A
  working session is refused; the pid must still be a `claude` process;
  SIGTERM only, and one that does not exit in 10 s is left running.
### Sessions by number

- `sessions.focus_1` … `focus_9` focus the Nth session as the SESSIONS
  panel lists it — `Space a 1` … `Space a 9` under vim, `Ctrl+Alt+1` …
  `Ctrl+Alt+9` under standard. A session on another tab page brings
  that page up; in the sessions mode it is swapped into the focused
  column; past the last card it says so.
- Each of the first nine cards wears its number, a muted digit in the
  column left of the card, under the on-screen / ready mark; the sessions table has a `#` column with the
  same numbers. The card's hover lists its chord.
- In the sessions view — the sessions mode on screen, or the SESSIONS
  panel with the keys — plain `Ctrl+1` … `Ctrl+9` focus the session
  whose card wears that number, in both profiles. Elsewhere they stay
  the tabs'. The sessions mode's own `Ctrl+1` … `Ctrl+9` used to count
  sessions without the docked ones, so the key could miss the card by
  one; `sessions.show_1` … `show_9` are gone with it.

### Claude accounts: one Re-auth per account

- Each account in the Claude usage pane has a state line under its
  name: `signed in · resets 3:20am`, or `expired`, `keychain holds
  another account`, `no login yet` — each with a Re-auth button. Re-auth
  (also the account's right-click menu, the Claude chip's menu and
  `ai.claude_reauth`) opens `claude login` in a pane, watches the login
  land in the macOS keychain, and files it under the account when its
  email is the account's; the pane closes and the figures come back.
  The separate `R` capture step is no longer needed.
- A login for another account on file is never filed under the one
  being re-authed: a box says whose it is and offers *File under* that
  account, or *Cancel*.
- An account whose token has expired is re-captured on its own when the
  keychain holds that same account's login again (the CLI renews its
  own login as it is used), with one toast.
- The paste-a-token prompt is behind the account menu's *Advanced ▸
  Paste a token…*; adding an account no longer opens it.
- The compact meter's warning account shows its letter and percent in
  yellow or red on the chip's coral, then a `!` — no dark block. The
  hover names the account and why; a click on a chip with a `!` opens
  the usage pane at that account.

### A ticket key says what it names

- Hovering a ticket key that the Jira integration has lately polled —
  in a terminal, on a session card, anywhere it links — shows
  `ACME-123 · Fix the login redirect · In Review`; its right-click menu
  leads with the same line. An old or failed poll keeps the title and
  adds `as of 3h ago`. No request is made for it.
- The Jira integration writes what its `--values` poll and its pane's
  tabs list into a shared recent-items cache,
  `recent/jira/ticket.json` under the shared state dir (else the data
  root): key, summary, status, assignee's display name, priority, type,
  fix versions — never a description, an account id or an email.
- `recent_items.enabled = false` turns it off: mnml reads none of it
  and the integrations it starts write none.
- SDK: `sdk.cache` — `put` / `failed` / `get` / `query` over typed
  `Ticket`, `Pr`, `Pipeline` and `Release` records, with the file
  format documented as a contract (`docs/SDK.md`, *The recent-items
  cache*).
- Pull requests too: `widget#45`, a `PR 45` the link ranges resolved,
  or a link to the pull request's page hovers as
  `acme/widget#45 · Redesign the empty state · OPEN · Max Orr`. The
  Bitbucket integration writes the pull requests its `--values` poll and
  its pane's tabs list, and the pipeline runs its hourly probe and its
  Pipelines tabs see (`recent/bitbucket/pr.json`, `pipeline.json`).
- The Jira integration writes each project's fix versions whenever it
  fetches them anyway — a release tab resolving its version, the Fix
  Version picker — as releases, with the issues a release tab lists.
  The nearest unreleased release date is `current`, the one after it
  `next`; `recent_items.current_release = "ACME/2026.10"` names
  `current` outright.
- *Recent tickets and pull requests* (`picker.recent_items`, vim
  `Space f i`, standard `Ctrl+K Ctrl+E`) lists what the integrations
  last polled, newest first, a stale one marked; Enter opens it where
  its link would.
- `mnml cache get <kind> <id>`, `mnml cache ls <kind> [--source S]
  [--limit N]` and `mnml cache clear [kind] [--yes]` read and clear the
  cache from a shell (`docs/API.md`).

### A bare pull-request or pipeline number links

- `Pull request 5505`, `PR #5505` and `pipeline 10554` link to the
  repository whose numbers hold them. The Bitbucket integration's
  `--values` poll publishes, per repo, the lowest and highest pull
  request and pipeline it has seen (pipelines asked for once an hour),
  keeps them in `cache/link-ranges.json`, and mnml allows 50 above the
  highest. Several repositories: the link opens the workspace's own
  first and its menu lists `Open in <repo>` for each; none: no link.
  Reinstall the integration (`mnml-bitbucket --install`) to pick up the
  new links.
- SDK: a `links[]` entry may say `.resolve = .range, .ranges = "<kind>"`
  and put `{repo}` in its url; `Ipc.linkRanges(id, rows)` publishes the
  `{repo, kind, low, high}` table it reads (`docs/SDK.md`, *Links*).
- `.test` scripts: `click X Y ctrl` (or `super`, `alt`, `shift`).

### Tables use the width they have

- A table no longer cuts a name with `…` while the right of the pane is
  empty. `sdk.pane.columns.fit` takes each column's `need` (its longest
  visible cell) and a `fixed` flag: on a wide pane the spare goes to the
  columns being cut, in proportion to what each is short of and never
  past its need; numbers and dates stay fixed; what is left goes to the
  column that takes the rest, or stays blank. A narrow pane gives way
  exactly as before. A private integration's table gets this by passing
  `need` (see `docs/SDK.md`).
- Jira's Work tree and Bitbucket's tables measure their rows, so a long
  status, assignee, branch or author reads whole on a wide pane.
- The requests log (integration, reason), the git graph (author and
  branch past their 22 / 24 caps), a request's header and parameter
  tables (a long name) and the Files listing (a long kind) follow the
  same rule.
### The pane tab strip

- A narrow pane keeps its tab's close button. At a larger font the strip
  used to cut the tab at its edge and drop the close while still showing
  the `+` and the pane buttons. Now the pager goes first, then the `+`.
  Only then is the tab's name cut, with an ellipsis, down to six cells, and
  after that the pane buttons go from the left. The close is the last thing
  to go. A name that fits once the pager and `+` are gone is never cut.

### Jira and Bitbucket chips

- The Jira Work chip wears Atlassian's work-items icon, a card with a check,
  as Bitbucket's sidebar draws it for Jira work items, instead of the Jira
  logo. It is baked into `MnmlSymbols.ttf` at `U+F1C19`; run `./run.sh
  install-font` to pick it up. The chip's statusline count keeps the Jira
  logo.
### The statusline

- Right-click the statusline between its chips for *Segments ▸*: every
  segment, ticked while shown. A row hides or shows its chip at once and
  writes `.statusline.hidden` to the home config. RESTRICTED and the
  sandbox chip never hide.
- Every segment that can move ends its right-click menu on *Move left* /
  *Move right* — the built-ins and the integrations' segments alike — and
  the row's own menu has *Reset order*. The order is written to
  `.ui.statusline_segment_order` in the home config: the names it lists
  lead their side of the row, in its order, and the rest follow in the
  built-in order (`docs/CONFIG.md`, "Statusline segment order"). A chip
  whose click runs one command and had no menu of its own (jobs, macro,
  zoom, the session ring) gets one: that command, then the moves.
- A theme can colour the segments: `statusline_lsp`, `statusline_wrap`,
  `statusline_language` and eleven more `base_30` keys, each falling back to
  the colour the segment wore before.
- The session pager, ` ‹ ▣ 1/1 › `, has a ground of its own instead of the
  bar's dark grey: `sun` (a theme sets `statusline_pager`), its arrows and
  count in the dark ink the other coloured chips use.
- The bell's right-click marks the unread warnings read and copies the
  last message or the whole log; the mode chip's offers *Toggle keymap*.
- The spinner — the jobs chip's, the panels', an integration pane's — is
  eight-dot braille now and sits on the text's centre instead of riding
  above it.
- The Bitbucket pull-request and Jira assigned figures wear their chip's
  glyph. The host hands every integration it starts its installed
  manifest's chip glyph as `$MNML_CHIP_GLYPH`
  (`sdk.pane.chipGlyphFromEnv`), so a chip and its segment show one mark.
- One mark, spelled once: a manifest's segment writes `{chip}` in its
  resting text for the chip's glyph (`sdk.manifest.withChipMark` fills it
  in when the binary is built; mnml fills in any it still meets). Jira's
  assigned figure and Bitbucket's PRs figure do, and each integration
  tests that its chip, its resting text and its published figure agree.
  Bitbucket's reviews-waiting figure rests blank until it is counted,
  as the review-threads figure already did. Installing an integration
  whose segment rests on a different private-use glyph than its chip now
  warns, naming the integration, the segment and both glyphs.

### Keys

- Under vim, an Alt chord the keymap binds now beats the menu bar's
  Alt+letter: `Alt+H` from an editor toggles NvChad's scratch terminal
  instead of opening *Help*, and `Alt+R` toggles regex search instead of
  opening *Run*. Unbound Alt letters still open their menus; standard keeps
  every letter for the menus, as VS Code does.
- A Claude Code or Codex session on the launcher dock wears its tab's look — the product's mark (Claude's per *Icon ▸*) in the session's own colour — instead of the grey terminal ghost.
- The sidebar divider's right-click menu opens with the column's width
  now, in cells and as a share of the window (`Width: 42 cells · 21%`);
  the keyboard cursor starts on the first row below it.

### Hover help

- A menu row that only says something — the sidebar divider's
  `Width: 42 cells · 21%` — is its own help: hovering it shows the
  label, not *no help written yet*, and the hover audit no longer
  counts it as uncovered.
- The hover help names the keyboard shortcut: a button, chip, rail icon, launcher dock entry, menu or palette row whose click runs a command shows `Key: …` on the line right under its info-view entry's title, in view without scrolling — that command's chord in your profile (`Key: Ctrl+K Ctrl+T` in standard, `Key: Space t t` in vim for the theme pill), and says nothing when the profile binds none or the entry already lists it.

### Claude Code sessions

- `Open ×N ▸ Columns` with something already on the page leaves it the
  width the first session's split gives it and shares only the rest
  between the N sessions; an open editor is no longer squeezed into a
  fourth equal column. On an empty page the N sessions fill the row as
  before.

### Claude Code's review

- A Claude Code session's proposed change (`openDiff`, and `ai.apply`'s
  review) is drawn by the git panel's diff view: the same Hunk / Inline /
  Split toolbar, cycled by `t` or `git.diff_toggle_view`. Until you pick
  a view, a pane at least 80 cells wide opens in Split and a narrower one
  in Hunk. Each hunk header says `[✓ accept]` or `[  skip  ]`. It stays
  its own tab, so an untracked file is reviewed the same way.
- **`Y`**, the header's **Accept all** chip, or `ai.apply_accept_all`
  accepts every hunk and applies them in one step. Space or `a` still
  toggles one hunk; `t` now cycles the view, as in the git diff pane.
  The session is still answered `FILE_SAVED` or `DIFF_REJECTED`.
- The review no longer covers the session that asked for it. It opens
  as a tab in the split holding the file, else an editor split; with
  only the session on screen, a split opens beside it. Accept, reject or
  Esc puts the focus back on the session. `ai.review_placement`
  (`.editor`, the default, `.beside` or `.tab`, the old placement) and a
  row in Settings ▸ AI choose.

### Dependencies

- The terminal library behind every shell pane (ghostty) moved 366
  commits on, to its current main. Nothing changed that we could see:
  colour, scrollback, selection and a long prompt redrawn through
  narrowing and widening behave as before.
- Syntax grammars updated: Scala, Swift, Regex, Dockerfile/Containerfile,
  Protobuf, OCaml and Haskell. OCaml gains the OxCaml keywords and types
  and no longer paints a `#!` first line as a comment; Haskell paints
  `cases` as a keyword.

## v0.3.2

mnml 0.3.2 is the week after the cutover. Sessions get a mode of their own
— every Claude Code and Codex session side by side, with a ring that walks
the ones waiting on you — and mnml grows an API: a local socket with
`mnml remote`, a gate on what a program in a pane may ask for, and a face
for Claude Code's IDE protocol, so a session can open files, read the
selection and show its diffs in a review pane with no setup. Ticket keys
and PR references are links wherever they appear. The dashboards prefetch
and refresh on their own cadence. Jira and Bitbucket 0.2.2 ship alongside:
their chips wear Atlassian's own icons, and their cards and terminals link
to the issue or pull request they name.

### Safety

- A program in a pane can no longer run commands through the file channel
  without asking. A `run-command` of anything that changes more than the
  view, and every `open-pty`, now waits on a toast with a **Review**
  button; Review opens a box with *Allow once*, *Allow for the session*,
  *Deny* and *Cancel*, and nothing answered in two minutes is denied. The
  toast never takes the key you are typing.
- Every command now has a class — view, edit, write or exec — listed in
  `docs/commands.md`; a grant for the session covers one class until mnml
  quits.
- Each answer is a line in `.mnml/ipc/audit.jsonl` and in `events.jsonl`.
- `.api.allow_commands` and `.api.clients` in `config.zon` let a command
  or the file channel through unasked; a workspace you have not trusted
  cannot set them.

### The API

- Each mnml now serves a local socket that `mnml remote` (or `mnml r`)
  talks to: `open PATH[:LINE[:COL]]`, `run COMMAND-ID`, `status`, `panes`,
  `ping`, `instances`, and `call METHOD [JSON]` for anything raw, with
  `--json`. Run in a pane it reaches that mnml as that pane; run from any
  other terminal it finds the mnml whose workspace holds the current
  directory. `docs/API.md` has the methods and the exit codes.
- Every pane is told the socket and gets its own token, made when the pane
  starts and gone when it closes. A command run through the API that
  changes more than the view asks you first, naming the pane; *Allow for
  the session* lasts while that pane is open. Anything without a token may
  only read the status and the command list.
- Settings → Integrations → **API** turns the socket off.
- A Claude Code session started in an mnml pane links to mnml as its IDE
  with no setup. It sees your selection, opens files, reads diagnostics,
  and shows its edits as a diff in mnml's review pane for you to accept
  hunk by hunk or reject. An accepted diff is saved, as the session is
  told it was; a session asking to save a file itself asks you first.
- A linked session wears a link mark (`⇄`) on its tab, and on its SESSIONS
  card when nothing else has that spot; a toast says so when it first
  connects.
- `ai.send_selection` points the session you looked at last at the
  selected lines.
- The API switch covers the link too: off, no session is linked.

### Sessions

- The `+ New session` menu opens a batch of 3 or 6 Claude Code sessions
  as well as 2, 4 or 8 (`ai.claude_code_new_x3`, `_x6`).
- Each `Open ×N` row of that menu opens its arrangements to the right:
  *Tabs*, *Columns* — N full-height sessions side by side, equal widths —
  and, from four up, *Grid*. The pick is remembered (`ai.batch_arrange`)
  as what a plain click on `Open ×N` does; until one is made the AI
  layout toggle decides, as before.
- The Sessions row of the activity bar enters the sessions mode: the editor
  layout is put aside and every Claude Code and Codex session stands in
  columns side by side (`ai.session_columns`, 1 to 4, default 2; the AI
  chips' right-click *Show side by side* sets it), the rest stacked behind
  them. Click the row again and the layout comes back exactly as it was.
- In the sessions mode Ctrl+Tab / Ctrl+Shift+Tab step the focused column's
  stack, Ctrl+1 to Ctrl+9 show the rail's Nth session there, and Ctrl+N
  starts a new session in it; outside the mode those chords mean what they
  always did. Ctrl+Shift+N starts a Claude Code session anywhere.
- Closing a session keeps the shape: a zoomed session hands the zoom to the
  next one, and a column whose last session closes is refilled from the
  sessions stacked behind the others.
- One click on a SESSIONS card shows that session when the page is zoomed or
  in the sessions mode; a `•` beside a card marks a session on screen.
- `sessions.next_waiting` / `prev_waiting` (`Ctrl+Alt+N` / `Ctrl+Alt+Shift+N`,
  `space a j` / `space a k`) now walk every session that is ready for you,
  and skip the rest: the ones waiting on you first, oldest wait first, then
  the ones that finished a turn or ended since you last looked at them,
  oldest first. A session still working, or one you have already looked at,
  is passed over; it joins again when it finishes its next turn. The toast
  says which it is — `needs you: NAME (3 ready)`, `finished: NAME (3 ready)`.
  In the sessions mode the step swaps the session into the focused column;
  on a zoomed page it takes the zoom.
- A `◆` beside a SESSIONS card marks a session that finished or ended since
  you last looked at it, and the bell's right-click lists those sessions
  under *Finished:* / *Ended:* after the ones that need input.
- The session count on a strip no longer reads ` ‹ 1/1 › ` with several
  sessions open: a session left in the background, or started through a
  shell (`:term ./bin/claude`) or a wrapper script, now counts everywhere
  the tab mark does.
- A URL or a ticket key on a SESSIONS card — in its name, its output, its
  ticket chip — or in the sessions table's summary is a link: a dotted
  underline marks it, the pointer lights it, a click opens it in the
  browser, and a right-click offers *Copy link* / *Open link*. The card's
  menu lists each one as an `Open …` row, and Shift+F10 on the focused
  card now opens that menu.
- Hovering a SESSIONS card no longer re-clips its summary lines: only the
  name row makes room for the ` ⋯ `, and a URL below it keeps its length.
- A ticket key links only because an installed integration says what one
  looks like: a manifest's new `links[]` pairs a pattern with the address
  it opens (`docs/SDK.md`, *Links*). The Jira integration declares the
  issue key and writes your site in at `--install` (reinstall it to pick
  this up); with no integration declaring one, only URLs link.
- The help panel at the foot of the left column steps aside while
  SESSIONS has more cards than fit above it, so the list gets those rows
  instead of a scrollbar; it comes back when they fit, and its pin keeps
  it in place.
- SESSIONS has its list ready the first time you open it: the first read
  starts with mnml, in the background. A new or changed transcript shows
  within half a second while the section or the sessions table is on
  screen (two seconds while neither is): mnml looks at the files' sizes
  that often and reads only one that changed, so a quiet machine reads
  nothing. The process list, `git status` and the cloud runs follow a
  pace of their own — quick while a session is working and a view shows
  it, slower when nothing is, rare while nothing is showing. Settings →
  Integrations → *Dashboard refresh* chooses auto, fast, slow or manual
  (only the ⟳ chip reads); the intervals are `sessions.refresh` and
  `cloud_agents.refresh` in the config file.

### Links

- Ticket keys and pull-request refs link everywhere text is shown, not
  only on SESSIONS cards: a terminal pane's output, an editor's text, the
  Markdown preview, a commit's message in the git graph's detail column,
  a toast, and an HTTP response body. Each goes through the one rule set
  the installed integrations declare.
- In a terminal pane a link wears the same dotted underline and lights
  under the pointer; Ctrl/Cmd+click opens it and a right-click offers
  *Copy link* / *Open link* (a plain press still starts a selection).
  The pane matches a line only once it has held still for a frame, so a
  flood of output costs nothing extra.
- In an editor a key or a ref lights under the pointer and opens with
  `gx` or Ctrl/Cmd+click, as a URL already did.
- The Bitbucket integration links `<repo>#<number>` (`widget#42`) to that
  pull request in your workspace. `--install` writes config.zon's
  `workspace` in, links only the repos its `repos` lists when it lists
  any, and adds `<workspace>/<repo>#<number>`; without a config, mnml
  takes the workspace from `$BITBUCKET_WORKSPACE`. A bare `#42` names no
  repo and does not link. Reinstall the integration to pick this up.
- The wheel over a link scrolls what is under it.

### Tabs

- A tab strip whose tabs overflow shows ` ‹ 2/5 › `: the page of tabs on
  show, its arrows turning a page. Nothing is painted when every tab fits,
  and a session strip with one session shows no ` ‹ 1/1 › `.
- Beside the pager, ` ⋯ ` opens the buffer picker: every tab by name, on
  the page or not, one click away. It shows only while the strip pages, is
  the first thing to go on a strip short of room, and a session's strip
  leaves it to the sessions rail. The ` +N hidden ` count is gone — with
  every page a click away, nothing is hidden.
- Opening the tab just past the strip's last whole tab brings it into view
  whole; it used to stay cut at the edge, its name and close button lost.
- A page of tabs holds whole tabs only: the tab that would be cut at the
  strip's edge, before the new-tab `+`, is not painted there and starts
  the next page, as the page count already said.
- Double-click a tab to zoom its pane; double-click again to put the splits
  back.

### The frame

- The sidebar is a fifth of the window by default — 30 cells up to 150
  columns, 40 at 200, never more than 48 — and follows a resize; a number in
  `ui.tree_width` still pins it. Right-click its divider to reset or set the
  width (cells or `25%`), hide or auto-hide it, or move it to the other side.
- Every menu — right-click menus, the menu bar's drop-downs, chip and dock
  menus — prints each row's keyboard chord at its right edge, in muted grey,
  for the profile you are in (`Ctrl+N` under standard, the vim chord under
  vim). A row with no binding shows none, and a row too narrow for both drops
  the chord rather than clip its label.
- Under the standard profile those chords include the editor's own keys:
  the right-click menu's Cut, Copy, Paste, Undo and Select all read Ctrl+X,
  Ctrl+C, Ctrl+V, Ctrl+Z and Ctrl+A, and the hover help names them too. A
  command reached only through the leader (`Space a e`) prints no chord on
  a standard menu; its hover help names the leader row instead.
- Under the vim profile the same rows print Neovim's own keys: Cut `d`,
  Copy `y`, Paste `p`, Undo `u`, Redo Ctrl+R, Select all `ggVG`, Toggle fold
  `za` — never a VS Code chord where vim has a key of its own. Save stays
  Ctrl+S, which NvChad binds too.
- The standard profile has VS Code's AI chords: Ctrl+Alt+I (Open Chat)
  opens or focuses a Claude Code session, and Ctrl+Alt+Shift+L (Open Quick
  Chat) asks Claude a question. The `Space a c` / `Space a a` leader rows
  still work.

### Sandbox and demo

- `mnml --demo` opens a sample Zig workspace with history in a throwaway
  home, beside offline Jira and Bitbucket servers and a stand-in Claude Code
  session (no model runs, no network); a ` demo ` chip says so, and exit
  stops the servers and removes it all.
- `mnml --sandbox` and `mnml --demo` clean up when the process is sent
  SIGTERM, SIGHUP or SIGINT — a closed window or a stopped container —
  as they do on a quit: the terminal is given back, the demo's servers
  stop, the throwaway home is removed, and the exit status is 128 + the
  signal (143 for SIGTERM).
- A downloaded mnml opens the demo with its Jira and Bitbucket panes: the
  macOS and Linux archives, the `.deb` and `.rpm`, the Homebrew formula and
  the installer script now carry the demo's two offline servers
  (`mnml-fake-jira`, `mnml-fake-bitbucket`) beside `mnml`, and the demo uses
  the Jira and Bitbucket integrations the Marketplace installed. When either
  is missing, the first frame's notice names the folders it looked in.
  (Not on Windows, which has no `--demo`.)
- `mnml --help` lists `--demo`, and the sandbox's and the demo's messages
  begin `mnml:` like the rest of the command line.
- `ipc.report_input = true` writes an `input` line to the IPC
  `events.jsonl` when someone at the terminal presses a key, clicks,
  scrolls or pastes (at most one a second per kind, never what was typed),
  so a host replaying a script can tell when a person takes over. Off by
  default.

### Sessions

- The `session needs input: NAME` toast goes to the session when clicked
  (or through its ` Focus ` button): its pane comes forward with the keys,
  as a double-click on its SESSIONS card does; a session another terminal
  runs is shown selected in the sessions table.
- The bell's right-click menu leads with every session waiting on you right
  now, one `Needs input: NAME` row each, and a row goes to that session.
- **Search sessions…** (`ai.search_sessions`, also on the SESSIONS rail
  menu) searches every Claude Code and Codex transcript of this workspace
  for what was said and lists `name · date · line`; Enter goes to that
  session.

### Text fields

- A prompt's line and a picker's query take the mouse: a click puts the
  caret there, a double-click selects the word under the pointer and a
  triple the whole line; typing or a paste replaces the selection,
  Backspace deletes it.
- The same now holds for every other text input: the filter at the top of
  every sidebar list (SESSIONS, TODOS, NOTES, SEARCH and the rest) and of
  the Files, ZON, browser, grep and sessions-table panes, the find bar's
  Find and Replace fields, the `:` line, the settings filter, the HTTP
  pane's URL and its Params / Headers name and value cells, a WebSocket's
  message line, the debug console and a ZON field being edited.
  Shift+click and Shift with the arrows, Home or End grow a selection.
- A paste goes where you are typing: into a sidebar list's filter or a
  pane's filter, the `:` line and the debug console — before, those sent
  it to the editor underneath.
- A click on a find field gives it the keys; a click inside a ZON field
  being edited keeps editing instead of closing it.
- In a terminal or AI session pane a double-click selects a word and a
  triple-click the line, copied when "copy on select" is on, as a drag
  is (Shift-click when the program takes the mouse).

### Terminal panes

- A terminal's scrollback has a scrollbar over the pane's right column.
  It shows while you are scrolled back, or when the pointer is on that
  column; drag the thumb through the history, click the track to page.
  It never takes a column from the program, so nothing resizes when it
  appears, and full-screen programs (no scrollback) never show it.
- A right-click on a link — in a terminal, on a session card or in the
  sessions table — keeps that link lit in the accent with a solid
  underline while its menu is open, so you can see which link Copy link
  and Open link are for.

### Splits

- The Window menu's row is now *Auto-equalize splits* and carries a tick
  when it is on, and Settings → UI has the same switch. On, closing one of
  three splits leaves two even halves. It stays off by default.

### Jira and Bitbucket chips

- The four Atlassian chips wear Atlassian's own icons, the ones Bitbucket's
  and Jira's sidebars draw: the two-branch pull request on Bitbucket pull
  requests, the pipeline loop on Bitbucket pipelines, the three-column board
  on Jira Boards and the ship on Jira Fix Versions. They were the Bitbucket
  and Jira logos, two chips each. The marks are Atlassian's design-system
  SVGs (`@atlaskit/icon`, `@atlaskit/icon-lab`, Apache-2.0 — see
  `data/glyphs/NOTICE`), baked into `MnmlSymbols.ttf` at `U+F1C15`–`U+F1C18`
  at their sizes on Atlassian's 16-unit grid, so the pull request stands
  taller than the loop as it does on Atlassian's own pages. Run `./run.sh
  install-font` to pick them up — until then an installed face lacks them
  and the startup glyph check names the four. Under `--ascii` the chips
  still read `BP`, `BL`, `JB` and `JV`. The Jira Work chip keeps the Jira
  logo.

### Fixes
- The chevrons and the tree's lines wear the menu bar's grey — one step dimmer than before, the same colour on both.

- A toast's Copy, a menu's "Copy path" / "Copy link" and every other
  copy outside the editor reach the system clipboard, so the text pastes
  in another app; before, it landed only in mnml's own register.
- `mnml --demo` lists its three earlier sessions when the workspace path
  has a space, an underscore or a Windows drive letter: the demo names
  Claude Code's project folder by the same rule the app reads it by.
- The tree's connectors follow the Rust rule again: none under a top-level
  folder, in the chevrons' grey.
- `MnmlSymbols.ttf` declares JetBrains Mono's vertical metrics (ascender
  1020, descender -300, typo metrics in use), the box its connectors and
  icons were drawn in, rather than an 800 / -200 box of its own. Run
  `./run.sh install-font` to pick it up.
- The tree's lines meet what they connect: the `│` sits under the chevron
  and the `└`'s arm at the file icon's middle (both were 1.5 px off), and the
  arm is as heavy as the line instead of a pixel lighter. `./run.sh
  install-font` puts the redrawn lines in an installed face.
- Right-click on a link in a terminal or session pane offers "Copy link" and
  "Open link" above "Copy" (a right-click selects nothing, so Copy had
  nothing to copy); a hyperlink the program printed or a plain `https://…`
  in the output both count.
- Ctrl+Shift+V and Shift+Insert paste the clipboard into a terminal pane in
  both profiles (Shift+Insert used to send the program a raw key); plain
  Ctrl+V stays the program's (Claude Code's image paste).
- Ctrl+C over a selection in a terminal or session pane no longer reaches the
  program too: the selection was already copied, so Ctrl+C only clears it and
  the program hears nothing. With nothing selected Ctrl+C is still the
  program's own ^C. Both keymap profiles.
- New `ui.copy_on_select` (Settings: "Terminal copy on select", on by
  default): off, a drag in a terminal pane only selects and Ctrl+C over the
  selection is what copies it. Ctrl+Shift+C copies a selection either way.
- A program that turns on both the kitty keyboard protocol and application
  cursor keys gets arrows, Home and End as `CSI` sequences, as ghostty sends
  them, instead of the `ESC O` form.
- `:only` (`view.only`) no longer crashes when gathering the other splits
  empties one of them first — reachable when a pane was tabbed in two
  splits at once.
- Closing panes another tab page shows — `view.close_others` closes every
  pane, not just this page's — no longer leaves that page pointing at them.
  The next pane opened (the git status pane, say) was given a freed slot,
  appeared on both pages, and mnml crashed the next time it was shown.
- A pane closed while git mode was showing — the web demo's tour does this
  between its git and terminal flows — stayed behind in the editor layout
  the mode had put aside. Leaving the mode brought it back as a tab of
  nothing, and the next pane opened took its slot and appeared in two
  splits at once (`view.only` then crashed). Closing a pane now clears it
  there too, and a split never shows a pane twice.
- Closing a search (grep) pane, or re-running its query, while the search
  was still running leaked the hits it had found but not yet shown.
- `mnml test --sizes`: at a size a file was not written at, an `expect
  within <ms>` is waited on again (its verdict still ignored), so the steps
  after it run against the state they expect. A `shell` step after one could
  fail at 200x60 alone (`sessions_changes.test`).
- In the demo's shell, `claude` and `codex` are the stand-ins even where a
  login profile (macOS's `path_helper`) puts `/usr/local/bin` first on
  `PATH`, so a real CLI installed there is not the one that answers.
- Hovering the ` demo ` chip describes the demo in the info panel, not a
  plain `--sandbox`.
- In `--demo`, a Jira ticket's merged pull request no longer shows
  "BITBUCKET_ACCESS_TOKEN not set": the Jira pane reads its pipelines from
  the offline Bitbucket with that server's own token.
- `jira_work.refresh`, `bitbucket_prs.refresh` and any other `term` line of
  an integration installed from the Marketplace, a local folder or the demo
  said the program was "not on PATH": they looked only on PATH, while the
  pane itself runs the copy linked into the data root. They now run that
  copy too.

- Switching the workspace — a root's `○`, *Switch to this workspace*, or
  `view.switch_workspace` — now switches what mnml works on, not only the
  tree: the title, the statusline's folder and branch, git mode and `Ctrl+P`
  follow the root, and an HTTP env picked for the old workspace is dropped.
  The sections keep their order (only the `●` moves) and the old workspace's
  `○` switches back. The session is saved in the workspace switched to.
- On Linux, a terminal pane whose command prints and exits at once
  (`:terminal printf hi`) could come up empty: the exit was noticed before
  the command's last output was read. The exit now waits for that output.
- Showing or hiding an integration on the top bar toasts "top bar", as the
  menu says, and names the integration by its label (`Bitbucket PRs: shown
  on the top bar`), not its id; the first-party rows' menus say "Show on top
  bar" / "Hide from top bar" like the others.
- Bitbucket PRs: a repo's `Show more (N)` is the row under that repo's pull
  requests, counting that repo's hidden rows and showing that repo's when
  pressed. It used to be one row at the end of the tree, under the last
  repo's header, where it read as the last repo's.
- With a second workspace root in the tree, the primary root's header names
  its folder, as the added root's does, instead of its absolute path (cut to
  `● /Use…` at the stock width); the path is the header's hover.
- A workspace root alone in the tree names its path cut from the left —
  `● …/mnml-zig-worktrees/sidecar/`, or `● …car/` at the stock width — so
  the folder's name is what survives, not `● /Use…`. A root switched to
  names its folder beside the others, like any added root.
- Resting the pointer on an auto-hiding dock's `⋯` grip brings the strip up
  when `ui.dock.reveal_ms` runs out. Before, the strip came up only on the
  next pointer event after that: a single hover (an IPC `hover`, a hand that
  stops moving) showed nothing.
- An auto-hiding bottom dock above the statusline (the default placement)
  showed its `⋯` grip on the screen's last row but brought its items up two
  rows higher. The grip now sits on the row the items appear on — hover it,
  click it or `view.focus_dock`, and the strip comes up right there.
- *Move sidebar to the right* left the activity rail behind and dropped a
  width set by hand, and the moved sidebar's divider had no menu to move it
  back. The rail and the width now go with the sidebar, and either column's
  divider has a menu — the sidebar's offers *Move sidebar to the left*.
- The sidebar divider's ticked *Auto-hide sidebar* row now unticks (back to
  always shown) instead of setting auto-hide again, and right-clicking the
  edge of a revealed auto-hide sidebar opens that same divider menu.
- Esc in Settings now puts the sidebar back too: a width previewed on the
  *Tree width* row no longer stays on screen after the cancel, and a width
  set by hand comes back.
- Vim `]a` / `[a` (with a count) now step through the Claude Code and Codex
  sessions from a terminal pane's T-NORMAL mode too, as they do from an
  editor; before, `]` was dropped and the `a` went back to TERMINAL.
- Git mode's sidebar (a fifth of the window) now re-sizes when the window
  does, instead of keeping the width it snapped to.
- *Set width…* answers a share over 100% (`150%`) with the allowed range in
  cells, as it does for any other width out of range.
- HTTP: a request whose URL, headers or body name a `{{VAR}}` no env
  defines is no longer sent. The Response box (titled `✗ not sent`) and a
  toast name each variable and where to define it — `unresolved {{jira}} —
  no env defines it; add it to .mnml/env/<env>.env or pick an env` — where
  the literal braces used to reach the URL parser and fail as
  `InvalidFormat`. `mnml run` and `chain run` warn in the same words.
- HTTP: the request pane's Env chip reads `no env` when the workspace has no
  env file, instead of claiming `dev`, and its picker offers `+ New env…`.
  A selection whose file is gone — `[http] default_env`, `default_env=` in
  `.rqst/config`, `$MNML_ENV`, or a pick whose file was deleted — is dropped
  rather than shown.
- HTTP: the Response box's Body, Headers and Timeline tabs, and the request
  Body editor, show the shared scrollbar when their rows overflow, on their
  own column beside the text; a press on the Response bar's track jumps
  there.

## v0.3.1

mnml 0.3.1 is a fix release for the Jira and Bitbucket integrations, with
what landed on the editor since 0.3.0 alongside it.

### Jira and Bitbucket 0.2.1 — the gzip fix

- The reason for this release. Jira and Bitbucket compress their answers
  when the client offers it, and both integrations handed the compressed
  bytes to the JSON parser: every Jira pane said "the search answer was not
  JSON", and Bitbucket's panes failed the same way. The body is now read
  through the answer's content-encoding, as mnml's own HTTP client already
  does.
- A parse failure names what it saw: the read error that cut the body
  short, or the content-type, the size and the first bytes.
- This release's `integrations.json` offers Jira 0.2.1 and Bitbucket 0.2.1.
  An installed 0.2.0 reads *update available* in the Marketplace tab.

### Sessions

- Session cycling: `ai.focus_next_session` / `ai.focus_prev_session`
  (`ctrl+alt+pagedown` / `ctrl+alt+pageup`, `]a` / `[a` in a vim editor,
  with a count) step through every Claude Code and Codex pane — splits,
  stacked tabs, other tab pages and the bottom dock — with a `‹ 3/7 ›` on
  each session's tab strip and on the statusline's new sessions chip.
- The Claude and Codex chip menus open a session in a new tab or on a new
  tab page, and a worktree profile's session lands there too once its
  branch name is answered.

### The frame

- The launcher dock can live on the command line's own row:
  `ui.dock.placement = .shared` (`:dock shared`, or *on command line* in
  Settings) puts its items on the `:` row, always up with no grip and no
  extra row. Typing never moves them; they step aside only while a long
  command would reach them.
- The tree draws its connectors on every row below the top level —
  folders and files, a `│` while a sibling follows and a `└` on the last
  child — in the comment grey, so they can be seen.
- The tree's workspace dot (`ui.show_workspace_dots`) marks the active
  workspace with `●` and every other root with `○`, instead of sitting on
  the primary for good; a click on a dot switches to that workspace,
  and the rest of the header still folds. An extra root's *Switch to this
  workspace* switches directly instead of opening the picker. Removing the
  active root hands the dot, open, back to the primary.
- *About* prints the build's own version, not a fixed `0.3.0`.

### Integrations on the top bar

- The top bar's integration chips sit three cells apart, the same rhythm as
  the right-panel toggle beside them, instead of five.
- A newly installed integration — from the Marketplace, a local folder, a
  launcher or a shell `<binary> --install` — starts off the top bar; its
  menu's *Show on top bar* puts it there, and a reinstall or update keeps
  what you chose. Browser keeps its chip.
- An integration's rebuild chip is no longer hidden by the host rewriting
  its manifest.

### Testing

- The Jira and Bitbucket tests, and the corpus files for both panes, run
  against a fake site that compresses its answers.
- The tour and the drive harness launch mnml with the update check off, so
  a newer release on GitHub no longer changes every screenshot.
- A corpus file for session cycling and one for the shared dock.

### The website

- mnml.sh: the home page, downloads read from the latest release, the
  docs — install, getting started, configuration and its option
  reference, features, Lua, integrations — the release notes, and nine
  short recordings of mnml at work.

## v0.3.0

mnml 0.3.0 is the same editor, rewritten in Zig 0.16.0. One static binary per
platform, no runtime, and the shared `.test` corpus as the definition of
parity (every file at 120x40; the 80x24 and 200x60 sweeps check for panics,
leaks and rects outside their parent). Everything below is what the 0.2.x user notices; the
architecture behind it is in `docs/DESIGN.md`.

### The editor

- The core: a `String` buffer and a byte cursor behind one `apply` chokepoint;
  vim and standard keymaps as two complete profiles that never leak into the
  render layer. Undo groups, registers, marks, macros, dot-repeat.
- Multi-cursor — every cursor types, deletes, selects and puts. Visual block
  yanks and deletes the rectangle. Surround (`ys` / `ds` / `cs`), align,
  `ctrl+a` / `ctrl+x`, `gq` reflow, `gcc` comment toggle, the `[` `]` pairs, the
  section / method / TODO jumps.
- A save writes the file's terminating newline.
- Incremental tree-sitter highlighting for 43 grammars, compiled in. Spans
  slide with the text as you type; the reparse waits for idle. Language
  injection (fenced code, `<script>` / `<style>`), predicates and roles.
- Sticky context: the enclosing scope's header pinned above the viewport.
  Text objects, the symbol outline, the rendered markdown preview, snippets
  with tab stops that track the text.
- Open files are stat'ed every 2 s — a clean buffer reloads, a dirty one is
  warned.

### The frame

- Splits, tab pages, per-leaf strips, the statusline, the editor scrollbar
  and pin, drag-to-resize dividers and tabs, click-count selection, the wheel
  batch, right-click menus, overlays, the palette — the Rust frame, cell for
  cell.
- The 94 NvChad base46 palettes as ZON, derived into every UI role at compile
  time. `theme.pick` previews as you move; toggle, reset, follow-the-OS.
- The first-launch wizard — eight sections, Enter writes only what was
  touched; the last offers Jira and Bitbucket as checkboxes that install on
  the spot, with a Private integrations row under them. The settings overlay — sectioned rows, the file follows the row.
- Build-artifact directories stay hidden in the tree without a `.gitignore`.
- A pane that opens beside another sizes itself by what is already there:
  the first one takes an empty editor area whole, the third makes thirds and
  the fourth quarters, and a stack inside one of the columns keeps its own
  proportions. Integrations, terminals and session panes all follow the one
  rule now. `integrations.arrange = .fixed` — a row under Integrations in the
  settings overlay — puts back the old half-the-active-pane sizing.

### Config — ZON, not TOML

- `config.zon` beside your `config.toml`; mnml 0.3.0 never touches the TOML.
  Run `mnml export-config-zon` on 0.2.22 once to convert. Three layers (user,
  workspace, defaults), a typed schema, `Patch(T)` merges derived at compile
  time, `persistScalar` splices one value back into the file with a backup.
- Workspace trust is decided at load and asked once.
- Two profiles, so one machine can run the mnml you live in and the mnml you
  are working on. `MNML_PROFILE=dev` (or `--profile dev`) moves the data root
  to `~/.config/mnml-dev`, the session file to `.mnml/session-dev.zon`, the
  IPC mailbox and the running-instance marker to their own names, and paints
  a `dev` chip on the statusline with a matching window title. The first dev
  launch seeds itself from your stable setup — config, integration manifests
  and configs, launchers, themes — and never copies a credential, a cache or
  a session; `mnml profile` says which one you are in and `mnml profile seed
  --force` copies again.
- `docs/CONFIG.md` is the complete commented `config.zon`, and a test parses
  it.

### Panes

- `Pane.pty` — a shell or command in a split, painted from the libghostty-vt
  grid. `cargo` / `npm` / `pytest` / `go` runners and `test.*` in a pty pane,
  the tools picker, configured tasks (`task.run`, `task.<name>`, `:task`,
  startup tasks).
- Git: status, diff, blame, graph, staging — every call on a worker, results
  posted back as one event. Gutter marks and blame labels on the editor. One
  `Repo` per repository, a job queue, the one-hunk patch writer.
- Git, line by line: select rows in the diff pane (`v`, shift+arrows, a drag)
  and stage, unstage, discard, stash or commit just those lines — the same
  selection for the keys, the chips, the row menu and the palette. `t`
  cycles the diff view now that `v` selects.
- Git, conflicts: a conflicted file resolves in the editor. The status pane
  lists it under `⚠ Conflicts`, enter opens it with every block tinted and a
  row of chips above it (`Ours · Theirs · Both · Edit · Split · AI resolve`);
  vim `co` / `ct` / `cb` and `]x` / `[x`, standard `alt+1..3` and `f8`;
  `Split` shows ours against theirs in the diff pane; saving with no marker
  left stages the file.
- LSP: one stdio JSON-RPC transport shared with DAP. Diagnostics, completion,
  hover, peek, navigation, rename, formatting, code actions, symbols.
- DAP: breakpoints, watches, the debug and REPL panes, the `dap.*` commands. A
  scripted adapter in process drives the whole session under test.
- AI: ghost text, the agentic loop on the confirm channel, Claude Code and
  Codex panes, every `ai.*` runner, the Claude Agents dashboard (sessions
  across workspaces, filters, pause chip, live tail, kill), the 24 h spend
  report and the statusline meter.
- HTTP: `Pane.request` — the tabbed request pane, the send worker, the
  `http.*` commands. The request parser, envs, cookie jar, JWT decoding, SSE,
  a JSON-schema subset, HAR and Postman import, the captured log, chains,
  bench, mocks, history. `Pane.websocket` (a WebSocket client by hand) and
  `Pane.browser` (the CDP wire layer). The CLI: `run`, `chain run`,
  `discover` (JSON and a YAML subset), `sync`, `sync-check`, `proxy`.
- HTTP, beyond 0.2.x: an env file edited on disk reloads on its own
  (a toast says so); COLLECTIONS lists a multi-block file's `###`
  blocks and renames, duplicates, deletes and moves a request or a
  block from the row menu; `http.find_request` (`ctrl+shift+r`,
  `<leader>hr`) is a fuzzy picker over every block of every file;
  `:id` path segments take their `# @path id=…` value on send and get
  a `Path` group on the Params tab; the Body tab has a mode chip —
  raw, JSON (formatted on send), form-urlencoded, multipart with
  `name = @file` parts — that round-trips through curl's `-F` and
  `--data-urlencode`; `# @description` shows under the URL and
  `# @tags` feed the filter (`tag:smoke`) and the picker.
- The TODOS panel, and the reference module behind it — scan worker,
  snapshot, commands, panel, mouse — that every other panel is checked
  against.

### Integrations and the Marketplace

- Integrations are back, on the v2 bridge and the Zig SDK: each one is
  released on its own `<id>-v<version>` tag, and every mnml release carries
  `integrations.json`, the index the Marketplace tab reads by default. A row
  is listed only when its SDK is compatible and it was built for your
  platform; an install checks the sha256 before anything is written.
- `marketplace.add_source` (the palette, the tab's `+ source` chip, the tab
  strip's menu) adds a folder or `owner/repo[:dir]`, or a pasted GitHub repo
  URL — `https://github.com/owner/repo`, the same without the scheme, with a
  trailing `.git`, `…/tree/<branch>/<dir>` (the branch is dropped, the folder
  kept) or `git@github.com:owner/repo.git`. Any other URL is refused by name.
- A source already added is found under another spelling — the repo's case,
  the folder's case, a symlink — instead of being added twice. Adding a
  source while the Marketplace is disabled is refused before `config.zon` is
  written. A folder just added lists at once, not when the slowest source
  answers.
- An integration row built on an older SDK wears a `rebuild` chip; one whose
  source folder is gone wears `old SDK` instead and is not rebuilt. A
  rebuild toasts the SDK its fresh manifest is stamped with.
- A refresh or a quit no longer waits out a running install.
- Jira and Bitbucket poll adaptively, write an event feed, and share one
  rate-limit budget across windows and processes. The state file is the
  first of `<SERVICE>_RATELIMIT_STATE`,
  `$MNML_SHARED_STATE_DIR/<service>-ratelimit.json`,
  `<MNML_DATA_ROOT>/ratelimit/<service>.json`,
  `~/.config/mnml/ratelimit/<service>.json`.
- `MNML_OPEN_URL` decides whether a URL reaches the browser, for the host and
  every integration: unset or empty opens it, `none` drops it, any other
  value is a file the URL is appended to instead. A `.test` run logs to a
  file and `--headless` defaults to `none`, so neither opens a browser.

### Fixes and polish since 2026-09-20

- `--headless --ascii` paints the ASCII screen, as the terminal does.
- The update check and the Nerd Fonts release fetch run only from the
  terminal loop — never under `--headless`, a `.test` run or a unit test.
- A workspace with nothing to distrust is trusted without a prompt; an
  adapter added to its config later goes through the trust dialog.
- Vim: dozens of Neovim-parity fixes — counts on `n` / `N`, `D`, `C`, `j` /
  `k` under an operator; `u` and `gv` after Visual operators; case changes
  and word motions over non-ASCII and CJK text; `whichwrap`-style `h` / `l`;
  `&` / `g&`; Visual `p` and `"x`; puts setting `'[` / `']`; the "N fewer
  lines" message past `'report'`; an underline cursor while an operator
  waits. `:jumps`, `:changes`, `:display` and `:setlocal et / noet / wrap /
  nowrap` are new, and `:term` opens in the focused leaf.
- In the standard profile `Ctrl+N` asks for the new file's path from any
  focus, and `Ctrl+Shift+S` is Save As. `F3` / `Shift+F3` search from the cursor with the find bar open or
  closed. Typing over a selection is one undo stop.
- A shell pane's bash and fish mark their prompts (OSC 133, OSC 7), and a
  device-attributes query is answered.
- Windows: paths spell one way everywhere — the tree, SEARCH, TODOS, notes,
  LSP URIs, the HTTP panel — and installs, uninstalls, the bridge socket and
  `cmd.exe` command lines behave as on macOS and Linux.
- The statusline measures its chips in cells and never ends a lane on a
  dangling powerline arrow; chips of equal priority lay out by id.
- Restart outside `run.sh` relaunches mnml instead of quitting.

### Testing

- `mnml test` runs the shared `.test` corpus headlessly on a
  `DebugAllocator` with safety on; a leak fails the file. `--gate` runs the
  52-file Phase-0 set, `--sizes 80x24,120x40,200x60` sweeps the widths, and
  `--shard I/N` runs one of N disjoint slices of the corpus.
- Every unit test runs on `std.testing.allocator`. Leak = failure. The suite
  runs in Debug and ReleaseSafe; every PR cross-compiles the exe and every test
  binary for all five shipped targets.

### Shipping

- Five targets from one runner — `aarch64-apple-darwin`,
  `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`,
  `aarch64-unknown-linux-gnu`, `x86_64-pc-windows-gnu` — all ReleaseSafe, all
  `-Dcpu=baseline`. `.tar.xz` (`.zip` on Windows) with a `.sha256` each,
  `sha256.sum`, `mnml-installer.sh`, `mnml-installer.ps1`, an MSI for winget,
  `.deb` / `.rpm`, a Homebrew tap bump. Asset names drop the `-rs`:
  `mnml-<triple>.tar.xz`.
- `--version` prints the tag and the profile it would run in; a dev build
  prints the manifest version, the git short SHA and `-dirty`.

### Not in 0.3.0 (pin 0.2.x if you need one)

- The 0.2.x integrations other than Jira and Bitbucket — each comes back
  when it is rewritten on the v2 bridge and the SDK.
- Local FIM completion (ghost text uses Claude Code, the Claude API or
  Copilot), brotli, WebP, the glyph-builder SVG
  preview.
