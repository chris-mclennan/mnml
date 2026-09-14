-- eslint — run eslint over a JavaScript / TypeScript file when it is
-- saved and publish what it finds as diagnostics: the gutter dot, the
-- squiggle, the statusline count, the DIAGNOSTICS panel and `]d` show
-- them beside a language server's, under `eslint` as the source.
--
-- What it shows: the tool-wrapper shape — a hidden task (nothing to
-- watch, the output is only parsed), `on_line` as it arrives, and the
-- diagnostics sink keyed by this script's own namespace, so a set
-- replaces only what this script published.
--
-- To use it: paste into your `init.lua` (`script.edit_init`). eslint
-- must be on PATH (`npx eslint` works too — change `cmd`).

local ns = mnml.decor.namespace("eslint")

local function lint(path)
  local found = {}
  mnml.task.run {
    hidden = true,
    -- The compact formatter is one finding per line, which is all a
    -- wrapper needs; `--` keeps a leading-dash path out of the flags.
    cmd = "eslint --format compact -- " .. path,
    -- `app.js: line 3, col 5, Warning - 'x' is assigned but never used (no-unused-vars)`
    on_line = function(text)
      local line, col, severity, message = text:match("^.-: line (%d+), col (%d+), (%a+) %- (.+)$")
      if not line then return end
      found[#found + 1] = {
        line = tonumber(line),
        col = tonumber(col),
        severity = (severity == "Error") and "error" or "warning",
        message = message,
        source = "eslint",
      }
    end,
    -- Whatever it found replaces the file's previous list — including
    -- an empty one, which is how a fixed file stops being flagged.
    on_done = function()
      mnml.diagnostics.set(ns, path, found)
    end,
  }
end

mnml.on("save_post", function(a)
  if a.path:match("%.[jt]sx?$") then lint(a.path) end
end)
