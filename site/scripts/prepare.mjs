// Runs before `astro build` / `astro dev`:
//   1. the repo docs the generated pages are rendered from must exist —
//      a moved doc fails here with its name, not deep inside a render;
//   2. GitHub's newest mnml release is resolved (API, then the
//      releases/latest redirect, then the committed
//      src/data/release.json; a 20 s budget in all) into
//      src/data/release.latest.json, which the download page prefers.
//      With SITE_OFFLINE=1 the committed file stands.
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

// The release (scripts/release-source.mjs has the sources and their
// order). release.latest.json is written on every build — including a
// fall back to the committed file — so a file left by an earlier build
// never stands in for this one's answer; it carries `source`, which the
// download page prints as <meta name="mnml-release-source">.
// SITE_GITHUB_API / SITE_GITHUB_WEB replace https://api.github.com /
// https://github.com (point one at http://127.0.0.1:9 to rehearse it
// being down).
const out = path.resolve("src/data/release.latest.json");
if (process.env.SITE_OFFLINE === "1") {
  fs.rmSync(out, { force: true });
  console.log("prepare: SITE_OFFLINE=1 — using src/data/release.json (source: committed)");
} else {
  const { resolveRelease, tokenFrom } = await import("./release-source.mjs");
  const committed = JSON.parse(fs.readFileSync(path.resolve("src/data/release.json"), "utf8"));
  const token = tokenFrom(process.env);
  const { release, source } = await resolveRelease({
    fetch,
    repo: REPO,
    committed,
    token,
    api: process.env.SITE_GITHUB_API || undefined,
    web: process.env.SITE_GITHUB_WEB || undefined,
    log: (s) => console.log(`prepare: ${s}`),
  });
  fs.writeFileSync(out, JSON.stringify({ ...release, source }, null, 2) + "\n");
  const how = {
    api: `from the GitHub API${token ? " (with a token)" : ""}`,
    redirect: release.tag === committed.tag
      ? "from the releases/latest redirect, which agrees with src/data/release.json"
      : "from the releases/latest redirect; asset names from src/data/release.json, the installer checked",
    committed: "from src/data/release.json",
  }[source];
  console.log(`prepare: release ${release.tag}, ${release.assets.length} assets — ${how} (source: ${source})`);
  if (source === "committed") {
    console.warn(`prepare: WARNING — GitHub could not be asked which release is newest; the download page names the committed ${committed.tag}. If a newer release exists the page is stale until the next build: run \`node scripts/pin-release.mjs vX.Y.Z\` (docs/RELEASE.md).`);
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
