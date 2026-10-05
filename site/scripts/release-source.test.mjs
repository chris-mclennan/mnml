// npm test — scripts/release-source.mjs's decisions against a fake
// network: every request is answered from a table keyed by method and
// URL, and a request the table does not name fails the test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { cmpTag, newestCoreTag, pinnedIsCurrent, resolveRelease } from "./release-source.mjs";

const REPO = "example-org/app";
const API = "https://api.test";
const WEB = "https://web.test";
const ASSETS = ["app-installer.sh", "app-x86_64-unknown-linux-gnu.tar.xz", "sha256.sum"];
const committed = { tag: "v1.2.0", version: "1.2.0", assets: ASSETS };

const json = (body, status = 200, headers = {}) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
const status = (s, headers = {}) => new Response(null, { status: s, headers });
const rel = (tag, extra = {}) => ({ tag_name: tag, draft: false, prerelease: false, assets: ASSETS.map((name) => ({ name })), ...extra });
const down = () => { throw Object.assign(new TypeError("fetch failed"), { cause: { code: "ECONNREFUSED" } }); };

// A fetch that answers from `routes` ({"GET url": Response | () => Response})
// and records what it was asked, headers included.
function fakeFetch(routes) {
  const asked = [];
  const f = async (url, init = {}) => {
    const key = `${init.method ?? "GET"} ${url}`;
    asked.push({ key, headers: init.headers ?? {} });
    if (!(key in routes)) throw new Error(`unexpected request: ${key}`);
    const r = routes[key];
    return typeof r === "function" ? r() : r.clone();
  };
  f.asked = asked;
  return f;
}

const run = (routes, extra = {}) => {
  const fetch = fakeFetch(routes);
  return resolveRelease({ fetch, repo: REPO, committed, api: API, web: WEB, sleep: async () => {}, ...extra }).then((r) => ({ ...r, fetch }));
};

const LATEST = `GET ${API}/repos/${REPO}/releases/latest`;
const LIST = `GET ${API}/repos/${REPO}/releases?per_page=50`;
const REDIRECT = `HEAD ${WEB}/${REPO}/releases/latest`;
const asset = (tag) => `HEAD ${WEB}/${REPO}/releases/download/${tag}/app-installer.sh`;
const limited = () => json({ message: "API rate limit exceeded" }, 403, { "x-ratelimit-remaining": "0" });

test("tags: only vX.Y.Z counts, compared numerically", () => {
  assert.equal(newestCoreTag(["v0.3.2", "jira-v0.9.0", "v0.10.0-rc0", "v0.9.9", "bitbucket-v1.0.0"]), "v0.9.9");
  assert.ok(cmpTag("v0.10.0", "v0.9.9") > 0);
  assert.equal(newestCoreTag(["jira-v0.2.2"]), null);
});

test("API ok → api, its own asset list", async () => {
  const r = await run({ [LATEST]: json(rel("v1.3.0", { assets: [{ name: "only-one.tar.xz" }] })) });
  assert.equal(r.source, "api");
  assert.deepEqual(r.release, { tag: "v1.3.0", version: "1.3.0", assets: ["only-one.tar.xz"] });
});

test("a token is sent as a bearer header when present, and not otherwise", async () => {
  const withTok = await run({ [LATEST]: json(rel("v1.3.0")) }, { token: "t-123" });
  assert.equal(withTok.fetch.asked[0].headers.authorization, "Bearer t-123");
  const without = await run({ [LATEST]: json(rel("v1.3.0")) });
  assert.equal(without.fetch.asked[0].headers.authorization, undefined);
});

test("a bad token (401) is dropped and the call made once more without it", async () => {
  let n = 0;
  const r = await run({ [LATEST]: () => (n++ === 0 ? json({}, 401) : json(rel("v1.3.0"))) }, { token: "stale" });
  assert.equal(r.source, "api");
  assert.equal(r.fetch.asked[1].headers.authorization, undefined);
});

test("a 5xx then ok → retried, api", async () => {
  let n = 0;
  const r = await run({ [LATEST]: () => (n++ === 0 ? json({}, 502) : json(rel("v1.3.0"))) });
  assert.equal(r.source, "api");
  assert.equal(n, 2);
});

test("API 403 (rate-limited) → the redirect's tag + the committed asset names, after one asset HEAD", async () => {
  const r = await run({
    [LATEST]: limited(),
    [REDIRECT]: status(302, { location: `${WEB}/${REPO}/releases/tag/v1.3.0` }),
    [asset("v1.3.0")]: status(302, { location: "https://objects.test/x" }),
  });
  assert.equal(r.source, "redirect");
  assert.deepEqual(r.release, { tag: "v1.3.0", version: "1.3.0", assets: ASSETS });
  // A rate limit is not retried: it will not clear within a build.
  assert.equal(r.fetch.asked.filter((a) => a.key === LATEST).length, 1);
  assert.match(r.notes[0], /HTTP 403 \(rate-limited\)/);
});

test("API 429 and a redirect to the committed tag → redirect, the committed release", async () => {
  const r = await run({ [LATEST]: json({}, 429), [REDIRECT]: status(302, { location: `${WEB}/${REPO}/releases/tag/v1.2.0` }) });
  assert.equal(r.source, "redirect");
  assert.deepEqual(r.release, committed);
});

test("API and redirect both down → committed", async () => {
  const r = await run({ [LATEST]: down, [REDIRECT]: down });
  assert.equal(r.source, "committed");
  assert.deepEqual(r.release, committed);
  assert.equal(r.fetch.asked.filter((a) => a.key === LATEST).length, 3, "the API is tried three times");
  assert.match(r.notes.at(-1), /redirect did not answer \(ECONNREFUSED\)/);
});

test("the API's latest is an integration release → ignored; the newest vX.Y.Z from the list", async () => {
  const r = await run({
    [LATEST]: json(rel("jira-v0.2.2")),
    [LIST]: json([rel("jira-v0.2.2"), rel("v1.4.0-rc0", { prerelease: true }), rel("v1.3.0"), rel("bitbucket-v9.0.0"), rel("v1.2.0"), rel("v1.5.0", { draft: true })]),
  });
  assert.equal(r.source, "api");
  assert.equal(r.release.tag, "v1.3.0");
});

test("the redirect names an integration release → ignored → committed", async () => {
  const r = await run({ [LATEST]: limited(), [REDIRECT]: status(302, { location: `${WEB}/${REPO}/releases/tag/jira-v0.2.2` }) });
  assert.equal(r.source, "committed");
  assert.deepEqual(r.release, committed);
});

test("a newer tag whose assets 404 → committed", async () => {
  const r = await run({
    [LATEST]: limited(),
    [REDIRECT]: status(302, { location: `${WEB}/${REPO}/releases/tag/v1.3.0` }),
    [asset("v1.3.0")]: status(404),
  });
  assert.equal(r.source, "committed");
  assert.deepEqual(r.release, committed);
  assert.match(r.notes.at(-1), /app-installer\.sh is not there \(404\)/);
});

test("a redirect older than the committed tag → committed", async () => {
  const r = await run({ [LATEST]: limited(), [REDIRECT]: status(302, { location: `${WEB}/${REPO}/releases/tag/v1.1.0` }) });
  assert.equal(r.source, "committed");
});

test("the budget bounds a hanging network", async () => {
  let t = 0;
  const r = await run({ [LATEST]: down, [REDIRECT]: down }, { budgetMs: 1500, now: () => t, sleep: async (ms) => { t += ms; } });
  // 1 s of backoff spent; the 3 s one does not fit in what is left.
  assert.equal(r.fetch.asked.filter((a) => a.key === LATEST).length, 2);
  assert.equal(r.source, "committed");
});

test("pinned check: release.json against the newest vX.Y.Z tag reachable", () => {
  assert.deepEqual(pinnedIsCurrent("v0.3.0", ["v0.3.0", "v0.3.2", "jira-v0.9.0"]), { ok: false, newest: "v0.3.2" });
  assert.deepEqual(pinnedIsCurrent("v0.3.2", ["v0.3.0", "v0.3.2", "v0.4.0-rc0"]), { ok: true, newest: "v0.3.2" });
  assert.deepEqual(pinnedIsCurrent("v0.3.2", []), { ok: false, newest: null });
});
