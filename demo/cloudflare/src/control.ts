// Who may drive the demo, decided here (the Worker), not only in the page.
//
//   view   the tour plays; Replay and the part picker work; the visitor's
//          keys, clicks, wheel and paste never reach the container
//   ask    as view, until the visitor presses "Take control" (a one-line
//          notice, then input flows and the first key takes over the tour)
//   open   any key or click takes over (the local trial's behaviour)
//
// DEMO_CONTROL (wrangler.jsonc) sets the mode for everyone. A browser that
// opened `<base>/?control=<DEMO_CONTROL_SECRET>` carries a signed, HttpOnly
// cookie that makes it `open` whatever DEMO_CONTROL says.

export type Mode = "view" | "ask" | "open";
export const MODE_HEADER = "x-mnml-demo-control";
const COOKIE = "mnml_demo_control";
const COOKIE_DAYS = 30;

export function configuredMode(env: Env): Mode {
	const m = String(env.DEMO_CONTROL || "view");
	return m === "ask" || m === "open" ? m : "view";
}

// The mode for this request: `open` for an unlocked browser, else the
// configured one.
export async function modeFor(request: Request, env: Env): Promise<Mode> {
	const secret = env.DEMO_CONTROL_SECRET;
	if (secret) {
		const v = cookie(request, COOKIE);
		if (v && (await validToken(v, secret))) return "open";
	}
	return configuredMode(env);
}

// `?control=<secret>`: on a match, the response sets the unlock cookie.
// Match or not, the parameter is dropped with a redirect, so a wrong or
// missing secret looks exactly like a right one from outside.
export async function unlock(url: URL, env: Env, cookiePath: string): Promise<Response> {
	const given = url.searchParams.get("control") ?? "";
	const target = new URL(url);
	target.searchParams.delete("control");
	const headers = new Headers({ location: target.pathname + target.search, "cache-control": "no-store" });
	const secret = env.DEMO_CONTROL_SECRET;
	if (secret && (await sameSecret(given, secret))) {
		const exp = Math.floor(Date.now() / 1000) + COOKIE_DAYS * 86400;
		const secure = url.protocol === "https:" ? "; Secure" : "";
		headers.append(
			"set-cookie",
			`${COOKIE}=${exp}.${await sign(`open.${exp}`, secret)}; Path=${cookiePath}; Max-Age=${COOKIE_DAYS * 86400}; HttpOnly; SameSite=Strict${secure}`,
		);
	}
	return new Response(null, { status: 302, headers });
}

// The container's websocket, filtered: ttyd's client frames are a type
// byte and a payload — '0' input (keys, mouse, paste, and the terminal's
// answers to the app's queries), '1' resize, '2'/'3' flow control, and
// the first frame is the JSON handshake. Input passes only while
// `allowInput()` says so; everything else passes unchanged.
export function filterWebSocket(upstream: WebSocket, allowInput: () => boolean, headers: Headers): Response {
	const [client, server] = Object.values(new WebSocketPair());
	upstream.accept();
	server.accept();
	// Frames can arrive as Blobs; reading one is async, so each direction
	// is a chain that keeps the frames in order.
	const bytes = async (d: unknown) => (d instanceof Blob ? await d.arrayBuffer() : (d as ArrayBuffer | string));
	let toContainer = Promise.resolve();
	let toClient = Promise.resolve();
	server.addEventListener("message", (e) => {
		toContainer = toContainer.then(async () => {
			const d = await bytes(e.data);
			const first = typeof d === "string" ? d.charCodeAt(0) : new Uint8Array(d)[0];
			if (first === 0x30 && !allowInput()) return;
			try {
				upstream.send(d);
			} catch {
				server.close(1011, "container gone");
			}
		});
	});
	upstream.addEventListener("message", (e) => {
		toClient = toClient.then(async () => {
			try {
				server.send(await bytes(e.data));
			} catch {
				upstream.close(1011, "client gone");
			}
		});
	});
	const code = (c: number) => (c === 1005 || c === 1006 ? 1000 : c);
	server.addEventListener("close", (e) => upstream.close(code(e.code), e.reason));
	upstream.addEventListener("close", (e) => server.close(code(e.code), e.reason));
	server.addEventListener("error", () => upstream.close(1011, "client error"));
	upstream.addEventListener("error", () => server.close(1011, "container error"));
	return new Response(null, { status: 101, webSocket: client, headers });
}

function cookie(request: Request, name: string): string | null {
	for (const part of (request.headers.get("cookie") ?? "").split(/;\s*/)) {
		const i = part.indexOf("=");
		if (i > 0 && part.slice(0, i) === name) return part.slice(i + 1);
	}
	return null;
}

async function validToken(v: string, secret: string): Promise<boolean> {
	const [exp, mac] = v.split(".");
	if (!exp || !mac || !/^\d+$/.test(exp) || Number(exp) < Date.now() / 1000) return false;
	return sameSecret(mac, await sign(`open.${exp}`, secret));
}

async function sign(msg: string, secret: string): Promise<string> {
	const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)));
	return btoa(String.fromCharCode(...mac)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Constant-time comparison of two strings of any length (hashed first).
async function sameSecret(a: string, b: string): Promise<boolean> {
	const h = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
	const [x, y] = await Promise.all([h(a), h(b)]);
	return crypto.subtle.timingSafeEqual(x, y);
}
