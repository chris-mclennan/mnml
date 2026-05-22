# fim-engine — Plan & Roadmap

Working roadmap. The shipped surface is documented in [`README.md`](../README.md);
the user-facing summary in [`CHANGELOG.md`](../CHANGELOG.md).

fim-engine is a small, focused crate — local code completion and nothing else.
The goal is a tight, dependency-lean surface that `tmnl` and `mnml` can rely on.

---

## Roadmap

- [ ] **Streaming completion** — yield tokens as they generate, instead of
      returning the whole completion at once, so a consumer can render partial
      ghost text sooner.
- [ ] **Cancellation** — let a consumer abort an in-flight `complete` when the
      cursor moves (today the caller just drops the stale result).
- [ ] **CUDA / Vulkan acceleration** — alongside the existing `metal` feature,
      for non-Apple GPUs.
- [ ] **Model-choice tuning** — evaluate newer / smaller code models; expose
      sampling parameters (temperature, top-p) if they earn their keep.
- [ ] **Smaller download** — investigate a more aggressively quantized weight
      set to cut the first-run download below ~1 GB.
- [ ] **Warm-load API** — a way to pre-warm / probe model load progress without
      committing to a blocking `load`.

## Going public

- [ ] Publish to crates.io. fim-engine is a leaf (only crates.io dependencies),
      so it publishes cleanly on its own — and **must publish before `tmnl` and
      `mnml`**, which depend on it; their `Cargo.toml` path deps then gain a
      `version = "..."` alongside the path.

## Design notes

- **Stay lean.** fim-engine exists as its own crate so candle compiles once for
  a consuming app. Every dependency added here is a rebuild tax on tmnl + mnml —
  weigh new deps accordingly.
- **Blocking by design.** `load` and `complete` are blocking; consumers call
  them on a worker thread. Don't pull an async runtime into this crate.
- **The model is not bundled.** Weights download at runtime from the Hugging
  Face CDN; the crate ships only the inference code.
