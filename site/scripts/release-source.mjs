// Which mnml release the site names, and where that answer came from.
// scripts/prepare.mjs resolves it at build time, scripts/smoke.mjs asks
// for the newest one to compare the built page against, and
// scripts/pin-release.mjs uses the same tag rules. Every network call
// goes through the `fetch` passed in, so the tests never touch the
// network.
//
// The sources, in order:
//   api        api.github.com — /releases/latest, or the newest mnml
//              release in /releases when "latest" is not one of ours.
//              With GITHUB_TOKEN / GH_TOKEN set it is sent as a bearer
//              header; without one, shared build machines are routinely
//              rate-limited (HTTP 403 / 429).
//   redirect   github.com/<repo>/releases/latest answers 302 to
//              /releases/tag/<tag> and is not API-rate-limited. It gives
//              the tag only, so the asset names come from the committed
//              src/data/release.json (they carry no version); one HEAD
//              on a known asset of that tag proves they are there.
//   committed  src/data/release.json as committed. scripts/pin-release.mjs
//              rewrites it on every release.
//
// Only a tag like v0.3.2 is an mnml release. The repository also
// publishes integration releases (jira-v0.2.2, bitbucket-v0.2.2, …) and
// prereleases (v0.3.0-rc0); neither may become the site's release.

export const CORE_TAG = /^v(\d+)\.(\d+)\.(\d+)$/;
export const isCoreTag = (t) => typeof t === "string" && CORE_TAG.test(t);

// <0, 0, >0 as a is older than, the same as, or newer than b. Both core tags.
export function cmpTag(a, b) {
  const x = a.match(CORE_TAG).slice(1).map(Number);
  const y = b.match(CORE_TAG).slice(1).map(Number);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

// The newest core tag in a list, or null.
export function newestCoreTag(tags) {
  let best = null;
  for (const t of tags) if (isCoreTag(t) && (!best || cmpTag(t, best) > 0)) best = t;
  return best;
}

export const tokenFrom = (env) => env.GITHUB_TOKEN || env.GH_TOKEN || "";

// A network error as a word: ECONNREFUSED, ENOTFOUND, "timed out", …
const errWhy = (e) => (e.name === "TimeoutError" ? "timed out" : e.cause?.code ?? e.cause?.errors?.[0]?.code ?? e.message);

const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));

// A clock-bounded client over an injected fetch. Every request gets the
// smaller of `attemptMs` and what is left of `budgetMs`, so a dead
// network costs the build at most the budget, never a hang.
export function client({ fetch, repo, token = "", api = "https://api.github.com", web = "https://github.com", budgetMs = 20000, attemptMs = 8000, sleep = sleepMs, now = Date.now }) {
  const deadline = now() + budgetMs;
  const left = () => deadline - now();
  const call = (url, init = {}) => {
    const ms = Math.min(attemptMs, left());
    if (ms <= 0) return Promise.reject(new Error("out of time"));
    return fetch(url, { ...init, signal: AbortSignal.timeout(ms) });
  };

  // GET an API path as JSON. Network errors and 5xx are retried with
  // backoff (1 s, then 3 s) while the budget lasts; a 403 / 429 is a
  // rate limit that will not clear within a build, so it is not; a 401
  // means the token is bad, and the call is made once more without it.
  async function apiJson(p) {
    let auth = !!token;
    let last = "no attempt";
    const delays = [1000, 3000];
    for (let attempt = 0; attempt <= delays.length; attempt++) {
      if (attempt > 0) {
        if (left() <= delays[attempt - 1]) break;
        await sleep(delays[attempt - 1]);
      }
      const headers = { accept: "application/vnd.github+json", "user-agent": "mnml-site-build", "x-github-api-version": "2022-11-28" };
      if (auth) headers.authorization = `Bearer ${token}`;
      let r;
      try {
        r = await call(`${api}${p}`, { headers });
      } catch (e) {
        last = errWhy(e);
        continue;
      }
      if (r.ok) return { ok: true, json: await r.json() };
      if (r.status === 401 && auth) { auth = false; last = "HTTP 401 with the token"; attempt--; continue; }
      const limited = r.status === 429 || (r.status === 403 && r.headers.get("x-ratelimit-remaining") === "0");
      last = `HTTP ${r.status}${limited ? " (rate-limited)" : ""}`;
      if (r.status < 500) return { ok: false, why: last };
    }
    return { ok: false, why: last };
  }

  // The tag github.com/<repo>/releases/latest redirects to, or why not.
  async function redirectTag() {
    let last = "no attempt";
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const r = await call(`${web}/${repo}/releases/latest`, { method: "HEAD", redirect: "manual", headers: { "user-agent": "mnml-site-build" } });
        const loc = r.headers.get("location") ?? "";
        const m = loc.match(/\/releases\/tag\/([^/?#]+)$/);
        if (r.status >= 300 && r.status < 400 && m) return { ok: true, tag: decodeURIComponent(m[1]) };
        last = `HTTP ${r.status}${loc ? ` to ${loc}` : ""}`;
        if (r.status < 500) break;
      } catch (e) {
        last = errWhy(e);
      }
    }
    return { ok: false, why: last };
  }

  // Whether <tag>/<asset> is downloadable: true, false (404), or null
  // when the answer is anything else.
  async function assetExists(tag, name) {
    try {
      const r = await call(`${web}/${repo}/releases/download/${tag}/${name}`, { method: "HEAD", redirect: "manual", headers: { "user-agent": "mnml-site-build" } });
      if (r.status === 200 || r.status === 302) return true;
      if (r.status === 404) return false;
      return null;
    } catch {
      return null;
    }
  }

  return { apiJson, redirectTag, assetExists };
}

const usable = (j) => j && isCoreTag(j.tag_name) && !j.draft && !j.prerelease && Array.isArray(j.assets) && j.assets.length > 0;
const fromApi = (j) => ({ tag: j.tag_name, version: j.tag_name.slice(1), assets: j.assets.map((a) => a.name) });

// The newest mnml release by the API: /releases/latest when it is one of
// ours, else the newest usable core release in the first page of
// /releases. { ok, release } or { ok: false, why }.
export async function newestByApi(c, repo, log = () => {}) {
  const latest = await c.apiJson(`/repos/${repo}/releases/latest`);
  if (!latest.ok) return latest;
  if (usable(latest.json)) return { ok: true, release: fromApi(latest.json) };
  log(`the API's latest release is ${latest.json?.tag_name ?? "unnamed"}, not an mnml release — listing releases`);
  const list = await c.apiJson(`/repos/${repo}/releases?per_page=50`);
  if (!list.ok) return list;
  const rels = (Array.isArray(list.json) ? list.json : []).filter(usable);
  const tag = newestCoreTag(rels.map((r) => r.tag_name));
  if (!tag) return { ok: false, why: "no published vX.Y.Z release with assets in the first 50" };
  return { ok: true, release: fromApi(rels.find((r) => r.tag_name === tag)) };
}

// The asset the redirect path HEADs to prove a tag's files exist: the
// installer script (every release has one), else the first committed name.
const probeAsset = (assets) => assets.find((a) => /installer\.sh$/.test(a)) ?? assets[0];

// Resolve the release the site names. `committed` is src/data/release.json.
// Returns { release: {tag, version, assets}, source: "api"|"redirect"|"committed", notes: [string] }.
export async function resolveRelease({ committed, repo, log = () => {}, ...opts }) {
  const notes = [];
  const say = (s) => { notes.push(s); log(s); };
  const c = client({ repo, ...opts });

  const api = await newestByApi(c, repo, say);
  if (api.ok) return { release: api.release, source: "api", notes };
  say(`the API did not answer (${api.why}) — asking github.com/${repo}/releases/latest`);

  const red = await c.redirectTag();
  if (!red.ok) {
    say(`the releases/latest redirect did not answer (${red.why})`);
  } else if (!isCoreTag(red.tag)) {
    say(`releases/latest redirects to ${red.tag}, not an mnml release`);
  } else if (red.tag === committed.tag) {
    return { release: pick(committed), source: "redirect", notes };
  } else if (cmpTag(red.tag, committed.tag) < 0) {
    say(`releases/latest redirects to ${red.tag}, older than the committed ${committed.tag}`);
  } else {
    const name = probeAsset(committed.assets);
    const there = await c.assetExists(red.tag, name);
    if (there === true) {
      return { release: { tag: red.tag, version: red.tag.slice(1), assets: [...committed.assets] }, source: "redirect", notes };
    }
    say(`releases/latest redirects to ${red.tag}, but its ${name} ${there === false ? "is not there (404)" : "could not be checked"}`);
  }
  return { release: pick(committed), source: "committed", notes };
}

const pick = (r) => ({ tag: r.tag, version: r.version, assets: [...r.assets] });

// Whether src/data/release.json is at least the newest vX.Y.Z tag
// reachable from HEAD. { ok, newest } — newest null when there are none.
export function pinnedIsCurrent(committedTag, tags) {
  const newest = newestCoreTag(tags);
  if (!newest) return { ok: false, newest: null };
  return { ok: isCoreTag(committedTag) && cmpTag(committedTag, newest) >= 0, newest };
}
