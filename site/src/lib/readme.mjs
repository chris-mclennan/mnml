// Lines the site quotes from README.md verbatim, so the two never drift.
import fs from "node:fs";
import path from "node:path";
import { REPO_ROOT } from "./paths.mjs";

const README = fs.readFileSync(path.join(REPO_ROOT, "README.md"), "utf8");
function line(re, what) {
  const m = README.match(re);
  if (!m) throw new Error(`README.md has no ${what} line`);
  return m[0].trim();
}
export const WINGET_INSTALL = line(/^winget install \S+$/m, "`winget install <id>`");
