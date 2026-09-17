# The Linux box the gate runs in. Nothing here is mnml-specific beyond the
# toolchain: a current Debian, the Zig the repo pins, and the handful of
# programs the .test corpus shells out to (git, /bin/sh, python3).
#
# Built and driven by tools/linux/run.sh — see docs/CONTRIBUTING.md,
# "Running the gate on Linux".
FROM debian:trixie-slim

ARG ZIG_VERSION=0.16.0

# `bash` because the repo's scripts are `#!/usr/bin/env bash`; `python3`
# because some .test shell steps call it; `git` because the corpus builds
# real repositories to drive the git panel against. fontconfig + the two
# font sets are what the glyph side of the gate needs to be honest: Noto
# for the text, Symbols Nerd Font for the icon codepoints.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates curl file fontconfig fonts-noto-core git less \
        procps python3 rsync tar unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Symbols Nerd Font Mono — the icon half of the glyph checks. Pinned, so a
# new nerd-fonts release cannot silently change what the container sees.
ARG NERD_FONTS_VERSION=v3.2.1
RUN set -eux; \
    curl -fsSL -o /tmp/nf.zip \
      "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONTS_VERSION}/NerdFontsSymbolsOnly.zip"; \
    mkdir -p /usr/local/share/fonts/NerdFonts; \
    unzip -q -o /tmp/nf.zip -d /usr/local/share/fonts/NerdFonts; \
    rm -f /tmp/nf.zip; \
    fc-cache -f >/dev/null

# Zig, from ziglang.org. 0.16.0 names its tarballs zig-<arch>-<os>-<ver>.
RUN set -eux; \
    ZARCH=$(uname -m); \
    case "$ZARCH" in \
      x86_64|aarch64) ;; \
      *) echo "unsupported arch $ZARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz"; \
    mkdir -p /opt/zig; \
    tar -C /opt/zig --strip-components=1 -xf /tmp/zig.tar.xz; \
    rm -f /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

# The build cache and the package cache are docker volumes, so a second run
# is incremental. ZIG_GLOBAL_CACHE_DIR keeps the ~800 MB of fetched
# dependencies out of the image layer.
ENV ZIG_GLOBAL_CACHE_DIR=/zig-global-cache \
    HOME=/root \
    TERM=xterm-256color \
    LANG=C.UTF-8
RUN mkdir -p /zig-global-cache /work

WORKDIR /work
COPY entrypoint.sh /usr/local/bin/mnml-linux-gate
RUN chmod +x /usr/local/bin/mnml-linux-gate
ENTRYPOINT ["/usr/local/bin/mnml-linux-gate"]
CMD ["all"]
