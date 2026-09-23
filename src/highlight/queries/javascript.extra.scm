; mnml's additions to tree-sitter-javascript's highlights.scm, listed
; after it for js / jsx / ts / tsx (build.zig `local_queries`,
; table.zig). The crate's query paints no decorator: `@logged` and
; `@bound` on a class or a method were plain text, the two things an
; Angular / NestJS / MobX reader's eye scans a file by. Neovim's
; queries paint them as `@attribute`; so does this.

(decorator "@" @attribute)
(decorator (identifier) @attribute)
(decorator (member_expression) @attribute)
(decorator (call_expression function: (identifier) @attribute))
(decorator (call_expression function: (member_expression) @attribute))
