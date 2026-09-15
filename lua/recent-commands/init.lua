-- recent-commands — a live picker over the commands you actually run,
-- with the chords in a preview column beside them.
--
-- What it shows: a live picker source (`items` asked again as the query
-- changes, debounced), a `preview(row)` that fills the picker's second
-- column, `data` carried through untouched, and a source-wide
-- `on_accept`. The MRU is the app's own — `mnml.commands()` carries
-- each row's `rank` (1 = run most recently, nil = never run), the same
-- list the palette and `picker.recent_commands` order by, so a command
-- you ran from a chord, a menu or a `:` line counts here too.
--
-- To use it: paste into your `init.lua` (`script.edit_init`), then
-- `:user.recent` — or bind it (`mnml.map("ctrl+shift+r", "user.recent")`).

-- The rows: the commands matching the query, the ones run before first.
local function items(query)
  local rows = {}
  for _, c in ipairs(mnml.commands(query)) do
    rows[#rows + 1] = { label = c.title, detail = c.id, data = c, rank = c.rank, icon = c.rank and "*" }
  end
  -- `rank` is copied onto the row, not read through `data` in the
  -- comparator: this sort runs thousands of comparisons inside one
  -- 20 ms budget entry, and the extra table index costs it.
  table.sort(rows, function(a, b)
    if a.rank and b.rank then return a.rank < b.rank end
    if a.rank or b.rank then return a.rank ~= nil end
    return a.label < b.label
  end)
  return rows
end

-- The preview column: what the command is, and how to reach it.
local function preview(row)
  local c = row.data
  if not c then return { row.label } end
  local out = { { { text = c.title, fg = "accent", bold = true } },
                { { text = c.id, fg = "muted" } },
                "" }
  if #c.keys == 0 then
    out[#out + 1] = { { text = "no chord", fg = "muted" } }
  else
    out[#out + 1] = { { text = "chords", fg = "muted" } }
    for _, spec in ipairs(c.keys) do
      out[#out + 1] = { { text = "  " .. spec, fg = "syn_keyword" } }
    end
  end
  if c.rank then
    out[#out + 1] = ""
    out[#out + 1] = { { text = "run " .. c.rank .. " ago", fg = "muted" } }
  end
  return out
end

mnml.picker.source{
  id = "recent",
  title = "Recent commands",
  live = true,
  items = items,
  preview = preview,
  on_accept = function(row) mnml.run(row.data.id) end,
}

mnml.command{ id = "recent", title = "Recent commands", run = function() mnml.picker.open("recent") end }
