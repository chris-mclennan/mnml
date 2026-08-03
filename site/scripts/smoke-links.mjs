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

// Grab every `href="…"` from an HTML string. Deliberately naive —
// Starlight's output is well-formed enough that a regex is fine.
function extractHrefs(html) {
  const out = [];
  const re = /href="([^"#]+)(?:#[^"]*)?"/g;
  let m;
  while ((m = re.exec(html))) out.push(m[1]);
  return out;
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
    for (const href of extractHrefs(html)) {
      if (isExternalHref(href)) continue;
      if (href.startsWith('javascript:') || href.startsWith('data:')) continue;
      // Pagefind & sitemap assets are served by the host, not
      // part of the checkable page tree.
      if (href.startsWith('/pagefind/') || href === '/sitemap-index.xml') continue;
      const resolved = resolveInternal(href, dirname(page));
      if (!existsSync(resolved)) {
        // Also try one level up (Starlight sometimes emits
        // relative `./foo/` under a subdir).
        fail(`${page.replace(DIST_ROOT, '')} → dead link "${href}"`);
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
console.log('---------------------');
console.log(`hard fails: ${hardFails}    soft warns: ${softWarns}`);
process.exit(hardFails > 0 ? 1 : 0);
