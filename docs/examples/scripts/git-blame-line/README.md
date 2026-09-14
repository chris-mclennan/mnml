# git-blame-line

Virtual text at the end of the cursor line naming who last touched it,
refreshed 300 ms after the cursor stops and when a pane takes focus.

What it shows: a decoration namespace (so clearing touches nothing
else), `mnml.decor.virtual_text` at `eol`, and a hidden task — `git
blame` has no pane worth watching.

No commands, no keys: it paints while you move.
