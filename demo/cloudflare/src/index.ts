// The hosted web demo's Worker: one container per visitor session.
//
// Served under BASE_PATH (wrangler.jsonc: "/demo", the route on mnml.sh);
// the paths below are relative to it, and the prefix is stripped before a
// request reaches the container, which serves at `/` as in the local trial.
// The page uses relative URLs only, so it works at either.
//
//   GET  /            no `s` → a new session: 302 to `/?s=<id>`
//                     (`/demo` itself redirects to `/demo/` first)
//   GET  /new         the same ("Start again" on the page comes here)
//   GET  /healthz     the Worker itself; touches no container
//   *    /…?s=<id>    the session's container, unchanged — the page, its
//                     fonts and xterm.js, /api/* (the pointer stream is
//                     server-sent events), and ttyd's /term/token and
//                     /term/ws websocket
//
// A session id is a Durable Object id minted here (`newUniqueId`, 64 hex
// characters): a visitor cannot pick or guess one, and every id is a new
// DemoSession, so a new id is a new container. It travels in the URL, not
// a cookie: a cookie is shared by every tab, and two tabs must be two
// containers. The page adds `s` to the requests it makes itself; the ones
// the browser makes for it (fonts, scripts, the stylesheet) carry it in
// their Referer.
import { Container } from "@cloudflare/containers";
import { MODE_HEADER, type Mode, filterWebSocket, modeFor, unlock } from "./control";

const PORT = 7681;
// A session's container is stopped this long after its cap however it is
// being used: an abandoned tab that is still polling keeps a container
// "active", so `sleepAfter` alone would not end it.
const GRACE_S = 60;
const SESSION_RE = /^[0-9a-f]{64}$/;

export class DemoSession extends Container<Env> {
	defaultPort = PORT;
	// After the page lets go (the session ended, the tab closed), the
	// instance sleeps two minutes later and stops billing.
	sleepAfter = "2m";
	// No egress: the image needs nothing outbound (the Jira and Bitbucket
	// it shows are fakes inside it; the Claude session is a shim).
	enableInternet = false;
	// One start at a time: the page's first requests (its fonts, the state
	// poll, the websocket) arrive together, and each would otherwise begin
	// its own start-and-wait while the container is still coming up.
	private starting?: Promise<void>;
	// `ask` mode: the visitor pressed "Take control" in this session.
	private granted = false;

	constructor(ctx: DurableObjectState<{}>, env: Env) {
		super(ctx, env);
		this.envVars = {
			MNML_DEMO_LISTEN: `tcp:0.0.0.0:${PORT}`,
			MNML_DEMO_CAP_S: env.CAP_S,
			MNML_DEMO_IDLE_S: env.IDLE_S,
		};
	}

	override async fetch(request: Request): Promise<Response> {
		const now = Date.now();
		let born = await this.ctx.storage.get<number>("born");
		if (born === undefined) {
			born = now;
			await this.ctx.storage.put("born", born);
			await this.schedule(Number(this.env.CAP_S) + GRACE_S, "expire");
		}
		if ((await this.ctx.storage.get<boolean>("expired")) || now > born + (Number(this.env.CAP_S) + GRACE_S) * 1000) {
			await this.expire();
			return new Response("this demo session is over\n", { status: 410 });
		}
		// The mode the Worker decided for this request (missing = view).
		const h = request.headers.get(MODE_HEADER);
		const mode: Mode = h === "open" || h === "ask" ? h : "view";
		this.granted = (await this.ctx.storage.get<boolean>("granted")) === true;
		const path = new URL(request.url).pathname;
		if (path === "/__mnml/control/take") {
			if (mode === "ask") await this.ctx.storage.put("granted", (this.granted = true));
			return new Response(null, { status: mode === "view" ? 403 : 204 });
		}
		// Taking over the tour is input too.
		if (path === "/api/stop" && !this.inputAllowed(mode)) return new Response("view only\n", { status: 403 });

		if (!this.ctx.container?.running || (await this.getState()).status !== "healthy") {
			// The first request's mode (the page) is the session's: the runner
			// words the in-app banner by it.
			this.starting ??= this.startAndWaitForPorts({
				startOptions: { envVars: { ...this.envVars, MNML_DEMO_CONTROL: mode } },
			}).finally(() => (this.starting = undefined));
			try {
				await this.starting;
			} catch (e) {
				return new Response(`the demo container did not start: ${e}\n`, { status: 503 });
			}
		}
		let res = await this.containerFetch(request);
		if (res.webSocket && mode !== "open") return filterWebSocket(res.webSocket, () => this.inputAllowed(mode), res.headers);
		// A connection the container dropped before answering (the class
		// answers 500 with its own text) is retried once when the request can be
		// repeated: a GET has no body.
		if (res.status === 500 && request.method === "GET" && /^(Error proxying request|Container suddenly disconnected)/.test(await res.clone().text())) {
			await scheduler.wait(250);
			res = await this.containerFetch(request);
			if (res.webSocket && mode !== "open") return filterWebSocket(res.webSocket, () => this.inputAllowed(mode), res.headers);
		}
		return res;
	}

	private inputAllowed(mode: Mode): boolean {
		return mode === "open" || (mode === "ask" && this.granted);
	}

	// The hard end of a session: stop the container (its websocket and
	// streams close with it) and never start one again under this id.
	async expire(): Promise<void> {
		await this.ctx.storage.put("expired", true);
		if (this.ctx.container?.running) await this.stop();
	}

	override onError(error: unknown) {
		console.error("demo container error", this.ctx.id.toString(), error);
		throw error;
	}
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const base = (env.BASE_PATH || "").replace(/\/+$/, "");
		let path = url.pathname;
		// `?control=<secret>` on the demo's own page: maybe unlock this
		// browser, then the same URL without it.
		if (url.searchParams.has("control") && (path === base || path === `${base}/`))
			return unlock(url, env, base || "/");
		if (base) {
			if (path === base) return redirect(`${base}/`);
			if (!path.startsWith(`${base}/`)) return new Response("not found\n", { status: 404 });
			path = path.slice(base.length);
		}

		if (path === "/healthz") return new Response("ok\n", { headers: { "cache-control": "no-store" } });

		// The Durable Object's own paths are not the visitor's to call.
		if (path.startsWith("/__mnml/")) return new Response("not found\n", { status: 404 });

		const s = url.searchParams.get("s") ?? sessionFromReferer(request);
		if (path === "/new" || (path === "/" && !s)) {
			const ip = request.headers.get("cf-connecting-ip") ?? "local";
			const { success } = await env.NEW_SESSIONS.limit({ key: ip });
			if (!success) return page(429, "Too many new sessions", "Wait a minute, then try again.");
			return redirect(`${base}/?s=${env.DEMO.newUniqueId().toString()}`);
		}
		if (!s || !SESSION_RE.test(s)) return new Response("no demo session\n", { status: 400 });
		let id: DurableObjectId;
		try {
			id = env.DEMO.idFromString(s);
		} catch {
			return new Response("no demo session\n", { status: 400 });
		}

		const mode = await modeFor(request, env);
		const target = new URL(url);
		// "Take control" (ask mode) is the Durable Object's to record.
		target.pathname = path === "/control/take" && request.method === "POST" ? "/__mnml/control/take" : path;
		target.searchParams.delete("s");
		const fwd = new Request(target, request);
		fwd.headers.set(MODE_HEADER, mode);
		const res = await env.DEMO.get(id).fetch(fwd);

		if (path === "/") {
			// An old link to a session that is over: a fresh one.
			if (res.status === 410) return redirect(`${base}/new`);
			// No instance (max_instances reached, or the platform is still
			// provisioning one): say so instead of the platform's text.
			if (res.status >= 500 || res.status === 429)
				return page(503, "The demo is busy", "Every sandbox is in use. Try again in a minute.");
			const h = new Headers(res.headers);
			h.set("cache-control", "no-store");
			// The browser's own requests (fonts, scripts) must keep `?s=` in
			// their Referer; same-origin keeps the whole URL.
			h.set("referrer-policy", "same-origin");
			// The page learns its mode from a meta tag (no tag: the local
			// trial, open).
			return new HTMLRewriter()
				.on("head", { element: (e) => { e.append(`<meta name="mnml-demo-control" content="${mode}">`, { html: true }); } })
				.transform(new Response(res.body, { status: res.status, headers: h }));
		}
		return res;
	},
} satisfies ExportedHandler<Env>;

function sessionFromReferer(request: Request): string | null {
	const ref = request.headers.get("referer");
	if (!ref) return null;
	try {
		const r = new URL(ref);
		return r.host === new URL(request.url).host ? r.searchParams.get("s") : null;
	} catch {
		return null;
	}
}

function redirect(location: string): Response {
	return new Response(null, { status: 302, headers: { location, "cache-control": "no-store" } });
}

function page(status: number, title: string, text: string): Response {
	const body = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>mnml demo</title><style>body{background:#1e222a;color:#c8ccd4;font:16px/1.5 system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0 16px}h1{font-size:20px;color:#fff}</style>
<div><h1>${title}</h1><p>${text}</p><p><a href="" style="color:#53adda">Try again</a></p></div>`;
	return new Response(body, {
		status,
		headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "retry-after": "60" },
	});
}
