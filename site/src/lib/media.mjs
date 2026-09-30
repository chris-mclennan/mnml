// The recordings site-recorder commits: public/media/<name>.webm, an
// optional <name>.mp4 (H.264, for browsers that cannot play VP9) and a
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

// A recording is 200x60 cells; at the capture's 8x17px cell that is
// 1600x1020, the frame the page reserves before the poster loads.
export const CELLS = { width: 1600, height: 1020 };

function pngSize(file) {
  const b = fs.readFileSync(file);
  if (b.length < 24 || b.toString("ascii", 12, 16) !== "IHDR") return null;
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

export function media(name) {
  const dir = path.join(SITE_ROOT, "public/media");
  const has = (ext) => fs.existsSync(path.join(dir, `${name}.${ext}`));
  if (!has("webm")) return null;
  const meta = list.find((m) => m.name === name) || {};
  const size = has("png") ? pngSize(path.join(dir, `${name}.png`)) : null;
  return {
    video: `/media/${name}.webm`,
    mp4: has("mp4") ? `/media/${name}.mp4` : null,
    poster: size ? `/media/${name}.png` : null,
    title: meta.title || name,
    flow: meta.flow || "",
    ...(size || CELLS),
  };
}
