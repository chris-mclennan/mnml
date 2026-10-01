# The web demo's image: a real `mnml --demo` behind ttyd, with the attract
# runner (demo/attract/attract.py) in front. Built by demo/build.sh, which
# hands docker the repository's tracked files as the context (the legacy
# builder has no per-Dockerfile ignore file, and zig-pkg/ + .zig-cache/
# are gigabytes). Architecture-agnostic: whatever `uname -m` the build
# runs on (aarch64 on an Apple-silicon Mac, x86_64 on most hosts).
#
# Network is used only here, at build time (apt, Zig, the fonts, the Zig
# packages). The running container needs none: run it with
# `--network none` and reach it through a published port (demo/README.md).

ARG DEBIAN=debian:trixie-slim

# ── 1. build mnml, the two fakes, the two integrations, the symbols font ──
# BUILDER may name an image that already has Zig 0.16 on PATH (demo/build.sh
# passes the repo's Linux gate image when this machine has it: ziglang.org
# can be slow); on plain Debian the tarball is fetched.
ARG BUILDER=debian:trixie-slim
FROM ${BUILDER} AS build
ARG ZIG_VERSION=0.16.0
RUN command -v zig >/dev/null || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils && rm -rf /var/lib/apt/lists/*; }
RUN set -eux; \
    if command -v zig >/dev/null; then zig version; exit 0; fi; \
    ZARCH=$(uname -m); \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz"; \
    mkdir -p /opt/zig; tar -C /opt/zig --strip-components=1 -xf /tmp/zig.tar.xz; rm -f /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; zig version
ENV ZIG_GLOBAL_CACHE_DIR=/zig-global-cache
ENTRYPOINT []
WORKDIR /src
# The packages first, on their own layer: it is rebuilt only when
# build.zig.zon (or the checkout's zig-pkg/, which demo/build.sh sends
# when it has one — it may be empty) changes, so editing a source file
# does not re-download ~800 MB. A stub build.zig is enough for `--fetch`.
COPY build.zig.zon /src/
COPY zig-pkg /src/zig-pkg
RUN printf 'pub fn build(_: *@import("std").Build) void {}\n' > build.zig \
    && zig build --fetch && rm build.zig
# Only what the build reads, so editing demo/ never rebuilds the app.
COPY build.zig /src/
COPY src /src/src
COPY sdk /src/sdk
COPY integrations /src/integrations
COPY data /src/data
COPY docs /src/docs
COPY themes /src/themes
COPY tools /src/tools
COPY vendor /src/vendor
COPY lua /src/lua
ARG MNML_VERSION=demo
RUN zig build -Doptimize=ReleaseSafe -Dinstall-names -Dversion=${MNML_VERSION} --prefix /out \
    && ls -la /out/bin /out/share/mnml/fonts \
    && rm -rf /src/.zig-cache /zig-global-cache/*

# ── 2. the web fonts (JetBrains Mono, Symbols Nerd Font Mono, MnmlSymbols),
#       ttyd, and the binaries stripped ──
FROM ${DEBIAN} AS fonts
ARG NERD_FONTS_VERSION=v3.2.1
ARG JETBRAINS_MONO_VERSION=2.304
ARG TTYD_VERSION=1.7.7
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        binutils ca-certificates curl unzip woff2 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /fonts
RUN set -eux; \
    curl -fsSL -o /tmp/nf.zip "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/NerdFontsSymbolsOnly.zip"; \
    unzip -q -o /tmp/nf.zip -d /tmp/nf; cp /tmp/nf/SymbolsNerdFontMono-Regular.ttf .; \
    curl -fsSL -o /tmp/jb.zip "https://github.com/JetBrains/JetBrainsMono/releases/download/v${JETBRAINS_MONO_VERSION}/JetBrainsMono-${JETBRAINS_MONO_VERSION}.zip"; \
    unzip -q -o /tmp/jb.zip -d /tmp/jb; \
    for s in Regular Bold Italic BoldItalic; do cp /tmp/jb/fonts/webfonts/JetBrainsMono-$s.woff2 .; done; \
    cp /tmp/nf/LICENSE ./LICENSE-NerdFontsSymbols 2>/dev/null || true; \
    cp /tmp/jb/OFL.txt ./LICENSE-JetBrainsMono.txt 2>/dev/null || true; \
    rm -rf /tmp/nf /tmp/jb /tmp/*.zip
# ttyd is not in Debian trixie: its static release build, per arch.
RUN set -eux; \
    curl -fsSL -o /ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.$(uname -m)"; \
    chmod +x /ttyd; /ttyd --version
# ReleaseSafe keeps its safety checks; the debug info is not needed to
# run, and is most of the binary's size.
COPY --from=build /out/bin/mnml-zig /out/bin/mnml-jira /out/bin/mnml-bitbucket \
     /out/bin/mnml-fake-jira /out/bin/mnml-fake-bitbucket /bin-stripped/
RUN strip --strip-debug /bin-stripped/* && ls -la /bin-stripped
COPY --from=build /out/share/mnml/fonts/MnmlSymbols.ttf /fonts/
RUN woff2_compress SymbolsNerdFontMono-Regular.ttf && woff2_compress MnmlSymbols.ttf \
    && rm -f *.ttf && ls -la

# ── 3. the runtime ───────────────────────────────────────────────────────
FROM ${DEBIAN}
# git: the demo makes its workspace's history at start. zsh: the demo's
# prompt (`tour %`). bash: the stand-in `claude` / `codex`. vim-tiny: the
# terminal flow opens `vi`. ttyd: the web terminal. python3: the attract
# runner. Nothing else, and no network at run time.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash git less python3 tini vim-tiny zsh \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man
RUN useradd --create-home --shell /bin/zsh --uid 1000 demo \
    && mkdir -p /run/mnml-demo && chown demo:demo /run/mnml-demo
COPY --from=fonts /bin-stripped/ /opt/mnml/bin/
COPY --from=build /out/share /opt/mnml/share
# The curated Lua script set a packaged build lists from share/mnml/lua.
COPY --from=build /src/lua /opt/mnml/share/mnml/lua
RUN ln -s /opt/mnml/bin/mnml-zig /usr/local/bin/mnml
COPY --from=fonts /ttyd /usr/local/bin/ttyd
COPY demo/attract /opt/mnml-demo/attract
COPY demo/flows /opt/mnml-demo/flows
COPY demo/web /opt/mnml-demo/web
COPY --from=fonts /fonts /opt/mnml-demo/web/fonts
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color COLORTERM=truecolor \
    SHELL=/bin/zsh MNML_IPC_DIR=/tmp/mnml-demo/ipc \
    MNML_DEMO_PORT=7681 MNML_DEMO_CAP_S=600 MNML_DEMO_IDLE_S=180
USER demo
WORKDIR /home/demo
EXPOSE 7681
ENTRYPOINT ["/usr/bin/tini", "--", "python3", "/opt/mnml-demo/attract/attract.py"]
