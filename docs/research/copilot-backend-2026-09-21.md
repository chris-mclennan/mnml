# GitHub Copilot as a second ghost-text backend

2026-09-21. Design + protocol verification for `ai.suggest_backend = .copilot`.

Today ghost text has one backend family (`claude-code` / `claude-api`,
`src/ai/suggest.zig` + `src/app/ai.zig`). Copilot is the second, because
many people already pay for it — or have the free tier — and would
rather that key than a second one. The whole feature is **off until a
workspace opts in**: no buffer text leaves the machine through Copilot
until the user says so *for that workspace*.

## 1. What the protocol actually is, and how it was verified

Source: `@github/copilot-language-server` **1.548.0**, pulled with
`npm pack` into `.scratch/` (never installed, never started with
`--stdio`). Two artefacts were read:

- `package/README.md` — GitHub's own integration contract. The
  quotations below are from it.
- `package/dist/main.js` — the shipped bundle. Used to *confirm* the
  README and to settle the places where the README is incomplete. Greps
  below cite what was found.

`--help` was attempted (`node dist/language-server.js --help`) and is
useless: the bundle prints its own source, not a usage banner. So the
README + the bundle are the sources of record.

### 1.1 Confirmed, and coded against

| Message | Direction | Shape | Confirmed by |
|---|---|---|---|
| `initialize` | → | `params.initializationOptions.editorInfo = {name, version}`, `.editorPluginInfo = {name, version}`; `workspaceFolders`; `capabilities.workspace.workspaceFolders` | README "Initialization" (worked example) |
| `initialized` | → | "the second message the client must send" | README |
| `workspace/didChangeConfiguration` | → | `{settings: {http: {...}, telemetry: {...}, "github-enterprise": {uri}}}` | README "Configuration Management" |
| `textDocument/didOpen` / `didChange` / `didClose` | → | LSP 3.17, **incremental sync required** | README "Text Document Synchronization" |
| `textDocument/didFocus` | → | `{textDocument: {uri}}`, or `{}` for nothing focused | README "Text Document Focusing" |
| `textDocument/inlineCompletion` | → req | `{textDocument: {uri, version}, position, context: {triggerKind}, formattingOptions: {tabSize, insertSpaces}}` — `textDocument.version` and `formattingOptions` are **non-standard additions** | README "Inline Completions"; `"textDocument/inlineCompletion"` ×2 in `main.js` |
| ↳ result | ← | `{items: [{insertText, range, command}]}` | README |
| `textDocument/didShowCompletion` | → | `{item: <the whole item>}` | README; `"textDocument/didShowCompletion"` in `main.js` |
| `textDocument/didPartiallyAcceptCompletion` | → | `{item, acceptedLength}` — length **in UTF-16 code units**, measured **from the start of `insertText`**, not the length of the newly-accepted piece | README (explicit) |
| `workspace/executeCommand` | → req | the item's own `command` verbatim, **after** the accept. Copilot uses it for acceptance telemetry | README; `"github.copilot.didAcceptCompletionItem"` in `main.js` |
| `didChangeStatus` | ← notif | `{busy: bool, message: string, kind: "Normal"|"Error"|"Warning"|"Inactive", command?: Command}` | README; and in `main.js`: `sendNotification("didChangeStatus",{busy,kind,message,command})` |
| `signIn` | → req | → `{status: "AlreadySignedIn", user}` **or** `{status: "PromptUserDeviceFlow", userCode, verificationUri, expiresIn, interval, command}` | `main.js` `handleSignInInitiateChecked`, see §1.2 |
| `signOut` | → req | | `t.set("signOut", Gio)` in `main.js` |
| `$/cancelRequest` | → notif | "strongly encouraged to eagerly cancel completion requests" | README "Cancellation" |
| `window/logMessage`, `window/showMessageRequest`, `window/showDocument` | ← | | README |

### 1.2 Where the README is wrong/incomplete — settled from the bundle

The README's `signIn` example shows only

```json
{"userCode": "ABCD-EFGH", "command": {"command": "github.copilot.finishDeviceFlow", ...}}
```

which reads as "there is no verification URI; just execute the command
and a browser opens". The bundle says otherwise. `signIn` and
`signInInitiate` are bound to **the same handler**
(`t.set("signInInitiate",p7r), t.set("signIn",p7r)`), and that handler is:

```js
async function yYc(t,e,r){                       // handleSignInInitiateChecked
  const o = await t.get(_r).checkAndUpdateStatus({githubAppId:r.githubAppId});
  if (o.status === "OK") return [{status:"AlreadySignedIn", user:o.user}, null];
  const c = await t.get(z1).initiate(r);
  return [{ status:"PromptUserDeviceFlow",
            userCode: c.user_code,
            verificationUri: c.verification_uri,
            expiresIn: c.expires_in,
            interval: c.interval,
            command: {command: Rht, title:"Sign in with GitHub", arguments:[]} }, null];
}
var p7r = Se(AYc, yYc);
```

with `var Rht = "github.copilot.finishDeviceFlow"`. So:

- **`verificationUri` IS returned** (`https://github.com/login/device`).
  mnml shows the code *and* the URL, and offers to open it — the README's
  "execute the command and it opens a browser for you" path assumes a
  GUI editor. A terminal editor must be able to print the URL.
- `status` is `"AlreadySignedIn"` or `"PromptUserDeviceFlow"`; the grep
  finds exactly one literal of each.

The other three names the brief guessed at all **exist**, but are not
what the modern flow needs:

- `signInConfirm` — `handleSignInConfirmChecked` in the bundle. It
  belongs to the *old* two-step agent flow (`signInInitiate` then
  `signInConfirm` with the user code). The current server polls for the
  token itself inside `initiate` (`waitForAuth`, a `do…while` over the
  device-code endpoint) and reports the result through
  `didChangeStatus`. **mnml does not call `signInConfirm`.** It executes
  `github.copilot.finishDeviceFlow` (which the bundle's
  `FinishDeviceFlowCommand` resolves against the server's own
  `pendingSignIn`) and waits for the status notification.
- `checkStatus` — exists,
  `params {options?: {localChecksOnly?, forceRefresh?}}`, result
  `{status: "OK"|"NotSignedIn"|"NotAuthorized", user?}` (all three
  literals present). mnml calls it **once** after `initialized`, to know
  whether it is signed in before the first keystroke; after that
  `didChangeStatus` is the live source.
- `statusNotification` — the **v1** notification, still sent alongside
  `didChangeStatus` with a different shape (`{busy, kind, status,
  message}`, where `kind` becomes `"InProgress"` when busy). There is
  also `didChangeStatus/v2`. mnml reads `didChangeStatus` (v1-era name,
  the shape the README documents) and **ignores** the other two.

Not confirmed anywhere, so **not coded against**: any polling loop the
client drives itself, and any `verificationUri` on `signInConfirm`.

### 1.3 Deliberately out of scope for v1

Named here so the cut is on the record, not discovered later:

- `textDocument/copilotInlineEdit` (Next Edit Suggestions) — a
  *different* surface: edits away from the cursor, with deletions. mnml's
  ghost surface is insert-at-cursor. Would need its own UI.
- `textDocument/copilotPanelCompletion` — needs a panel; mnml has none
  for this.
- `textDocument/reportCachedInlineEdit` — only applies to a client-side
  edit cache, which v1 does not have.
- `window/showMessageRequest` — answered with the first action or `null`
  (the README calls support "essential" for billing notices); v1 surfaces
  the message as a toast and does not offer the buttons.
- `getCompletions` / `getCompletionsCycling` / `notifyShown` /
  `notifyAccepted` — the legacy pre-LSP agent API. Superseded by
  `textDocument/inlineCompletion`.

## 2. Privacy — the actual design

The requirement: *"can it be set to a private mode"*, default **off**.

Four gates, all of which must pass before one byte of buffer text is
serialised into a Copilot frame. `src/ai/copilot.zig`'s `Gate.decide`
is the single place they live, it returns a **typed reason**, and every
caller (didOpen, didChange, didFocus, inlineCompletion) goes through it.

1. `ai.suggest_backend == .copilot`. Any other value and the client is
   never even spawned.
2. **The workspace opted in**: `ai.copilot_here = true` in
   `<ws>/.mnml/config.zon`. Default `false`. Scoped to that workspace —
   there is no key that turns Copilot on for workspaces in general.
3. **The workspace is trusted.** `ai.copilot_here` is added to the
   `config/trust.zig` `exec_bearing` table under a new sink,
   `copilot_share`. That table is what an untrusted workspace layer is
   stripped against, so a repo you cloned cannot ship a
   `.mnml/config.zon` that opts *you* in: the key is removed, the
   RESTRICTED chip stands, and the trust dialog lists
   "send this workspace's text to GitHub Copilot — when you type" as a
   claim you have to accept by name. `ai.copilot.command` is in the same
   table (sink `copilot_server`) because it is an argv.
4. **The file is not excluded.** `ai.copilot.exclude` globs, defaulting
   to `.env*`, `*.pem`, `*.key`, `id_*`, plus:
   - everything `src/ai/suggest.zig`'s existing `isSecretBearing` already
     keeps home (it guards the Claude backends; Copilot inherits it), and
   - **anything gitignored**, matched with the same `app/gitignore.zig`
     `globMatch`/`Rules` the tree and grep use. Build output and local
     `.env.local`s are ignored for a reason.

A file blocked by (4) is *also* never `didOpen`'d — not opened-then-not-
completed. The fake server's log is what proves it (tests §4).

`ai.copilot.command` never auto-downloads anything. Default resolution:
`copilot-language-server` on `PATH`; nothing else. `npx --yes
@github/copilot-language-server --stdio` is documented as a thing the
user may *write into their config*, never something mnml runs on its own.
A missing binary is one toast naming the install line
(`npm i -g @github/copilot-language-server`), the backend marks itself
unavailable, and no further attempts are made that session.

## 3. Shape of the code

```
src/ai/copilot.zig      pure: Gate, exclusion globs, argv default, item→ghost,
                        status kinds, utf-16 acceptedLength. No App. Unit-tested.
src/copilot/client.zig  the wire: Transport (rpc/jsonrpc.zig) + Copilot's own
                        envelope. NOT lsp/client.zig — Copilot is not a language
                        server here; it registers no diagnostics, no caps.
src/app/copilot.zig     the app: spawn on demand, doc sync, request + cancel,
                        accept telemetry, sign-in, status → chip, the commands.
tools/fake_copilot/     the deterministic server the tests drive, with a --log.
```

`src/ai/suggest.zig` gains `Backend.copilot`; `local` keeps its migration
note. `src/app/ai.zig::fireSuggestion` gains one branch that hands off to
`app/copilot.zig` instead of starting a worker — everything else
(debounce, generation, the `ghost_chip` surfaces, Tab/`ctrl+→`/`ctrl+↓`)
is shared, unchanged.

Positions are **UTF-16** (LSP's default; Copilot declares no
`positionEncoding`). `acceptedLength` is UTF-16 code units from the start
of `insertText`, per the README.

Multi-line items are supported: the ghost surface already renders a
multi-line suggestion and `ctrl+↓` takes one line of it.

Process spawn is `rpc/jsonrpc.zig`'s `Transport.spawn`, the same path the
LSP client and the debug adapter use — no unix-only calls, so Windows and
Linux work the way the LSP client does.

## 4. What the tests pin

A fake Copilot server (`tools/fake_copilot/`, reached through
`$MNML_FAKE_COPILOT` the way `$MNML_FAKE_LSP` is) implements
`initialize`, `checkStatus`, `signIn`, `didChangeStatus`,
`textDocument/inlineCompletion` with one canned item, and
`workspace/executeCommand` — and **records every method it receives** to
`--log`, one per line. The log is the assertion surface: an absence is
provable.

1. backend `.copilot`, workspace **not** opted in → the log contains no
   `didOpen`, no `didChange`, no `inlineCompletion`. (The server is not
   even spawned; the test asserts the log file is absent/empty.)
2. opted in, an excluded file (`.env.local`) → typing sends nothing.
3. opted in, an ordinary file → typing yields the canned ghost text, Tab
   accepts it, `workspace/executeCommand` reaches the fake.
4. signed-out status shows on the chip (`copilot · signed out`) and
   `ai.copilot_sign_in` puts the device code + URL on screen.
5. `ai.copilot.command` naming a binary that does not exist → one toast
   with the install line, no crash, no silent no-op.

Every one of these is break-checked: the break is grepped for in the file
*after* patching (a `zig fmt` reflow has silently dropped a break here
before), the suite is run, and the file is restored from a scratch copy —
never `git checkout`.
