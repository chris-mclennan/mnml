# Multi-pane siblings — design draft

**Status:** draft, 2026-06-27. For discussion before implementation.

## Problem

Today's Bridge / Mount protocol assumes one pane per sibling:
- Mount sibling: one manifest, one UDS socket, one frame stream
- Pty sibling: one Pty profile, one process

A sibling that wants two visual surfaces (master/detail, dashboard +
log tail, browser + console) has to either render both inside one
pane (manual internal split, ugly) or shell out to `OpenPty` tier-2
IPC to spawn a side Pty that mnml can't associate back with the
first pane.

Want to bake the multi-pane assumption into the protocol now so we
don't have to retrofit when richer integrations land. Examples that
benefit:

- A sibling like Datadog: pane A = service list, pane B = traces for
  the focused service. User clicks A → B updates.
- mnml-aws-lambda: pane A = function list, pane B = invocation log
  for the focused function.
- A debug sibling: pane A = breakpoint list, pane B = stack trace
  pane C = variable inspector.

## Non-goals

- Replacing the existing single-pane API. Single-pane stays the
  default; multi-pane is opt-in via the new fields.
- Allowing a sibling to render directly into mnml chrome (the rail,
  statusline, file tree). That's a different surface and needs
  separate protocol design — see TODO "rail widgets".
- Resizing siblings owning multiple top-level windows / tabs. One
  manifest = one connected pane group, full stop.

## Manifest extension

A manifest currently looks like:

```toml
id = "tattle_tests"
name = "Tattle tests"
binary = "mnml-tattle-tests"
icon = ""
color = "green"
```

For multi-pane, optional `[[panes]]` array:

```toml
id = "datadog"
name = "Datadog"
binary = "mnml-obs-datadog"

# When [[panes]] is present, the top-level `icon` / `color` are
# unused (or default-only) and each pane row owns its own icon.
# When [[panes]] is absent, behavior is unchanged from today.

[[panes]]
id = "services"
name = "Services"
icon = ""
color = "blue"
mode = "list"          # passed to binary as `--mode list`

[[panes]]
id = "traces"
name = "Traces"
icon = ""
color = "orange"
mode = "detail"        # passed as `--mode detail`
parent = "services"    # cleanup / close-with-parent semantics
```

`parent` is a soft link — closing pane A doesn't close pane B unless
`parent` is set. It's the manifest author's expression of "this pane
makes no sense without that one."

## Activity-bar layout

Each `[[panes]]` entry registers its own activity-bar icon. They
appear as a group under the manifest's name in a tooltip-revealed
expander, OR inline as N adjacent icons. Default: inline.
Manifest can override:

```toml
[ui]
grouping = "expander" | "inline"   # default inline
```

For 2-3 panes inline is fine. For 4+ the expander is more readable.

## Spawn semantics

Each pane click spawns the binary with `--mode <pane.mode>`. The
binary's process tree:

```
mnml
└─ mnml-obs-datadog --mode list   (pid 1234)
```

If the user clicks the second icon while the first is open, two
spawn shapes:

1. **Independent processes** (default). mnml spawns a fresh
   `mnml-obs-datadog --mode detail` (pid 5678). Two separate UDS
   sockets, two independent render loops. Sibling can choose to
   discover its peer via env (mnml passes `MNML_SIBLING_PEERS` =
   "list:/path/to/socket1,detail:/path/to/socket2") and communicate
   side-channel. mnml doesn't mediate.

2. **Multiplexed** (sibling opts in). Sibling sets `multiplex = true`
   in its manifest. When the second icon is clicked, mnml sends a
   tier-2 `OpenAdditionalPane { pane_id = "detail" }` message over
   the existing UDS. Sibling spawns a second render loop in-process
   (or returns a second frame stream). One process, two panes.

   Multiplex is power-mode for siblings that want tight coupling
   (real-time updates from list → detail). Costs the sibling extra
   complexity (running two render loops); mnml-side is simpler
   (one UDS to track).

## Cleanup

When the user closes a pane:

- If pane has no `parent` in the manifest and no other open panes
  share its UDS → kill the sibling process.
- If pane has a `parent` AND the parent pane is open → just close
  the child pane (sibling stays running).
- If pane is the parent AND children are open → close children
  first, then this pane, then kill the process.
- If sibling is multiplexed → just send `ClosePane { pane_id }`;
  sibling decides when to die.

Crash recovery: if the sibling process dies unexpectedly, mnml
closes all panes belonging to that sibling and toasts "X crashed".
If the sibling was multiplexed and one pane fails to render but
the process is alive (sibling-side error), mnml replaces the pane
content with "X failed to render (sibling reports error)" and
keeps the other panes running.

## New wire-protocol additions (`mnml-bridge`)

Additive, no breaking changes:

```rust
// New IPC variant — sibling asks mnml to open another pane
// "alongside" the current one. Used when the sibling itself
// wants to spawn a side Pty (analogous to OpenPty today but
// for Mount-protocol panes).
pub enum SiblingMessage {
    // ... existing variants ...

    /// Sibling-initiated: "spawn a companion Mount pane that
    /// renders for `mode`. The user can close it independently
    /// but if this pane closes, that one closes too."
    OpenChildPane { mode: String, label: String },
}

// New host message — mnml asks an already-running multiplexed
// sibling to start rendering a second pane in the same process.
pub enum HostMessage {
    // ... existing variants ...

    /// Host-initiated: user clicked an activity-bar icon for
    /// pane `pane_id`. Sibling should start its render loop for
    /// that pane and send Frame messages with the new pane id
    /// in the header.
    OpenAdditionalPane { pane_id: String },

    /// Host-initiated: user closed pane `pane_id`. Sibling
    /// should stop rendering it. May or may not exit the
    /// process — sibling's choice.
    ClosePane { pane_id: String },
}

// Existing Frame messages get a `pane_id` field. Default = the
// manifest's `id` (back-compat: single-pane siblings ship today's
// behavior unchanged).
pub struct Frame {
    pub pane_id: String,
    pub cells: Vec<Cell>,
    // ... existing fields ...
}
```

## Open questions

1. **Discoverable mode list**: how does mnml know which `mode`
   strings the sibling accepts? Manifest declares them — but no
   way for mnml to verify. Sibling could publish a schema in a
   `mnml-tattle-tests --modes` command that mnml calls during
   install to validate. Punt for v1.

2. **Pane ordering**: manifest order? User-rearrangeable? Punt to
   inline-only for v1; user-rearrangeable later if a sibling wants
   it.

3. **Layout hint**: should the manifest say "this pane prefers a
   horizontal split alongside its parent"? Layout policy is mnml's
   concern, not the sibling's — leave it to the user's split
   choices.

4. **Shared state vs independent**: should sibling panes share an
   in-process cache (multiplexed mode) by default? Different
   processes share via the sibling's choice of IPC (sockets, files,
   environment, …). Don't bake into mnml.

## Phased rollout

1. **v1** — manifest `[[panes]]` array + activity-bar registration
   for each. Each click spawns a fresh process (no multiplex).
   `parent` / cleanup semantics. No sibling-bridge changes; siblings
   already get `--mode <x>` argv routing.

2. **v2** — multiplex mode. Add `OpenAdditionalPane` /
   `ClosePane` HostMessages. Sibling opts in via `multiplex = true`.

3. **v3** — sibling-initiated `OpenChildPane` SiblingMessage.

Each phase is independently shippable.

## Sketch of v1 implementation

`src/mount_manifest.rs`:
- Parse optional `[[panes]]` array. Default to a single-entry array
  derived from top-level fields if absent.
- Validate `parent` references point at an existing pane entry.

`src/app/mod.rs`:
- `mount_manifests: Vec<MountManifest>` already exists. Iteration
  for activity-bar rendering becomes `for m in mount_manifests { for
  pane in m.panes() }`.
- `App::open_mount_pane(manifest_id, pane_id)` spawns the sibling
  with `--mode <pane.mode>`. Tracks the PaneId.
- `App::close_pane_id(pid)` — when closing a pane, also close any
  children where parent == pid.

Test coverage:
- Manifest with `[[panes]]` parses correctly.
- Each pane click spawns a new process.
- Closing parent closes children.
- Manifest with no `[[panes]]` still works (back-compat).
