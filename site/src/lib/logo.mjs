// The wordmark the app paints on its start page — `logo` in
// src/ui/welcome.zig — read from the source at build time, the way
// demo/Dockerfile extracts it for the web demo, so the three cannot drift.
import fs from "node:fs";
import path from "node:path";
import { REPO_ROOT } from "./paths.mjs";

const SOURCE = "src/ui/welcome.zig";

export function logoLines() {
  const zig = fs.readFileSync(path.join(REPO_ROOT, SOURCE), "utf8");
  const block = zig.match(/^pub const logo = \[_\]\[\]const u8\{\n([\s\S]*?)\n\};/m);
  if (!block) throw new Error(`${SOURCE}: no \`pub const logo\` block`);
  const lines = block[1].split("\n").map((l) => {
    const m = l.match(/^\s*"(.*)",\s*$/);
    if (!m) throw new Error(`${SOURCE}: unexpected logo row: ${l}`);
    return m[1].replace(/\\\\/g, "\\");
  });
  if (lines.length < 3) throw new Error(`${SOURCE}: the logo has ${lines.length} rows`);
  return lines;
}
