-- mnml init.lua — the reference example (docs/LUA.md walks through it).
--
-- Lives at <data root>/init.lua (yours) or <workspace>/.mnml/init.lua
-- (the repo's; runs once the workspace is trusted). `script.reload`
-- re-runs it after an edit. Everything here is reachable through the
-- `mnml` table; there is no `os`, `io` or `require`.

-- A command: `user.hello` in the palette, `:user.hello`, a `.test`
-- step, IPC, and the chord it declares.
mnml.command{
  id = "hello",
  title = "Say hello",
  keys = { "ctrl+shift+h" },
  run = function()
    mnml.toast("hello from init.lua")
  end,
}

-- A hook: every save reports its size. The payload is flat — see the
-- HookArgs table in docs/LUA.md for each hook's fields.
mnml.on("save_post", function(a)
  mnml.toast(a.path .. " saved (" .. a.bytes .. " bytes)")
end)

-- A statusline segment, polled every 250 ms; nil hides it.
mnml.statusline.segment{
  id = "notes",
  side = "right",
  fn = function()
    return "notes " .. #notes
  end,
}

-- A scratch-notes pane. `render(w, h)` returns rows; a row is a string
-- or a list of segments `{ text=, fg=, bg=, bold=, italic=, underline=,
-- hit= }`. Colors are theme roles ("accent", "muted", "syn_keyword"…),
-- never values. A segment with `hit` is clickable: `on_hit(id, button)`.
-- While the pane is focused every key reaches `on_key(name)` first;
-- return true to keep it from the chord chain.
notes = { "write the manual", "cut a release" }
local pane

local function render(w, h)
  local rows = {
    { { text = " NOTES ", fg = "accent", bold = true }, { text = " a adds the cursor line · x removes · click toggles", fg = "muted" } },
    "",
  }
  for i, n in ipairs(notes) do
    rows[#rows + 1] = { { text = "  " .. i .. ". ", fg = "muted" }, { text = n, hit = i } }
  end
  return rows
end

mnml.command{
  id = "notes",
  title = "Open the scratch notes pane",
  run = function()
    pane = mnml.pane.open{
      title = "Notes",
      render = render,
      on_hit = function(id, button)
        if button == "right" then
          table.remove(notes, id)
        else
          notes[id] = notes[id]:sub(1, 1) == "✓" and notes[id]:sub(3) or ("✓ " .. notes[id])
        end
      end,
      on_key = function(k)
        if k == "a" then
          local line = mnml.buf.line(select(1, mnml.buf.cursor()))
          notes[#notes + 1] = line or "(empty)"
          return true
        elseif k == "x" then
          table.remove(notes)
          return true
        end
        return false
      end,
    }
  end,
}

-- A picker source: `mnml.picker.open("notes")` lists the notes; Enter
-- runs the row's on_accept.
mnml.picker.source{
  id = "notes",
  title = "Notes",
  items = function(query)
    local items = {}
    for i, n in ipairs(notes) do
      items[#items + 1] = { label = n, detail = "#" .. i, on_accept = function() mnml.toast("picked " .. n) end }
    end
    return items
  end,
}

mnml.map("ctrl+shift+n", function() mnml.picker.open("notes") end)

-- A task: runs in a pane below; `on_done{ ok, code | signal }` fires
-- when it exits. This is the only way a script reaches the shell.
mnml.command{
  id = "notes_count",
  title = "Count the notes with wc (a task)",
  run = function()
    mnml.task.run{ cmd = "printf '%s\\n' " .. #notes .. " | wc -l", label = "wc", on_done = function(r)
      mnml.toast(r.ok and "wc done" or "wc failed")
    end }
  end,
}

-- Read the merged config, never write it.
if mnml.config.get("editor.input_style") == "vim" then
  mnml.map("space u n", function() mnml.run("user.notes") end)
end
