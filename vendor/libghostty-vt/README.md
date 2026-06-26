# vendored libghostty-vt (cross-built prebuilt)

ghostty pins Zig 0.15.2, which **cannot link on macOS 26** (Darwin 25). So we
cross-build `libghostty-vt.a` from Linux (Zig is a cross-compiler) and link the
prebuilt via pkg-config — no Zig needed on macOS. `libghostty-vt-sys`'s
`pkg-config` feature (see Cargo.toml + .cargo/config.toml) consumes the .pc here.

## Where the .a files live

The static libs are **not** tracked in git (3 targets × ~10-14MB = ~37MB
together — too big for the repo). They live on a GitHub release:

  <https://github.com/chris-mclennan/mnml/releases/tag/vendored-libghostty-vt-0.1.0>

To fetch them on a fresh clone (or after a `git clean`):

    ./vendor/libghostty-vt/fetch-prebuilts.sh

The script is idempotent — it skips files already present at the expected
size. CI runs it once before `cargo build`; `./run.sh` runs it on every
launch so you don't have to remember.

## Supported targets

| Target | Path | Built by |
|---|---|---|
| aarch64-apple-darwin | `lib-aarch64-darwin/libghostty-vt.a` | the original libghostty-vt port |
| x86_64-unknown-linux-gnu | `lib-x86_64-linux/libghostty-vt.a` | `build-linux-x86_64-from-arm64.sh` |
| aarch64-unknown-linux-gnu | `lib-aarch64-linux/libghostty-vt.a` | `build-aarch64-linux-from-arm64.sh` |

`.cargo/config.toml` picks the matching pkgconfig dir per host triple.

## Regenerating the .a files

Rare — only when ghostty bumps its pinned commit. From this directory:

    colima start  # ensure docker is available
    docker run --rm --platform linux/arm64 \
      -v "$PWD/out":/out -v "$PWD/build-<target>.sh":/build.sh:ro \
      debian:bookworm-slim bash /build.sh

The script downloads Zig 0.15.2 (linux aarch64), clones ghostty at the
pinned commit, runs `zig build -Demit-lib-vt=true -Dapp-runtime=none
-Demit-xcframework=false -Doptimize=ReleaseFast -Dcpu=baseline
-Dtarget=<target> --prefix /out`, then writes the .a to `out/lib/`.

After regenerating, upload to the release and bump the script's expected-size
constants:

    gh release upload vendored-libghostty-vt-0.1.0 \
      out/lib/libghostty-vt.a#libghostty-vt-<target>.a --clobber

## Roadmap

This is a BRIDGE until ghostty adopts Zig 0.16 (which links on macOS 26);
then drop the prebuilt + pkg-config feature and let the crate build from
source.
