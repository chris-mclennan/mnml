// docs/CONFIG.md → the option reference's data. The doc's "The complete
// file" section is one commented config.zon; this walks it and gives back
// one entry per dotted key, with the value the file writes and the
// comment that documents it:
//
//   - a comment on the key's own line, and the comment lines directly
//     above it, belong to that key. A comment that introduces a run of
//     keys therefore lands on the first of them — the file has no way to
//     say otherwise;
//   - a comment left before a closing brace, with no key after it,
//     belongs to the section it closes;
//   - a Map section (src/config/Config.zig names them: `name: Map(…)`)
//     takes keys the user chooses, so its body is an example rather than
//     a set of options: it becomes one entry that shows the lines as the
//     file writes them. A list of one-line elements does the same; a
//     list whose elements span lines gets one sub-entry per field;
//   - the `// ── editor ───` banners only separate the file, and are
//     dropped.
//
// Anything the walk cannot classify is returned in `unparsed`, so
// scripts/prepare.mjs can say so; those lines are still on the page, in
// the whole file at its end.
import fs from "node:fs";
import path from "node:path";

// The doc split around its complete-file section.
export function splitConfigDoc(md) {
  const start = md.indexOf("\n## The complete file\n");
  if (start < 0) throw new Error("docs/CONFIG.md has no \"## The complete file\" section");
  const next = md.indexOf("\n## ", start + 1);
  const head = md.slice(0, start + 1);
  const complete = md.slice(start + 1, next < 0 ? md.length : next + 1);
  const rest = next < 0 ? "" : md.slice(next + 1);
  const m = complete.match(/```zon\n([\s\S]*?)\n```/);
  if (!m) throw new Error("docs/CONFIG.md's complete-file section has no ```zon block");
  return { head, complete, rest, zon: m[1] };
}

// The names Config.zig declares as `Map(…)`.
export function mapNames(configZig) {
  return new Set([...configZig.matchAll(/^\s*(\w+):\s*Map\(/gm)].map((m) => m[1]));
}

// code / comment halves of a line, respecting strings.
function splitComment(line) {
  let q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q && c === "\\") { i++; continue; }
    if (c === '"') q = !q;
    else if (!q && line.startsWith("//", i)) return [line.slice(0, i), line.slice(i + 2)];
  }
  return [line, null];
}

function braceDelta(code) {
  let q = false, d = 0;
  for (let i = 0; i < code.length; i++) {
    const c = code[i];
    if (q && c === "\\") { i++; continue; }
    if (c === '"') q = !q;
    else if (!q) { if (c === "{") d++; else if (c === "}") d--; }
  }
  return d;
}

const BANNER = /^\s*──.*──\s*$/;
const KEY = /^\.(@"[^"]*"|[A-Za-z_]\w*)\s*=\s*(.*?)\s*$/;
const isExample = (s) => /\b(an example|example|e\.g\.)/i.test(s || "");

function dedent(lines) {
  const ind = Math.min(...lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length));
  return lines.map((l) => l.slice(ind)).join("\n");
}

// → { entries, unparsed }. An entry: { key, depth, kind: "key" | "group" |
// "map" | "list", value, example, comment: [lines], trailing, notes:
// [lines], excerpt, fields: [entry] }.
export function parseZon(zon, maps) {
  const lines = zon.split("\n");
  const entries = [];
  const unparsed = [];
  const stack = []; // { entry | null, elem: bool }
  let pending = [];
  let fold = null; // { entry, depth, lines }
  const pathOf = () => stack.filter((f) => f.entry).map((f) => f.entry.key).at(-1);
  const take = () => { const c = pending; pending = []; return c; };

  // The outer `.{` … `}` of the file.
  let i = lines.findIndex((l) => l.trim());
  if (lines[i].trim() !== ".{") throw new Error("the complete file does not open with .{");
  const last = lines.findLastIndex((l) => l.trim());

  for (i = i + 1; i < last; i++) {
    const raw = lines[i];
    const [codePart, com] = splitComment(raw);
    const code = codePart.trim();

    if (fold) {
      fold.lines.push(raw);
      fold.depth += braceDelta(code);
      if (fold.depth <= 0) { fold.entry.excerpt = dedent(fold.lines); fold = null; }
      continue;
    }
    if (!code) {
      if (com !== null && !BANNER.test(com)) pending.push(com.replace(/^ /, ""));
      continue;
    }
    const d = braceDelta(code);
    const top = stack.at(-1);
    const km = code.match(KEY);

    if (km) {
      const name = km[1].replace(/^@"|"$/g, "");
      const parent = pathOf();
      if (top?.elem) {
        // a field of a multi-line list element
        const list = top.list;
        const field = { key: `${list.key}[].${name}`, depth: list.depth + 1, kind: "key", value: km[2].replace(/,$/, ""), comment: take(), trailing: com?.trim() || "", notes: [], fields: [] };
        field.example = isExample(field.trailing);
        if (!list.fields.some((f) => f.key === field.key)) list.fields.push(field);
        if (d !== 0) unparsed.push(raw);
        continue;
      }
      const entry = { key: parent ? `${parent}.${name}` : name, depth: stack.filter((f) => f.entry).length + 1, kind: "key", value: null, comment: take(), trailing: com?.trim() || "", notes: [], fields: [], excerpt: null };
      entries.push(entry);
      if (d === 0) {
        entry.value = km[2].replace(/,$/, "");
        entry.example = isExample(entry.trailing);
        continue;
      }
      if (d < 0) { unparsed.push(raw); continue; }
      // An opener: a Map folds; a list is told by its first element.
      const nextCode = lines.slice(i + 1).map((l) => splitComment(l)[0].trim()).find(Boolean) || "";
      if (maps.has(name)) {
        entry.kind = "map";
        fold = { entry, depth: d, lines: [raw] };
      } else if (/^\.\{/.test(nextCode)) {
        entry.kind = "list";
        if (nextCode === ".{") stack.push({ entry, list: entry });
        else fold = { entry, depth: d, lines: [raw] };
      } else {
        entry.kind = "group";
        stack.push({ entry });
      }
      continue;
    }
    if (code === ".{" && top?.list) { stack.push({ entry: null, elem: true, list: top.list }); take(); continue; }
    if (d < 0 && /^}+,?$/.test(code.replace(/\s/g, ""))) {
      for (let k = 0; k < -d; k++) {
        const f = stack.pop();
        const owner = f?.entry || (f?.elem ? null : null);
        if (pending.length && owner) owner.notes.push(...take());
      }
      take();
      continue;
    }
    unparsed.push(raw);
  }
  return { entries, unparsed };
}

export function loadConfigOptions(repoRoot) {
  const md = fs.readFileSync(path.join(repoRoot, "docs/CONFIG.md"), "utf8");
  const zig = fs.readFileSync(path.join(repoRoot, "src/config/Config.zig"), "utf8");
  const parts = splitConfigDoc(md);
  return { ...parts, ...parseZon(parts.zon, mapNames(zig)) };
}
