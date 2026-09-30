---
title: Lua Scripting
description: mnml runs Lua 5.4 scripts that add commands, keys, statusline segments, pickers, panes and background tasks — the way an init.lua extends Neovim.
---

If you have written an `init.lua` for Neovim, this will feel familiar.
mnml has Lua 5.4 compiled into the binary, and a script talks to the
editor through one table, `mnml`. There is nothing to install and no
runtime to manage.

## What a script can do

- **Commands and keys.** Register a command that shows up in the
  palette, on the `:` line and in which-key, and bind chords to it.
- **Hooks.** Run code when a file opens or saves, the cursor rests, a
  language server attaches, git status changes, or an HTTP request is
  about to go out.
- **Buffers.** Read the text, the cursor and the selection, and edit
  through the same edit operations the editor itself uses, so undo works.
- **Decorations and diagnostics.** Virtual text, gutter marks and
  highlights, and diagnostics that appear beside the language server's.
- **The statusline and the picker.** Add a segment of your own, or a
  picker source with a preview column.
- **Panes, sections and operators.** Open a pane you render yourself,
  add a section to the sidebar, or register a vim-style operator.
- **Tasks.** Run a shell command in the background and act on its
  output line by line.

## What a script cannot do

A script cannot reach the file system, the shell or the network
directly: Lua's `os`, `io`, `package`, `debug`, `dofile` and `loadfile`
are not there. Running a program goes through `mnml.task.run`, and a
workspace's `init.lua` does not run at all until you trust the
workspace.

Each call into a script has a 20 ms budget. A script that runs past it is
stopped and reported, rather than freezing the editor.

## Where scripts live

| File | Runs |
| ---- | ---- |
| `~/.config/mnml/init.lua` | Always, at start-up. |
| `<workspace>/.mnml/init.lua` | Only when you have trusted that workspace. |
| `~/.config/mnml/scripts/<name>/` | An installed script, with its own manifest and its own Lua state. |

(`~/.config/mnml` is the default data root; `MNML_DATA_ROOT` moves it.)

`script.edit_init` opens your `init.lua`, creating it on save. Saving
either `init.lua` reloads it at once; `script.reload` reloads
everything by hand.

## An example

This is a complete `init.lua`. It adds a word count to the statusline,
a command that counts the `TODO` lines in the current file, and a
notice after every save:

```lua
-- A word count on the statusline, and a command that counts the
-- TODO lines in the current file.

mnml.statusline.segment{
  id = "words",
  fn = function()
    local ok, text = pcall(mnml.buf.text)  -- errors when no editor is focused
    if not ok then return nil end          -- nil hides the segment
    local n = 0
    for _ in text:gmatch("%S+") do n = n + 1 end
    return n .. " words"
  end,
}

mnml.command{
  id = "todos",                            -- becomes user.todos
  title = "Count TODOs in this file",
  keys = { "space u t" },
  run = function()
    local count = 0
    for i = 1, mnml.buf.line_count() do
      if mnml.buf.line(i):find("TODO") then count = count + 1 end
    end
    mnml.toast(count .. " TODO line(s) in " .. (mnml.buf.path() or "this buffer"))
  end,
}

mnml.on("save_post", function(a)
  mnml.toast("saved " .. a.path .. " (" .. a.bytes .. " bytes)")
end)
```

After you save it:

- the statusline shows the word count of the file you are editing;
- `user.todos` is in the command palette, and `:user.todos` runs it;
- `space u t` runs it in the vim profile, and `ctrl+k u t` in the
  standard profile, where `ctrl+k` opens the same which-key menu.

Every command a script registers is prefixed `user.`, so it can never
replace a built-in one. `mnml.buf.text()` raises an error when no editor
is focused, which is why the segment calls it through `pcall`.

> [!TIP]
> This example was run as written with mnml's `.test` harness
> (`mnml test`), which is also how you can test your own scripts. See *Testing a script* in the
> [Lua reference](/docs/lua/reference#testing-a-script).

## Writing scripts in mnml

Editing an `init.lua` in mnml gets completion and hover for the `mnml`
table. `script.run_selection` runs the selected lines, or the cursor
line, and shows the result — `space L l` in the vim profile,
`ctrl+alt+enter` in the standard one. An error in a script is reported
with its file and line.

## Installing and sharing scripts

A script you want to keep, version or share is a **directory** with a
`script.zon` manifest, an `init.lua`, and optionally a `lib/` folder it
can `require` from. Each installed script runs in a Lua state of its
own: one that errors is disabled on its own, and the others keep
running.

The SCRIPTS section (`view.activity_scripts`) lists what is installed.
Its Marketplace tab lists the five example scripts that ship with every
release — a git blame on the cursor line, an ESLint wrapper that feeds
diagnostics, a recent-commands picker, a TODO list in the sidebar, and
a surround operator. `script.install` installs from a folder, a git URL
or an archive, and asks for trust first. `script.doctor` shows every
script's state, hooks and budget overruns.

## Reference

The [Lua reference](/docs/lua/reference) documents every `mnml.*`
function with its signature and an example, every hook and its fields,
the manifest, and the five shipped scripts as recipes.
