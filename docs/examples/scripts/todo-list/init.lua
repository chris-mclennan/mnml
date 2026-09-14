-- todo-list — every TODO in the workspace as a rail section of its own,
-- grouped by file, Enter opening the file at the line.
--
-- What it shows: `mnml.list{}` (the panel every built-in section is —
-- header, filter, sort chip, folds, row menu), `mnml.section{}` (a real
-- activity-bar row, in the place `after` names), and a hidden task
-- whose output is only ever parsed (`grep` through `task.run{ hidden,
-- on_line }`).
--
-- To use it: paste into your `init.lua` (`script.edit_init`). The row
-- appears under TODOs on the rail.

local hits = {}   -- { path = "src/app.zig", line = 12, text = "…" }
local list        -- forward: the parse feeds it, the list asks for it

local function parse(text)
  -- grep -n answers `path:line:text`.
  local path, line, rest = text:match("^([^:]+):(%d+):(.*)$")
  if not path then return end
  local note = rest:match("TODO[:%s]*(.*)") or rest
  hits[#hits + 1] = { path = path, line = tonumber(line), text = (note:gsub("^%s+", "")) }
end

local function scan()
  hits = {}
  mnml.task.run{
    cmd = "grep -rn TODO --exclude-dir=.git --exclude-dir=.mnml . | head -200",
    hidden = true,
    on_line = parse,
    on_done = function() if list then list:refresh() end end,
  }
end

-- The rows: a fold header per file, an item per hit, in the sort's order.
local function rows(sort)
  local order, per_file = {}, {}
  for _, h in ipairs(hits) do
    order[#order + 1] = h
    per_file[h.path] = (per_file[h.path] or 0) + 1
  end
  if sort == "Name" then
    table.sort(order, function(a, b)
      if a.path ~= b.path then return a.path < b.path end
      return a.line < b.line
    end)
  end
  local out, seen = {}, nil
  for _, h in ipairs(order) do
    if h.path ~= seen then
      seen = h.path
      out[#out + 1] = { header = h.path, count = per_file[h.path] }
    end
    out[#out + 1] = { label = h.text, detail = h.path .. ":" .. h.line }
  end
  return out
end

-- A row's `detail` is `<path>:<line>` — the whole of what opening needs.
local function open(detail)
  local path, line = detail:match("^(.*):(%d+)$")
  if path then mnml.ex("e +" .. line .. " " .. path) end
end

list = mnml.list{
  title = "TODOS (lua)",
  sort = { "Found", "Name" },
  rows = rows,
  on_enter = function(row) open(row.detail) end,
  on_menu = function(row)
    return { { label = "Open " .. row.detail, run = function() open(row.detail) end },
             { label = "Rescan", run = scan } }
  end,
}

mnml.section{ id = "todos_lua", title = "TODOS (lua)", glyph = "\u{f046}", ascii = "T",
              list = list, side = "left", after = "todos" }

mnml.command{ id = "todos_scan", title = "Rescan the lua TODOs", run = scan }
scan()
