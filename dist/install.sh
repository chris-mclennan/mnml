#!/bin/sh
# mnml installer — downloads the release archive for this machine, checks
# its sha256, and puts `mnml` on your PATH.
#
#   curl --proto '=https' --tlsv1.2 -LsSf https://github.com/chris-mclennan/mnml/releases/latest/download/mnml-installer.sh | sh
#
# Environment:
#   MNML_VERSION       a tag without the v (0.3.0); default: the latest release
#   MNML_INSTALL_DIR   where the binary goes; default: ~/.local/bin
#   MNML_REPO          owner/repo on GitHub; default: chris-mclennan/mnml
#   MNML_BASE_URL      full URL of the release's asset directory. Overrides
#                      MNML_REPO + MNML_VERSION — for mirrors and for testing
#                      the script against a local directory served over HTTP.
#
# Flags do the same: --version V, --dir D, --repo R, --base-url U, --help.
#
# Plain POSIX sh: no bash, no arrays, no local. Runs under dash, busybox ash,
# macOS's /bin/sh and zsh's sh mode.
set -eu

repo=${MNML_REPO:-chris-mclennan/mnml}
version=${MNML_VERSION:-}
install_dir=${MNML_INSTALL_DIR:-"$HOME/.local/bin"}
base_url=${MNML_BASE_URL:-}

usage() {
    sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || cat <<EOF
mnml installer
  --version V    a tag without the v; default: latest
  --dir D        install directory; default: ~/.local/bin
  --repo R       owner/repo; default: chris-mclennan/mnml
  --base-url U   asset directory URL (overrides --repo/--version)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) version=$2; shift 2 ;;
        --version=*) version=${1#--version=}; shift ;;
        --dir) install_dir=$2; shift 2 ;;
        --dir=*) install_dir=${1#--dir=}; shift ;;
        --repo) repo=$2; shift 2 ;;
        --repo=*) repo=${1#--repo=}; shift ;;
        --base-url) base_url=$2; shift 2 ;;
        --base-url=*) base_url=${1#--base-url=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "mnml installer: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say() { printf 'mnml: %s\n' "$*"; }
die() { printf 'mnml: error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

# ── this machine → a Rust triple ──
os=$(uname -s)
arch=$(uname -m)
case "$os" in
    Darwin) os_part=apple-darwin ;;
    Linux) os_part=unknown-linux-gnu ;;
    MINGW*|MSYS*|CYGWIN*) die "on Windows, run install.ps1 (irm … | iex) instead" ;;
    *) die "unsupported OS: $os (mnml ships macOS and Linux archives)" ;;
esac
case "$arch" in
    x86_64|amd64) arch_part=x86_64 ;;
    arm64|aarch64) arch_part=aarch64 ;;
    *) die "unsupported architecture: $arch (mnml ships x86_64 and aarch64)" ;;
esac
if [ "$os_part" = unknown-linux-gnu ] && [ ! -e /lib/ld-linux-x86-64.so.2 ] && [ ! -e /lib/ld-linux-aarch64.so.1 ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
    say "warning: no glibc loader found — the -gnu build may not run here (musl? try building from source)"
fi
triple="$arch_part-$os_part"
asset="mnml-$triple.tar.xz"

# ── where to fetch from ──
if need curl; then
    fetch() { curl --proto '=https' --tlsv1.2 -fsSL -o "$2" "$1"; }
    fetch_any() { curl -fsSL -o "$2" "$1"; }
elif need wget; then
    fetch() { wget -q -O "$2" "$1"; }
    fetch_any() { wget -q -O "$2" "$1"; }
else
    die "need curl or wget"
fi
# Local mirrors (http://127.0.0.1) cannot satisfy --proto '=https'.
case "$base_url" in http://*) fetch() { fetch_any "$@"; } ;; esac

if [ -z "$base_url" ]; then
    if [ -n "$version" ]; then
        base_url="https://github.com/$repo/releases/download/v${version#v}"
    else
        base_url="https://github.com/$repo/releases/latest/download"
    fi
fi

sha256() {
    if need sha256sum; then sha256sum "$1" | cut -d' ' -f1
    elif need shasum; then shasum -a 256 "$1" | cut -d' ' -f1
    elif need openssl; then openssl dgst -sha256 "$1" | sed 's/^.*= //'
    else die "need sha256sum, shasum or openssl to verify the download"
    fi
}

# ── download + verify ──
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mnml-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

say "downloading $base_url/$asset"
fetch "$base_url/$asset" "$tmp/$asset" || die "download failed: $base_url/$asset"
fetch "$base_url/$asset.sha256" "$tmp/$asset.sha256" || die "download failed: $base_url/$asset.sha256"
expected=$(cut -d' ' -f1 "$tmp/$asset.sha256")
actual=$(sha256 "$tmp/$asset")
[ "$expected" = "$actual" ] || die "sha256 mismatch for $asset
  expected $expected
  got      $actual"
say "sha256 verified"

# ── unpack + install ──
need tar || die "need tar"
if ! (cd "$tmp" && tar -xJf "$asset") 2>/dev/null; then
    need xz || die "need xz to unpack $asset"
    (cd "$tmp" && xz -dc "$asset" | tar -xf -) || die "could not unpack $asset"
fi
bin="$tmp/mnml-$triple/mnml"
[ -f "$bin" ] || bin=$(find "$tmp" -type f -name mnml | head -n 1)
[ -n "$bin" ] && [ -f "$bin" ] || die "archive did not contain a mnml binary"

mkdir -p "$install_dir" || die "cannot create $install_dir"
[ -w "$install_dir" ] || die "$install_dir is not writable (set MNML_INSTALL_DIR)"
# Copy beside, then rename: a running mnml keeps its old inode.
cp "$bin" "$install_dir/mnml.tmp.$$"
chmod 0755 "$install_dir/mnml.tmp.$$"
mv -f "$install_dir/mnml.tmp.$$" "$install_dir/mnml"
say "installed $("$install_dir/mnml" --version 2>/dev/null || echo mnml) to $install_dir/mnml"

# ── the demo's offline servers ──
# `mnml --demo` starts mnml-fake-jira and mnml-fake-bitbucket from the
# binary's own directory, so they go beside it. A failure here costs the
# demo its Jira and Bitbucket panes, not an install.
for fake in mnml-fake-jira mnml-fake-bitbucket; do
    src="$(dirname "$bin")/$fake"
    [ -f "$src" ] || continue
    if cp "$src" "$install_dir/$fake.tmp.$$" 2>/dev/null && chmod 0755 "$install_dir/$fake.tmp.$$" &&
        mv -f "$install_dir/$fake.tmp.$$" "$install_dir/$fake"; then
        say "installed $install_dir/$fake (the offline server mnml --demo starts)"
    else
        rm -f "$install_dir/$fake.tmp.$$" 2>/dev/null || true
        say "could not install $fake beside mnml (mnml --demo will open without it)"
    fi
done

# ── the curated Lua script set ──
# The archive carries it as share/mnml/lua beside the binary; mnml also
# looks one level up from its own directory, so ~/.local/bin/mnml finds
# ~/.local/share/mnml/lua. Ours, not the user's — installed scripts live
# under the data root — so an upgrade replaces it wholesale. A failure
# here costs an empty Marketplace tab, not an install.
lua_src="$tmp/mnml-$triple/share/mnml/lua"
if [ -d "$lua_src" ]; then
    share_dir=$(dirname "$install_dir")/share/mnml
    if mkdir -p "$share_dir" 2>/dev/null && cp -R "$lua_src" "$share_dir/lua.tmp.$$" 2>/dev/null; then
        rm -rf "$share_dir/lua"
        mv -f "$share_dir/lua.tmp.$$" "$share_dir/lua"
        say "script set installed to $share_dir/lua"
    else
        rm -rf "$share_dir/lua.tmp.$$" 2>/dev/null || true
        say "could not install the script set beside $install_dir (the editor still runs)"
    fi
fi

# ── the mnml catalogue ──
# The INTEGRATIONS section's Marketplace tab default source, laid beside
# the script set and probed the same way. A failure here costs an empty
# Marketplace tab, not an install.
cat_src="$tmp/mnml-$triple/share/mnml/marketplace.zon"
if [ -f "$cat_src" ]; then
    share_dir=$(dirname "$install_dir")/share/mnml
    if mkdir -p "$share_dir" 2>/dev/null && cp "$cat_src" "$share_dir/marketplace.zon.tmp.$$" 2>/dev/null; then
        mv -f "$share_dir/marketplace.zon.tmp.$$" "$share_dir/marketplace.zon"
        say "integration catalogue installed to $share_dir/marketplace.zon"
    else
        rm -f "$share_dir/marketplace.zon.tmp.$$" 2>/dev/null || true
        say "could not install the integration catalogue (the Marketplace tab will be empty)"
    fi
fi

# ── MnmlSymbols.ttf ──
# The face mnml's own marks are drawn from — the Claude and Codex marks,
# the tree connectors, the terminal icon. Laid beside the script set. The
# terminal still has to be told about it; mnml's own startup check says so
# when it is not.
font_src="$tmp/mnml-$triple/share/mnml/fonts/MnmlSymbols.ttf"
if [ -f "$font_src" ]; then
    font_dir=$(dirname "$install_dir")/share/mnml/fonts
    if mkdir -p "$font_dir" 2>/dev/null && cp "$font_src" "$font_dir/MnmlSymbols.ttf.tmp.$$" 2>/dev/null; then
        mv -f "$font_dir/MnmlSymbols.ttf.tmp.$$" "$font_dir/MnmlSymbols.ttf"
        say "symbols font installed to $font_dir/MnmlSymbols.ttf"
        say "point your terminal at it: font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols"
    else
        rm -f "$font_dir/MnmlSymbols.ttf.tmp.$$" 2>/dev/null || true
        say "could not install the symbols font (mnml's own marks will show as ?)"
    fi
fi

# ── PATH hint ──
case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
        say "$install_dir is not on your PATH. Add it:"
        case "${SHELL:-}" in
            */fish) say "  fish_add_path $install_dir" ;;
            */zsh) say "  echo 'export PATH=\"$install_dir:\$PATH\"' >> ~/.zshrc" ;;
            *) say "  echo 'export PATH=\"$install_dir:\$PATH\"' >> ~/.profile" ;;
        esac
        ;;
esac
