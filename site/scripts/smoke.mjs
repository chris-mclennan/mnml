// npm run smoke — after `npm run build`:
//   1. every internal link and asset in dist/ resolves to a built file,
//      and every #fragment to an id on the page it points at;
//   2. every release download URL anywhere in dist/ — a button's href or
//      an install line's text — answers a HEAD with 200 after redirects.
// SKIP_DOWNLOAD_CHECKS=1 skips (2) (site.yml sets it on pull requests).
// Exits 1 on any failure.
import fs from "node:fs";
import path from "node:path";
import { REPO } from "../src/repo.mjs";

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
  const list = [...downloads].sort();
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
      if (status !== 200) bad.push(`download ${u} → ${status}`);
    }
  }));
}
if (bad.length) {
  for (const b of bad) console.error(`smoke: FAIL ${b}`);
  console.error(`smoke: ${bad.length} failure(s)`);
  process.exit(1);
}
console.log("smoke: ok");
