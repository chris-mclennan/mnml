#!/usr/bin/env bash
# mnml interactive launcher — pick a mode from a menu.
# Companion to ./run.sh (which takes static subcommands). Run this when
# you want to be prompted; run ./run.sh <mode> directly when you know
# what you want.
set -u
cd "$(dirname "$0")"

# Colors (24-bit; match the family teal/green/grey palette).
TEAL=$'\033[38;2;83;192;188m'
GREEN=$'\033[38;2;152;195;121m'
GREY=$'\033[38;2;92;99;112m'
BOLD=$'\033[1m'
RST=$'\033[0m'

printf '\n%s%s┌─ mnml launcher ──────────────────────────────────────┐%s\n' \
    "$BOLD" "$TEAL" "$RST"
printf '%s%s│%s  Pick a mode:                                        %s%s│%s\n' \
    "$BOLD" "$TEAL" "$RST" "$BOLD" "$TEAL" "$RST"
printf '%s%s└──────────────────────────────────────────────────────┘%s\n\n' \
    "$BOLD" "$TEAL" "$RST"

PS3=$'\n'"  ${GREEN}→${RST} pick a number: "
COLUMNS=1
options=(
    "mnml — standalone in this terminal"
    "mnml — under tmnl (mnml as a native tab in tmnl)"
    "mnml — headless (no window; scripted stdin → file IPC)"
    "build — debug build"
    "release — release build"
    "test — run cargo test"
    "check — fmt + clippy (matches CI)"
    "quit"
)
select choice in "${options[@]}"; do
    case "$REPLY" in
        1) exec ./run.sh ;;
        2) exec ./run.sh under-tmnl ;;
        3) exec ./run.sh headless ;;
        4) exec ./run.sh build ;;
        5) exec ./run.sh release ;;
        6) exec ./run.sh test ;;
        7) exec ./run.sh check ;;
        8) echo "bye"; exit 0 ;;
        *) printf '  %sunknown choice %q — try again%s\n' "$GREY" "$REPLY" "$RST" ;;
    esac
done
