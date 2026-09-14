-- git-blame-line — who last touched the line the cursor is on, at the
-- end of that line, in the muted role.
--
-- What it shows: a decoration namespace (so clearing touches nothing
-- else), virtual text at `eol`, a hidden task (`git blame` has no pane
-- to be watched in), and the two hooks that say "the user is looking
-- at this line now" — `cursor_idle` and `pane_focus`.
--
-- To use it: paste into your `init.lua` (`script.edit_init`).

local ns = mnml.decor.namespace("git-blame-line")
-- The `<path>:<line>` the label on screen is about, and the one the
-- run in flight is about: neither the same line twice nor two runs.
local shown, asked = nil, nil

local function paint(pane, line, label)
  -- The pane may be gone by the time git answered.
  pcall(mnml.decor.virtual_text, ns, pane, line, { { text = "   " .. label, fg = "muted" } })
end

local function blame(pane, line)
  if not pane or not line then return end
  -- Not every focused pane is an editor, and a scratch buffer has no path.
  local ok, path = pcall(mnml.buf.path, pane)
  if not ok or not path then return end
  local key = path .. ":" .. line
  if key == shown or key == asked then return end
  asked = key
  local label = nil
  mnml.task.run {
    hidden = true,
    cmd = "git blame -L " .. line .. "," .. line .. " --date=relative -- " .. path,
    -- `^0d9ac1f (Chris McLennan 3 days ago 12) the line's own text`
    on_line = function(text)
      label = label or text:match("^%^?%x+%s+%((.-)%s+%d+%)")
    end,
    on_done = function(r)
      asked = nil
      shown = nil
      pcall(mnml.decor.clear, ns, pane)
      if not r.ok or not label then return end
      shown = key
      paint(pane, line, label)
    end,
  }
end

mnml.on("cursor_idle", function(a)
  blame(a.pane, a.line)
end)

mnml.on("pane_focus", function(a)
  if not a.pane then return end
  local ok, line = pcall(mnml.buf.cursor, a.pane)
  if ok then blame(a.pane, line) end
end)
