---
agent: drive-mnml
severity: SEV-3
surface: command-palette
---

# Command palette: last visible row truncates the command id mid-string

The palette renders each row as `group · title · id  chord`. When the
title is long enough to push the id column past the right edge, the id
gets cut mid-string with no `…` indicator:

```
view  ·  Toggle rainbow brackets (depth-cycling color on ()[]{})  ·  view.toggle_brack
```

(Should be `view.toggle_brackets`.) The `ctrl+l` / `ctrl+,` chord
column reserves space on the right but the id column doesn't honor it,
so the id silently overflows into the chord-column-width margin.

Captured in `/tmp/qa-vis-04b-palette.png`.

## Fix
Either: (a) truncate the title to keep the id fully visible, (b)
truncate the id with `…` suffix instead of mid-glyph cut, or (c) drop
the id column when it'd overflow (the title alone is usually enough).
