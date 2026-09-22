# mnml-fake-dap — a deterministic Debug Adapter

`zig build` installs `zig-out/bin/mnml-fake-dap`, a Debug Adapter
Protocol server over stdio (`Content-Length` framing, JSON) that "runs"
the launched file as a tiny line-oriented program. It exists so the
debug UI — breakpoints, the stack, variables, watches, the REPL,
stepping, exceptions, output — can be tested for real on every platform
with no toolchain installed. Everything it sends is a function of the
program text and the requests it received: no clocks, no environment,
no randomness. The same program and the same requests give the same
events, byte for byte.

`main.zig` is the protocol (`Server`) and the stdio loop; `program.zig`
is the language and the debugger model over it. Both carry their unit
tests (`zig build test` runs them, leak-checked on
`std.testing.allocator`); the DAP client's integration test in
`src/app/dap.zig` spawns the installed binary, and the
`tests/e2e/dap_session_*.test` scripts drive it through the panes.

## The language

Every line is one statement. Blank lines and `#` comments are not
statements: steps skip them and a breakpoint on one is unverified. A
breakpoint on a line stops *before* it runs; `next` runs one line;
`stepIn` on a `call` lands on the function's first line; `stepOut`
returns to the line after the `call`. Reaching the end of the file is
`exit 0`.

| statement | meaning |
|---|---|
| `let x = <literal>` | define `x` in the current frame: an int (`42`), a string (`"hi"`), or a struct (`struct{a=1,b="two"}` — fields are ints or strings; a struct value expands in the variables pane) |
| `x = <expr>` | assign to the nearest `x` (this frame, then main); an unknown name is defined here |
| `print "text"` / `print <expr>` | one `output` event (`stdout`), the text plus a newline |
| `fn f` … `end` | a function; the body is skipped at the top level |
| `call f` | run `f` in a new frame (the caller's frame sits on the `call` line); `end` returns |
| `throw "msg"` | an exception: a `stderr` output line `throw: msg`, and a stop when a filter says so (below) |
| `sleep` | a line that runs until `pause`; the stop is on the sleep line and `next` moves past it |
| `exit <code>` | end the program: `exited{exitCode}` then `terminated` |

Expressions: ints, names, `a.b` on a struct, `"strings"`, `struct{…}`,
`+ - * /`, `== != < <= > >=` (comparisons yield `1` / `0`; strings
compare with `==` / `!=` only), parentheses. Errors are reported by
name: `no such variable`, `no such field`, `not a struct`,
`type mismatch`, `division by zero`, `syntax error`. A line that does
not parse is an exception stop when it is reached, not before.

Values render as `42`, `"hi"`, `{a=1, b="two"}` with types `int`,
`string`, `struct`.

### Exceptions

`initialize` advertises two filters: `error` (stop on every throw,
default off) and `uncaught` (stop on a throw that reaches the top
level, default on). A throw inside a function is caught by its caller:
the function returns early and the caller continues after the `call`.
A throw at the top level ends the program with exit code 1 on resume
(`uncaught: msg` on stderr first). The `stopped` event carries
`reason: "exception"`, `text: "Throw"` (the exception's TYPE, as DAP
has it — `"Error"` for a runtime error such as an unknown name) and
`description: "<msg>"`, the shape debugpy sends (`text:
"ZeroDivisionError"`, `description: "division by zero"`).

## The requests

| request | answer |
|---|---|
| `initialize` | the capabilities (conditional + hit-conditional breakpoints, set-variable, evaluate-for-hovers, terminate; no step-back) and the filters, then one `output` event with `category: "telemetry"` (`fake-dap-telemetry`, a version in `data`) — debugpy's habit, which a console must not paint — and NOT the `initialized` event, which follows `launch` |
| `launch{program}` | loads the file; a missing file is `success:false` with `cannot read <path>: <error>`. The reply, then the `initialized` event — lldb-dap's and debugpy's order (the protocol's sequence diagram), so a client that waits for `initialized` before sending `launch` deadlocks here as it does against them |
| `attach{program}` | the same program, "already running" — it starts on `configurationDone` like a launch, and the reply is followed by `initialized` too. What differs is the goodbye: a fake has no real process a test could `kill -0`, so `<program>.debuggee` beside the file is the ledger — `attached` on attach, then `killed` after `terminate` or `disconnect{terminateDebuggee: true}`, `detached` after a `disconnect` without it (what a client must send for a process it did not start) |
| `setBreakpoints{source, breakpoints[{line, condition, hitCondition}]}` | replaces the list; `verified` per breakpoint (a statement line of the launched program). Sent before `launch`, the source file is read then so `verified` is real. Hit counts start over on every set |
| `setExceptionBreakpoints{filters}` | the enabled filter ids |
| `configurationDone` | starts the run |
| `threads` | one thread, id 1, `main` |
| `stackTrace` | the frames, top first; ids count from 1 at the bottom (main); `line` is 1-based; `source.path` is the launched file |
| `scopes{frameId}` | `Locals` (that frame's variables) and `Globals` (main's) |
| `variables{variablesReference}` | the scope's variables (`name`, `value`, `type`, and a reference for a struct) or a struct's fields |
| `evaluate{expression, frameId, context}` | the value in that frame (the top one when unset), for every context; a struct named by the expression gets a reference. With `context: "repl"` the console's extras: `name = expr` assigns to the nearest `name` (this frame, then main; an unknown name is defined here) and answers with the value, as lldb's console does; `bt` answers with one line per frame (`* frame #0: f at prog.dbg:3`, then `  frame #1: …`) and no type, and an error's message runs to two lines (`no such variable`, then `  in: <expression>`) — the shapes lldb-dap and debugpy answer with, which a console must paint whole |
| `setVariable{variablesReference, name, value}` | `value` is an expression in the scope's frame; a scope's variable or a struct's field |
| `continue` / `next` / `stepIn` / `stepOut` | the response, a `continued` event, then the run: `output` events in order, then `stopped{reason}` (`breakpoint`, `step`, `exception`, `pause`) or `exited` + `terminated`. A resume invalidates every struct reference |
| `pause` | ends a `sleep`: `stopped{reason: "pause"}`; `success:false` when nothing is running |
| `terminate` | `terminated` (once); the program is over (an attached one: the ledger says `killed`) |
| `disconnect` | the loop ends (an attached program's ledger says `detached`, or `killed` when `terminateDebuggee` is true) |
| anything else | `success:false` with `unsupported request: <command>`; a frame that is not JSON is ignored |
| any request whose `arguments` is not an object (or absent) | `success:false` with `` <command>: `arguments` must be an object, not <kind> `` — debugpy's strictness, so a client that writes `[]` for an argument-less request fails here as it does there |

Hit conditions: `5`, `== 5`, `>= 5`, `> 5`, `< 5`, `<= 5`, `% 5`; one
that does not parse matches every hit. A condition that fails to
evaluate stops (and says why on stderr).

## How a `.test` uses it

`mnml-zig test` exports `MNML_FAKE_DAP` — the adapter beside the
runner binary, else the path `zig build` installs it at — into the
environment every App's children inherit. An adapter's `cmd` and
`args` expand `$NAME` / `${NAME}` from that environment, and
`dap.run`, finding no adapter for the file, reads the config layers
again and takes their `.dap` table (trusted workspaces only; the
runner's workspace is). So a script writes the adapter and the
program, opens the file, and starts a session:

```
write prog.dbg "let x = 1\nx = x + 1\nprint x\n"
write .mnml/config.zon .{ .dap = .{ .dbg = .{ .cmd = "$MNML_FAKE_DAP" } } }
open prog.dbg
command editor.use_vim
key j
command dap.toggle_breakpoint
command dap.run
expect screen contains "dap: stopped (breakpoint)"
expect screen contains "▶"
command dap.show
expect screen contains "x: int = 1"
```

The stop's jump to the line lands after the stop toast and focuses the
editor, so a script waits for the gutter `▶` before opening a pane it
then expects to be active. The panes are restyled by a later track:
assert on data words (`x: int = 1`, `prog.dbg:4  main`,
`stopped (breakpoint)`), not on geometry.

The same works outside the corpus: `export MNML_FAKE_DAP=$PWD/zig-out/bin/mnml-fake-dap`,
the config above in a workspace, and `dap.run` on a `.dbg` file.
