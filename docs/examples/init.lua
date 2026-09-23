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

-- The HTTP hooks: every send from a request pane carries a header, and
-- a 401 empties the token in the active env so the next `{{TOKEN}}`
-- shows as unresolved. `a.headers` is a name → value table; returning
-- the table sends it as it is (docs/LUA.md, "The HTTP hooks").
mnml.on("http_request", function(a)
  a.headers["X-Client"] = "mnml/init.lua"
  return a
end)
mnml.on("http_response", function(a)
  if a.status == 401 then mnml.http.set_var("TOKEN", "") end
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
-- runs the row's on_accept. `live = true` asks `items(query)` again as
-- the query changes
-- (debounced); `preview(row)` fills the picker's second column; `data`
-- is yours and comes back untouched; `on_accept` on the source sees the
-- whole row (or the marked ones under `multi = true`).
mnml.picker.source{
  id = "notes",
  title = "Notes",
  live = true,
  items = function(query)
    local items = {}
    for i, n in ipairs(notes) do
      items[#items + 1] = { label = n, detail = "#" .. i, data = i, on_accept = function() mnml.toast("picked " .. n) end }
    end
    return items
  end,
  preview = function(row)
    return { { { text = row.label, fg = "accent", bold = true } }, "", { { text = "note " .. tostring(row.data), fg = "muted" } } }
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

-- A hidden task: no pane at all, its output parsed a line at a time by
-- `on_line`, and the findings published through the diagnostics sink —
-- the gutter dot, the squiggle, the DIAGNOSTICS panel and `]d` all show
-- them, exactly as a language server's do.
local lint_ns = mnml.decor.namespace("notes_lint")

mnml.command{
  id = "notes_lint",
  title = "Lint the notes (a hidden task into the diagnostics sink)",
  run = function()
    local found = {}
    mnml.task.run{
      cmd = "printf '1:todo without a verb\n'",
      hidden = true,
      on_line = function(text)
        local line, msg = text:match("^(%d+):(.*)$")
        if line then
          found[#found + 1] = { line = tonumber(line), col = 1, severity = "warning", message = msg, source = "notes" }
        end
      end,
      -- A `set` on every run, the empty one included: that is how a run
      -- that found nothing clears what the last one found.
      on_done = function()
        local path = mnml.buf.path()
        if path then mnml.diagnostics.set(lint_ns, path, found) end
      end,
    }
  end,
}

-- Decorations: what a script paints into an editor without changing its
-- text. They live in a namespace, follow the text through edits, and are
-- data the renderer reads — never a callback in the paint loop.
local mark_ns = mnml.decor.namespace("notes_marks")

mnml.command{
  id = "notes_mark",
  title = "Mark the cursor line (virtual text, a gutter cell, a ground)",
  run = function()
    local pane = mnml.pane.active()
    local line = select(1, mnml.buf.cursor())
    mnml.decor.clear(mark_ns)
    mnml.decor.virtual_text(mark_ns, pane, line, { { text = "  ← noted", fg = "muted" } }, { at = "eol" })
    mnml.decor.gutter(mark_ns, pane, line, "▎", { fg = "accent", priority = 50 })
    mnml.decor.line(mark_ns, pane, line, "cursor_line")
    -- The word under the cursor, highlighted through its byte range.
    local w = mnml.buf.word_at()
    if w then mnml.decor.highlight(mark_ns, pane, w.start, w["end"], "match") end
  end,
}

-- An operator: `gy{motion}` in vim, ctrl+alt+y in standard, one undo
-- step whatever `run` applies. The range arrives in the shape
-- `mnml.buf.selection()` answers with, whichever road it came by — a
-- motion, a text object, a Visual selection, or the cursor's word.
mnml.operator{
  id = "note_it",
  title = "Add the range to the notes",
  keys = { vim = "gy", standard = "ctrl+alt+y" },
  run = function(range)
    notes[#notes + 1] = mnml.buf.range(range.start, range["end"])
  end,
}

-- A list, and the rail section that hosts it: the caps header, the
-- filter, the sort chip, the folds and the row menu every built-in
-- section has, with `rows(sort)` the only thing the script writes.
local notes_list = mnml.list{
  title = "NOTES",
  sort = { "Order", "A-Z" },
  rows = function(sort)
    local rows = { { header = "notes", count = #notes } }
    local shown = { table.unpack(notes) }
    if sort == "A-Z" then table.sort(shown) end
    for i, n in ipairs(shown) do
      rows[#rows + 1] = { label = n, detail = "#" .. i, icon = "•" }
    end
    return rows
  end,
  on_enter = function(row) mnml.toast(row.label) end,
  on_menu = function(row)
    return { { label = "Toast it", run = function() mnml.toast(row.label) end } }
  end,
}

mnml.section{ id = "notes_section", title = "NOTES", glyph = "󰎞", ascii = "N",
              list = notes_list, side = "left" }

-- `mnml.commands()` is the read behind a picker or a list over what the
-- app can do; each row carries its MRU `rank` (nil when never run).
-- `mnml.inspect` writes any value out for reading, and `print` toasts —
-- together they are the debugger.
mnml.command{
  id = "notes_debug",
  title = "Print what this script knows",
  run = function()
    local save = mnml.commands("file.save")[1]
    print(mnml.inspect{ notes = #notes, workspace = mnml.workspace(), save_rank = save and save.rank })
  end,
}

-- Read the merged config, never write it.
if mnml.config.get("editor.input_style") == "vim" then
  mnml.map("space u n", function() mnml.run("user.notes") end)
end
