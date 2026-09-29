---
severity: SEV-3
status: open
---
# A private source added from a folder with non-ASCII letters gets an id with one `-` per UTF-8 byte (`intégrations` → `int--grations`)

**Command id / surface:** `marketplace.add_source`; the source id shown in every Marketplace row `(… )`, the toast, and `config.zon`.

**Reproduction** (fresh launch; workspace folder `intégrations/one/{build.zig,manifest.zon}`):
```
{"cmd":"run-command","id":"marketplace.add_source"}
{"cmd":"type","text":"intégrations"}
{"cmd":"key","key":"enter"}
```

**Expected:** an id that reads like the folder — `intégrations`, or one `-` (or a transliteration) per non-ASCII character.

**Actual:** toast `added int--grations: 1 integration found`; config gets `.id = "int--grations"`. A folder `ünï cødé` becomes `--n---c--d--`.

**Why:** `idFrom` (`src/app/marketplace.zig` ~965) walks bytes and replaces every byte that is not ASCII alphanumeric / `-` / `_` / `.`, so each 2-byte letter becomes `--`.

**Reproduced:** 3/3 fresh launches.
