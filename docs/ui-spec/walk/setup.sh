#!/bin/bash
set -eu
ROOT=/private/tmp/walk
# The workspace the walk copies: any real multi-repo folder of yours.
WALK_WS="${WALK_WS:?set WALK_WS to the workspace folder the walk should copy}"
WALK_PNG="${WALK_PNG:-}"
rm -rf "$ROOT"; mkdir -p "$ROOT/pristine" "$ROOT/home/bin" "$ROOT/home/.claude/projects" "$ROOT/out"
# 1. workspace copy (keep .git; drop the heavy dirs and stale IPC)
rsync -a --exclude node_modules --exclude target --exclude zig-out --exclude .mnml/ipc --exclude .mnml/ipc-zig --exclude .mnml/chrome-profile \
  "$WALK_WS"/ "$ROOT/pristine/ws/"
# sample files of every language the walk opens (the workspace has none of these)
S="$ROOT/pristine/ws/walk-samples"; mkdir -p "$S" "$ROOT/pristine/ws/requests"
cat >"$S/sample.ts" <<'T'
// sample.ts — a TypeScript file for the walkthrough
export interface Todo { id: number; title: string; done: boolean }
export function toggle(t: Todo): Todo {
  return { ...t, done: !t.done };
}
const items: Todo[] = [{ id: 1, title: "walk", done: false }];
console.log(items.map(toggle));
T
cat >"$S/sample.py" <<'T'
"""sample.py — a Python file for the walkthrough"""
import json
from dataclasses import dataclass

@dataclass
class Todo:
    id: int
    title: str
    done: bool = False

def toggle(t: Todo) -> Todo:
    return Todo(t.id, t.title, not t.done)

if __name__ == "__main__":
    print(json.dumps([toggle(Todo(1, "walk")).__dict__]))
T
cat >"$S/sample.go" <<'T'
// sample.go — a Go file for the walkthrough
package main

import "fmt"

type Todo struct {
	ID    int
	Title string
	Done  bool
}

func toggle(t Todo) Todo { t.Done = !t.Done; return t }

func main() {
	fmt.Println(toggle(Todo{1, "walk", false}))
}
T
cat >"$S/sample.rs" <<'T'
//! sample.rs — a Rust file for the walkthrough
#[derive(Debug, Clone)]
pub struct Todo {
    pub id: u32,
    pub title: String,
    pub done: bool,
}

impl Todo {
    pub fn toggle(&self) -> Todo {
        Todo { done: !self.done, ..self.clone() }
    }
}

fn main() {
    let t = Todo { id: 1, title: "walk".into(), done: false };
    println!("{:?}", t.toggle());
}
T
cat >"$S/sample.md" <<'T'
# Walkthrough sample

A **markdown** file with a list, a link and a code block.

- one
- two
- [mnml](https://example.com)

```rust
fn main() { println!("hi"); }
```

| col | val |
|-----|-----|
| a   | 1   |
T
cat >"$S/sample.json" <<'T'
{
  "name": "walk",
  "version": "0.1.0",
  "items": [{"id": 1, "title": "walk", "done": false}],
  "nested": {"a": true, "b": null, "c": 3.5}
}
T
cat >"$S/sample.zon" <<'T'
.{
    .name = "walk",
    .version = "0.1.0",
    .dependencies = .{
        .vaxis = .{ .url = "https://example.com/vaxis.tar.gz", .hash = "1220abcd" },
    },
    .paths = .{ "build.zig", "src" },
}
T
cat >"$S/sample.lua" <<'T'
-- sample.lua — a Lua file for the walkthrough
local M = {}
function M.toggle(t)
  return { id = t.id, title = t.title, done = not t.done }
end
print(M.toggle({ id = 1, title = "walk", done = false }).done)
return M
T
cat >"$S/sample.toml" <<'T'
# sample.toml — a TOML file for the walkthrough
[package]
name = "walk"
version = "0.1.0"

[[items]]
id = 1
title = "walk"
done = false
T
cat >"$S/sample.yml" <<'T'
# sample.yml — a YAML file for the walkthrough
name: walk
version: 0.1.0
items:
  - id: 1
    title: walk
    done: false
nested:
  a: true
  b: ~
T
# demo.http comes from the chrome fixture: FIXTURE=dir, else the main
# checkout's git-ignored .mnml/chrome-fixture, else its older place
# beside the main checkout (<repo>-worktrees/chrome-fixture).
if [ -z "${FIXTURE:-}" ]; then
  REPO=$(cd "$(dirname "$0")/../../.." && pwd); . "$REPO/tools/wt-lib.sh"; MAIN=$(wt_main "$REPO")
  FIXTURE=$MAIN/.mnml/chrome-fixture; [ -d "$FIXTURE" ] || FIXTURE=$MAIN-worktrees/chrome-fixture
fi
cp "$FIXTURE/ws/requests/demo.http" "$ROOT/pristine/ws/requests/demo.http"
[ -n "$WALK_PNG" ] && cp "$WALK_PNG" "$S/sample.png"
# 2. data roots: private copies of the REAL ~/.config/mnml (both apps read it; Rust config.toml, Zig config.zon)
cp -R $HOME/.config/mnml "$ROOT/pristine/rs-data"
cp -R $HOME/.config/mnml "$ROOT/pristine/zig-data"
rm -rf "$ROOT/pristine/rs-data/backups" "$ROOT/pristine/zig-data/backups"
# 3. HOME: a private dir whose .claude mirrors the real one read-only-by-intent
for e in $HOME/.claude/* $HOME/.claude/.[!.]*; do
  b=$(basename "$e"); [ "$b" = projects ] && continue; ln -s "$e" "$ROOT/home/.claude/$b"
done
P=$HOME/.claude/projects
ln -s "$P/-Users-chrismclennan-Projects-mnml-zig" "$ROOT/home/.claude/projects/-Users-chrismclennan-Projects-mnml-zig"
for n in 1 2 3 4; do
  mkdir -p "$ROOT/slot$n"
  ln -s "$P/-Users-chrismclennan-Projects-acmeco-claude-workspace" "$ROOT/home/.claude/projects/-private-tmp-walk-slot$n-ws"
done
# the user's git identity / gh etc: symlink a few dotfiles so git works as the user
for f in .gitconfig .gitignore_global .config; do [ -e "$HOME/$f" ] && ln -s "$HOME/$f" "$ROOT/home/$f"; done
# 4. shims — never the real CLI
cat >"$ROOT/home/bin/claude" <<'T'
#!/bin/bash
# fake claude for the walkthrough: never the real CLI
case "${1:-}" in
  --version|-v) echo "2.0.0 (walk shim)"; exit 0 ;;
esac
sid=""; for a in "$@"; do case "$prev" in --resume|--session-id) sid=$a;; esac; prev=$a; done
printf '\033]0;\342\234\263 walk shim\007'
echo "claude (walk shim) $*"
echo "> "
exec -a claude /bin/sh -c 'while :; do sleep 1; done' --resume "$sid"
T
cp "$ROOT/home/bin/claude" "$ROOT/home/bin/codex"; sed -i '' 's/claude (walk shim)/codex (walk shim)/; s/-a claude/-a codex/' "$ROOT/home/bin/codex"
chmod +x "$ROOT/home/bin/claude" "$ROOT/home/bin/codex"
du -sh "$ROOT/pristine"/*; echo "setup done: $ROOT"
