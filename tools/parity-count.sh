#!/usr/bin/env bash
# parity-count.sh — the Totals table of docs/PARITY.md, counted from its rows.
#
# One `| feature | status | … |` row per line, counted under the `## `
# section it sits in. The status is the cell's first word once `*` is
# stripped — `done (Zig-only)` and `done — beyond the reference` are done —
# and only done / partial / cut / missing count: a `**Zig-only**` row, the
# Totals / Landed / Remaining / Cuts / Disputed tables and a header row do
# not. A `\|` inside a cell (a code span that shows a pipe) is not a column
# break. The two integration sections are printed apart, as the page counts
# them apart. Prints the table in the page's own layout, so a recount is a
# paste.
# Usage: tools/parity-count.sh [path/to/PARITY.md]
set -euo pipefail
f="${1:-$(cd "$(dirname "$0")/.." && pwd)/docs/PARITY.md}"
awk -F'|' '
  /^## / { sec = substr($0, 4); next }
  sec ~ /^(Totals|Landed|Remaining|Cuts|Disputed)/ { next }
  /^\|/ {
    line = $0; gsub(/\\\|/, "", line); split(line, cell, "|")
    st = cell[3]; gsub(/\*/, "", st); gsub(/^[ \t]+/, "", st); sub(/[ \t(—].*$/, "", st)
    if (st != "done" && st != "partial" && st != "cut" && st != "missing") next
    if (!(sec in seen)) { seen[sec] = 1; order[++n] = sec }
    c[sec, st]++
  }
  END {
    print "| section | done | partial | cut | missing | rows |"
    print "|---|---|---|---|---|---|"
    for (i = 1; i <= n; i++) {
      s = order[i]
      if (s ~ /^Integration/) continue
      r = c[s,"done"] + c[s,"partial"] + c[s,"cut"] + c[s,"missing"]
      printf "| %s | %d | %d | %d | %d | %d |\n", s, c[s,"done"], c[s,"partial"], c[s,"cut"], c[s,"missing"], r
      td += c[s,"done"]; tp += c[s,"partial"]; tc += c[s,"cut"]; tm += c[s,"missing"]
    }
    printf "| **total** | **%d** | **%d** | **%d** | **%d** | **%d** |\n", td, tp, tc, tm, td + tp + tc + tm
    print ""
    for (i = 1; i <= n; i++) {
      s = order[i]
      if (s !~ /^Integration/) continue
      r = c[s,"done"] + c[s,"partial"] + c[s,"cut"] + c[s,"missing"]
      printf "%s: %d done, %d partial, %d cut, %d missing, of %d\n", s, c[s,"done"], c[s,"partial"], c[s,"cut"], c[s,"missing"], r
    }
  }' "$f"
