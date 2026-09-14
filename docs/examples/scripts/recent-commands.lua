-- recent-commands — a live picker over the commands you actually run,
-- with the chords in a preview column beside them.
--
-- What it shows: a live picker source (`items` asked again as the query
-- changes, debounced), a `preview(row)` that fills the picker's second
-- column, `data` carried through untouched, and a source-wide
-- `on_accept`. The MRU is the script's own: every accept moves its id
-- to the front, and the rows are ordered by it.
--
-- To use it: paste into your `init.lua` (`script.edit_init`), then
-- `:user.recent` — or bind it (`mnml.map("ctrl+shift+r", "user.recent")`).

local mru = {}

local function rank_of(id)
  for i, seen in ipairs(mru) do if seen == id then return i end end
end

local function remember(id)
  local at = rank_of(id)
  if at then table.remove(mru, at) end
  table.insert(mru, 1, id)
end

-- The rows: the commands matching the query, the ones run before first.
local function items(query)
  local rows = {}
  for _, c in ipairs(mnml.commands(query)) do
    local rank = rank_of(c.id)
    rows[#rows + 1] = { label = c.title, detail = c.id, data = c, rank = rank, icon = rank and "*" }
  end
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
  local rank = rank_of(c.id)
  if rank then
    out[#out + 1] = ""
    out[#out + 1] = { { text = "run " .. rank .. " ago", fg = "muted" } }
  end
  return out
end

mnml.picker.source{
  id = "recent",
  title = "Recent commands",
  live = true,
  items = items,
  preview = preview,
  on_accept = function(row)
    remember(row.data.id)
    mnml.run(row.data.id)
  end,
}

mnml.command{ id = "recent", title = "Recent commands", run = function() mnml.picker.open("recent") end }
