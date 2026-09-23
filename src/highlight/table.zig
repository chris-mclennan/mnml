//! The language table: for every file type mnml-zig highlights, which grammar to load,
//! which query layers to compile, and how extensions / filenames / injection names map
//! onto it. This is the behavioural contract the Rust highlighter established — a `.ts`
//! file is highlighted with JavaScript's captures *plus* TypeScript's, `.tsx` adds the
//! JSX layer, Markdown is two grammars with the inline one injected — kept here as data.
//!
//! Everything is comptime: the table is an array literal, the layered query sources are
//! concatenated at compile time, and the alias maps are `StaticStringMap`s.

const std = @import("std");
const ts = @import("tree_sitter");
const q = @import("ts_queries");

pub const LanguageFn = *const fn () callconv(.c) *const ts.Language;

pub const Entry = struct {
    /// Canonical key — the first extension of its group (`rs`, `js`, `ts`, `md`, …), or
    /// the pseudo-key `markdown_inline` for the grammar that only exists as an injection.
    key: []const u8,
    language: LanguageFn,
    /// Highlight query layers, in order. `highlightSource` joins them with a newline.
    highlights: []const []const u8,
    /// Injection query, or empty when the grammar has none we use.
    injections: []const u8 = "",
    /// Reserved for locals-aware highlighting and text objects (Phase 2). Nothing reads it.
    locals: []const u8 = "",
    /// A short sample that must parse without an `ERROR` node — the test-suite fixture.
    fixture: []const u8,
};

pub const entries = [_]Entry{
    .{ .key = "rs", .language = tree_sitter_rust, .highlights = &.{q.rust_highlights}, .injections = q.rust_injections, .fixture = "fn main() {\n    let s = \"hi\";\n}\n" },
    .{ .key = "js", .language = tree_sitter_javascript, .highlights = &.{ q.javascript_highlights, q.javascript_highlights_extra }, .injections = q.javascript_injections, .fixture = "const x = 1;\nconsole.log(x);\n" },
    .{ .key = "jsx", .language = tree_sitter_javascript, .highlights = &.{ q.javascript_highlights, q.javascript_highlights_jsx, q.javascript_highlights_extra }, .injections = q.javascript_injections, .fixture = "const el = <div className=\"a\">hi</div>;\n" },
    .{ .key = "py", .language = tree_sitter_python, .highlights = &.{q.python_highlights}, .fixture = "def f(x):\n    return x + 1\n" },
    .{ .key = "json", .language = tree_sitter_json, .highlights = &.{q.json_highlights}, .fixture = "{\"a\": [1, 2, {\"b\": null}]}\n" },
    .{ .key = "go", .language = tree_sitter_go, .highlights = &.{q.go_highlights}, .fixture = "package main\n\nfunc main() {\n\tprintln(\"hi\")\n}\n" },
    .{ .key = "toml", .language = tree_sitter_toml, .highlights = &.{q.toml_highlights}, .fixture = "[package]\nname = \"mnml\"\n" },
    // TypeScript's own highlights are ~35 lines of TS-specific captures; JavaScript's carry
    // the keywords / literals / comments. Without the JS layer most tokens stay plain.
    .{ .key = "ts", .language = tree_sitter_typescript, .highlights = &.{ q.javascript_highlights, q.javascript_highlights_extra, q.typescript_highlights }, .fixture = "const x: number = 1;\ninterface A { b: string }\n" },
    .{ .key = "tsx", .language = tree_sitter_tsx, .highlights = &.{ q.javascript_highlights, q.javascript_highlights_jsx, q.javascript_highlights_extra, q.typescript_highlights }, .fixture = "const el = <div>{1 + 1}</div>;\nlet y: string = \"a\";\n" },
    .{ .key = "css", .language = tree_sitter_css, .highlights = &.{q.css_highlights}, .fixture = "a { color: red; }\n" },
    .{ .key = "html", .language = tree_sitter_html, .highlights = &.{q.html_highlights}, .injections = q.html_injections, .fixture = "<html><body><p class=\"x\">hi</p></body></html>\n" },
    .{ .key = "sh", .language = tree_sitter_bash, .highlights = &.{q.bash_highlights}, .fixture = "for f in *.c; do echo \"$f\"; done\n" },
    // Markdown is two grammars: block structure here, and the inline grammar (emphasis,
    // code spans, links) that the block injections query pulls in as `markdown_inline`.
    .{ .key = "md", .language = tree_sitter_markdown, .highlights = &.{q.markdown_highlights}, .injections = q.markdown_injections, .fixture = "# Title\n\nSome *text* with `code`.\n" },
    .{ .key = "markdown_inline", .language = tree_sitter_markdown_inline, .highlights = &.{q.markdown_inline_highlights}, .injections = q.markdown_inline_injections, .fixture = "Some *emphasis* and `code` and [a link](http://x).\n" },
    .{ .key = "c", .language = tree_sitter_c, .highlights = &.{q.c_highlights}, .fixture = "int main(void) {\n    return 0;\n}\n" },
    // C++'s own query is the delta over C (`; inherits: c` in neovim's
    // layout); without the C layer, `int main() { return 0; }` paints nothing.
    .{ .key = "cpp", .language = tree_sitter_cpp, .highlights = &.{ q.c_highlights, q.cpp_highlights }, .fixture = "#include <vector>\nint main() { std::vector<int> v; return 0; }\n" },
    .{ .key = "rb", .language = tree_sitter_ruby, .highlights = &.{q.ruby_highlights}, .fixture = "def hi(name)\n  puts \"hi #{name}\"\nend\n" },
    .{ .key = "java", .language = tree_sitter_java, .highlights = &.{q.java_highlights}, .fixture = "class A {\n    int f() { return 1; }\n}\n" },
    .{ .key = "cs", .language = tree_sitter_c_sharp, .highlights = &.{q.c_sharp_highlights}, .fixture = "class A {\n    int F() => 1;\n}\n" },
    .{ .key = "lua", .language = tree_sitter_lua, .highlights = &.{q.lua_highlights}, .fixture = "local function f(x)\n  return x + 1\nend\n" },
    .{ .key = "yaml", .language = tree_sitter_yaml, .highlights = &.{q.yaml_highlights}, .fixture = "a: 1\nb:\n  - x\n  - y\n" },
    .{ .key = "scala", .language = tree_sitter_scala, .highlights = &.{q.scala_highlights}, .fixture = "object A {\n  def f(x: Int): Int = x + 1\n}\n" },
    .{ .key = "ex", .language = tree_sitter_elixir, .highlights = &.{q.elixir_highlights}, .injections = q.elixir_injections, .fixture = "defmodule A do\n  def f(x), do: x + 1\nend\n" },
    .{ .key = "hs", .language = tree_sitter_haskell, .highlights = &.{q.haskell_highlights}, .injections = q.haskell_injections, .fixture = "module Main where\n\nmain :: IO ()\nmain = putStrLn \"hi\"\n" },
    .{ .key = "php", .language = tree_sitter_php, .highlights = &.{q.php_highlights}, .injections = q.php_injections, .fixture = "<?php\nfunction f($x) { return $x + 1; }\n" },
    .{ .key = "swift", .language = tree_sitter_swift, .highlights = &.{q.swift_highlights}, .injections = q.swift_injections, .fixture = "func f(_ x: Int) -> Int {\n    return x + 1\n}\n" },
    .{ .key = "zig", .language = tree_sitter_zig, .highlights = &.{q.zig_highlights}, .injections = q.zig_injections, .fixture = "const std = @import(\"std\");\npub fn main() void {}\n" },
    .{ .key = "nix", .language = tree_sitter_nix, .highlights = &.{q.nix_highlights}, .injections = q.nix_injections, .fixture = "{ pkgs ? import <nixpkgs> {} }:\npkgs.hello\n" },
    // OCaml's implementation and interface grammars share one highlights query.
    .{ .key = "ocaml", .language = tree_sitter_ocaml, .highlights = &.{q.ocaml_highlights}, .fixture = "let f x = x + 1\nlet () = print_int (f 1)\n" },
    .{ .key = "mli", .language = tree_sitter_ocaml_interface, .highlights = &.{ocaml_interface_highlights}, .fixture = "val f : int -> int\n" },
    .{ .key = "dart", .language = tree_sitter_dart, .highlights = &.{q.dart_highlights}, .fixture = "int f(int x) {\n  return x + 1;\n}\n" },
    .{ .key = "sql", .language = tree_sitter_sql, .highlights = &.{q.sql_highlights}, .fixture = "SELECT id, name FROM users WHERE id = 1;\n" },
    .{ .key = "make", .language = tree_sitter_make, .highlights = &.{q.make_highlights}, .fixture = "all: main.o\n\tcc -o app main.o\n" },
    .{ .key = "kt", .language = tree_sitter_kotlin, .highlights = &.{q.kotlin_highlights}, .fixture = "fun main() {\n    println(\"hi\")\n}\n" },
    .{ .key = "regex", .language = tree_sitter_regex, .highlights = &.{q.regex_highlights}, .fixture = "^[a-z]+(\\d{2,3})?$" },
    // Containerfile and Dockerfile are one grammar; the crate name follows the OCI spelling.
    .{ .key = "dockerfile", .language = tree_sitter_containerfile, .highlights = &.{q.containerfile_highlights}, .injections = q.containerfile_injections, .fixture = "FROM alpine:3.19\nRUN apk add curl\nCMD [\"sh\"]\n" },
    .{ .key = "hcl", .language = tree_sitter_hcl, .highlights = &.{q.hcl_highlights}, .fixture = "resource \"aws_s3_bucket\" \"b\" {\n  bucket = \"x\"\n}\n" },
    .{ .key = "proto", .language = tree_sitter_proto, .highlights = &.{q.proto_highlights}, .fixture = "syntax = \"proto3\";\nmessage A {\n  int32 id = 1;\n}\n" },
    .{ .key = "diff", .language = tree_sitter_diff, .highlights = &.{q.diff_highlights}, .fixture = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n" },
    .{ .key = "vue", .language = tree_sitter_vue, .highlights = &.{q.vue_highlights}, .injections = q.vue_injections, .fixture = "<template>\n  <div>{{ msg }}</div>\n</template>\n" },
    .{ .key = "svelte", .language = tree_sitter_svelte, .highlights = &.{q.svelte_highlights}, .injections = svelte_injections, .fixture = "<script>\n  let n = 1;\n</script>\n<p>{n}</p>\n" },
    .{ .key = "astro", .language = tree_sitter_astro, .highlights = &.{q.astro_highlights}, .injections = q.astro_injections, .fixture = "---\nconst x = 1;\n---\n<p>{x}</p>\n" },
};

/// The interface grammar has no `shebang` node, so the crate's one shared `highlights.scm`
/// fails to compile against it (`ts_query_new` → NodeType at the comment pattern). The Rust
/// highlighter hit the same wall and silently left `.mli` files plain; here that single
/// alternative is dropped at comptime and the rest of the query is shared as intended.
const ocaml_interface_highlights: []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    const needle = " (shebang)";
    const i = std.mem.indexOf(u8, q.ocaml_highlights, needle) orelse
        @compileError("ocaml highlights.scm no longer mentions (shebang) — drop this patch");
    break :blk q.ocaml_highlights[0..i] ++ q.ocaml_highlights[i + needle.len ..];
};

/// svelte-ng's injections inject EVERY `raw_text` as JavaScript — the
/// `<style>` body included, and ahead of the `lang="ts"` pattern — where
/// nvim-treesitter's query, which it follows otherwise, injects the
/// template's `{…}` expressions (`svelte_raw_text`) and leaves `<script>`
/// and `<style>` to the inherited HTML layer and the `lang` patterns.
/// Patched here to nvim's pattern.
const svelte_injections: []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    const needle = "((raw_text) @injection.content\n  (#set! injection.language \"javascript\"))";
    const i = std.mem.indexOf(u8, q.svelte_injections, needle) orelse
        @compileError("svelte injections.scm no longer has the raw_text catch-all — drop this patch");
    break :blk q.svelte_injections[0..i] ++ "((svelte_raw_text) @injection.content\n  (#set! injection.language \"javascript\"))" ++ q.svelte_injections[i + needle.len ..];
};

/// `entries[i].highlights` joined with newlines, each layer's `; inherits:`
/// resolved, computed once at compile time.
pub const highlight_sources: [entries.len][]const u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var out: [entries.len][]const u8 = undefined;
    for (entries, 0..) |e, i| {
        var joined: []const u8 = "";
        for (e.highlights, 0..) |layer, li| {
            if (li > 0) joined = joined ++ "\n";
            joined = joined ++ withInherited(.highlights, layer);
        }
        out[i] = joined;
    }
    break :blk out;
};

pub fn highlightSource(index: usize) []const u8 {
    return highlight_sources[index];
}

/// `entries[i].injections` with its `; inherits:` resolved; empty when
/// the entry has none.
pub const injection_sources: [entries.len][]const u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var out: [entries.len][]const u8 = undefined;
    for (entries, 0..) |e, i| out[i] = if (e.injections.len == 0) "" else withInherited(.injections, e.injections);
    break :blk out;
};

pub fn injectionSource(index: usize) []const u8 {
    return injection_sources[index];
}

pub const QueryKind = enum { highlights, injections };

/// nvim-treesitter's `; inherits: a,b` modeline, in the comment lines
/// that open a query: the file is only the delta over the named
/// languages' queries of the same kind. Those come first, in the order
/// named and each resolved in turn, then the file itself — so its own
/// patterns, later, win a node both capture (the engine's rule, and
/// Neovim's). Read as a comment, the line dropped the whole base: Vue
/// and Svelte had no tag, attribute or `<style>` layer at all.
pub fn withInherited(comptime kind: QueryKind, comptime src: []const u8) []const u8 {
    @setEvalBranchQuota(2_000_000);
    comptime var base: []const u8 = "";
    comptime var lines = std.mem.splitScalar(u8, src, '\n');
    inline while (lines.next()) |raw| {
        const line = comptime std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != ';') break;
        const body = comptime std.mem.trimStart(u8, std.mem.trimStart(u8, line, ";"), " \t");
        if (!comptime std.mem.startsWith(u8, body, "inherits:")) continue;
        comptime var names = std.mem.splitScalar(u8, body["inherits:".len..], ',');
        inline while (names.next()) |n| {
            // `(name)` is nvim's "only when named explicitly"; the table
            // always names it.
            const name = comptime std.mem.trim(u8, n, " \t()");
            if (name.len == 0) continue;
            base = base ++ withInherited(kind, inheritedQuery(kind, name)) ++ "\n";
        }
    }
    return base ++ src;
}

/// The query a `; inherits:` name stands for. nvim-treesitter splits
/// HTML into `html_tags` (tags, attributes, `<script>` / `<style>`) and
/// `html` (that plus the document); the grammar's own queries are the
/// first, so both names are them. A name this table does not carry is a
/// compile error, never a silently missing layer.
fn inheritedQuery(comptime kind: QueryKind, comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "html") or std.mem.eql(u8, name, "html_tags")) return switch (kind) {
        .highlights => q.html_highlights,
        .injections => q.html_injections,
    };
    @compileError("`; inherits: " ++ name ++ "` names a query this table does not carry");
}

/// Index of the entry whose `key` matches, or null.
pub fn find(key: []const u8) ?usize {
    return key_index.get(key);
}

const key_index = blk: {
    var kvs: [entries.len]struct { []const u8, usize } = undefined;
    for (entries, 0..) |e, i| kvs[i] = .{ e.key, i };
    break :blk std.StaticStringMap(usize).initComptime(kvs);
};

// ── name resolution ──────────────────────────────────────────────────────────

/// A file extension (already lower-cased, no dot) → table key.
pub fn keyForExtension(ext: []const u8) ?[]const u8 {
    return extension_aliases.get(ext);
}

const extension_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "rs", "rs" },
    .{ "js", "js" },
    .{ "cjs", "js" },
    .{ "mjs", "js" },
    .{ "jsx", "jsx" },
    .{ "py", "py" },
    .{ "json", "json" },
    .{ "jsonl", "json" },
    .{ "ndjson", "json" },
    .{ "go", "go" },
    .{ "toml", "toml" },
    .{ "ts", "ts" },
    .{ "cts", "ts" },
    .{ "mts", "ts" },
    .{ "tsx", "tsx" },
    .{ "css", "css" },
    .{ "scss", "css" },
    .{ "sass", "css" },
    .{ "html", "html" },
    .{ "htm", "html" },
    .{ "sh", "sh" },
    .{ "bash", "sh" },
    .{ "zsh", "sh" },
    .{ "fish", "sh" },
    .{ "md", "md" },
    .{ "markdown", "md" },
    .{ "mdx", "md" },
    .{ "markdown_inline", "markdown_inline" },
    .{ "c", "c" },
    .{ "h", "c" },
    .{ "cpp", "cpp" },
    .{ "cc", "cpp" },
    .{ "cxx", "cpp" },
    .{ "hpp", "cpp" },
    .{ "hh", "cpp" },
    .{ "hxx", "cpp" },
    .{ "rb", "rb" },
    .{ "rake", "rb" },
    .{ "gemspec", "rb" },
    .{ "java", "java" },
    .{ "cs", "cs" },
    .{ "lua", "lua" },
    .{ "yaml", "yaml" },
    .{ "yml", "yaml" },
    .{ "scala", "scala" },
    .{ "sc", "scala" },
    .{ "sbt", "scala" },
    .{ "ex", "ex" },
    .{ "exs", "ex" },
    .{ "hs", "hs" },
    .{ "php", "php" },
    .{ "php3", "php" },
    .{ "php4", "php" },
    .{ "php5", "php" },
    .{ "phtml", "php" },
    .{ "swift", "swift" },
    .{ "zig", "zig" },
    .{ "nix", "nix" },
    .{ "ocaml", "ocaml" },
    .{ "ml", "ocaml" },
    .{ "mli", "mli" },
    .{ "dart", "dart" },
    .{ "sql", "sql" },
    .{ "psql", "sql" },
    .{ "mysql", "sql" },
    .{ "mk", "make" },
    .{ "make", "make" },
    .{ "makefile", "make" },
    .{ "kt", "kt" },
    .{ "kts", "kt" },
    .{ "regex", "regex" },
    .{ "dockerfile", "dockerfile" },
    .{ "containerfile", "dockerfile" },
    .{ "hcl", "hcl" },
    .{ "tf", "hcl" },
    .{ "tfvars", "hcl" },
    .{ "terraform", "hcl" },
    .{ "proto", "proto" },
    .{ "protobuf", "proto" },
    .{ "diff", "diff" },
    .{ "patch", "diff" },
    .{ "vue", "vue" },
    .{ "svelte", "svelte" },
    .{ "astro", "astro" },
});

/// Files conventionally named without an extension (`Makefile`, `Dockerfile.dev`,
/// `Gemfile`, `.envrc`) → table key. Checked before the extension.
pub fn keyForFilename(name: []const u8) ?[]const u8 {
    if (filename_aliases.get(name)) |k| return k;
    if (std.mem.startsWith(u8, name, "Dockerfile.") or std.mem.startsWith(u8, name, "Containerfile.")) return "dockerfile";
    return null;
}

const filename_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Makefile", "make" },         .{ "makefile", "make" },            .{ "GNUmakefile", "make" },
    .{ "Rakefile", "rb" },           .{ "Gemfile", "rb" },               .{ "Vagrantfile", "rb" },
    .{ "Brewfile", "rb" },           .{ "Podfile", "rb" },               .{ "Fastfile", "rb" },
    .{ ".env", "sh" },               .{ ".envrc", "sh" },                .{ "Dockerfile", "dockerfile" },
    .{ "dockerfile", "dockerfile" }, .{ "Containerfile", "dockerfile" }, .{ "containerfile", "dockerfile" },
    // The shell's own dotfiles: no extension, no shebang, shell to
    // every tool (shellcheck parses a `.zshrc`; it only asks for a
    // shebang). Without these rows they painted plain beside a green
    // `.env`.
    .{ ".zshrc", "sh" },             .{ ".zshenv", "sh" },               .{ ".zprofile", "sh" },
    .{ ".zlogin", "sh" },            .{ ".zlogout", "sh" },              .{ ".bashrc", "sh" },
    .{ ".bash_profile", "sh" },      .{ ".bash_login", "sh" },           .{ ".bash_logout", "sh" },
    .{ ".bash_aliases", "sh" },      .{ ".profile", "sh" },              .{ ".shrc", "sh" },
});

/// An injection language name — a code-fence info string (`rust`, `console`) or a literal
/// from an `injections.scm` (`markdown_inline`, `html`) — → table key. Case-insensitive;
/// surrounding whitespace ignored. Longer names than `max_language_name` never match.
pub fn keyForLanguageName(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_language_name) return null;
    var buf: [max_language_name]u8 = undefined;
    const name = std.ascii.lowerString(buf[0..trimmed.len], trimmed);
    return language_name_aliases.get(name);
}

const max_language_name = 32;

const language_name_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "rust", "rs" },                         .{ "rs", "rs" },
    .{ "javascript", "js" },                   .{ "js", "js" },
    .{ "node", "js" },                         .{ "jsx", "jsx" },
    .{ "typescript", "ts" },                   .{ "ts", "ts" },
    .{ "tsx", "tsx" },                         .{ "python", "py" },
    .{ "py", "py" },                           .{ "json", "json" },
    .{ "jsonc", "json" },                      .{ "json5", "json" },
    .{ "jsonl", "json" },                      .{ "ndjson", "json" },
    .{ "go", "go" },                           .{ "golang", "go" },
    .{ "toml", "toml" },                       .{ "css", "css" },
    .{ "scss", "css" },                        .{ "sass", "css" },
    .{ "bash", "sh" },                         .{ "sh", "sh" },
    .{ "shell", "sh" },                        .{ "shellscript", "sh" },
    .{ "zsh", "sh" },                          .{ "console", "sh" },
    .{ "fish", "sh" },                         .{ "html", "html" },
    .{ "htm", "html" },                        .{ "xml", "html" },
    .{ "markdown", "md" },                     .{ "md", "md" },
    .{ "mdx", "md" },                          .{ "markdown_inline", "markdown_inline" },
    .{ "markdown-inline", "markdown_inline" }, .{ "c", "c" },
    .{ "cpp", "cpp" },                         .{ "c++", "cpp" },
    .{ "cxx", "cpp" },                         .{ "cc", "cpp" },
    .{ "ruby", "rb" },                         .{ "rb", "rb" },
    .{ "java", "java" },                       .{ "csharp", "cs" },
    .{ "c#", "cs" },                           .{ "cs", "cs" },
    .{ "c_sharp", "cs" },                      .{ "lua", "lua" },
    .{ "yaml", "yaml" },                       .{ "yml", "yaml" },
    .{ "scala", "scala" },                     .{ "sbt", "scala" },
    .{ "elixir", "ex" },                       .{ "ex", "ex" },
    .{ "exs", "ex" },                          .{ "haskell", "hs" },
    .{ "hs", "hs" },                           .{ "php", "php" },
    .{ "php_only", "php" },                    .{ "swift", "swift" },
    .{ "zig", "zig" },                         .{ "nix", "nix" },
    .{ "ocaml", "ocaml" },                     .{ "ml", "ocaml" },
    .{ "ocaml_interface", "mli" },             .{ "mli", "mli" },
    .{ "dart", "dart" },                       .{ "sql", "sql" },
    .{ "psql", "sql" },                        .{ "mysql", "sql" },
    .{ "make", "make" },                       .{ "makefile", "make" },
    .{ "kotlin", "kt" },                       .{ "kt", "kt" },
    .{ "kts", "kt" },                          .{ "regex", "regex" },
    .{ "dockerfile", "dockerfile" },           .{ "containerfile", "dockerfile" },
    .{ "hcl", "hcl" },                         .{ "terraform", "hcl" },
    .{ "tf", "hcl" },                          .{ "tfvars", "hcl" },
    .{ "proto", "proto" },                     .{ "protobuf", "proto" },
    .{ "diff", "diff" },                       .{ "patch", "diff" },
    .{ "vue", "vue" },                         .{ "svelte", "svelte" },
    .{ "astro", "astro" },
});

// Every alias target must be a real table key — checked once, at compile time.
comptime {
    @setEvalBranchQuota(20_000);
    for (extension_aliases.values()) |k| if (key_index.get(k) == null) @compileError("extension alias → unknown key: " ++ k);
    for (filename_aliases.values()) |k| if (key_index.get(k) == null) @compileError("filename alias → unknown key: " ++ k);
    for (language_name_aliases.values()) |k| if (key_index.get(k) == null) @compileError("language alias → unknown key: " ++ k);
}

// ── grammar entry points (linked from the ts-grammars static lib) ────────────

extern fn tree_sitter_rust() callconv(.c) *const ts.Language;
extern fn tree_sitter_javascript() callconv(.c) *const ts.Language;
extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_tsx() callconv(.c) *const ts.Language;
extern fn tree_sitter_python() callconv(.c) *const ts.Language;
extern fn tree_sitter_json() callconv(.c) *const ts.Language;
extern fn tree_sitter_go() callconv(.c) *const ts.Language;
extern fn tree_sitter_toml() callconv(.c) *const ts.Language;
extern fn tree_sitter_markdown() callconv(.c) *const ts.Language;
extern fn tree_sitter_markdown_inline() callconv(.c) *const ts.Language;
extern fn tree_sitter_c() callconv(.c) *const ts.Language;
extern fn tree_sitter_bash() callconv(.c) *const ts.Language;
extern fn tree_sitter_css() callconv(.c) *const ts.Language;
extern fn tree_sitter_html() callconv(.c) *const ts.Language;
extern fn tree_sitter_cpp() callconv(.c) *const ts.Language;
extern fn tree_sitter_ruby() callconv(.c) *const ts.Language;
extern fn tree_sitter_java() callconv(.c) *const ts.Language;
extern fn tree_sitter_yaml() callconv(.c) *const ts.Language;
extern fn tree_sitter_c_sharp() callconv(.c) *const ts.Language;
extern fn tree_sitter_lua() callconv(.c) *const ts.Language;
extern fn tree_sitter_scala() callconv(.c) *const ts.Language;
extern fn tree_sitter_elixir() callconv(.c) *const ts.Language;
extern fn tree_sitter_haskell() callconv(.c) *const ts.Language;
extern fn tree_sitter_php() callconv(.c) *const ts.Language;
extern fn tree_sitter_make() callconv(.c) *const ts.Language;
extern fn tree_sitter_swift() callconv(.c) *const ts.Language;
extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_nix() callconv(.c) *const ts.Language;
extern fn tree_sitter_ocaml() callconv(.c) *const ts.Language;
extern fn tree_sitter_ocaml_interface() callconv(.c) *const ts.Language;
extern fn tree_sitter_dart() callconv(.c) *const ts.Language;
extern fn tree_sitter_sql() callconv(.c) *const ts.Language;
extern fn tree_sitter_kotlin() callconv(.c) *const ts.Language;
extern fn tree_sitter_regex() callconv(.c) *const ts.Language;
extern fn tree_sitter_containerfile() callconv(.c) *const ts.Language;
extern fn tree_sitter_hcl() callconv(.c) *const ts.Language;
extern fn tree_sitter_proto() callconv(.c) *const ts.Language;
extern fn tree_sitter_diff() callconv(.c) *const ts.Language;
extern fn tree_sitter_vue() callconv(.c) *const ts.Language;
extern fn tree_sitter_svelte() callconv(.c) *const ts.Language;
extern fn tree_sitter_astro() callconv(.c) *const ts.Language;
