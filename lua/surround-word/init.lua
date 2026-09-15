-- surround-word — wrap a range in a pair of characters, as one edit.
--
-- What it shows: `mnml.operator{}`, which reaches both profiles by their
-- own road — `gs{motion}` / `gsiw` / `gss` / `V…gs` under vim, the
-- chord over the selection (or the word under the cursor) under
-- standard — and the three reads a text operation needs:
-- `mnml.buf.selection`, `mnml.buf.range`, `mnml.buf.word_at`.
--
-- To use it: paste into your `init.lua` (`script.edit_init`). Then
-- `gsiw` in vim, or `ctrl+shift+s` in standard.

-- The pair to wrap in. `mnml.config.get` reads the merged config, so a
-- `[tools.surround] pair = "[]"` in config.zon changes it.
local function pair()
  local want = mnml.config.get("tools.surround.pair")
  if type(want) == "string" and #want >= 2 then
    return want:sub(1, 1), want:sub(2, 2)
  end
  return "(", ")"
end

-- A linewise range keeps its own indentation: the pair goes around the
-- text, not around the leading blanks.
local function trim(text, from)
  local lead = text:match("^%s*") or ""
  return from + #lead, text:sub(#lead + 1)
end

mnml.operator{
  id = "surround",
  title = "Surround the range",
  keys = { vim = "gs", standard = "ctrl+shift+s" },
  run = function(range)
    local from, to = range.start, range["end"]
    if to <= from then return end
    local text = mnml.buf.range(from, to)
    if range.mode == "line" then
      from, text = trim(text, from)
      text = text:gsub("%s+$", "")
      to = from + #text
    end
    local open, close = pair()
    mnml.buf.apply{ op = "replace_range", start = from, ["end"] = to,
                    text = open .. text .. close }
  end,
}

-- The other half of the pair: `gS` (or `ctrl+shift+d`) takes one off
-- again, so the operator is reversible without reaching for `u`.
mnml.operator{
  id = "unsurround",
  title = "Drop the surrounding pair",
  keys = { vim = "gS", standard = "ctrl+shift+d" },
  run = function(range)
    local text = mnml.buf.range(range.start, range["end"])
    if #text < 2 then return end
    local open, close = pair()
    if text:sub(1, 1) ~= open or text:sub(-1) ~= close then
      mnml.toast("nothing to unsurround here", "warn")
      return
    end
    mnml.buf.apply{ op = "replace_range", start = range.start, ["end"] = range["end"],
                    text = text:sub(2, #text - 1) }
  end,
}
