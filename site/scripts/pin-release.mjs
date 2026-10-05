// Keeps src/data/release.json — the release the download page names when
// GitHub cannot be asked at build time — on the newest release.
//
//   node site/scripts/pin-release.mjs v0.3.3   # rewrite it from that release
//   node site/scripts/pin-release.mjs --check  # exit 1 when it is older than
//                                              # the newest vX.Y.Z tag
//                                              # reachable from HEAD
//
// Pinning reads the release's asset names from the GitHub API (with
// GITHUB_TOKEN / GH_TOKEN when set), then `gh api` if that fails. Only a
// published, non-prerelease vX.Y.Z release with assets is accepted. Run
// it after the release is published and scripts/dist-check.sh is happy
// (docs/RELEASE.md); commit the result.
//
// --check is what makes forgetting that loud: npm run smoke,
// tools/run-sh-check.sh and scripts/release.sh run it.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { REPO } from "../src/repo.mjs";
import { client, isCoreTag, pinnedIsCurrent, tokenFrom } from "./release-source.mjs";

const SITE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FILE = path.join(SITE, "src/data/release.json");
const rel = path.relative(process.cwd(), FILE) || FILE;
const COMMENT = "The release the download page names when GitHub cannot be asked at build time. scripts/pin-release.mjs writes it on every release; scripts/prepare.mjs resolves the live one into release.latest.json (ignored), which src/lib/release.mjs prefers.";

// Every vX.Y.Z-shaped tag reachable from HEAD in the repository holding
// the site.
export function reachableTags(cwd = SITE) {
  const out = execFileSync("git", ["--no-optional-locks", "tag", "--merged", "HEAD", "--list", "v*"], { cwd, encoding: "utf8" });
  return out.split("\n").map((s) => s.trim()).filter(isCoreTag);
}

export function check() {
  const pinned = JSON.parse(fs.readFileSync(FILE, "utf8")).tag;
  const { ok, newest } = pinnedIsCurrent(pinned, reachableTags());
  if (newest === null) {
    return { ok: false, msg: `pin-release: no vX.Y.Z tag is reachable from HEAD — a shallow clone? (fetch with tags: \`git fetch --tags\`, or actions/checkout with fetch-depth: 0)` };
  }
  if (!ok) {
    return { ok: false, msg: `pin-release: ${rel} names ${pinned}, but ${newest} is tagged — once ${newest} is published, run \`node site/scripts/pin-release.mjs ${newest}\` and commit it (docs/RELEASE.md, "The sequence")` };
  }
  return { ok: true, msg: `pin-release: ${rel} names ${pinned}, the newest tag reachable from HEAD is ${newest} — current` };
}

async function assetsOf(tag) {
  const c = client({ fetch, repo: REPO, token: tokenFrom(process.env), api: process.env.SITE_GITHUB_API || undefined });
  const r = await c.apiJson(`/repos/${REPO}/releases/tags/${tag}`);
  let j = r.ok ? r.json : null;
  if (!j) {
    console.log(`pin-release: the API did not answer (${r.why}) — trying \`gh api\``);
    try {
      j = JSON.parse(execFileSync("gh", ["api", `repos/${REPO}/releases/tags/${tag}`], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
    } catch (e) {
      throw new Error(`could not read release ${tag} (${e.message.split("\n")[0]})`);
    }
  }
  if (j.draft || j.prerelease) throw new Error(`${tag} is a ${j.draft ? "draft" : "prerelease"}`);
  const names = (j.assets ?? []).map((a) => a.name).sort();
  if (!names.length) throw new Error(`${tag} has no assets yet — wait for the Release workflow`);
  return names;
}

async function pin(tag) {
  if (!isCoreTag(tag)) throw new Error(`${tag} is not an mnml release tag (vX.Y.Z)`);
  const before = JSON.parse(fs.readFileSync(FILE, "utf8"));
  const assets = await assetsOf(tag);
  const added = assets.filter((a) => !before.assets.includes(a));
  const gone = before.assets.filter((a) => !assets.includes(a));
  fs.writeFileSync(FILE, JSON.stringify({ comment: COMMENT, tag, version: tag.slice(1), assets }, null, 2) + "\n");
  console.log(`pin-release: ${rel}: ${before.tag} → ${tag}, ${assets.length} assets`);
  for (const a of added) console.log(`pin-release:   + ${a}`);
  for (const a of gone) console.log(`pin-release:   - ${a}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = process.argv[2];
  if (arg === "--check") {
    const r = check();
    (r.ok ? console.log : console.error)(r.msg);
    process.exit(r.ok ? 0 : 1);
  } else if (arg && !arg.startsWith("-")) {
    try {
      await pin(arg);
    } catch (e) {
      console.error(`pin-release: ${e.message}`);
      process.exit(1);
    }
  } else {
    console.error("usage: pin-release.mjs vX.Y.Z | --check");
    process.exit(64);
  }
}
