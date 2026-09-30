// The recordings site-recorder commits: public/media/<name>.webm with a
// <name>.png poster, listed in src/media.json. Nothing here assumes which
// clips exist — a page asks for one by name and gets null when it is not
// there yet.
import fs from "node:fs";
import path from "node:path";
import { SITE_ROOT } from "./paths.mjs";

const list = (() => {
  const p = path.join(SITE_ROOT, "src/media.json");
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return []; }
})();

export function media(name) {
  const dir = path.join(SITE_ROOT, "public/media");
  const has = (ext) => fs.existsSync(path.join(dir, `${name}.${ext}`));
  if (!has("webm")) return null;
  const meta = list.find((m) => m.name === name) || {};
  return { video: `/media/${name}.webm`, poster: has("png") ? `/media/${name}.png` : null, title: meta.title || name };
}
