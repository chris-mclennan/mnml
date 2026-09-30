// Paths resolve from the site folder, not import.meta.url: Astro bundles
// these modules into dist/, where a relative URL no longer points into the
// source tree. `npm run …` always runs in site/.
import path from "node:path";
export const SITE_ROOT = process.cwd();
export const REPO_ROOT = path.resolve(SITE_ROOT, "..");
export const CONTENT_ROOT = path.join(SITE_ROOT, "src/content/docs");
