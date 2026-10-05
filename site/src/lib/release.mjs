// The release the download page describes: what scripts/prepare.mjs
// resolved at build time (release.latest.json, with its `source`), else
// the committed src/data/release.json (source "committed"). Assets are
// looked up by pattern, so a release missing one (say, no Intel Mac
// build) drops that button instead of linking a 404.
import fs from "node:fs";
import path from "node:path";
import { SITE_ROOT } from "./paths.mjs";
import { assetUrl, releaseUrl } from "../repo.mjs";

function load() {
  for (const f of ["release.latest.json", "release.json"]) {
    const p = path.join(SITE_ROOT, "src/data", f);
    if (fs.existsSync(p)) {
      const r = JSON.parse(fs.readFileSync(p, "utf8"));
      return { ...r, source: f === "release.json" ? "committed" : r.source ?? "committed", from: f };
    }
  }
  throw new Error("src/data/release.json is missing");
}

export const RELEASE = load();
export const VERSION = RELEASE.version;
export const TAG = RELEASE.tag;
// api | redirect | committed — printed as <meta name="mnml-release-source">.
export const SOURCE = RELEASE.source;
export const RELEASE_URL = releaseUrl(TAG);
// Release-notes pages are named by version with dots as dashes (0-3-0).
export const versionSlug = (v) => v.replace(/\./g, "-");

// The first asset whose name matches `re`, as { name, url }, or null.
export function asset(re) {
  const name = RELEASE.assets.find((a) => re.test(a));
  return name ? { name, url: assetUrl(TAG, name) } : null;
}
