# Perf — cold start regression, 2026-08-10

Cold start went 220ms → 640ms between v0.4.11 and v0.4.12. Bisect
lands on `bun install` picking up chalk v5 → v6 which added ESM
init cost.

## Options

1. Pin chalk to 5.x (fastest to ship).
2. Move chalk to lazy-require in `src/cli/format.ts`.
3. Drop chalk entirely — we use it for 3 color codes.

Recommend (3).
