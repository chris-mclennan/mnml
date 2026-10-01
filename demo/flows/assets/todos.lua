-- todos.lua: a palette command and a statusline chip, in a dozen lines.
local function todos()
  local n = 0
  for i = 1, mnml.buf.line_count() do
    local l = mnml.buf.line(i)
    if l:find("TODO") or l:find("FIXME") then n = n + 1 end
  end
  return n
end

mnml.command{
  id = "count_todos",
  title = "Count the TODO and FIXME lines",
  run = function()
    mnml.toast(("%d TODO / FIXME line(s) in this file"):format(todos()))
  end,
}

mnml.statusline.segment{ id = "todos", side = "left", fn = function()
  local ok, n = pcall(todos)
  return ok and n > 0 and ("todo " .. n) or nil
end }
