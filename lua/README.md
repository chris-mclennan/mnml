# The scripts that ship with mnml

The curated Lua set lives here, in the repo, the way the official
integrations live in `integrations/` and the official launchers in
`launchers/`. There is no separate `mnml-scripts` repo to clone and no
index to fetch: the SCRIPTS section's **Marketplace** tab lists this
folder out of the box, on a fresh data root, with no config at all.

| script | the shape it is the whole of |
|---|---|
| `git-blame-line/` | decorations + a hidden task |
| `eslint/` | a tool wrapper into the diagnostics sink |
| `recent-commands/` | a live picker source with a preview column |
| `todo-list/` | a rail section fed by `mnml.list{}` |
| `surround-word/` | a text operation registered as an operator |

Each is a directory — `script.zon`, `init.lua`, `README.md`, optionally
`lib/*.lua` — and each is driven by a `.test` that runs the file **as it
is written** (`tests/e2e/lua_example_*.test`), so a change that breaks
one fails the suite. `docs/LUA.md`'s Recipes chapter is these five.

## How the binary finds this folder

`src/app/scripts.zig`'s `shippedRoot`, in order:

1. `build_options.scripts_dir` — this folder's absolute path, baked in
   at build time, so a dev build lists the set straight away;
2. `<exe dir>/../share/mnml/lua` — `/usr/bin/mnml` with
   `/usr/share/mnml/lua`, the layout `nfpm/mnml.yaml` lays down for the
   `.deb` and the `.rpm`;
3. `<exe dir>/share/mnml/lua` — the layout `scripts/package.sh` puts in
   the `.tar.xz` and the Windows `.zip`, beside the binary;
4. `<exe dir>/mnml-data/lua` — the portable directory
   (`src/config/data_root.zig`).

`scripts.marketplace_local` in the config, and `MNML_SCRIPTS_MARKETPLACE`
in the environment, each point the tab at a folder of your own instead;
the environment wins. Anything else a user installs — a git URL, an
archive, a folder — lands in `<data root>/scripts/` and is badged
`community`, `private` or `dev` rather than `official`.

## Adding one

A script belongs here when it is the clearest example of a shape, small
enough to read in one sitting (under 80 lines is the bar the design set),
and covered by a `.test`. Anything larger or more niche is a community
script the user installs by URL.

Set `.source = .marketplace` in its `script.zon` — that is what badges
the row `official` — and declare every command and hook it registers:
the trust dialog shows those claims before the first run, so a manifest
that under-declares reads as dishonest the first time someone opens
`script.doctor`.
