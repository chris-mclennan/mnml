#!/bin/bash
# Re-sum the three command-id pins to the number of `.{ .id = "` entries in specs.zig (cwd = a worktree),
# and collapse the duplicate pin lines a keep-both leaves behind.
N=$(grep -cE '^\s*\.\{ \.id = "' src/commands/specs.zig)
sed -i '' -E "s/test \"[0-9]+ specs, unique ids\"/test \"$N specs, unique ids\"/; s/expectEqual\(@as\(usize, [0-9]+\), specs\.len\)/expectEqual(@as(usize, $N), specs.len)/" src/commands/specs.zig
sed -i '' -E "s/expectEqual\(@as\(usize, [0-9]+\), count\)/expectEqual(@as(usize, $N), count)/" src/core/command.zig
for f in src/commands/specs.zig src/core/command.zig; do
  awk 'BEGIN{prev=""} { if ($0==prev && ($0 ~ /specs, unique ids/ || $0 ~ /expectEqual\(@as\(usize, [0-9]+\), (specs\.len|count)\)/)) next; print; prev=$0 }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
echo "pins=$N"
