// Every docs page, resolved to what it renders:
//   generated — a repo doc named by nav.json's "generated" (docs/*.md);
//   written   — src/content/docs/<path>.md or <path>/index.md;
//   pending   — a nav.json page whose file is not there yet, which
//               renders a stub instead of failing the build.
// Written pages that nav.json does not list still get built, so a link
// to one works; they just have no sidebar entry.
import fs from "node:fs";
import path from "node:path";
import { CONTENT_ROOT } from "./paths.mjs";
import { PAGES, GENERATED_LEDE } from "./nav.mjs";
import { parseFrontmatter, renderMarkdown, renderRepoDoc } from "./markdown.mjs";

function contentFile(url) {
  const rel = url.replace(/^\/docs\/?/, "");
  const cands = rel ? [`${rel}.md`, `${rel}/index.md`] : ["index.md"];
  for (const c of cands) if (fs.existsSync(path.join(CONTENT_ROOT, c))) return c;
  return null;
}

function allContentFiles(dir = CONTENT_ROOT, pre = "") {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? allContentFiles(path.join(dir, e.name), `${pre}${e.name}/`) : e.name.endsWith(".md") ? [`${pre}${e.name}`] : [],
  );
}
const urlOf = (file) => ("/docs/" + file.replace(/\.md$/, "").replace(/(^|\/)index$/, "")).replace(/\/$/, "");

const LANDING = { url: "/docs", title: "mnml Docs", crumbs: [], generated: null, landing: true };

export function docsPages() {
  const listed = [LANDING, ...PAGES];
  const known = new Set(listed.map((p) => p.url));
  const extra = allContentFiles()
    .map((f) => ({ url: urlOf(f), title: null, crumbs: [], generated: null }))
    .filter((p) => !known.has(p.url));
  return [...listed, ...extra];
}

// → { title, description, html, headings, hideToc, source, state }
export function loadPage(page) {
  if (page.generated) {
    const { html, headings } = renderRepoDoc(page.generated);
    return { title: page.title, description: GENERATED_LEDE[page.generated] || "", html, headings, hideToc: false, source: page.generated, state: "generated" };
  }
  const file = contentFile(page.url);
  if (file) {
    const raw = fs.readFileSync(path.join(CONTENT_ROOT, file), "utf8");
    const { data, body } = parseFrontmatter(raw);
    const { html, headings, title } = renderMarkdown(body, { dropH1: false });
    return {
      title: data.title || title || page.title || "Untitled",
      description: data.description || "",
      html, headings,
      hideToc: data.hideToc === true,
      source: `site/src/content/docs/${file}`,
      state: "written",
    };
  }
  return { title: page.title, description: "", html: "", headings: [], hideToc: true, source: null, state: "pending", landing: !!page.landing };
}
