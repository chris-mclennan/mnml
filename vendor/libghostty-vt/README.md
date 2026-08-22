# vendored libghostty-vt (build scripts + retired prebuilt notes)

**Note (2026-08-22):** the C headers moved into the sys crate for
crates.io self-containment — they now live at
`crates/mnml-libghostty-vt-sys/vendor/include/`. Only the historical
build/prebuilt scripts + this README remain at the workspace root.

The `.a` files + pkg-config plumbing were retired 2026-08-02 when the
pinned ghostty commit bumped past the 0.2.1 pin and the 0.1.0-dev
prebuilts on GitHub Releases went stale against the new headers. Same
day, the pin bumped again to origin/main HEAD to pick up the July 25-26
upstream Windows static-lib linking fixes (ghostty PRs #13452, #13473)
— those require zig 0.16.0.

## How the library gets built now

`crates/mnml-libghostty-vt-sys/build.rs` clones ghostty at `GHOSTTY_COMMIT` (currently
`6837d7027…`, kept in lock-step with the headers here) and runs `zig build
-Demit-lib-vt` on every target. Needs zig 0.16.0 + git on PATH.

Empirically zig 0.16.0 links fine on macOS 26 for ghostty at this commit —
the earlier "cannot link on macOS 26" workaround that motivated the
prebuilt path is no longer needed. If it ever regresses, the fix is either
a newer zig (waiting on ghostty to bump its pin) or reintroducing
cross-built prebuilts here.

## Regenerating headers

Whenever `GHOSTTY_COMMIT` bumps in `crates/mnml-libghostty-vt-sys/build.rs`, re-sync
the headers so bindgen sees the same shape as the compiled `.a`. The
headers live inside the sys crate — regen writes into the crate's
`vendor/include/`, not the workspace-root `vendor/libghostty-vt/`:

    git clone --filter=blob:none --no-checkout https://github.com/ghostty-org/ghostty.git /tmp/g
    (cd /tmp/g && git checkout <new-commit> -- include/ghostty/)
    rm -rf crates/mnml-libghostty-vt-sys/vendor/include/ghostty
    cp -R /tmp/g/include/ghostty crates/mnml-libghostty-vt-sys/vendor/include/

## Bringing prebuilts back (if needed)

If we ever want to skip the zig source-build on macOS/Linux (e.g. to
shorten CI first-build time), the shape lives in git history from before
2026-08-02: `pkgconfig-*/` dirs + a `fetch-prebuilts.sh` + per-target
`.cargo/config.toml` env blocks + the CI "Fetch libghostty-vt prebuilts"
step. Bringing them back requires cross-building the `.a` for each target
(the `build-*.sh` scripts here are the starting point but reference the
old ghostty commit) and uploading to a fresh GitHub release.
