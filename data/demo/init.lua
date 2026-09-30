-- mnml --demo's first screen: util.zig in the editor, a Claude Code
-- session on the right (the stand-in: no model runs) and a shell under
-- it. This is the throwaway home's own init.lua; edit it and save to
-- see a script reload.
mnml.on("startup", function()
  mnml.ex("e src/util.zig")
  mnml.run("ai.claude_code_new_right")
  mnml.run("term.shell_bottom")
end)
