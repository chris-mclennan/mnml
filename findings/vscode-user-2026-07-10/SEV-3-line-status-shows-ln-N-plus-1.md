## [SEV-3] Statusline shows `Ln 10/9` after Ctrl+A on a 9-line file (cursor virtually past-EOF)

**Reproduction**:

```jsonc
{"cmd":"open","path":"src.py"}       // 9-line Python file
{"cmd":"key","key":"ctrl+a"}
{"cmd":"snapshot"}
// statusline reads: Ln 10/9 Col 1  Sel 158
```

**Expected** (VS Code): after Select-All, cursor is placed at end of last line (line 9). Statusline shows `Ln 9`.

**Actual**: `Ln 10/9` — the file is 9 lines but the statusline shows the cursor on line 10. Presumably because Ctrl+A places cursor at `text.len()` and the file ends with a `\n`, so the byte position falls on the phantom line 10 col 1.

**Notes**: Cosmetic but reads as "off by one". Same phantom line 10 shows up after other end-of-buffer motions on trailing-newline files. Also visible after Alt+Down at the last line (moves cursor past EOF onto virtual row 10). See `src/editor/mod.rs::current_line()` — the char-boundary at the file's terminal newline is likely counted as its own line.
