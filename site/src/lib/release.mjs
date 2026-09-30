// The release the download page describes: GitHub's latest when
// scripts/prepare.mjs could fetch it at build time, else the committed
// src/data/release.json. Assets are looked up by pattern, so a release
// missing one (say, no Intel Mac build) drops that button instead of
// linking a 404.
import fs from "node:fs";
import path from "node:path";
import { SITE_ROOT } from "./paths.mjs";
import { assetUrl, releaseUrl } from "../repo.mjs";

function load() {
  for (const f of ["release.latest.json", "release.json"]) {
    const p = path.join(SITE_ROOT, "src/data", f);
    if (fs.existsSync(p)) return { ...JSON.parse(fs.readFileSync(p, "utf8")), from: f };
  }
  throw new Error("src/data/release.json is missing");
}

export const RELEASE = load();
export const VERSION = RELEASE.version;
export const TAG = RELEASE.tag;
export const RELEASE_URL = releaseUrl(TAG);
// Release-notes pages are named by version with dots as dashes (0-3-0).
export const versionSlug = (v) => v.replace(/\./g, "-");

// The first asset whose name matches `re`, as { name, url }, or null.
export function asset(re) {
  const name = RELEASE.assets.find((a) => re.test(a));
  return name ? { name, url: assetUrl(TAG, name) } : null;
}
