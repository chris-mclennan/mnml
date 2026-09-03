#!/usr/bin/env node
// #860 — post-build smoke check for the mnml site.
//
// Runs two passes:
//
// 1. INTERNAL — walks every built HTML page under dist/ and asserts
//    that every `<a href="/foo">` / `<a href="foo.html">` link
//    resolves to a page that actually exists in dist/. Catches
//    manual-writer sidebar drift + slug typos.
//
// 2. DOWNLOADS — walks install.mdx and asserts every
//    `releases/latest/download/mnml-rs-*` URL returns a 200 (or an
//    HTTPS 302 that eventually resolves). Uses HEAD to avoid pulling
//    the actual artifact bytes. Skipped when the environment sets
//    `SKIP_DOWNLOAD_CHECKS=1` (dev loop, or a release-day window
//    where new artifacts are still uploading).
//
// Exit code: 0 on clean, 1 if any check fails. Intended target: run
// after `npm run build` in CI (see .github/workflows/site.yml).

import { readdir, readFile, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SITE_ROOT = resolve(__dirname, '..');
const DIST_ROOT = join(SITE_ROOT, 'dist');
const INSTALL_MDX = join(SITE_ROOT, 'src', 'content', 'docs', 'install.mdx');

// Track hard failures separately from soft warnings so the exit
// code reflects real breakage, not intermittent network drops.
let hardFails = 0;
let softWarns = 0;

function fail(msg) {
  hardFails++;
  console.error(`FAIL: ${msg}`);
}
function warn(msg) {
  softWarns++;
  console.warn(`WARN: ${msg}`);
}

async function walkHtml(dir, acc = []) {
  for (const ent of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) await walkHtml(p, acc);
    else if (ent.isFile() && extname(ent.name) === '.html') acc.push(p);
  }
  return acc;
}

// Grab every `href="…"` from an HTML string, SPLIT into path and
// fragment. Deliberately naive — Starlight's output is well-formed
// enough that a regex is fine.
//
// 2026-09-03: the old regex was `/href="([^"#]+)(?:#[^"]*)?"/` and
// returned only the capture group — so every `#fragment` was thrown
// away before any check saw it, and a pure same-page `href="#foo"`
// did not match at all (`[^"#]+` needs one non-`#` character). The
// checker therefore reported "0 fails" on a site with broken anchors,
// which is worse than having no checker: it was evidence of health
// that could not detect illness.
function extractHrefs(html) {
  const out = [];
  const re = /href="([^"]*)"/g;
  let m;
  while ((m = re.exec(html))) {
    const raw = m[1];
    if (!raw) continue;
    const hash = raw.indexOf('#');
    if (hash === -1) out.push({ path: raw, frag: null });
    else
      out.push({
        path: raw.slice(0, hash),
        frag: decodeURIComponent(raw.slice(hash + 1)) || null,
      });
  }
  return out;
}

// Every id/name a page defines, for anchor resolution.
const anchorCache = new Map();
async function anchorsIn(file) {
  if (anchorCache.has(file)) return anchorCache.get(file);
  let ids = new Set();
  try {
    const html = await readFile(file, 'utf8');
    for (const m of html.matchAll(/\bid="([^"]+)"/g)) ids.add(m[1]);
    for (const m of html.matchAll(/\bname="([^"]+)"/g)) ids.add(m[1]);
  } catch {
    ids = new Set();
  }
  anchorCache.set(file, ids);
  return ids;
}

function isExternalHref(href) {
  return /^(https?:)?\/\//.test(href) || href.startsWith('mailto:');
}

// Resolve an internal link to the corresponding dist/ file. Handles
// the two Starlight patterns: `/some/slug/` (dir + index.html) and
// `/some/file.html` (rare but supported).
function resolveInternal(href, currentDir) {
  // Strip leading slash: absolute paths are relative to DIST_ROOT.
  let target = href.startsWith('/')
    ? join(DIST_ROOT, href.slice(1))
    : join(currentDir, href);
  // Normalize trailing slash → index.html.
  if (target.endsWith('/') || (!extname(target) && !target.endsWith('.html'))) {
    target = join(target, 'index.html');
  }
  return target;
}

async function checkInternalLinks() {
  if (!existsSync(DIST_ROOT)) {
    fail(`dist/ not found at ${DIST_ROOT} — run \`npm run build\` first`);
    return;
  }
  const pages = await walkHtml(DIST_ROOT);
  console.log(`checking internal links across ${pages.length} pages…`);
  for (const page of pages) {
    const html = await readFile(page, 'utf8');
    for (const { path: href, frag } of extractHrefs(html)) {
      // A pure `#fragment` link targets THIS page.
      if (href === '') {
        if (frag && !(await anchorsIn(page)).has(frag)) {
          fail(`${page.replace(DIST_ROOT, '')} → dead anchor "#${frag}"`);
        }
        continue;
      }
      if (isExternalHref(href)) continue;
      // Schemes this checker cannot resolve as internal links. CodeQL
      // (js/incomplete-url-scheme-check) flags an allow/deny list that
      // omits `vbscript:` — harmless here since this only decides what
      // to skip, but a scheme list with a known hole is worth closing.
      if (/^(javascript|data|vbscript):/i.test(href)) continue;
      // Pagefind & sitemap assets are served by the host, not
      // part of the checkable page tree.
      if (href.startsWith('/pagefind/') || href === '/sitemap-index.xml') continue;
      const resolved = resolveInternal(href, dirname(page));
      if (!existsSync(resolved)) {
        fail(`${page.replace(DIST_ROOT, '')} → dead link "${href}"`);
        continue;
      }
      // The page exists; now check the anchor within it. A link to a
      // heading that has been renamed lands the reader at the top of
      // the right page with no sign anything is wrong — which is
      // exactly the failure a link checker is for.
      if (frag && !(await anchorsIn(resolved)).has(frag)) {
        fail(`${page.replace(DIST_ROOT, '')} → dead anchor "${href}#${frag}"`);
      }
    }
  }
}

// Pull every `releases/latest/download/…` URL out of install.mdx.
// We hit the source markdown, not dist/ — the URLs are literals
// and the .mdx-to-html pipeline can wrap them in props that make
// regex extraction harder.
async function extractDownloadUrls() {
  const text = await readFile(INSTALL_MDX, 'utf8');
  const re =
    /https:\/\/github\.com\/[^"'\s`]+\/releases\/latest\/download\/[^"'\s`]+/g;
  return [...new Set(text.match(re) ?? [])];
}

// Every OTHER external link in the docs.
//
// 2026-09-03 — the download probe covered 8 URLs and nothing else, so
// a dead third-party link in the install instructions
// (`opensource.dev/dist/`, cited as cargo-dist's home on the page that
// tells people how to install mnml) sat there returning 404 while the
// checker reported a clean run.
//
// Placeholders are skipped, not probed: the docs deliberately contain
// `api.example.com`, `<repo>`, `{{VAR}}` and `…` as illustrative URLs,
// and probing those would produce noise that trains people to ignore
// the output.
const PLACEHOLDER = /example\.com|example-org|<[^>]*>|\{\{|…|\.\.\./;
async function extractExternalUrls() {
  const files = [];
  await walkDocs(join(SITE_ROOT, 'src', 'content', 'docs'), files);
  const urls = new Set();
  for (const f of files) {
    // Strip fenced code blocks first. They hold SAMPLE OUTPUT — a
    // toast quoting a `releases/tag/v0.1.5` URL is illustrating what
    // mnml prints, not offering the reader a link. Probing those
    // reports a 404 for a doc that is entirely correct, which is the
    // fastest way to teach people to ignore a checker.
    const text = (await readFile(f, 'utf8')).replace(/```[\s\S]*?```/g, '');
    for (const m of text.match(/https:\/\/[^)"'\s`\]]+/g) ?? []) {
      const url = m.replace(/[.,;:]+$/, '');
      if (PLACEHOLDER.test(url)) continue;
      if (/\/releases\/latest\/download\//.test(url)) continue; // covered above
      urls.add(url);
    }
  }
  return [...urls];
}

async function walkDocs(dir, acc) {
  for (const ent of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) await walkDocs(p, acc);
    else if (/\.(md|mdx)$/.test(ent.name)) acc.push(p);
  }
}

async function checkExternalUrls() {
  if (process.env.SKIP_DOWNLOAD_CHECKS === '1') return;
  const urls = await extractExternalUrls();
  console.log(`probing ${urls.length} external doc links…`);
  const CONCURRENCY = 4;
  for (let i = 0; i < urls.length; i += CONCURRENCY) {
    const batch = urls.slice(i, i + CONCURRENCY);
    const statuses = await Promise.all(batch.map(headProbe));
    batch.forEach((url, j) => {
      const s = statuses[j];
      // Only a 404 is actionable. 403 is routinely a host refusing a
      // scripted HEAD (crates.io does), and 405 means the endpoint
      // exists but does not take GET/HEAD.
      if (s === 404) fail(`${url} → 404`);
      // 403 = host refusing a scripted HEAD (crates.io does this).
      // 405/400 = the endpoint exists but does not take GET/HEAD — a
      // form's POST action, for instance. None of those mean the docs
      // are wrong, and reporting them trains people to ignore output.
      else if (![200, 400, 403, 405].includes(s)) warn(`${url} → ${s}`);
    });
  }
}

async function headProbe(url) {
  try {
    // GitHub redirects HEAD on releases/latest/download to the
    // real asset; fetch follows redirects by default.
    const res = await fetch(url, { method: 'HEAD', redirect: 'follow' });
    return res.status;
  } catch (e) {
    return `net:${e.code ?? e.name}`;
  }
}

async function checkDownloadUrls() {
  if (process.env.SKIP_DOWNLOAD_CHECKS === '1') {
    console.log('skipping download HEAD checks (SKIP_DOWNLOAD_CHECKS=1)');
    return;
  }
  const urls = await extractDownloadUrls();
  console.log(`probing ${urls.length} release-download URLs…`);
  // Probe in parallel but cap concurrency so we don't torch
  // GitHub with 20 simultaneous HEADs.
  const CONCURRENCY = 4;
  for (let i = 0; i < urls.length; i += CONCURRENCY) {
    const batch = urls.slice(i, i + CONCURRENCY);
    const statuses = await Promise.all(batch.map(headProbe));
    batch.forEach((url, j) => {
      const s = statuses[j];
      if (s === 200) return;
      // 404 is a real download-page bug; anything else is likely
      // transient / network. Distinguish so CI has actionable
      // signal without flaking on GitHub hiccups.
      if (s === 404) fail(`${url} → 404`);
      else warn(`${url} → ${s}`);
    });
  }
}

console.log('#860 site smoke tests');
console.log('---------------------');
await checkInternalLinks();
await checkDownloadUrls();
await checkExternalUrls();
console.log('---------------------');
console.log(`hard fails: ${hardFails}    soft warns: ${softWarns}`);
process.exit(hardFails > 0 ? 1 : 0);
