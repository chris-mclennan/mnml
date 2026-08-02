# vendored libghostty-vt (headers only)

Just the C headers under `include/ghostty/` remain here — the `.a` files +
pkg-config plumbing were retired 2026-08-02 when the pinned ghostty commit
bumped to `a887df42` (matches upstream `libghostty-vt-sys` 0.2.1) and the
0.1.0-dev prebuilts on GitHub Releases went stale against the new headers.

## How the library gets built now

`crates/mnml-vt-sys/build.rs` clones ghostty at `GHOSTTY_COMMIT` (currently
`a887df42…`, kept in lock-step with the headers here) and runs `zig build
-Demit-lib-vt` on every target. Needs zig 0.15.2 + git on PATH.

Empirically zig 0.15.2 links fine on macOS 26 for ghostty at this commit —
the earlier "cannot link on macOS 26" workaround that motivated the
prebuilt path is no longer needed. If it ever regresses, the fix is either
a newer zig (waiting on ghostty to bump its pin) or reintroducing
cross-built prebuilts here.

## Regenerating headers

Whenever `GHOSTTY_COMMIT` bumps in `crates/mnml-vt-sys/build.rs`, re-sync
the headers so bindgen sees the same shape as the compiled `.a`:

    git clone --filter=blob:none --no-checkout https://github.com/ghostty-org/ghostty.git /tmp/g
    (cd /tmp/g && git checkout <new-commit> -- include/ghostty/)
    rm -rf vendor/libghostty-vt/include/ghostty
    cp -R /tmp/g/include/ghostty vendor/libghostty-vt/include/

## Bringing prebuilts back (if needed)

If we ever want to skip the zig source-build on macOS/Linux (e.g. to
shorten CI first-build time), the shape lives in git history from before
2026-08-02: `pkgconfig-*/` dirs + a `fetch-prebuilts.sh` + per-target
`.cargo/config.toml` env blocks + the CI "Fetch libghostty-vt prebuilts"
step. Bringing them back requires cross-building the `.a` for each target
(the `build-*.sh` scripts here are the starting point but reference the
old ghostty commit) and uploading to a fresh GitHub release.
