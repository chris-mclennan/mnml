# The component gallery under vhs (xterm.js — a legacy terminal without the
# kitty keyboard). `cd tapes && vhs gallery.tape` writes shots/*.png, one per
# screen. For ghostty and Terminal.app run `zig build canvas-demo` directly.
Output shots/gallery.gif
Set Shell "bash"
Set FontSize 13
Set Width 1180
Set Height 640
Set Padding 8
Set TypingSpeed 40ms
Type "cd $HOME/Projects/mnml-zig-worktrees/ui && ./zig-out/bin/canvas-demo"
Enter
Sleep 2s
Sleep 700ms
Screenshot shots/vhs-1-canvas.png
Sleep 700ms
Tab
Sleep 500ms
Sleep 700ms
Screenshot shots/vhs-2-editor.png
Sleep 700ms
Tab
Sleep 300ms
Type "jj"
Type "/"
Type "kitty"
Sleep 500ms
Sleep 700ms
Screenshot shots/vhs-3-panel.png
Sleep 700ms
Tab
Sleep 300ms
Type "42"
Sleep 400ms
Sleep 700ms
Screenshot shots/vhs-4-prompt.png
Sleep 700ms
Tab
Sleep 300ms
Right
Sleep 300ms
Sleep 700ms
Screenshot shots/vhs-5-confirm.png
Sleep 700ms
Tab
Sleep 400ms
Sleep 700ms
Screenshot shots/vhs-6-whichkey.png
Sleep 700ms
Tab
Sleep 300ms
Type "git"
Down
Sleep 400ms
Sleep 700ms
Screenshot shots/vhs-7-picker.png
Sleep 700ms
Tab
Sleep 300ms
Type "std"
Enter
Sleep 400ms
Sleep 700ms
Screenshot shots/vhs-8-find.png
Sleep 700ms
Ctrl+C
Sleep 300ms
