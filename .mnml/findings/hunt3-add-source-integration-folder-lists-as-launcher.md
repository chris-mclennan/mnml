---
severity: SEV-2
status: fixed
---
# Adding one integration's own folder as a private source lists its `manifest.zon` as a `[launcher]`; Install then "installs" it without building, leaving a row whose binary is missing

**Command id / surface:** `marketplace.add_source` (same path as the `+ source` chip and the first-launch Private integrations row); Marketplace tab `i`.

**Reproduction** (fresh launch; `<fx>/slowsrc/slow/` is a Zig integration folder: `build.zig`, `manifest.zon` with `.id = "slow"`, `.binary = "mnml-slow"`):
```
{"cmd":"run-command","id":"marketplace.add_source"}
{"cmd":"type","text":"<fx>/slowsrc/slow"}
{"cmd":"key","key":"enter"}
# click the Slow row, then
{"cmd":"key","key":"i"}
```

**Expected:** the folder is recognised as the Zig integration it is (a folder with `build.zig` + `manifest.zon`) — listed `[app] Slow`, and Install builds it — or the add is refused with a hint to add the parent folder. Adding the parent (`<fx>/slowsrc`) does list it as `[app] Slow`.

**Actual:** toast `added slow: 1 integration found`; the row reads `[launcher] Slow  Private`. Install toasts `marketplace: installed slow — wrote …/integrations/slow.zon`: the app manifest is copied as a launcher, nothing is built, and the Installed tab shows `Slow (mnml-slow not ins…`.

**Why:** `listLocalDir` (`src/app/marketplace.zig:817`) treats every loose `*.zon` at depth 0 as a launcher manifest (it only skips `build.zig.zon`), and only a *subfolder* with `build.zig` is an app — the folder itself is never checked for `build.zig`.

**Reproduced:** 3/3 fresh launches.
