# [SEV-2] `j` from a fold header lands cursor inside the folded region

## Reproduction

Workspace: /tmp/mnml-nvhunt2/scen9 with code.rs:

```rust
fn foo() {
    let x = 1;
    let y = 2;
    println!("{} {}", x, y);
}
```

```jsonl
{"cmd":"wait_ms","ms":300}
{"cmd":"open","path":"code.rs"}
{"cmd":"wait_ms","ms":400}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"g g"}
{"cmd":"type","text":"zc"}
{"cmd":"wait_ms","ms":200}
{"cmd":"type","text":"j"}
{"cmd":"wait_ms","ms":100}
{"cmd":"snapshot"}
```

## Expected

After `zc` on the fold header (line 1), the fold covers lines 2–5 and the
screen shows `fn foo() {    ⋯ 4 hidden` on line 1 with line 6 next.
`j` from line 1 should move to line 6 — the first _visible_ line after
the closed fold. Cursor: (line 6, col 1).

## Actual

Cursor lands at (line 2, col 1) — the first hidden line inside the fold.
Any subsequent `l`/`w` motion happens inside the invisible region; the
user has no visual anchor.

## Source pointer

Unknown exact file:line. `MoveDown` in `src/edit_op.rs` doesn't consult
`buffer.folds`; the fold hit-testing lives in `src/ui/editor_view.rs` for
render, but the cursor bump is on the state side.

## Notes

Vim treats a closed fold as a single "line" for cursor motion — `j`/`k`
skip the fold body. This is fundamental to fold ergonomics; without it a
folded section is basically unnavigable.
