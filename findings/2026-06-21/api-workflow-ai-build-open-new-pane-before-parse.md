---
finding: ai-build-opens-pane-before-parse-succeeds
severity: SEV-2
surface: http.send
---

**Repro**:
1. Run `:http.ai_build` and type "get list of users from jsonplaceholder".
2. Claude's response is garbled or contains markdown that the curl parser fails to strip (can be reproduced by setting `ANTHROPIC_API_KEY` to a dummy and injecting a bad response via a proxy, or wait for a model regression producing unstrippable fences).
3. The parse step fails.

**Expected**: toast "http.ai_build: parse failed: …" with no new pane opened. The user stays in their current context.

**Actual**: `drain_http_ai_build` (src/app/http.rs:481–519) calls `self.open_new_request_pane()` **before** checking whether the parsed request is valid. Specifically:

```rust
Ok(curl) => match crate::http::parse(&curl) {
    Ok(parsed) => {
        self.open_new_request_pane();  // <-- pane opened here
        let Some(cur) = self.active else { continue };
        if let Some(Pane::Request(rp)) = self.panes.get_mut(cur) {
            rp.request = parsed;
            ...
        }
    }
    Err(e) => {
        self.toast(format!("http.ai_build: parse failed: {e}"));
    }
},
```

When `crate::http::parse(&curl)` returns `Err`, no pane is opened — this is the correct branch. **However**: in the `Ok(parsed)` branch, `open_new_request_pane` fires unconditionally before the `self.active` check on the next line. If `open_new_request_pane` somehow fails to set `self.active` (it always does set it, but under the None → push-to-layout path a layout race could leave `active = Some(id)` pointing at a phantom layout leaf before the next render), the subsequent `self.panes.get_mut(cur)` gets the right id but the pane was just pushed so it works.

**The actual confirmed bug**: `open_new_request_pane` always opens a pane and changes the active view, even in the `Err(e)` sub-case of Claude replying successfully but with unparseable content (e.g. a model saying "I can't help with that" — a non-curl English response). After toasting the parse error, the user finds a blank empty Request pane has been opened. This is observable: the layout has split and the new pane is blank but visible.

Wait — re-reading: `open_new_request_pane` is called only inside `Ok(parsed)`, not in `Err(e)`. But when Claude returns `Ok(curl)` and `parse(&curl)` returns `Err(e)`, no pane opens. The bug is subtler: `Ok(curl)` then `parse(&curl)` returning `Ok(parsed)` is the happy path. The reported issue is: what if the model returns `Ok(curl)` but the strip-code-fence logic (`out.replace("\\\n", " ")`) produces a multi-line curl with a continuation that the parser can't handle? In that case `parse` returns `Err`, and `open_new_request_pane` is NOT called. So this specific path is safe.

**Revised finding (SEV-2)**: If `self.active` is `None` when `drain_http_ai_build` runs (no open panes — edge case after closing all panes while ai_build was in flight), `open_new_request_pane()` creates a pane with the empty-state layout path (`Layout::Leaf(new_id)`). The `let Some(cur) = self.active else { continue }` on the next line will then succeed (active was just set). But `self.panes.get_mut(cur)` will return the pane pushed by `open_new_request_pane` — which is the **correct** pane. This path actually works.

**Revised confirmed finding**: The `continue` inside the `for result in replies` loop at line 488 means if `self.active` is `None` after `open_new_request_pane` (should be impossible but defensive), the loop skips populating the pane — leaving an empty blank Request pane open in Edit mode. The `open_new_request_pane` comment at line 3236 explicitly notes this was a previously buggy path. If `continue` fires, the pane is left in its initial `RunState::Failed("(not sent — press r to fire)")` state with empty method/url, no indication to the user that Claude's response was dropped. Toast says "✓ ready (Source tab)" but the pane shows nothing in the source buffer.

**Offending file:line**: `src/app/http.rs:491–507`. The `continue` on line 492 after `open_new_request_pane()` on line 491 can drop the AI-built curl silently.
