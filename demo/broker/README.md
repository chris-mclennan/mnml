# demo/broker — the interface (built: `demo/cloudflare/`)

`demo/cloudflare/` implements this on Cloudflare Containers: a Durable
Object per session is the per-visitor container, the Worker routes and
proxies, `sleepAfter` plus a hard stop past the cap reap it, `max_instances`
and a per-IP rate limit bound it, `enableInternet = false` denies egress.
The text below is the contract it was built against.

The trial (`demo/run-local.sh`) starts one container by hand. The hosted
demo needs a broker that gives **every visitor a fresh container** and
throws it away afterwards. This folder is where it goes; nothing here
runs today. What it has to do, against what the image already offers:

## The container's side (exists)

- Image `mnml-demo:<tag>` (`demo/build.sh`). Entrypoint: the attract
  runner. One visitor per container: ttyd takes one websocket at a time.
- Listens on TCP `MNML_DEMO_PORT` (7681), or on a unix socket with
  `MNML_DEMO_LISTEN=unix:/path` (the local trial's `--network none` mode).
- `GET /` — the page. `GET /term/`, `/term/token`, `/term/ws` — ttyd.
  `GET /fonts/*`.
- `GET /api/state` → `{"phase": "idle|starting|tour|live|ended",
  "flow", "remaining_s", "resume_in_s", "inputs", "flows": [...]}` —
  the broker's health and reap signal: `idle` after a visitor left,
  `ended` after the cap.
- `POST /api/replay`, `POST /api/play?flow=NAME|N`, `POST /api/stop`.
- Env: `MNML_DEMO_CAP_S` (600), `MNML_DEMO_IDLE_S` (180).
- Needs no network at run time; ~1 GB memory and 2 CPUs is generous
  (measure under load before fixing limits). Exits 0 on SIGTERM; mnml's
  sandbox is removed on the way out.

## The broker's side (to build)

1. `GET /` on the public host → allocate a container (or take one from a
   small warm pool — `mnml --demo` is ready in about two seconds, the
   container in under a second more), route this visitor to it, and
   pin them there (a cookie or a per-container path/subdomain).
2. Proxy HTTP **and the websocket** to it unchanged.
3. Reap: when `/api/state` says `ended`, or `idle` for ~30 s after a
   visitor connected, or the websocket closed, or a hard ceiling (cap +
   a minute) passed — stop and delete the container. Never reuse one.
4. "Start again" on the page reloads the terminal iframe; behind a
   broker it should instead ask for a new container (change the page's
   `again` handler to hit a broker endpoint).
5. Limits: a global cap on concurrent containers, a per-IP rate limit,
   and a queue page when full.
6. Egress: none. On a host that cannot express "no network", deny all
   egress in its firewall/policy; the image needs nothing outbound.
