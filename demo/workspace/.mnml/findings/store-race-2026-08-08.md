# Store race — 2026-08-08

Concurrent writes to the same note file drop one of the two edits.

## Repro

```sh
loop write note-a "first" &
loop write note-a "second" &
wait
loop read note-a  # <— may show either "first" OR "second", never a merge
```

## Root cause

`Store.write` opens the file `O_TRUNC` without flock. Second writer
truncates the first writer's content before the first writer's
write hits disk.

## Fix

Use `renameat2(RENAME_EXCHANGE)` where available, `.tmp + rename`
elsewhere. Add a store-level lock per note id.
