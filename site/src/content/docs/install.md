---
title: Install
description: How to install mnml.
---

## Cargo

```sh
cargo install mnml-rs
```

The crate is `mnml-rs`; the binary it installs is `mnml`.

## Or a build from source

```sh
git clone https://github.com/chris-mclennan/mnml-rs
cd mnml-rs
cargo build --release
./target/release/mnml
```

## Nerd Font

A [Nerd Font](https://www.nerdfonts.com/) is recommended for devicons and powerline glyphs. JetBrainsMono Nerd Font is a good default. Without a Nerd Font, run `mnml --ascii` (or set `[ui] ascii_icons = true` in your config) for a plain-text fallback.

## Releases

Pre-built binaries for each tagged release are on the [releases page](https://github.com/chris-mclennan/mnml-rs/releases). For the modern dev experience, `cargo install` is the recommended path.

## Verify

```sh
mnml --version
```
