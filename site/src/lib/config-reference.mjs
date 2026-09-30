// /docs/config/reference: docs/CONFIG.md as ghostty.org's Option Reference
// — one heading per dotted key (`ui.dock.placement`), its default in a
// chip and its comment from the file under it — followed by the doc's own
// guide sections and, last, the whole annotated config.zon as one block.
// The walk over the file is scripts/config-options.mjs.
import GithubSlugger from "github-slugger";
import { Marked } from "marked";
import { loadConfigOptions } from "../../scripts/config-options.mjs";
import { REPO_ROOT } from "./paths.mjs";
import { renderMarkdown, highlight, svg, ICON, escapeHtml, rewriteHref } from "./markdown.mjs";

const SOURCE = "docs/CONFIG.md";
const inline = new Marked({ gfm: true });

// Comment text is prose with `code` spans; outside the spans, <data root>
// and the like are text, not tags.
function prose(text) {
  const safe = text.split(/(`[^`]*`)/).map((part, i) => (i % 2 ? part : part.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"))).join("");
  return inline.parseInline(safe).replace(/href="([^"]+)"/g, (_, h) => `href="${escapeHtml(rewriteHref(h, SOURCE))}"`);
}

// Comment lines → paragraphs (a bare `//` line breaks one).
function paragraphs(lines) {
  const out = [];
  let cur = [];
  for (const l of lines) {
    if (!l.trim()) { if (cur.length) out.push(cur.join(" ")); cur = []; }
    else cur.push(l.trim());
  }
  if (cur.length) out.push(cur.join(" "));
  return out.map((p) => `<p>${prose(p)}</p>`).join("");
}

// A comment on the key's own line is a note, not a sentence: `.vim |
// .standard` lists the values, and "clamped to 10..80" starts lower-case
// with no stop. On the page each reads as a sentence.
const ENUM_ONLY = /^\.[\w@"]+(\s*\|\s*\.[\w@"]+)+$/;
function trailingText(t) {
  if (!t) return null;
  if (ENUM_ONLY.test(t)) return "One of " + t.split(/\s*\|\s*/).map((v) => `\`${v}\``).join(", ") + ".";
  let s = t.replace(/^[a-z]/, (c) => c.toUpperCase());
  if (!/[.!?)`"]$/.test(s)) s += ".";
  return s;
}

function heading(depth, id, key) {
  return `<h${depth} id="${escapeHtml(id)}" class="jump opt"><a class="jump-link" href="#${escapeHtml(id)}"><code>${escapeHtml(key)}</code></a><span class="jump-mark" aria-hidden="true">${svg(ICON.link, 14)}</span></h${depth}>`;
}

function entryHtml(e, depth, id) {
  let h = heading(depth, id, e.key);
  if (e.value !== null && e.value !== undefined) {
    h += `<p class="opt-default"><span>${e.example ? "Example" : "Default"}</span><code>${escapeHtml(e.value)}</code></p>`;
  }
  const note = trailingText(e.trailing);
  h += paragraphs([...e.comment, ...(note ? ["", note] : [])]);
  if (e.excerpt) h += `<div class="codeblock">${highlight(e.excerpt, "zig")}<button class="copy" type="button" aria-label="Copy code">Copy</button></div>`;
  if (e.notes.length) h += paragraphs(e.notes);
  for (const f of e.fields) h += entryHtml(f, 4, f.key);
  return h + "\n";
}

export function renderConfigReference() {
  const { head, complete, rest, entries } = loadConfigOptions(REPO_ROOT);
  if (entries.length < 100) throw new Error(`config reference: only ${entries.length} keys found in ${SOURCE} — the walk has lost the file's shape`);
  // The doc's own headings keep GitHub's ids, so links into docs/CONFIG.md
  // still land; a section id that one of them already uses gets a suffix.
  const slugger = new GithubSlugger();
  const a = renderMarkdown(head, { sourcePath: SOURCE, slugger });
  const b = renderMarkdown(rest, { sourcePath: SOURCE, slugger, dropH1: false });
  const c = renderMarkdown(complete, { sourcePath: SOURCE, slugger, dropH1: false });
  const taken = new Set([...a.headings, ...b.headings, ...c.headings].map((h) => h.id));
  const lead = `<p class="opt-lead">Every key below is written as it appears in <code>config.zon</code>, with its default. The text under a key is the comment written beside it or directly above it in the file; a comment that introduces a run of keys sits on the first of them. Sections that take keys you name (<code>keys.vim</code>, <code>lsp</code>, <code>tasks</code> …) and lists are shown as the file writes them. The whole annotated file is at the end of the page, under <a href="#the-complete-file">The complete file</a>.</p>\n`;
  const optHeadings = [];
  let opts = "";
  for (const e of entries) {
    const depth = e.depth === 1 ? 2 : 3;
    const id = depth === 2 && taken.has(e.key) ? `${e.key}-section` : e.key;
    optHeadings.push({ depth, id, text: e.key });
    opts += entryHtml(e, depth, id);
  }
  return {
    html: a.html + lead + opts + b.html + c.html,
    headings: [...a.headings, ...optHeadings, ...b.headings, ...c.headings],
    title: a.title,
  };
}
