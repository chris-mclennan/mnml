// One renderer for every docs page, written or generated:
//   - heading ids the way GitHub makes them (github-slugger), so a link
//     to docs/CONFIG.md#some-heading lands on the same heading here;
//   - GitHub alert blockquotes (> [!NOTE] …) as callouts;
//   - a list right after <!-- cards --> as card links, after
//     <!-- buttons --> as a button row;
//   - a paragraph that is only <!-- video: NAME --> as that recording
//     (src/media.json) in the window frame the home page draws, with the
//     clip's one-sentence flow as its caption;
//   - fenced code highlighted by shiki in One Dark / One Light;
//   - tables wrapped so they scroll sideways on a phone;
//   - relative links in a repo doc sent to that doc's page here when it
//     has one, else to the file on GitHub.
import fs from "node:fs";
import path from "node:path";
import { Marked, Renderer } from "marked";
import GithubSlugger from "github-slugger";
import { createHighlighter } from "shiki";
import { blobUrl } from "../repo.mjs";
import { SITE_PATH_FOR } from "./nav.mjs";
import { REPO_ROOT } from "./paths.mjs";
import { media } from "./media.mjs";

const LANGS = ["zig", "sh", "powershell", "lua", "json", "toml", "diff", "python", "rust", "yaml", "javascript", "http", "ini", "markdown"];
const ALIAS = { zon: "zig", bash: "sh", shell: "sh", console: "sh", zsh: "sh", ps1: "powershell", pwsh: "powershell", jsonl: "json", py: "python", js: "javascript", md: "markdown", yml: "yaml" };
const THEMES = { dark: "one-dark-pro", light: "one-light" };
const highlighter = await createHighlighter({ themes: Object.values(THEMES), langs: LANGS });

const defaultTable = Renderer.prototype.table;
const escapeHtml = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const plain = (s) => s.replace(/<[^>]+>/g, "").replace(/[`*_]/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");

export function highlight(code, lang) {
  let l = (lang || "").trim().split(/\s+/)[0].toLowerCase();
  l = ALIAS[l] || l;
  const known = LANGS.includes(l);
  return highlighter.codeToHtml(code, { lang: known ? l : "text", themes: THEMES, defaultColor: "dark" });
}

// A relative link in a repo doc → its page on the site, or GitHub.
export function rewriteHref(href, sourcePath) {
  if (!sourcePath || /^([a-z][a-z0-9+.-]*:|#|\/)/i.test(href)) return href;
  const [p, hash] = href.split("#");
  const repoPath = path.posix.normalize(path.posix.join(path.posix.dirname(sourcePath), p)).replace(/\/$/, "");
  const site = SITE_PATH_FOR[repoPath];
  if (site) return site + (hash ? `#${hash}` : "");
  if (repoPath.startsWith("..")) return href;
  return blobUrl(repoPath) + (hash ? `#${hash}` : "");
}

const CALLOUT_ICON = {
  note: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
  tip: '<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5M9 18h6M10 22h4"/>',
  important: '<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/><path d="M12 8v4M12 16h.01"/>',
  warning: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4M12 17h.01"/>',
  caution: '<path d="M2.586 16.726A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2h6.624a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586z"/><path d="M12 8v4M12 16h.01"/>',
};
const svg = (d, size = 20) => `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
export const ICON = {
  arrow: '<path d="M5 12h14M12 5l7 7-7 7"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
};
export { svg, escapeHtml, plain };

// <!-- video: NAME --> → the clip in a window frame. The page's script
// (layouts/Docs.astro) plays it once it scrolls into view, unless the
// visitor prefers reduced motion; until then only the poster loads.
// MP4 comes first: Safari before 17.4 cannot play the WebM.
export function videoHtml(name) {
  const m = media(name);
  const title = escapeHtml(m?.title || name);
  const frame = (body) => `<div class="window"><div class="window-bar"><ul class="lights" aria-hidden="true"><li></li><li></li><li></li></ul><span class="title">${title}</span><span></span></div><div class="window-body">${body}</div></div>`;
  if (!m) return `<figure class="clip">${frame('<div class="placeholder">recording pending</div>')}</figure>\n`;
  const sources = [m.mp4 && `<source src="${m.mp4}" type="video/mp4">`, `<source src="${m.video}" type="video/webm">`].filter(Boolean).join("");
  const poster = m.poster ? ` poster="${m.poster}"` : "";
  return `<figure class="clip" style="--ar:${m.width}/${m.height}">${frame(`<video class="clip-video"${poster} width="${m.width}" height="${m.height}" muted loop playsinline preload="none" aria-label="${title}">${sources}</video>`)}${m.flow ? `<figcaption>${escapeHtml(m.flow)}</figcaption>` : ""}</figure>\n`;
}

// "[Title](/docs/x) — one sentence" → { href, title, desc }.
function cardItem(item, parser) {
  const toks = item.tokens?.[0]?.tokens || [];
  const link = toks.find((t) => t.type === "link");
  if (!link) return null;
  const rest = toks.slice(toks.indexOf(link) + 1);
  let desc = parser.parseInline(rest).trim().replace(/^(—|–|-|:)\s*/, "");
  return { href: link.href, title: parser.parseInline(link.tokens), desc };
}

export function parseFrontmatter(raw) {
  const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/);
  if (!m) return { data: {}, body: raw };
  const data = {};
  const lines = m[1].split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const kv = lines[i].match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!kv) continue;
    let [, k, v] = kv;
    if (/^[|>][-+]?$/.test(v)) {
      const block = [];
      while (i + 1 < lines.length && /^\s+|^$/.test(lines[i + 1]) && !/^[A-Za-z_][\w-]*:/.test(lines[i + 1])) block.push(lines[++i].trim());
      v = v.startsWith(">") ? block.join(" ").trim() : block.join("\n").trim();
    } else if (/^(["']).*\1$/.test(v)) v = v.slice(1, -1);
    if (v === "true") v = true;
    else if (v === "false") v = false;
    data[k] = v;
  }
  return { data, body: raw.slice(m[0].length) };
}

// markdown → { html, headings: [{depth, id, text}], title (first h1) }.
export function renderMarkdown(text, { sourcePath = null, dropH1 = true, slugger = new GithubSlugger() } = {}) {
  const headings = [];
  let title = null;
  const marked = new Marked({ gfm: true });
  marked.use({
    hooks: {
      processAllTokens(tokens) {
        for (let i = 0; i < tokens.length; i++) {
          const t = tokens[i];
          const clip = t.type === "html" && t.text.trim().match(/^<!--\s*video:\s*([\w-]+)\s*-->$/)?.[1];
          if (clip) {
            t.text = t.raw = videoHtml(clip);
            t.block = true;
            continue;
          }
          const kind = t.type === "html" && t.text.trim().match(/^<!--\s*(cards|buttons)\s*-->$/)?.[1];
          if (!kind) continue;
          t.type = "space";
          t.raw = "";
          const next = tokens.slice(i + 1).find((x) => x.type !== "space");
          if (next?.type === "list") next.mnmlKind = kind;
        }
        return tokens;
      },
    },
    renderer: {
      heading({ tokens, depth, text: raw }) {
        const inner = this.parser.parseInline(tokens);
        const id = slugger.slug(plain(inner));
        if (depth === 1 && title === null && dropH1) {
          title = plain(inner);
          return "";
        }
        if (depth >= 2 && depth <= 4) headings.push({ depth, id, text: plain(inner) });
        return `<h${depth} id="${id}" class="jump"><a class="jump-link" href="#${id}">${inner}</a><span class="jump-mark" aria-hidden="true">${svg(ICON.link, 14)}</span></h${depth}>\n`;
      },
      code({ text: code, lang }) {
        return `<div class="codeblock">${highlight(code, lang)}<button class="copy" type="button" aria-label="Copy code">Copy</button></div>\n`;
      },
      table(token) {
        return `<div class="table-wrap">${defaultTable.call(this, token)}</div>\n`;
      },
      blockquote({ tokens }) {
        const inner = this.parser.parse(tokens);
        const m = inner.match(/^<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(?:<br>)?\s*/i);
        if (!m) return `<blockquote>${inner}</blockquote>\n`;
        const kind = m[1].toLowerCase();
        let body = inner.slice(m[0].length);
        body = body.replace(/^<\/p>\s*/, "");
        if (!/^</.test(body.trim())) body = `<p>${body}`;
        const label = kind[0].toUpperCase() + kind.slice(1);
        return `<aside class="callout ${kind}"><div class="callout-head">${svg(CALLOUT_ICON[kind])}<span>${label}</span></div><div class="callout-body">${body}</div></aside>\n`;
      },
      list(token) {
        if (token.mnmlKind) {
          const items = token.items.map((it) => cardItem(it, this.parser)).filter(Boolean);
          if (token.mnmlKind === "cards") {
            return `<div class="card-links"><ul>${items.map((c) => `<li><a class="card-link" href="${escapeHtml(c.href)}"><span class="card-title">${c.title}</span>${c.desc ? `<span class="card-desc">${c.desc}</span>` : ""}</a></li>`).join("")}</ul></div>\n`;
          }
          return `<div class="button-links"><ul>${items.map((c, i) => `<li><a class="button large ${i === 0 ? "brand" : "neutral"}" href="${escapeHtml(c.href)}">${c.title}</a></li>`).join("")}</ul></div>\n`;
        }
        return false;
      },
      link({ href, title: t, tokens }) {
        const inner = this.parser.parseInline(tokens);
        const h = rewriteHref(href, sourcePath);
        const ext = /^https?:/.test(h) ? ' rel="noopener"' : "";
        return `<a href="${escapeHtml(h)}"${t ? ` title="${escapeHtml(t)}"` : ""}${ext}>${inner}</a>`;
      },
    },
  });
  const html = marked.parse(text);
  return { html, headings, title };
}

export function renderRepoDoc(sourcePath) {
  const text = fs.readFileSync(path.join(REPO_ROOT, sourcePath), "utf8");
  return renderMarkdown(text, { sourcePath });
}
