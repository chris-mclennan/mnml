# Cutting a release

One tag, one runner, ~21 assets. This is the sequence, then the two traps
that have each cost the Rust repo a version number.

## The sequence

```sh
scripts/release.sh v0.3.0 --dry-run    # build + every check, no tag
scripts/release.sh v0.3.0              # the same, then `git tag -a v0.3.0`
git push origin v0.3.0                 # release.sh prints this; it never pushes
# … watch the Release workflow …
scripts/dist-check.sh v0.3.0           # count the assets. Green is not enough.
```

`release.sh` refuses a dirty tree (a dirty tree ships `-dirty` binaries),
refuses an existing tag, cuts CHANGELOG.md's top section as the notes and
scrub-checks it, runs `zig build dist -Dversion=X` for all five targets — the
exact command `release.yml` runs — and confirms this machine's packaged
binary prints the version.

What the tag push starts (`.github/workflows/`):

| workflow | runs on | produces |
|---|---|---|
| `release.yml` `build` | ubuntu | 5 archives + 5 `.sha256`, `sha256.sum`, `mnml-installer.sh`, `mnml-installer.ps1`, `dist-manifest.json`, `integrations.json` (the release index — see *Integrations*); creates the release with the notes |
| `release.yml` `msi` | windows | `mnml-x86_64-pc-windows-gnu.msi` + `.sha256` (WiX 5, from the zip) |
| `release.yml` `verify` | ubuntu | `dist-check.sh --min 17` — fails the run if the release is short |
| `package-linux.yml` | ubuntu ×2 | `mnml-{x86_64,aarch64}-unknown-linux-gnu.{deb,rpm}` (nfpm) |
| `bump-homebrew-tap.yml` | ubuntu | `Formula/mnml.rb` in chris-mclennan/homebrew-tap, from `dist/homebrew/mnml.rb` |
| `winget-releaser.yml` | ubuntu | a PR to microsoft/winget-pkgs for `ChrisMcLennan.mnml` |

The last three fire on `workflow_run` of Release, not `release: published` —
a release created with `GITHUB_TOKEN` inside a workflow does not emit the
`published` event (GitHub's anti-loop rule). They also accept
`workflow_dispatch` with a version, for a rerun.

Twenty-one assets when everything has run — 5 archives + 5 `.sha256`
(10), `sha256.sum` + two installers + `dist-manifest.json` +
`integrations.json` (15), the MSI + its `.sha256` (17), then `.deb` +
`.rpm` for two Linux arches (21). `scripts/dist-check.sh` carries that
list by name and fails on the first missing one; `release.yml`'s own
`verify` job runs it with `--min 17 --without-linux-packages`, because
package-linux has not run yet at that point.

## Integrations

Nothing is bundled in the mnml archive: it stays one binary per
platform. Each integration in `integrations/` ships on its own tag, and
every mnml release carries an index of the ones built for it.

**One integration, one tag.** `git tag -a jira-v0.2.0 && git push origin
jira-v0.2.0` runs `.github/workflows/release-integration.yml`: it builds
`integrations/jira/` in its own folder (`-j2`, ReleaseSafe,
`-Dcpu=baseline`) for the five targets and
`scripts/package-integration.sh` packages each —

| asset | what |
|---|---|
| `mnml-<id>-<rust-triple>.tar.xz` (`.zip` on Windows) | one directory, `mnml-<id>-<triple>/`, with the binary, the integration's README and the licenses |
| `<archive>.sha256` | `<hash>  <file>` |
| `sha256.sum` | every archive |
| `integration.json` | the same as data: id, version, the SDK version it was built on (`sdk/mnml-sdk/build.zig.zon`), the binary, and per target the asset's URL and sha256 |

Twelve assets; the workflow's `verify` job counts them. The tag's
version must be the integration's manifest version
(`integrations/<id>/manifest.zon`); `<version>-<pre>` (`sample-v0.1.0-test`)
publishes a prerelease. An integration release is never marked
*latest* — `releases/latest` is mnml's, and the installers read it.
`gh workflow run release-integration.yml -f id=jira` is the dry run
(`dry_run` defaults to true: the assets land on the workflow run, no
release); a pull request that touches the workflow or the packaging
script dry-runs `sample` on its own.

**The index.** `integrations/index.zon` lists the id and version of
each integration an mnml release offers (a unit test holds each version
to the folder's manifest). `release.yml` downloads each row's
`integration.json` from its `<id>-v<version>` release and
`tools/integrations_index.zig` joins them — with the label,
description, docs and chip from `data/marketplace.zon` — into
`integrations.json`, uploaded beside the archives. A publishing run
fails on a row whose release is missing, a release whose version is
not the row's, and one built on an SDK this mnml would not offer (the
same rule mnml applies: `mnml_sdk.compatible`, the same major and
below 1.0 the same minor). So the order for a release is:

```sh
# bump integrations/<id>/manifest*.zon (and data/marketplace.zon,
# integrations/index.zon) for each integration that changed, then:
git tag -a jira-v0.2.0 -m jira-v0.2.0 && git push origin jira-v0.2.0
git tag -a bitbucket-v0.2.0 -m bitbucket-v0.2.0 && git push origin bitbucket-v0.2.0
# … wait for both Release-an-integration runs …
scripts/release.sh v0.3.0 && git push origin v0.3.0
```

An integration whose code did not change keeps its row and its old
release, as long as its SDK is still compatible.

**What mnml does with it.** The Marketplace tab's default source is
`https://github.com/chris-mclennan/mnml/releases/download/v<its
version>/integrations.json` (`Config.default_marketplace_sources`; a dev
build has no release and skips it). A row is listed when its SDK is
compatible and it has an asset for this platform. Install downloads
the asset, refuses it unless its sha256 is the index's, writes the
binary to `<data root>/integrations/<id>/bin/`, links
`<data root>/bin/<binary>` at it and runs `<binary> --install`, which
writes the manifests; a newer version in the index makes the row
`update available`, and installing again is the update. The
first-launch setup offers Jira and Bitbucket from the same listing
(`docs/CONFIG.md`, "First launch"). `MNML_MARKETPLACE_INDEX=<url>`
points a session at any index — how a dev build installs from a
release.

## The symbols font

Every archive carries `share/mnml/fonts/MnmlSymbols.ttf` (built by `zig
build font` from `src/glyph/`), and the `.deb` / `.rpm` install it under
the prefix. Neither puts it in the user's font directory — nothing
should write there behind their back — so mnml falls back for its own
block until they do: the unfocused pty pane's hollow cursor paints `▯`
instead of `U+F2001`, and the tofu check names the rest. From a
checkout that step is `./run.sh install-font` — `.\run.ps1
install-font` on Windows, which also has to register the face under
HKCU, because a file alone is not an installed font there — and both
merge with whatever MnmlSymbols is already installed rather than
replacing it. A release note that changes what the face carries should
say so.

The MSI has no font step either, and Windows Terminal has no
font-fallback list, so a Windows user who installs from a release has
two manual steps left: point the profile's font face at a full
Nerd-Font-patched mono, and install MnmlSymbols per-user.
`docs/INSTALL-CHECKLIST.md` → *Windows 11* steps 2 and 4 are those two,
written out.

## The shipped names

`zig build release` (and so `dist`, and so every archive) builds with
`-Dinstall-names`: the stable profile's IPC mailbox is `<ws>/.mnml/ipc`
and its running-instance marker is `mnml-running-$USER.workspace` — a
shipped mnml is the one you live in, so it owns the plain names. This
repo's own builds keep `ipc-zig` / `mnml-zig-running-…` so a dev build
never finds a shipped instance, and `MNML_PROFILE=dev` takes those
names in any build (`docs/CONFIG.md`, "Profiles"). An explicit
`-Dipc-subdir` / `-Dmarker-prefix` still wins and is forwarded to the
per-target builds.

Installing a local build for daily use is not part of a release:
`./run.sh install` does that from a working tree — `.\run.ps1 install`
on Windows (`docs/CONTRIBUTING.md`, "Daily driver + development on one
machine"). A release is for everybody else.

Before a release that anyone will install on a clean machine, walk
`docs/INSTALL-CHECKLIST.md` for each OS the release ships for: it is
the per-OS first-run list — prerequisites, install, font, first launch,
a file, a terminal pane, quit-and-return — plus the UTM
pristine-snapshot routine the guests are kept on.

## Trap 1 — the CHANGELOG secret scrub

**Never write a credential-shaped literal in CHANGELOG.md.** Not an
`Authorization` header with its value spelled out, not a Slack-token prefix,
not an API-key prefix, not a token assignment with a quoted value — not even
an obviously fake one.

GitHub Actions replaces any substring that equals a stored repo secret with
`***` — everywhere in a job's output, including inside JSON. In the Rust repo
cargo-dist embedded the changelog in its plan manifest; a scrubbed line
corrupted the JSON, the build matrix failed to parse, the build jobs were
*skipped*, and the Release run reported **success** while shipping one file.
Twice: v0.2.9 and v0.2.18.

Here the notes are posted as the release body rather than embedded in a
manifest, so the same accident would corrupt the body instead of the build.
The scrub check runs anyway, in `release.sh` and again in `release.yml`
before anything is uploaded. The pattern lives in those two files (one
regex, case-insensitive): the bearer-header word followed by a space, the
two Slack token prefixes, an `sk-` key prefix with eight or more characters
after it, and a `token` assignment with a quoted value. This page is written
to pass it too — `grep -Ei` the pattern over `docs/` and expect no output.

Describe the shape in prose ("an auth header written as a `{{VAR}}`
reference").

## Trap 2 — a green run that shipped nothing

A workflow's conclusion says its jobs ran, not that the release has its
files. After every release:

```sh
gh release view vX.Y.Z --json assets --jq '.assets|length'   # want 21, not 1
scripts/dist-check.sh vX.Y.Z                                 # the same, by name
```

A tag that shipped short cannot be reused safely (`releases/latest/download`
already pointed at it; Homebrew and winget may have read it). Bump the patch
and re-cut — v0.2.9 → v0.2.10, v0.2.18 → v0.2.19.

## Dependencies

What mnml builds against is pinned, and nothing moves it automatically.
`.github/workflows/upstream-watch.yml` (Mondays 07:00 UTC, or by hand)
says each week what is behind and whether moving looks safe;
`tools/upstream-watch.sh` writes its report:

- **Pins** in `build.zig.zon`: ghostty (commits behind main, the pin's
  date), vaxis (the commit ghostty's own main pins for it), the
  tree-sitter grammars (crates.io's newest stable), Lua (the newest 5.4.x).
- **Zig**: the newest stable release against `minimum_zig_version` and
  the version `ci.yml` installs.
- **Actions** pinned by sha whose major tag has moved.
- **npm** in `site/` and `demo/cloudflare/`: outdated by major/minor/patch,
  `npm audit` by severity.
- **Upstream threads** mnml follows (ghostty discussions #13629 and
  #13460, the resize-redraw regression; the list is at the top of the
  script): state, comments, maintainer comments, labels.
- **Release channels**: the latest release against the Homebrew tap, the
  newest winget manifest, the version mnml.sh/download prints, and
  mnml.sh/demo answering — after a release, a disagreement here is a
  publish step that did not land.
- **This run's jobs**: mnml built against ghostty main, its terminal tests
  there (`pty-test`, and the app's `pty_*` tests), the resize repro
  (`tools/upstream/ghostty-resize-repro/`) against main — "FIXED
  upstream" means `keepCursorRow` in `src/pty/common.zig` can go — and,
  when a newer stable Zig exists, a build with it.

It writes to one issue here, labelled `upstream-watch`: the body is the
latest report, and a comment (the notification) is added only when
something that matters changed — a new version, a moved tag, a thread
that moved, a channel that disagrees, a job result. A pin falling further
behind main is not news by itself; the job results are. Nothing else is
written: no push, no pull request, no pin bump. `tools/upstream-watch.sh
--dry-run` prints the same report locally (read-only; npm is skipped
without `node_modules`), and `tools/upstream-watch-check.sh` tests its
parsing and its comment decision offline against
`tools/upstream/fixtures/`.

**A pin moves only by a deliberate branch** in a worktree, merged
through `tools/gate/` (`merge-batch.sh`) like any other change — never
a direct edit on `main`, never "just the zon".

- **ghostty** — `zig fetch --save=ghostty
  https://github.com/ghostty-org/ghostty/archive/<sha>.tar.gz`, then
  `zig build pty-test -Dtest-trace=true -Dtest-trace-live=true`, the
  app's terminal tests (`MNML_TEST_FILTER=.pty_ zig build unit
  -Dtest-trace=true`) and
  `tools/upstream/ghostty-resize-repro/check.sh main --main-sha <sha>`.
  If the repro says FIXED, drop `keepCursorRow` in the same branch and
  keep its tests. Move `ghostty_main` in the repro's own zon too.
- **vaxis** — take the `deps.files.ghostty.org/vaxis-<commit>` URL ghostty
  main pins (its `build.zig.zon`) and `zig fetch --save=vaxis <url>`; the
  TUI's tests (`zig build unit`) and a look at the real window.
- **a tree-sitter grammar** — `zig fetch --save=ts_<name>
  https://static.crates.io/crates/tree-sitter-<name>/tree-sitter-<name>-<version>.crate`,
  then `zig build highlight-test`; a grammar's node names change between
  versions, so read the highlight queries' failures, not just the count.
- **Lua** — `zig fetch --save=lua https://www.lua.org/ftp/lua-5.4.<n>.tar.gz`
  and `zig build unit`.
- **Zig** — one branch moves every place that names the version:
  `minimum_zig_version` in `build.zig.zon` (and the integrations' and the
  SDK's zons), `ZIG_VERSION` in `ci.yml`, `release.yml` and
  `release-integration.yml`, `tools/linux/Dockerfile`, `demo/Dockerfile`
  and `tools/shims/zig` (`git grep -F` the old version). The weekly
  zig-next job only says whether a plain `zig build` compiles; the gate
  is the whole chain.

## Versions

- `build.zig.zon`'s `.version` is the dev baseline (`0.3.2-dev`). It is not
  the tag; `-Dversion=` is, and `release.yml` passes the tag through. Bump
  it to the NEXT patch right after tagging, or every dev build between
  releases names the version already shipped.
- A prerelease tag (`v0.3.0-rc0`) creates a GitHub prerelease. The MSI's
  ProductVersion is numeric, so `build.ps1` strips the suffix to `0.3.0` for
  the installer database only.
- CHANGELOG.md's top heading should name the version being cut;
  `release-notes.sh` warns when it does not, and fails when the section is
  empty.

## First release on a new remote

Nothing here has run against GitHub yet. Before `v0.3.0`:

1. Repo secrets: `HOMEBREW_TAP_TOKEN` (fine-grained PAT, Contents read/write
   on chris-mclennan/homebrew-tap) and `WINGET_TOKEN` (Contents write on the
   chris-mclennan/winget-pkgs fork). Both exist for the Rust repo; copy them.
2. `gh workflow run release.yml -f version=0.3.0-rc0` — the dry run: the same
   build, artifacts on the workflow, no release created.
3. `scripts/release.sh v0.3.0-rc0` and push the tag. A prerelease; the tap
   and winget workflows will run against it, which is the point — fix them on
   an rc, not on 0.3.0.
4. `scripts/dist-check.sh v0.3.0-rc0`.
