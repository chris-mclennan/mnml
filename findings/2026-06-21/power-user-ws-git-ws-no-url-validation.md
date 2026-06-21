---
finding: ws-connect-no-url-validation
severity: SEV-3
agent: power-user-ws-git
repro: code-review
---

# `:ws.connect` accepts any URL including `http://`, garbage strings

`App::ws_connect_to` (src/app/http.rs:565-587) only checks for
empty after trim:

```rust
pub fn ws_connect_to(&mut self, url: &str) {
    let url = url.trim().to_string();
    if url.is_empty() {
        self.toast("ws: URL can't be empty");
        return;
    }
    let pane = Pane::Websocket(crate::websocket::WebsocketPane::connect(url.clone()));
    ...
}
```

There's no `ws://` / `wss://` scheme validation. The user can type:

- `http://example.com` — opens a Pane::Websocket whose worker
  immediately errors with a connect failure. User now has a
  zombie `· closed` tab they need to manually close.
- `example.com` (no scheme) — tungstenite's URI parser may
  accept it as opaque or reject; either way unclear toast.
- `wss://` (no host) — `host_of_url` strips the scheme, returns
  empty string. Tab title renders as `ws … ` with no host.

Defense-in-depth: a quick scheme + basic-URL sanity check before
spawning the worker would make all three error paths explicit:

```rust
if !(url.starts_with("ws://") || url.starts_with("wss://")) {
    self.toast(format!(
        "ws: URL must start with ws:// or wss:// (got {url})"
    ));
    return;
}
match tungstenite::http::Uri::try_from(&url[..]) {
    Ok(uri) if uri.host().is_some() => { /* ok */ },
    _ => {
        self.toast(format!("ws: malformed URL: {url}"));
        return;
    }
}
```

Cost: 8 lines. Benefit: clear toast on user typo + no zombie panes.
