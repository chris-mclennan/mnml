// Runs before `astro build` / `astro dev`:
//   1. the repo docs the generated pages are rendered from must exist —
//      a moved doc fails here with its name, not deep inside a render;
//   2. GitHub's latest release is fetched (8 s budget) into
//      src/data/release.latest.json, which the download page prefers to
//      the committed src/data/release.json. Offline, or with
//      SITE_OFFLINE=1, the committed file stands.
import fs from "node:fs";
import path from "node:path";
import { PAGES } from "../src/lib/nav.mjs";
import { REPO } from "../src/repo.mjs";

const repoRoot = path.resolve("..");
let bad = 0;
const gen = PAGES.filter((p) => p.generated);
for (const p of gen) {
  if (!fs.existsSync(path.join(repoRoot, p.generated))) {
    console.error(`prepare: ${p.generated} is missing (src/nav.json names it for ${p.url})`);
    bad++;
  }
}
if (bad) process.exit(1);
console.log(`prepare: ${gen.length} generated-page sources found`);

// The option reference walks docs/CONFIG.md's complete file key by key
// (scripts/config-options.mjs). A line it cannot place is still on the
// page, in the whole file at the end, but has no heading of its own.
{
  const { loadConfigOptions } = await import("./config-options.mjs");
  const { entries, unparsed } = loadConfigOptions(repoRoot);
  console.log(`prepare: option reference — ${entries.length} keys from docs/CONFIG.md`);
  for (const l of unparsed) console.warn(`prepare: option reference could not place this line (it stays in the whole file): ${l.trim()}`);
}

const out = path.resolve("src/data/release.latest.json");
if (process.env.SITE_OFFLINE === "1") {
  fs.rmSync(out, { force: true });
  console.log("prepare: SITE_OFFLINE=1 — using src/data/release.json");
} else {
  try {
    const headers = { accept: "application/vnd.github+json", "user-agent": "mnml-site-build" };
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers, signal: AbortSignal.timeout(8000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const j = await r.json();
    const rel = { tag: j.tag_name, version: j.tag_name.replace(/^v/, ""), assets: j.assets.map((a) => a.name) };
    if (!rel.assets.length) throw new Error("the latest release has no assets");
    fs.writeFileSync(out, JSON.stringify(rel, null, 2) + "\n");
    console.log(`prepare: latest release ${rel.tag}, ${rel.assets.length} assets`);
  } catch (e) {
    console.log(`prepare: could not read the latest release (${e.message}) — using ${fs.existsSync(out) ? "the last fetched one" : "src/data/release.json"}`);
  }
}

// 3. The link-preview image, og.png (1200x630), rendered from the hero
//    recording's poster so it follows a re-recorded hero. Build output
//    (gitignored); src/layouts/Site.astro names it only when it exists.
{
  const { ogImage } = await import("./og-image.mjs");
  const pub = path.resolve("public");
  const poster = path.join(pub, "media/hero.png");
  const out = path.join(pub, "og.png");
  try {
    if (!fs.existsSync(poster)) throw new Error("no media/hero.png");
    ogImage(poster, out);
    console.log("prepare: og.png from media/hero.png");
  } catch (e) {
    fs.rmSync(out, { force: true });
    console.warn(`prepare: no og.png (${e.message}) — the pages go without a preview image`);
  }
}
