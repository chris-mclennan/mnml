// src/nav.json → the docs pages. nav.json has ghostty.org's shape: each
// node is a "link" or a "folder" with a path relative to its parent, and
// a folder's "/" child is its overview page. A link with "generated"
// names the repo doc its page is rendered from at build time.
import NAV from "../nav.json" with { type: "json" };

const join = (base, p) => (p === "/" ? base : `${base}${p}`);

// Every page as { url, title, crumbs, generated }. url is "/docs/…"
// without a trailing slash ("/docs" for the landing). crumbs are the
// folders above it, as { title, url } (url null when the folder has no
// overview page).
export const PAGES = [];
function walk(nodes, base, crumbs) {
  for (const n of nodes) {
    const url = join(base, n.path);
    if (n.type === "folder") {
      const hasOverview = (n.children || []).some((c) => c.type === "link" && c.path === "/");
      walk(n.children || [], url, [...crumbs, { title: n.title, url: hasOverview ? url : null }]);
    } else {
      PAGES.push({ url, title: n.title, crumbs, generated: n.generated || null, overview: n.path === "/" });
    }
  }
}
walk(NAV.items, "/docs", []);

export const NAV_ITEMS = NAV.items;
export { join };

// Repo doc → its page, for rewriting links between the generated docs.
export const SITE_PATH_FOR = Object.fromEntries(
  PAGES.filter((p) => p.generated).map((p) => [p.generated, p.url]),
);

// The one-sentence lede on each generated page, keyed by source.
export const GENERATED_LEDE = {
  "docs/CONFIG.md": "Every key mnml reads from config.zon, with its default and what it changes.",
  "docs/KEYMAP_PROFILES.md": "The vim and standard keymaps: which chords each profile binds, and which both share.",
  "docs/commands.md": "Every command in the palette and the : line, with its default chord in each keymap profile.",
  "docs/LUA.md": "The mnml table a Lua script sees: commands, keys, hooks, buffers, decorations and panes.",
  "docs/SDK.md": "mnml-sdk, the Zig package an integration is written with, and the wire it speaks.",
};
