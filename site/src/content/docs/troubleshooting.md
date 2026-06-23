---
title: Troubleshooting
description: Common install / launch issues — nightly bundle for testing latest cargo builds, the macOS Tahoe "Intel-based apps" warning, and how to recover.
---

## Nightly bundle

`./scripts/build-app.sh --nightly` builds a second macOS bundle at `target/mnml-nightly.app` that's distinct from the stable `mnml.app`:

- **Different bundle identifier** (`sh.mnml.app.nightly` vs `sh.mnml.app`) — both can live in `/Applications/` at once, both can be dock-pinned independently, Cmd-Tab shows them as separate apps.
- **Inverted-color icon palette** — cool blue ground + charcoal `mnml` wordmark, so the two are visually distinguishable at a glance.
- **The launcher execs your latest cargo build directly** (`$HOME/Projects/mnml/target/release/mnml`) instead of packaging a snapshot binary into the bundle. Rebuild with `cargo build --release` and the next launch of `mnml-nightly.app` picks up the new code — no rebundling, no `cp` into `/Applications/`.

Use case: pin nightly to the dock for one-click access to whatever's currently in your local `target/release/`, while the stable bundle in `/Applications/` stays untouched at the last DMG you installed.

**Not part of release CI** — nightly is a local maintainer convenience. There's no nightly DMG, no auto-update, no signed artifact. Build it yourself with `./scripts/build-app.sh --nightly` and copy the result wherever you want it. Source: `scripts/build-app.sh`, `scripts/launcher-nightly.sh`, `scripts/Info-nightly.plist`.

## "Intel-based apps" warning on macOS Tahoe (26)

If you installed an mnml DMG older than v0.1.2 and you're running macOS Tahoe (26) or later, you may see this warning the first time you launch mnml:

> **Support Ending for Intel-based Apps.** This version will not open in a future release of macOS.

mnml ships native arm64 binaries for Apple Silicon. The warning is a false positive — the cause was a missing `LSMinimumSystemVersion = 11.0` key in the `.app` bundle's `Info.plist`. Without that key, Tahoe falls back to its legacy heuristics and classifies anything declaring `LSMinimumSystemVersion < 11.0` (pre-Big-Sur, the macOS version where Apple Silicon shipped) as a legacy Intel app, regardless of the actual binary architecture.

**Fixed in v0.1.2 and later.** If you see the warning, redownload the latest DMG from the [Install](/install/) page or:

```sh
brew upgrade chris-mclennan/tap/mnml
```

You can confirm you're on a fixed build:

```sh
defaults read /Applications/mnml.app/Contents/Info.plist LSMinimumSystemVersion
# 11.0
```

If it still prints `10.14` or doesn't exist, your bundle is pre-v0.1.2 — update.
