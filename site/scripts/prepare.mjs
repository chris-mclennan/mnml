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
