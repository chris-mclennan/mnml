// npm run smoke — after `npm run build`:
//   1. every internal link and asset in dist/ resolves to a built file,
//      and every #fragment to an id on the page it points at;
//   2. every release download URL anywhere in dist/ — a button's href or
//      an install line's text — answers a HEAD with 200 after redirects.
//   3. the download page carries its release marker
//      (<meta name="mnml-release-version|mnml-release-source">), and
//      src/data/release.json is not older than the newest vX.Y.Z tag
//      reachable from HEAD (scripts/pin-release.mjs --check; needs the
//      tags — site.yml checks out with fetch-depth: 0);
//   4. the built page's version is not older than the newest mnml
//      release GitHub names (API with GITHUB_TOKEN / GH_TOKEN when set,
//      else the releases/latest redirect).
// SKIP_DOWNLOAD_CHECKS=1 skips (2) and (4) (site.yml sets it on pull
// requests). Exits 1 on any failure.
import fs from "node:fs";
import path from "node:path";
import { REPO } from "../src/repo.mjs";
import { client, cmpTag, isCoreTag, newestByApi, tokenFrom } from "./release-source.mjs";
import { check as pinnedCheck } from "./pin-release.mjs";

const DIST = path.resolve("dist");
if (!fs.existsSync(DIST)) {
  console.error("smoke: no dist/ — run `npm run build` first");
  process.exit(1);
}
const pages = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith(".html")) pages.push(p);
  }
})(DIST);
const html = new Map(pages.map((p) => [p, fs.readFileSync(p, "utf8")]));
const idCache = new Map();
const ids = (file) => {
  if (!idCache.has(file)) idCache.set(file, new Set([...(html.get(file) ?? "").matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])));
  return idCache.get(file);
};
function fileFor(urlPath) {
  const p = path.join(DIST, decodeURIComponent(urlPath));
  if (fs.existsSync(p) && fs.statSync(p).isFile()) return p;
  if (fs.existsSync(path.join(p, "index.html"))) return path.join(p, "index.html");
  if (fs.existsSync(p + ".html")) return p + ".html";
  return null;
}

const bad = [];
// Paths the mnml.sh zone serves from a Worker, not from dist/: the browser
// demo (demo/cloudflare). A link to one is not a missing page; it is
// probed live with the download URLs instead.
const workerRoutes = ["/demo", "/demo/"];
const servedByWorker = (p) => workerRoutes.some((r) => p === r || p.startsWith(r.endsWith("/") ? r : r + "/"));
const workerLinks = new Set();
let checked = 0;
const downloads = new Set();
const dlRe = new RegExp(`https://github\\.com/${REPO.replace("/", "\\/")}/releases/(?:latest/)?download/[^\\s"'<>|)]+`, "g");
for (const [file, s] of html) {
  const pageUrl = "/" + path.relative(DIST, file).split(path.sep).join("/").replace(/index\.html$/, "");
  for (const m of s.matchAll(dlRe)) downloads.add(m[0].replace(/&amp;/g, "&"));
  for (const m of s.matchAll(/\s(?:href|src|poster)="([^"]*)"/g)) {
    const raw = m[1].replace(/&amp;/g, "&");
    if (!raw || /^(https?:)?\/\//.test(raw) || /^(mailto|data|javascript):/.test(raw)) continue;
    checked++;
    const u = new URL(raw, "http://site" + pageUrl);
    if (servedByWorker(u.pathname)) { workerLinks.add("https://mnml.sh" + u.pathname); continue; }
    const target = raw.startsWith("#") ? file : fileFor(u.pathname);
    if (!target) { bad.push(`${pageUrl}: ${raw} → no such page or file`); continue; }
    if (u.hash && target.endsWith(".html")) {
      const id = decodeURIComponent(u.hash.slice(1));
      if (!ids(target).has(id)) bad.push(`${pageUrl}: ${raw} → no id "${id}" on ${u.pathname}`);
    }
  }
}
console.log(`smoke: ${pages.length} pages, ${checked} internal links and assets checked`);
if (!downloads.size) bad.push("no release download URL found anywhere in dist/ — the download page lost its links");

if (process.env.SKIP_DOWNLOAD_CHECKS === "1") {
  console.log(`smoke: ${downloads.size} download URLs, probes skipped (SKIP_DOWNLOAD_CHECKS=1)`);
} else {
  const list = [...downloads, ...workerLinks].sort();
  const probe = async (u) => {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const r = await fetch(u, { method: "HEAD", redirect: "follow", signal: AbortSignal.timeout(20000) });
        if (r.status === 200 || attempt === 1) return r.status;
      } catch (e) {
        if (attempt === 1) return `error: ${e.cause?.code ?? e.message}`;
      }
    }
  };
  let i = 0;
  await Promise.all(Array.from({ length: 6 }, async () => {
    while (i < list.length) {
      const u = list[i++];
      const status = await probe(u);
      console.log(`smoke: HEAD ${status} ${u}`);
      if (status !== 200) bad.push(`${workerLinks.has(u) ? "worker route" : "download"} ${u} → ${status}`);
    }
  }));
}
// 3. The release marker, and the committed release against the tags.
const dlPage = html.get(path.join(DIST, "download/index.html")) ?? "";
const meta = (name) => dlPage.match(new RegExp(`<meta[^>]*name="${name}"[^>]*content="([^"]*)"`))?.[1] ?? null;
const builtVersion = meta("mnml-release-version");
const builtSource = meta("mnml-release-source");
if (!builtVersion || !builtSource) {
  bad.push("download/index.html has no <meta name=\"mnml-release-version\"> / <meta name=\"mnml-release-source\">");
} else {
  console.log(`smoke: the download page names ${builtVersion} (source: ${builtSource})`);
}
{
  const r = pinnedCheck();
  if (r.ok) console.log(r.msg.replace(/^pin-release/, "smoke"));
  else bad.push(r.msg.replace(/^pin-release: /, ""));
}

// 4. The built page against the newest release GitHub names.
if (process.env.SKIP_DOWNLOAD_CHECKS === "1") {
  console.log("smoke: the newest-release comparison skipped (SKIP_DOWNLOAD_CHECKS=1)");
} else if (builtVersion) {
  const c = client({ fetch, repo: REPO, token: tokenFrom(process.env), api: process.env.SITE_GITHUB_API || undefined, web: process.env.SITE_GITHUB_WEB || undefined });
  const api = await newestByApi(c, REPO);
  let newest = api.ok ? api.release.tag : null;
  let how = "the API";
  if (!newest) {
    const red = await c.redirectTag();
    if (red.ok && isCoreTag(red.tag)) { newest = red.tag; how = "the releases/latest redirect"; }
  }
  const built = `v${builtVersion}`;
  if (!newest) {
    console.warn(`smoke: WARNING — could not learn the newest release (API: ${api.why}); the page's ${builtVersion} is unchecked`);
  } else if (!isCoreTag(built) || cmpTag(built, newest) < 0) {
    bad.push(`the download page names ${builtVersion} (source: ${builtSource}), but ${newest} is released (per ${how})`);
  } else {
    console.log(`smoke: the download page's ${builtVersion} is the newest release (per ${how})`);
  }
}

if (bad.length) {
  for (const b of bad) console.error(`smoke: FAIL ${b}`);
  console.error(`smoke: ${bad.length} failure(s)`);
  process.exit(1);
}
console.log("smoke: ok");
