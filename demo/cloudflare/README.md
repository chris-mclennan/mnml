# demo/cloudflare — the browser demo on Cloudflare Containers

The hosted form of `demo/`: **mnml.sh/demo**, one fresh container per
visitor session. Nothing here is deployed until someone runs `wrangler
deploy`; the site has no link to it.

## How it fits together

```
browser ── mnml.sh/demo/?s=<id> ──▶ Worker (src/index.ts)          route on the mnml.sh zone
                                     │  strips /demo, decides the control mode
                                     ▼
                         Durable Object DemoSession(<id>)           one per session id
                                     │  starts ONE container, proxies HTTP,
                                     │  the SSE pointer stream and ttyd's websocket
                                     ▼
                         container (demo/Dockerfile, linux/amd64)    basic: 1/4 vCPU, 1 GiB, 4 GB
                           attract.py on tcp:0.0.0.0:7681, ttyd, mnml --demo
                           enableInternet = false: no egress
```

- **A session is a Durable Object id** the Worker mints (`newUniqueId`,
  64 hex characters) on `/demo/` or `/demo/new` and redirects to
  `/demo/?s=<id>`. A new id is a new Durable Object, and so a new
  container: *fresh container per visitor* is structural, not a cleanup
  step. Ids cannot be chosen or guessed (`idFromString` rejects anything
  the namespace did not mint).
- **Why the URL and not a cookie:** a cookie is shared by every tab, and
  two tabs must be two containers. The page adds `s` to the requests it
  makes itself (`api/*`, `term/token`, `term/ws`, the pointer stream);
  the browser's own requests for the fonts, scripts and stylesheet carry
  it in their `Referer` (the page is served with `Referrer-Policy:
  same-origin`). A reload keeps the session (same container, a new `mnml
  --demo` in it); **Start again** goes to `/demo/new`, a new container.
- **The prefix:** the Worker strips `BASE_PATH` (`/demo`) before a request
  reaches the container, which serves at `/` exactly as in the local
  trial; the page uses relative URLs only, so it works at either. `/demo`
  redirects to `/demo/`. `BASE_PATH` is a var, so a hostname of its own
  (`demo.mnml.sh`, `BASE_PATH = ""`) needs no code change.
- **The port:** the runner listens on TCP 7681 (`MNML_DEMO_LISTEN=
  tcp:0.0.0.0:7681`, set by the Durable Object). The Durable Object
  reaches it through `ctx.container.getTcpPort(7681)` (the `Container`
  class's `defaultPort`); a container has no public ingress, so only its
  Durable Object can reach that port. The local trial keeps its unix
  socket + relay (`demo/run-local.sh`, `--network none`).
- **Ending:** the container's own 10-minute cap stays (the runner ends
  the session; the page shows *Start again*). A hosted page whose session
  ended stops polling and closes its streams, so the instance sleeps
  `sleepAfter` (2 minutes) later. Because an open tab that keeps polling
  counts as activity, the Durable Object also stops the container for good
  a minute after the cap (`expire`), and an old `?s=` link after that
  redirects to a new session.
- **Limits:** `max_instances` (20) caps concurrent visitors; past it the
  page says the demo is busy. New sessions are rate-limited to 6 a minute
  per IP (`ratelimits`).
- **Egress:** `enableInternet = false`, and no `allowedHosts` or outbound
  handlers: nothing in the container can reach out. The Jira and Bitbucket
  it shows are fakes inside it; the Claude session is a shim.

## Who may drive it: `DEMO_CONTROL`

| value | what a visitor can do |
| --- | --- |
| `view` (default) | watch: the tour plays, Replay and the part picker work, the countdown runs. Keys, clicks, wheel and paste never reach the container. |
| `ask` | as `view`, plus a **Take control** button under the frame: a one-line notice (what is real, what is a stand-in), then input flows and the first key takes over the tour. |
| `open` | any key or click takes over (the local trial's behaviour). |

Enforced by the Worker, not only the page: the Worker decides the mode and
the Durable Object drops ttyd's input frames (`'0'` type) and refuses
`api/stop` unless the session may drive. A hand-made websocket client to a
`view` session reaches nothing (verified, see below).

**Private unlock.** `https://mnml.sh/demo?control=<secret>` compares the
value with the secret `DEMO_CONTROL_SECRET` (constant-time); on a match it
sets a signed (HMAC-SHA-256), `HttpOnly`, `SameSite=Strict`, `Secure`
cookie on `/demo` for 30 days that makes **that browser** `open` whatever
`DEMO_CONTROL` says — every tab in it, since a cookie is per browser.
Wrong or missing secret: the same redirect without the parameter, no
cookie, nothing to tell them apart. Set the secret once:

```bash
npx wrangler secret put DEMO_CONTROL_SECRET     # prompts for the value; never in the repo
```

**Changing the mode** is an edit of `DEMO_CONTROL` in `wrangler.jsonc`
and `npx wrangler deploy`. The image does not change, so the deploy only
uploads the Worker (Docker's cache rebuilds the thin `Dockerfile` layer
instantly and the registry already has it). Flipping it without a deploy
would need a KV namespace read per request; not done — a deploy takes
seconds.

## Run it locally

Needs Docker (Colima works) **with the buildx plugin** (wrangler builds
with `docker build --load --provenance=false`; without buildx that fails
with "unknown flag"), Node, and this machine's Zig 0.16 for the
cross-compile. Wrangler 4.145.0 (pinned in `package.json`) runs
Containers locally through Docker; the local container runs the amd64
image under emulation (Rosetta on Apple silicon).

```bash
cd demo/cloudflare
npm install
./build-image.sh                 # mnml-demo:cf-amd64: binaries cross-compiled here, then the image
printf 'DEMO_CONTROL_SECRET=%s\n' "$(openssl rand -hex 16)" > .dev.vars   # git-ignored
npx wrangler dev                 # http://localhost:8787/demo
npx wrangler dev --var DEMO_CONTROL:ask     # or open; --var CAP_S:45 for a short cap
```

`wrangler dev` builds `./Dockerfile` (FROM the local `mnml-demo:cf-amd64`)
and starts a container per session as the Worker asks for one. Stopping
`wrangler dev` with a signal can leave its containers running; `docker ps
--filter name=workerd-mnml-demo` lists them. Re-run `./build-image.sh`
after changing the app or `demo/`, then restart `wrangler dev`.

## Deploy (you run this)

```bash
cd demo/cloudflare
npm install
./build-image.sh
npx wrangler secret put DEMO_CONTROL_SECRET    # once
npx wrangler deploy
```

`wrangler deploy` uploads the Worker, builds `./Dockerfile` for
linux/amd64, pushes it to Cloudflare's registry and creates the
Containers application; the first deploy can take several minutes before
containers answer. Check with `npx wrangler containers list` and
`curl https://mnml.sh/demo/healthz` (the Worker alone, no container).

**The route.** `wrangler.jsonc` routes `mnml.sh/demo` and `mnml.sh/demo/*`
on the `mnml.sh` zone to this Worker (`workers_dev` and preview URLs
off). A Worker route on the zone takes precedence over the Pages site for
the paths it matches, and only those — the rest of mnml.sh stays the
site. The patterns are the two exact ones rather than `mnml.sh/demo*`,
which would also take any page whose path merely starts with `demo`
(`/demos`, `/demo-video`). If the site ever gets its own `/demo` page,
this route hides it. The alternative is a hostname of its own: a
`demo.mnml.sh` custom domain (`"routes": [{ "pattern": "demo.mnml.sh",
"custom_domain": true }]`, `BASE_PATH = ""`).

## Sizing: `basic`

Measured under `wrangler dev` (the same image, amd64 under Rosetta):

| | |
| --- | --- |
| peak memory of one session (cgroup `memory.peak`), whole tour twice round, all 8 flows | **99 MiB** (steady 65–90 MiB) |
| image | **108 MB** compressed, **460 MB** unpacked (326 MB of files in the running container) |
| CPU | median 0.6 % of a core, p90 10 %, bursts to one core at start |
| cold start, first request → tour playing (new container) | **2.8–2.9 s** (one 4.6 s outlier); page HTML in 0.75–0.9 s |

`basic` (1/4 vCPU, 1 GiB, 4 GB disk) has 10× the memory and disk the
session uses. `lite` (1/16 vCPU, 256 MiB) would hold the memory but a
sixteenth of a core is too little for mnml's start and the tour's
bursts; `standard-1` (4 GiB) buys nothing here. Cold start on Cloudflare
is the platform's (image pull to a new location, VM start) plus the
~2 s mnml needs; expect more than local on a location's first start.

## Cost (Workers Paid, `basic`)

Billed per 10 ms while running: memory and disk on the instance size,
CPU on use ($0.0000025/GiB-s, $0.00000007/GB-s, $0.000020/vCPU-s; the
plan includes 25 GiB-h, 200 GB-h and 375 vCPU-min a month). A session is
10 minutes plus the 2-minute sleep tail: **720 s**.

| per session | memory 1 GiB × 720 s | disk 4 GB × 720 s | CPU (~5 % of a core avg; 1/4 core flat out) | total |
| --- | --- | --- | --- | --- |
| | 0.2 GiB-h = $0.0018 | 0.8 GB-h = $0.0002 | 0.6 vCPU-min = $0.0007 (3 min = $0.0036) | **≈ $0.003** (worst ≈ $0.006) |

| per month | memory | disk | CPU | bill beyond the $5 plan |
| --- | --- | --- | --- | --- |
| 100 sessions | 20 GiB-h (in the 25 included) | 80 GB-h (in 200) | 60 min (in 375) | **$0** |
| 1000 sessions | 200 GiB-h → 175 over = $1.58 | 800 GB-h → 600 over = $0.15 | 600 min → 225 over = $0.27 (worst $3.15) | **≈ $2.00** (worst ≈ $4.90) |

Workers and Durable Object requests (the page polls state once a second,
~700 requests a session) and Durable Object duration stay inside the
plan's included amounts at 1000 sessions. Egress is the terminal stream
and ~0.5 MB of fonts per session, far inside the 1 TB included.

## What was verified, and what only a deploy can show

Verified locally, headed Chrome at 1960×880, DPR 2, against `wrangler dev`
at `http://localhost:8787/demo` (`.verify/demo-cloudflare/` in the
worktree that built this): the fonts, the 200×60 grid filling the frame,
the tour with its pointer, take-over, Replay, Full screen, right-click
reaching mnml; two tabs → two `?s=` ids → two containers (a file written
in one is absent in the other; separate sandboxes; separate runner
state); Start again → a new id and a new container; the cap ending →
the page goes quiet (0 requests in 10 s) and Start again works; a closed
tab's container stops within the 2-minute `sleepAfter`, an ended
session's a minute past its cap, and its old link hands out a new
session; `view` drops a click, keys, wheel, the banner and a hand-made
websocket client's input (0 input events in the app's `events.jsonl`;
the same client with the unlock cookie drives it), `?control=` unlocks
one browser while another stays `view`, `ask` gates until the button.

Egress in `wrangler dev`: from inside the container DNS answers NXDOMAIN
for everything, HTTP and HTTPS are cut, TCP connects are accepted by
the local interceptor and closed without data. That is the local
emulation (a sidecar with TPROXY rules); `enableInternet = false` on
Cloudflare is a property of the deployed runtime, so **after deploy**,
check egress from a live instance (for example with `wrangler containers
ssh`, which needs SSH enabled in the container config) and check:
the cold start from a far location, `max_instances` reached → the busy
page, the per-IP rate limit, the route not shadowing anything on the
site, and the `Secure` unlock cookie over HTTPS.

## Rollback

```bash
npx wrangler delete                          # the Worker, its route and its Durable Objects
npx wrangler containers list                 # then, if the application is still listed:
npx wrangler containers delete <ID>
npx wrangler containers images list          # and the image:
npx wrangler containers images delete <IMAGE>:<TAG>
```

Deleting the Worker removes the `mnml.sh/demo*` routes with it, so those
paths fall back to the Pages site. `demo/` (and the local trial) stays.
