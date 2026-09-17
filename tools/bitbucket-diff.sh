#!/usr/bin/env bash
# bitbucket-diff — run the Rust Bitbucket reference and the Zig pane on
# the fake server and print the content that differs per screen.
#
#   tools/bitbucket-diff.sh [--size 120x40] [--out DIR]
#
# The Rust side needs a build of `mnml-forge-bitbucket` with a base-URL
# override (`BITBUCKET_BASE_URL`), since the stock binary hard-codes
# api.bitbucket.org: `MNML_BB_ORACLE_BIN` names it (default: the oracle
# build under mnml-integrations' target/). The Zig side is this repo's
# `zig-out/bin/mnml-zig` + `mnml-bitbucket` + `mnml-fake-bitbucket`,
# built here when missing. The screens land in `--out` (a temp dir by
# default) as rust-<screen>.txt / zig-<screen>.txt for reading by eye.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$ROOT/zig-out/bin/mnml-zig" ] && [ -x "$ROOT/zig-out/bin/mnml-bitbucket" ] && [ -x "$ROOT/zig-out/bin/mnml-fake-bitbucket" ] || (cd "$ROOT" && zig build) || exit 1
exec python3 "$ROOT/tools/bitbucket-diff.py" "$@"
