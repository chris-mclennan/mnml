# vendored libghostty-vt (cross-built prebuilt)

ghostty pins Zig 0.15.2, which **cannot link on macOS 26** (Darwin 25). So we
cross-build `libghostty-vt.a` from Linux (Zig is a cross-compiler) and link the
prebuilt via pkg-config — no Zig needed on macOS. `libghostty-vt-sys`'s
`pkg-config` feature (see Cargo.toml + .cargo/config.toml) consumes the .pc here.

The `.a`/`.dylib` are gitignored (binaries). Regenerate for aarch64-macos:

    colima start
    docker run --rm --platform linux/arm64 \
      -v "$PWD/out":/out -v "$PWD/build.sh":/build.sh:ro \
      debian:bookworm-slim bash /build.sh
    # build.sh: download Zig 0.15.2 (linux aarch64), clone ghostty@<commit>,
    #   zig build -Demit-lib-vt=true -Dapp-runtime=none -Demit-xcframework=false \
    #     -Doptimize=ReleaseFast -Dcpu=baseline -Dtarget=aarch64-macos --prefix /out
    # then copy out/{include,lib} here.

This is a BRIDGE until ghostty adopts Zig 0.16 (which links on macOS 26); then
drop the prebuilt + pkg-config feature and let the crate build from source.
