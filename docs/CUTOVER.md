# Cutover day

The day mnml-zig becomes `chris-mclennan/mnml`: its history becomes that
repo's `main`, the Rust history moves to a new archived
`chris-mclennan/mnml-rust` with its releases re-created there, and the
0.2.x branches, tags and releases leave the main repo. The mnml release
stays one binary per platform; the integrations ship on their own
`<id>-v<version>` tags, and the mnml release carries an
`integrations.json` index that refuses to publish without them.

Every step below is a command and the check that proves it landed. A
green workflow is not a check — count the assets (`docs/RELEASE.md`,
Trap 2). Nothing here is run by an agent; each step is the operator's.

The names used throughout:

```sh
MAIN=chris-mclennan/mnml          # the repo that stays
RUST=chris-mclennan/mnml-rust     # the new archive
ZIG=chris-mclennan/mnml-zig       # where the Zig history lives today
V=0.3.0                           # the mnml tag, v$V
WORK=~/cutover-$(date +%Y%m%d)    # scratch: mirrors, release assets, lists
mkdir -p "$WORK"
```

## Why the order is what it is

The integration tags go before the mnml tag, because `release.yml`
refuses to publish an mnml release whose `integrations.json` rows have no
release behind them. Both go **after** the repo swap, because everything
a release writes names the repo it was built in: the `integrations.json`
asset URLs, the Homebrew formula's URLs, the winget manifest, and the
`releases/latest` that the installers and every 0.2.x update toast read.
A 0.3.0 cut on `mnml-zig` and moved afterwards would carry `mnml-zig`
URLs forever. The 0.2.x releases leave the main repo **last**, after
0.3.0's tap bump, because until then `brew install mnml` resolves to a
0.2.x asset URL on the main repo.

## 0. The days before

**0.1 — the checklist on the Zig tree.**

```sh
cd <a clean clone of $ZIG>, on main
tools/cutover-check.sh --tag v$V --final-repo $MAIN
```

Expect `todo` on `integrations` until step 5 (the releases do not exist
yet) and on `targets` / `version-build` without `--build`; every other
line must be `ok`. The ones that are `FAIL` on the tree as it is today
each need a change merged first:

- `old-repo` — README's install lines, `dist/install.sh` and
  `dist/install.ps1`'s default `MNML_REPO`, the MSI's about-URL,
  `data/marketplace.zon`'s docs links, the info view's issue link, and
  the marketplace index URL (`Config.default_index_url`, once the
  integration-release track lands) must say `$MAIN`. The check prints
  each line.
- `integrations` / `dist-check` — the integration-release track
  (`integrations/index.zon`, `release-integration.yml`, the 21-asset
  `dist-check.sh`) must be on main.

Then, once, the slow half:

```sh
tools/cutover-check.sh --tag v$V --build --final-repo $MAIN
```

`targets` builds the five targets; `version-build` builds ReleaseSafe
with `-Dversion=$V` and reads `--version` back.

**0.2 — the dry runs on `$ZIG`.** Nothing is published:

```sh
gh workflow run release.yml --repo $ZIG -f version=$V-rc0
gh workflow run release-integration.yml --repo $ZIG -f id=jira
gh workflow run release-integration.yml --repo $ZIG -f id=bitbucket
gh run list --repo $ZIG --limit 3      # all three green
```

Check: each run's artifacts hold the archives (`gh run view <id> --repo
$ZIG` lists them).

**0.3 — the "0.2.22" string.** The new app tells a 0.2.x user to run
`mnml export-config-zon` from **0.2.22** (`src/app.zig`,
`src/app/discovery.zig`, the toast test, CHANGELOG.md). If the final
Rust release ends up as 0.2.23 (step 1 shipped short and was re-cut),
change those strings before step 6.

**0.4 — a mirror of the main repo.** The rollback for everything below:

```sh
git clone --mirror https://github.com/$MAIN.git "$WORK/mnml-rust.git"
gh release list --repo $MAIN --limit 500 --json tagName --jq '.[].tagName' > "$WORK/rust-releases.txt"
git -C "$WORK/mnml-rust.git" tag > "$WORK/rust-tags.txt"
git -C "$WORK/mnml-rust.git" rev-parse main > "$WORK/rust-main.sha"
wc -l "$WORK"/rust-*.txt               # 25 releases, 34 tags on 2026-09-26
```

`rust-releases.txt` and `rust-tags.txt` are the lists step 9 deletes by —
never a pattern. Step 2.0 refreshes all three once 0.2.22 exists.

## 1. The final Rust release, 0.2.22

From the Rust tree (`$MAIN` as it still is). 0.2.22 is the one that ships
`mnml export-config-zon`, and its README, crate description and release
notes say the project moved. Its `repository` metadata can point at
`$RUST` once step 2.1 has created the repo.

The Rust repo's own rules apply here (its CLAUDE.md, "Cutting a
release"): the CHANGELOG gets no credential-shaped literal — describe
the shape in prose — because cargo-dist embeds it in its manifest and a
scrubbed line ships a release with one file.

```sh
# crates.io: merge release-plz's release PR for 0.2.22 — it publishes
# mnml-rs 0.2.22 and tags mnml-rs-v0.2.22
gh pr list --repo $MAIN --search "release-plz"            # merge the 0.2.22 one
cargo search mnml-rs --limit 1                            # mnml-rs = "0.2.22"

# binaries: the cargo-dist tag
git tag -a v0.2.22 -m "mnml 0.2.22" && git push origin v0.2.22
gh release view v0.2.22 --repo $MAIN --json assets --jq '.assets|length'   # 22, not 1
```

Check: `cargo install mnml-rs --version 0.2.22 --root "$WORK/cargo" &&
"$WORK/cargo/bin/mnml" export-config-zon --help` runs. The tap bump
(`brew info chris-mclennan/tap/mnml` says 0.2.22) and the winget PR
follow as they always have.

If 0.2.22 shipped short: bump to 0.2.23 and re-cut (never re-push a tag),
then step 0.3.

## 2. The Rust archive, `mnml-rust`

**2.0 — refresh the mirror and the lists.** 0.2.22 added a release, a
tag or two and commits since step 0.4; without this, step 2 would leave
them out of the archive and step 9 would leave them on `$MAIN`.

```sh
git -C "$WORK/mnml-rust.git" remote update --prune
gh release list --repo $MAIN --limit 500 --json tagName --jq '.[].tagName' > "$WORK/rust-releases.txt"
git -C "$WORK/mnml-rust.git" tag > "$WORK/rust-tags.txt"
git -C "$WORK/mnml-rust.git" rev-parse main > "$WORK/rust-main.sha"
grep -x v0.2.22 "$WORK/rust-releases.txt" "$WORK/rust-tags.txt"     # both files
```

**2.1 — the repo, the history, the tags.**

```sh
gh repo create $RUST --public --description "mnml 0.2.x, the Rust version — archived. mnml lives at github.com/$MAIN"
git -C "$WORK/mnml-rust.git" push https://github.com/$RUST.git 'refs/heads/main:refs/heads/main' 'refs/tags/*:refs/tags/*'
```

Check: `git ls-remote --tags https://github.com/$RUST.git | wc -l` equals
`wc -l < "$WORK/rust-tags.txt"`; `git ls-remote https://github.com/$RUST.git
main` equals `cat "$WORK/rust-main.sha"`.

**2.2 — the releases, re-created with their assets.**

```sh
while read -r t; do
  d="$WORK/assets/$t"; mkdir -p "$d"
  gh release download "$t" --repo $MAIN --dir "$d" --clobber || true
  gh release view "$t" --repo $MAIN --json body --jq .body > "$d.notes"
  title=$(gh release view "$t" --repo $MAIN --json name --jq .name)
  gh release create "$t" --repo $RUST --verify-tag --title "$title" \
      --notes-file "$d.notes" --latest=false $(ls "$d"/* 2>/dev/null)
done < "$WORK/rust-releases.txt"
gh release edit v0.2.22 --repo $RUST --latest
```

Check, per release — the same count on both sides:

```sh
while read -r t; do
  a=$(gh release view "$t" --repo $MAIN --json assets --jq '.assets|length')
  b=$(gh release view "$t" --repo $RUST --json assets --jq '.assets|length')
  [ "$a" = "$b" ] || echo "SHORT: $t main=$a rust=$b"
done < "$WORK/rust-releases.txt"      # prints nothing
```

**2.3 — archive it.** `gh repo archive $RUST --yes`. Check: `gh repo view
$RUST --json isArchived --jq .isArchived` is `true`.

## 3. Switch off the Rust release machinery on the main repo

release-plz publishes to crates.io on every push to `main`. The Zig
history has no `release-plz.yml`, so the swap alone would stop it — but
do not rely on the push that replaces `main` being evaluated against the
new tree.

```sh
gh workflow disable release-plz.yml --repo $MAIN
gh variable delete RELEASE_PLZ_ENABLED --repo $MAIN
gh secret delete CARGO_REGISTRY_TOKEN --repo $MAIN
gh pr list --repo $MAIN --state open                      # close every Rust PR:
gh pr close <n> --repo $MAIN --delete-branch              # release-plz, dependabot, …
```

Check: `gh variable list --repo $MAIN` has no `RELEASE_PLZ_ENABLED`;
`gh secret list --repo $MAIN` has no `CARGO_REGISTRY_TOKEN` and still has
`HOMEBREW_TAP_TOKEN` and `WINGET_TOKEN` (the Zig workflows read those —
`tools/cutover-check.sh`'s `secrets` item); `gh pr list --repo $MAIN` is
empty. The other Rust-era secrets (signing, newsletter, sibling checkout)
nothing in the Zig workflows reads; delete them or leave them.

## 4. The swap: `main` ← the Zig history

No force-push. The Zig history goes up as a new branch, becomes the
default, the old `main` is deleted, and the new branch is renamed:

```sh
git clone https://github.com/$ZIG.git "$WORK/zig" && cd "$WORK/zig"
git push https://github.com/$MAIN.git main:refs/heads/zig-main
gh repo edit $MAIN --default-branch zig-main
git push https://github.com/$MAIN.git --delete main
gh api -X POST repos/$MAIN/branches/zig-main/rename -f new_name=main
```

Branch protection on `main`, if any, has to allow the delete for the
minute it takes; put it back after.

Then the other Rust branches (`git ls-remote --heads
https://github.com/$MAIN.git`): `windows-compat`, the `release-plz-*` and
`dependabot/*` leftovers — each is in the mirror and in `$RUST` already
if it matters:

```sh
git push https://github.com/$MAIN.git --delete windows-compat   # and so on
```

Checks:

```sh
gh api repos/$MAIN --jq .default_branch                          # main
git ls-remote https://github.com/$MAIN.git refs/heads/main       # the Zig main SHA
git -C "$WORK/zig" rev-parse main                                # the same
git ls-remote --heads https://github.com/$MAIN.git               # main only
```

From here work in a clone of `$MAIN`. `$ZIG` can be archived with a
pointer to `$MAIN` once step 7 is done.

## 5. The integration tags

One per `integrations/index.zon` row, each at the version that row names
(a unit test holds them to the manifests). From a clean clone of `$MAIN`
on `main`:

```sh
for t in jira-v0.2.0 bitbucket-v0.2.0 sample-v0.1.0; do    # = index.zon's rows
  git tag -a "$t" -m "$t" && git push origin "$t"
done
gh run list --repo $MAIN --workflow release-integration.yml --limit 3   # wait for all green
for t in jira-v0.2.0 bitbucket-v0.2.0 sample-v0.1.0; do
  echo "$t $(gh release view "$t" --repo $MAIN --json assets --jq '.assets|length')"
done                                                        # 12 each
```

Check: `tools/cutover-check.sh --tag v$V` now says `integrations  ok`.
An integration release is never *latest*; `gh release list --repo $MAIN`
still shows v0.2.22 as Latest here, and that is right.

## 6. The mnml tag

```sh
tools/cutover-check.sh --tag v$V --build     # every line ok, exit 0
scripts/release.sh v$V --dry-run
scripts/release.sh v$V                       # tags locally; prints the push
git push origin v$V
gh run watch --repo $MAIN $(gh run list --repo $MAIN --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

`release.yml`'s own `verify` job counts 17 (it runs before the Linux
packages exist). When `package-linux.yml` is done too:

```sh
gh release view v$V --repo $MAIN --json assets --jq '.assets|length'   # 21, not 1
scripts/dist-check.sh v$V                                              # by name, and opens one archive
gh api repos/$MAIN/releases/latest --jq .tag_name                       # v0.3.0
```

`releases/latest` is what `mnml-installer.sh` / `.ps1` download from and
what every 0.2.x update check asks, so the last line is the moment the
0.2.x toasts start.

## 7. The follow-ups — tap, winget, Linux packages

All three run on `workflow_run` of Release (a release created by
`GITHUB_TOKEN` emits no `published` event); each also takes
`workflow_dispatch -f version=$V` for a rerun.

```sh
gh run list --repo $MAIN --limit 6          # bump-homebrew-tap, winget-releaser, package-linux: green
```

- **Homebrew.** `gh api repos/chris-mclennan/homebrew-tap/contents/Formula/mnml.rb
  --jq .content | base64 -d | grep -E 'version|download/'` shows `$V`
  and `$MAIN` URLs. On a Mac: `brew update && brew upgrade mnml && mnml
  --version` prints `$V`.
- **winget.** `WID=$(sed -n 's/^ *identifier: //p'
  .github/workflows/winget-releaser.yml)`, then `gh pr list --repo
  microsoft/winget-pkgs --search "$WID $V"` shows the PR. It merges on
  Microsoft's time; `winget show "$WID"` says `$V` after that.
- **Linux packages.** The four `.deb` / `.rpm` are among the 21 above.
  On a guest (`docs/INSTALL-CHECKLIST.md`): `sudo apt install
  ./mnml-x86_64-unknown-linux-gnu.deb && mnml --version`.
- **The curl / irm installers**, on a clean guest: README's two lines
  install `$V` from `$MAIN`.
- **The marketplace**: a fresh 0.3.0 lists Jira and Bitbucket from
  `https://github.com/$MAIN/releases/download/v$V/integrations.json`;
  installing one downloads its asset (the first-launch wizard's section
  8 does the same).

## 8. The 0.2.x update toast

A 0.2.x install asks `api.github.com/repos/$MAIN/releases/latest` once per
launch and toasts when the tag is newer. Check it for real, on a machine
or guest with a 0.2.x install (0.2.21 from the tap before step 7, or
`cargo install mnml-rs --version 0.2.21 --root "$WORK/old"`):

- launch it: the toast names v0.3.0, with the hint for its channel —
  `brew upgrade mnml` for Homebrew (right), a release-page link for an
  app bundle (right), and `cargo install mnml-rs` for a cargo install,
  which reinstalls 0.2.22, not 0.3.0: a cargo user reads the 0.2.22
  moved notice and the 0.3.0 notes for the real path.
- before upgrading, on 0.2.22: `mnml export-config-zon` writes
  `config.zon` beside `config.toml`.
- after upgrading: 0.3.0 reads the `.zon`; with a `config.toml` and no
  `config.zon`, the first launch toasts the conversion once per data root
  (`ui.config_toml_notice_shown`), and `:messages` repeats it every
  launch.

## 9. The 0.2.x tags and releases leave the main repo

Only after step 2's counts matched and step 7's tap bump is in — until
then `brew install` for anyone on the old formula resolves to a v0.2.x
asset on `$MAIN`.

```sh
while read -r t; do
  gh release delete "$t" --repo $MAIN --cleanup-tag --yes
done < "$WORK/rust-releases.txt"
while read -r t; do
  git push https://github.com/$MAIN.git --delete "refs/tags/$t" 2>/dev/null
done < "$WORK/rust-tags.txt"
```

Checks:

```sh
gh release list --repo $MAIN               # v0.3.0 and the integration releases only
git ls-remote --tags https://github.com/$MAIN.git | grep -c 'v0\.2\.'      # 0
gh release list --repo $RUST --limit 500 | wc -l      # = wc -l < "$WORK/rust-releases.txt"
```

Old winget manifests and old Homebrew formula commits point at v0.2.x
URLs on `$MAIN`, and those now 404; the current tap and the winget PR
point at `$V`. The re-created copies are on `$RUST` for anyone who needs
a 0.2.x binary.

## 10. After

- `tools/cutover-check.sh --tag v$V` on `$MAIN`: every line `ok`.
- The site: `site.yml` on `$MAIN` is the Zig one now; its first run is
  green and the published pages point at `$MAIN`.
- `$ZIG`: archive it with a description pointing at `$MAIN` (`gh repo
  edit $ZIG --description "…"; gh repo archive $ZIG --yes`), or delete it
  once nothing links to it.

## Rollback

**A tag shipped no binaries, or short.** Do not delete and re-push the
same tag, and do not reuse its number: `releases/latest/download` has
already pointed at it, and the tap and winget may have read it. Say so
in its notes (`gh release edit v$V --notes "Shipped incomplete — use
v0.3.1."`), bump the patch — CHANGELOG heading and all — and re-cut:
v0.3.0 → v0.3.1, as the Rust repo did twice (v0.2.9 → v0.2.10, v0.2.18 →
v0.2.19). The same holds for 0.2.22 (→ 0.2.23, then step 0.3).

**An integration release shipped short.** Bump that integration's patch
(`integrations/<id>/manifest.zon`, `integrations/index.zon`, and
`data/marketplace.zon` if it names the version), merge, tag
`<id>-v<new>`. If the mnml tag is not out yet, carry on at step 6. If it
is, its `integrations.json` points at the short release: cut the next
mnml patch after the new integration release is green.

**`release.yml` refused to publish.** The index check found a row with
no release, a version mismatch, or an SDK this mnml would not offer. The
mnml tag has built nothing public; fix the row or the integration
release, then bump the mnml patch and tag again — the refused tag is
burned like any other.

**The swap went wrong before step 6.** The Rust `main` is in the mirror
and in `$RUST`: push `$(cat "$WORK/rust-main.sha")` from the mirror as a
new branch, make it the default, delete the broken `main`, rename — step
4 in reverse. Tags and releases have not been touched until step 9.

**After step 9.** The mirror (`$WORK/mnml-rust.git`), the downloaded
assets (`$WORK/assets/`) and `$RUST` hold everything that was removed;
re-creating a 0.2.x release on `$MAIN` is step 2.2 with the repos
swapped.
