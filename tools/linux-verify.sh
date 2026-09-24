#!/usr/bin/env bash
# tools/linux-verify.sh — the whole verification sequence, on Linux, in a
# throwaway container, on a copy of HEAD.
#
#   tools/linux-verify.sh                 # every step, logs in .verify/linux/
#   tools/linux-verify.sh build unit      # only the named steps (see STEPS)
#
# What it runs, in order, each with its exit code captured and its log kept:
#
#   build-partial   zig build -Dpartial=false
#   unit-safe       zig build unit -Doptimize=ReleaseSafe --summary all
#   unit-debug      zig build unit --summary all
#   build-safe      zig build -Doptimize=ReleaseSafe
#   gate            mnml-zig test --gate --sizes 80x24,120x40,200x60
#   corpus          MNML_E2E_ALLOW_SHELL=1 mnml-zig test tests/e2e
#   run-sh-check    tools/run-sh-check.sh
#   integrations    zig build test in integrations/{sample,jira,bitbucket}
#                   and sdk/mnml-sdk
#
# How it differs from tools/linux/run.sh (the interactive, bind-mounted
# one): the tree is `git archive HEAD` streamed INTO the container, so the
# run sees exactly the commit and nothing in the container can write back
# to the worktree; the only things that come out are the logs. It runs as
# an unprivileged user (a permission test run as root passes for the wrong
# reason), and it can run with no network at all.
#
# Knobs (environment):
#
#   MNML_LINUX_ARCH     amd64 | arm64. Default: the docker server's own
#                       architecture, so a Mac on Apple Silicon runs a
#                       native arm64 image with the aarch64 Zig — no
#                       emulation. Naming the other one runs under
#                       emulation (slow) and the script says so.
#   MNML_LINUX_BASE     the Debian/Ubuntu base image (default
#                       debian:trixie-slim). The image build installs what
#                       the steps need with apt, but only what the base
#                       lacks — a base that already carries git, python3,
#                       perl, node and npm (node:20 does) needs no apt.
#   MNML_LINUX_OFFLINE  1 = the image build and the run get --network none:
#                       nothing is installed with apt (a missing tool is
#                       reported, not fetched), and the Zig packages come
#                       only from the seed below. Proves the run is offline.
#   MNML_LINUX_PKG_SEED a directory of Zig package tarballs (a global
#                       cache's p/) copied into the container's cache.
#                       Default: this machine's `zig env` global cache p/,
#                       when it exists. Packages are source, not binaries,
#                       so a macOS cache seeds a Linux run.
#   MNML_LINUX_OUT      where the logs land (default .verify/linux).
#   MNML_LINUX_KEEP     1 = leave the container (for a post-mortem shell).
#   MNML_LINUX_TRIM_GB  when the container's free disk falls below this many
#                       GB between compile steps, the step's .zig-cache is
#                       dropped (default 8; 0 never trims).
#
# The Zig tarball is downloaded once into .verify/cache/ and checked
# against the sha256 pinned below (the values ziglang.org/download/
# index.json publishes for 0.16.0).
#
# Exit status: 0 when every step passed, 1 otherwise; $OUT/summary.tsv
# holds one `step<TAB>exit<TAB>seconds<TAB>numbers` row a step.
set -uo pipefail

ZIG_VERSION=0.16.0
ZIG_SHA256_x86_64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ZIG_SHA256_aarch64=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17

ALL_STEPS="build-partial unit-safe unit-debug build-safe gate corpus run-sh-check integrations"

# ---------------------------------------------------------------- inside ---
# The same file, copied into the container, runs the steps.
if [ "${1:-}" = "--inside" ]; then
  shift
  OUT=/out
  mkdir -p "$OUT"
  : >"$OUT/summary.tsv"
  cd /work || exit 70
  STEPS=${*:-$ALL_STEPS}
  rc_all=0

  free_gb() { df -Pk /work | awk 'NR==2 { print int($4 / 1048576) }'; }
  trim() {
    local lim=${MNML_LINUX_TRIM_GB:-8}
    [ "$lim" -gt 0 ] || return 0
    if [ "$(free_gb)" -lt "$lim" ]; then
      echo "[trim: $(free_gb) GB free < $lim GB — dropping .zig-cache]"
      rm -rf /work/.zig-cache
    fi
  }

  # numbers: the lines that carry a step's counts.
  # zig's `Build Summary`, the corpus/gate `N/M passed (…)` trailer,
  # run-sh-check's `N passed, M failed`.
  numbers() {
    grep -aE '^Build Summary|^[0-9]+/[0-9]+ passed|^run-sh-check: [0-9]+ passed' "$1" \
      | sed 's/^Build Summary: //' | paste -sd '|' - | sed 's/|/ | /g'
  }

  run_step() {
    local name=$1; shift
    local log="$OUT/$name.log" t0 e
    t0=$(date +%s)
    echo "== $name: $*" | tee -a "$OUT/progress.log"
    { echo "+ $*"; echo "[pwd $(pwd); $(free_gb) GB free]"; } >"$log"
    "$@" >>"$log" 2>&1
    e=$?
    local secs=$(( $(date +%s) - t0 ))
    echo "[exit $e, ${secs}s, $(free_gb) GB free]" >>"$log"
    printf '%s\t%s\t%s\t%s\n' "$name" "$e" "$secs" "$(numbers "$log")" >>"$OUT/summary.tsv"
    echo "   $name -> exit $e (${secs}s)" | tee -a "$OUT/progress.log"
    [ "$e" -eq 0 ] || rc_all=1
    return 0
  }

  integrations() {
    local e=0 d
    for d in integrations/sample integrations/jira integrations/bitbucket sdk/mnml-sdk; do
      echo "---- $d"
      (cd "$d" && zig build test --summary all) || { echo "---- $d: exit $?"; e=1; }
    done
    return $e
  }

  {
    echo "uname: $(uname -a)"
    echo "zig: $(zig version)"
    echo "user: $(id)"
    echo "locale: LANG=${LANG:-} LC_ALL=${LC_ALL:-}"
    for t in git python3 perl node npm ps xxd zsh less script; do
      printf '%s: %s\n' "$t" "$(command -v $t || echo MISSING)"
    done
    echo "free: $(free_gb) GB"
  } >"$OUT/environment.txt"

  for s in $STEPS; do
    case "$s" in
      build-partial) run_step "$s" zig build -Dpartial=false; trim ;;
      unit-safe)     run_step "$s" zig build unit -Doptimize=ReleaseSafe --summary all; trim ;;
      unit-debug)    run_step "$s" zig build unit --summary all; trim ;;
      build-safe)    run_step "$s" zig build -Doptimize=ReleaseSafe ;;
      gate)          run_step "$s" env MNML_E2E_ALLOW_SHELL=1 ./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60 ;;
      corpus)        run_step "$s" env MNML_E2E_ALLOW_SHELL=1 ./zig-out/bin/mnml-zig test tests/e2e ;;
      run-sh-check)  run_step "$s" tools/run-sh-check.sh ;;
      integrations)  run_step "$s" integrations ;;
      *) echo "unknown step: $s" >&2; rc_all=1 ;;
    esac
  done
  exit $rc_all
fi

# --------------------------------------------------------------- outside ---
# The whole driver is one function, read in full before any of it runs:
# bash reads a script as it goes, so an edit to this file during an hour-
# long run would otherwise change the lines it has not reached yet.
main() {
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=${MNML_LINUX_ENGINE:-docker}
command -v "$ENGINE" >/dev/null 2>&1 || { echo "linux-verify: $ENGINE not found" >&2; exit 127; }

for s in "$@"; do
  case " $ALL_STEPS " in *" $s "*) ;; *) echo "linux-verify: unknown step '$s' (steps: $ALL_STEPS)" >&2; exit 64 ;; esac
done

ARCH=${MNML_LINUX_ARCH:-$("$ENGINE" version --format '{{.Server.Arch}}' 2>/dev/null)}
case "$ARCH" in
  amd64|x86_64)  ARCH=amd64; ZARCH=x86_64;  ZSHA=$ZIG_SHA256_x86_64 ;;
  arm64|aarch64) ARCH=arm64; ZARCH=aarch64; ZSHA=$ZIG_SHA256_aarch64 ;;
  *) echo "linux-verify: unsupported arch '$ARCH' (amd64 | arm64)" >&2; exit 64 ;;
esac
SERVER_ARCH=$("$ENGINE" version --format '{{.Server.Arch}}' 2>/dev/null)
if [ "$SERVER_ARCH" != "$ARCH" ]; then
  echo "linux-verify: NOTE linux/$ARCH on a $SERVER_ARCH engine runs under emulation"
fi

BASE=${MNML_LINUX_BASE:-debian:trixie-slim}
OFFLINE=${MNML_LINUX_OFFLINE:-0}
OUT=${MNML_LINUX_OUT:-$ROOT/.verify/linux}
CACHE=$ROOT/.verify/cache
IMAGE=mnml-zig-linux-verify:$ZIG_VERSION-$ARCH
CTR=mnml-zig-linux-verify-$$
NET=()
[ "$OFFLINE" = 1 ] && NET=(--network none)

mkdir -p "$CACHE" "$OUT"

# 1. The Zig tarball, pinned by sha256.
TARBALL=zig-$ZARCH-linux-$ZIG_VERSION.tar.xz
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
if [ ! -f "$CACHE/$TARBALL" ]; then
  [ "$OFFLINE" = 1 ] && { echo "linux-verify: offline and no $CACHE/$TARBALL" >&2; exit 69; }
  echo "== downloading $TARBALL"
  curl -fsSL -o "$CACHE/$TARBALL.part" "https://ziglang.org/download/$ZIG_VERSION/$TARBALL" \
    && mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL" || { echo "linux-verify: download failed" >&2; exit 69; }
fi
GOT=$(sha "$CACHE/$TARBALL")
[ "$GOT" = "$ZSHA" ] || { echo "linux-verify: $TARBALL sha256 $GOT, want $ZSHA" >&2; exit 65; }

# 2. The image: the base, the tools the steps shell out to, Zig, a user.
CTX=$(mktemp -d "${TMPDIR:-/tmp}/linux-verify-ctx.XXXXXX")
trap 'rm -rf "$CTX"' EXIT
ln "$CACHE/$TARBALL" "$CTX/zig.tar.xz" 2>/dev/null || cp "$CACHE/$TARBALL" "$CTX/zig.tar.xz"
cat >"$CTX/Dockerfile" <<'EOF'
ARG BASE
FROM ${BASE}
ARG OFFLINE=0
# tool:package — installed only when the base lacks the tool. git builds
# the corpus's repositories; python3 drives the pty checks; perl, xxd, ps
# and cmp appear in .test shell steps; node/npm are what the npm runner
# tests drive; zsh is the shell the pty_* files start (`# env:
# SHELL=/bin/zsh`) and less the pager pty_wheel_pager scrolls; xz
# unpacks Zig.
RUN set -eu; missing=""; \
    for p in bash:bash git:git python3:python3 perl:perl ps:procps cmp:diffutils \
             xxd:xxd node:nodejs npm:npm zsh:zsh less:less xz:xz-utils script:bsdutils useradd:passwd; do \
      command -v "${p%%:*}" >/dev/null 2>&1 || missing="$missing ${p#*:}"; \
    done; \
    if [ -n "$missing" ]; then \
      if [ "$OFFLINE" = 1 ]; then echo "offline build: not installing:$missing"; \
      else apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates $missing \
           && rm -rf /var/lib/apt/lists/*; fi; \
    fi
COPY zig.tar.xz /tmp/zig.tar.xz
RUN mkdir -p /opt/zig && tar -C /opt/zig --strip-components=1 -xJf /tmp/zig.tar.xz \
    && rm /tmp/zig.tar.xz && ln -sf /opt/zig/zig /usr/local/bin/zig && zig version
# Not root: a file made unreadable is unreadable to the tests, as it is
# to a user.
RUN useradd -m -u 4242 verify && mkdir -p /work /out /zig-cache/p \
    && chown -R verify:verify /work /out /zig-cache
USER verify
ENV HOME=/home/verify ZIG_GLOBAL_CACHE_DIR=/zig-cache LANG=C.UTF-8 TERM=xterm-256color
WORKDIR /work
EOF
echo "== image $IMAGE (base $BASE, linux/$ARCH, offline=$OFFLINE)"
"$ENGINE" build -q ${NET[@]+"${NET[@]}"} --platform "linux/$ARCH" \
  --build-arg BASE="$BASE" --build-arg OFFLINE="$OFFLINE" -t "$IMAGE" "$CTX" >/dev/null \
  || { echo "linux-verify: image build failed" >&2; exit 70; }

# 3. The container, the tree, the package seed.
cleanup() {
  rm -rf "$CTX"
  [ "${MNML_LINUX_KEEP:-0}" = 1 ] && { echo "== kept container $CTR"; return; }
  "$ENGINE" rm -f "$CTR" >/dev/null 2>&1
}
trap cleanup EXIT
# --init: PID 1 is a real init that reaps. Under `sleep` as PID 1 an
# orphan the tests kill stays a zombie, `kill(pid, 0)` keeps answering
# for it, and cdp's orphan tests fail for a reason no machine has.
"$ENGINE" run -d --init --name "$CTR" ${NET[@]+"${NET[@]}"} --platform "linux/$ARCH" "$IMAGE" sleep infinity >/dev/null \
  || { echo "linux-verify: container did not start" >&2; exit 70; }

HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD)
echo "== tree: git archive $HEAD_SHA"
git -C "$ROOT" archive --format=tar HEAD | "$ENGINE" exec -i "$CTR" tar -x -C /work \
  || { echo "linux-verify: copying the tree failed" >&2; exit 70; }
# build.zig stamps --version from git, and some .test files want a
# repository underfoot: one commit of the same tree.
"$ENGINE" exec "$CTR" sh -c 'cd /work && git init -q && git -c user.email=verify@localhost -c user.name=verify add -A \
  && git -c user.email=verify@localhost -c user.name=verify commit -q -m "linux-verify '"$HEAD_SHA"'"' \
  || { echo "linux-verify: git init in the copy failed" >&2; exit 70; }

SEED=${MNML_LINUX_PKG_SEED:-}
if [ -z "$SEED" ] && command -v zig >/dev/null 2>&1; then
  g=$(zig env 2>/dev/null | sed -n 's/.*\.global_cache_dir = "\(.*\)",/\1/p')
  [ -n "$g" ] && [ -d "$g/p" ] && SEED=$g/p
fi
if [ -n "$SEED" ]; then
  echo "== package seed: $SEED"
  # A macOS tar carries com.apple.* xattrs as pax keywords GNU tar
  # would warn about once a file.
  (cd "$SEED" && COPYFILE_DISABLE=1 tar -c --exclude='*.part' .) \
    | "$ENGINE" exec -i "$CTR" tar -x --warning=no-unknown-keyword -C /zig-cache/p
fi

"$ENGINE" cp "$0" "$CTR:/tmp/linux-verify.sh" >/dev/null

# 4. Run, then bring the logs out.
echo "== running: ${*:-$ALL_STEPS}"
"$ENGINE" exec ${MNML_LINUX_TRIM_GB:+-e MNML_LINUX_TRIM_GB="$MNML_LINUX_TRIM_GB"} "$CTR" \
  bash /tmp/linux-verify.sh --inside "$@"
RC=$?
rm -rf "$OUT"
mkdir -p "$OUT"
"$ENGINE" cp "$CTR:/out/." "$OUT/" >/dev/null
{ echo "head: $HEAD_SHA"; echo "arch: linux/$ARCH (engine $SERVER_ARCH)"; echo "base: $BASE"; echo "offline: $OFFLINE"; } >>"$OUT/environment.txt"

echo
echo "== summary (logs in $OUT)"
awk -F'\t' '{ printf "%-14s exit %-3s %6ss  %s\n", $1, $2, $3, $4 }' "$OUT/summary.tsv"
exit $([ "$RC" -eq 0 ] && echo 0 || echo 1)
}
main "$@"
exit $?
