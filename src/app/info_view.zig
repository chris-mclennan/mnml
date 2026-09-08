//! The info view's words and state (`ui/info_view.zig` paints them).
//! What the box says is Rust `hover_help.rs`'s ladder: the thing the
//! pointer rests on (a chip, a tree row, a tab — from the previous
//! frame's hits, so the box can be laid out before this frame paints),
//! else what the keyboard focus is on (the tree's cursor row, past the
//! first), else the active pane, else the one-liner for the focused
//! surface — `Sidebar` / `Editor` / `Right panel`. An overlay is not a
//! surface: the ladder reads the one the keys go back to (`focusUnder`).
//! The curated entries (`treeRowCopy`, `chipCopy`) are the Rust
//! dictionary's tree and chip sections.
//!
//! The kebab's menu is the one row Rust has: turn the panel off. A
//! `→ Run it` link runs the command the copy names; the app keeps the
//! ids by position because the painter's `Copy` is plain data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Mouse = @import("../core/key.zig").Mouse;
const command = @import("../core/command.zig");
const CommandId = command.CommandId;
const hit_mod = @import("../ui/hit.zig");
const HitTarget = hit_mod.HitTarget;
const view = @import("../ui/info_view.zig");
const tree_view = @import("../ui/tree_view.zig");
const tree_mod = @import("tree.zig");
const icons = @import("../ui/icons.zig");
const discovery = @import("discovery.zig");

pub const Copy = view.Copy;
pub const Part = view.Part;

pub const max_links = 3;

pub const State = struct {
    scroll: u16 = 0,
    /// From the last paint, so the wheel knows where it stops.
    max_scroll: u16 = 0,
    /// A hash of the last copy's title: a new topic scrolls back to the top.
    topic: u64 = 0,
    /// What the `→` rows run, by position.
    links: [max_links]?CommandId = @splat(null),
};

/// The copy for this frame — and the state it implies: the links the
/// rows will run, the scroll reset when the topic changed.
pub fn pick(app: *App, arena: Allocator) Allocator.Error!Copy {
    const copy = try pickCopy(app, arena);
    const st = &app.info_view;
    const topic = std.hash.Wyhash.hash(0, copy.title);
    if (topic != st.topic) {
        st.topic = topic;
        st.scroll = 0;
    }
    return copy;
}

fn pickCopy(app: *App, arena: Allocator) Allocator.Error!Copy {
    const st = &app.info_view;
    st.links = @splat(null);
    if (app.hover_live) if (app.hover) |h| if (app.hits.at(h.x, h.y)) |target| if (try hoverCopy(app, arena, target)) |c| return c;
    if (try focusCopy(app, arena)) |c| return c;
    if (try activePaneCopy(app, arena)) |c| return c;
    return emptyCopy(app);
}

/// What the pointer rests on. The box itself says nothing new.
fn hoverCopy(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!?Copy {
    switch (target) {
        .info_view => return null,
        .tree_chip => |c| return chipCopy(app, c),
        .tree_root => |r| {
            if (r == 0) return .{
                .title = "Workspace root",
                .body = "Names the folder the tree is rooted at — click to collapse or expand the whole tree. The chips on the row make a folder or a file, pull, fold every directory, and rescan.",
            };
            if (r - 1 < app.tree.roots.items.len) return .{
                .title = try std.fmt.allocPrint(arena, "Workspace: {s}", .{app.tree.roots.items[r - 1].name}),
                .body = "An extra workspace root from `workspaces` in config.zon. Click to open or fold its tree; view.switch_workspace makes it the one open.",
            };
            return null;
        },
        .tree_node => |idx| {
            if (idx >= app.tree.rows.items.len) return null;
            const row = app.tree.rows.items[idx];
            if (row.header) return null;
            return try rowCopy(arena, row.name(), row.is_dir);
        },
        else => {
            const tip = (try discovery.describe(app, arena, target)) orelse return null;
            return .{ .title = tip.title, .body = tip.detail orelse "" };
        },
    }
}

/// The surface the keys go back to under an overlay: the prompt's, the
/// confirm's or the menu's way back, else the active pane (the tree
/// when there is none). Rust keeps `app.focus` on the surface while a
/// picker or a confirm is up, so its ladder never sees the overlay —
/// the delete box shows the row's doc and the picker the `Sidebar`
/// line. The statusline's mode chip resolves the same way.
fn focusUnder(app: *const App) app_mod.FocusId {
    const fallback: app_mod.FocusId = if (app.active) |a| .{ .pane = a } else .tree;
    return switch (app.focus) {
        .overlay => switch (app.overlay) {
            .prompt => |p| p.return_focus orelse fallback,
            .confirm => |c| c.return_focus orelse fallback,
            .menu => |m| m.return_focus,
            else => fallback,
        },
        else => app.focus,
    };
}

/// The tree's cursor row, flattened as Rust's focus ladder shows it.
/// Nothing on a header, and nothing at rest on the first row — the
/// `Sidebar` copy stays until the user walks.
fn focusCopy(app: *App, arena: Allocator) Allocator.Error!?Copy {
    if (focusUnder(app) != .tree) return null;
    const rows = app.tree.rows.items;
    if (app.tree.cursor >= rows.len) return null;
    const row = rows[app.tree.cursor];
    if (row.header) return null;
    var first: usize = 0;
    while (first < rows.len and rows[first].header) : (first += 1) {}
    if (app.tree.cursor == first) return null;
    return try view.flatten(arena, try rowCopy(arena, row.name(), row.is_dir));
}

/// The curated entry for a tree row, else the generic line.
fn rowCopy(arena: Allocator, name: []const u8, is_dir: bool) Allocator.Error!Copy {
    if (try treeRowCopy(arena, name, is_dir)) |c| return c;
    if (is_dir) return .{
        .title = try std.fmt.allocPrint(arena, "{s}/", .{name}),
        .body = "Directory. Enter or Right expands / opens. j/k walks rows.",
    };
    return .{
        .title = name,
        .body = "File. Enter opens it in a new tab. Right-click for cut / copy / paste / rename.",
    };
}

/// The active pane's summary (Rust `describe_active_pane`).
fn activePaneCopy(app: *App, arena: Allocator) Allocator.Error!?Copy {
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .editor => |*e| try editorCopy(arena, p, e),
        .request => .{ .title = p.title(), .body = "Request pane — Enter to send, Ctrl+S saves as .http/.curl." },
        .pty => .{ .title = p.title(), .body = "Terminal pane — Ctrl+Alt+H to detach, Ctrl+Alt+K to kill." },
        .md_preview => .{ .title = p.title(), .body = "Rendered markdown preview — click header chip to jump back to source." },
        .ai => .{ .title = p.title(), .body = "Claude / Codex session — type at the bottom prompt." },
        // Rust's `describe_active_pane` says nothing for the graph: the
        // box keeps the sidebar's own words in git mode.
        .git_graph => null,
        else => .{ .title = p.title() },
    };
}

/// `name  ·  LANG  ·  L:C  ·  N lines` with the editor's chords; the
/// identifier under the cursor first when there is one.
fn editorCopy(arena: Allocator, p: *const app_mod.Pane, e: *const app_mod.EditorPane) Allocator.Error!Copy {
    const ed = e.buf.editor;
    const pos = ed.rowCol();
    const title = p.title();
    var lang_buf: [16]u8 = undefined;
    const lang: []const u8 = if (e.buf.doc.path) |path| (if (icons.extensionOf(std.fs.path.basename(path))) |ext| (if (ext.len <= lang_buf.len) std.ascii.upperString(&lang_buf, ext) else "TEXT") else "TEXT") else "TEXT";
    const sym = wordUnderCursor(ed.doc.bytes(), ed.cursor);
    if (sym.len > 0 and sym.len <= 48) return .{
        .title = try std.fmt.allocPrint(arena, "{s}  ·  {s}  ·  {s}  ·  L{d}:{d}", .{ sym, lang, title, pos.row + 1, pos.col + 1 }),
        .body = "[gd] Definition · [gr] References · [K] Hover · [F2] Rename",
    };
    const lines = @max(ed.lineCount(), 1);
    return .{
        .title = try std.fmt.allocPrint(arena, "{s}  ·  {s}  ·  L{d}:{d}  ·  {d} lines{s}", .{ title, lang, pos.row + 1, pos.col + 1, lines, if (p.dirty()) " · unsaved" else "" }),
        .body = if (e.pinned) "Pinned — stays at the front of the bufferline." else "[gd] Definition · [gr] References · [Ctrl+.] Code actions · [Ctrl+P] Files",
    };
}

/// The identifier the cursor is in or on; empty between tokens.
pub fn wordUnderCursor(text: []const u8, cursor: usize) []const u8 {
    if (text.len == 0) return "";
    const at = @min(cursor, text.len - 1);
    if (!isWord(text[at])) return "";
    var start = at;
    while (start > 0 and isWord(text[start - 1])) start -= 1;
    var end = at + 1;
    while (end < text.len and isWord(text[end])) end += 1;
    return text[start..end];
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Rust's box title for a section: its label in title case (`Todos`).
fn sectionTitle(p: app_mod.PanelId) []const u8 {
    return switch (p) {
        .todos => "Todos",
        .notes => "Notes",
        .findings => "Findings",
        .sessions => "Sessions",
        .git => "Source control",
        .diagnostics => "Diagnostics",
        .http => "HTTP",
        .outline => "Outline",
        .debug => "Run and debug",
        .integrations => "Integrations",
    };
}

/// The one-liner per focused surface.
fn emptyCopy(app: *App) Copy {
    return switch (focusUnder(app)) {
        .tree => .{ .title = "Sidebar", .body = "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette." },
        // The box is titled with the section (Rust's `Todos`), whichever
        // column it is in.
        .panel => |p| if (p == .git and app.git_palette.active)
            .{ .title = "Sidebar", .body = "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette." }
        else if (p == .integrations)
            // Rust's words for the INTEGRATIONS section.
            .{ .title = sectionTitle(p), .body = "Installed integrations. Enter fires the command. Right-click for Configure / Uninstall." }
        else
            .{ .title = sectionTitle(p), .body = "Arrows walk rows. Enter jumps to the source. F6 cycles focus." },
        // In git mode the graph pane says nothing of its own and Rust's box
        // shows the sidebar's words.
        .pane => |id| if (app.git_palette.active and app.panes.get(id) != null and app.panes.get(id).?.* == .git_graph)
            .{ .title = "Sidebar", .body = "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette." }
        else
            .{ .title = "Editor", .body = "Hover a chip, tab, or tree row for help. Ctrl+Shift+P opens the palette." },
        // `focusUnder` never says so: an overlay names its surface.
        .overlay => unreachable,
    };
}

// ─── the dictionary ─────────────────────────────────────────────────────

const open_shortcuts = [_]view.Shortcut{
    .{ .chord = "Enter", .label = "Open in the active pane" },
    .{ .chord = "Ctrl+Enter", .label = "Open in a horizontal split" },
};

const dir_shortcuts = [_]view.Shortcut{
    .{ .chord = "Enter", .label = "Expand / collapse" },
    .{ .chord = "→ / ←", .label = "Expand / collapse (arrows)" },
};

const Row = struct { key: []const u8, lang: []const u8, body: []const u8 };

/// Whole-filename rows (Rust `filename_row_copy`), lower-cased.
const by_name = [_]Row{
    .{ .key = "package.json", .lang = "npm manifest", .body = "Declares this package's dependencies, scripts, and metadata for npm / pnpm / yarn. Syntax-only highlighting; no schema validation. `npm run <script>` from a terminal pane runs anything listed under `scripts`." },
    .{ .key = "dockerfile", .lang = "Dockerfile", .body = "Defines how `docker build` assembles an image — base layer, copied files, entrypoint. Syntax-only highlighting. `:!docker build .` from the cmdline works if docker is on PATH." },
    .{ .key = ".env", .lang = "Environment variables", .body = "Untracked key=value pairs the process reads at startup. This is separate from mnml's own `{{VAR}}` substitution, which reads `.mnml/env/<name>.env` in Request panes. Treat this file as secrets — keep it out of git." },
    .{ .key = "makefile", .lang = "Build recipes", .body = "Defines named targets (`make build`, `make test`, …) as shell recipes. Tab-indentation is significant — a space where a tab is expected is the #1 Makefile syntax error. No LSP; syntax-only highlighting." },
    .{ .key = "package-lock.json", .lang = "npm lockfile", .body = "Exact dependency-tree snapshot npm resolved from `package.json`. Generated by `npm install` — don't hand-edit; a mismatch with `package.json` triggers a warning on the next install." },
    .{ .key = "pnpm-lock.yaml", .lang = "pnpm lockfile", .body = "Exact dependency-tree snapshot pnpm resolved from `package.json`. Generated by `pnpm install` — don't hand-edit." },
    .{ .key = "tsconfig.json", .lang = "TypeScript project config", .body = "Compiler options, path aliases, and `include`/`exclude` globs that tsserver reads to resolve module paths. A wrong `baseUrl` or `paths` entry here is the usual cause of false 'cannot find module' errors in the editor." },
    .{ .key = ".gitignore", .lang = "Git ignore rules", .body = "Path patterns excluded from `git status` / `git add`. mnml's own file picker excludes `.git/` unconditionally regardless of what's listed here." },
    .{ .key = ".gitattributes", .lang = "Git attributes", .body = "Per-path git behavior — line-ending normalization, diff drivers, merge strategies, archive export-ignore. Affects what `git` does with the file, not how mnml renders it." },
    .{ .key = ".gitconfig", .lang = "Git config", .body = "INI-style git settings — user identity, aliases, remotes. A repo's `.git/config` takes precedence over this one when both set the same key." },
    .{ .key = ".eslintrc", .lang = "ESLint config", .body = "Lint rules and plugin config for ESLint. mnml doesn't run ESLint itself — pair with a terminal pane (`eslint .`) or an LSP that surfaces its diagnostics." },
    .{ .key = ".prettierrc", .lang = "Prettier config", .body = "Formatting rules — quote style, semicolons, line width — for Prettier. mnml doesn't format on save from this file; run `prettier --write` from a terminal pane." },
    .{ .key = ".editorconfig", .lang = "EditorConfig", .body = "Cross-editor whitespace rules (indent size, tabs vs spaces, trailing newline) keyed by glob. mnml reads it for the indentation of the files it covers." },
    .{ .key = ".dockerignore", .lang = "Docker ignore rules", .body = "Paths excluded from the build context `docker build` sends to the daemon — same glob syntax as `.gitignore`. Keeping it tight speeds up builds and keeps secrets out of the image." },
    .{ .key = ".npmrc", .lang = "npm config", .body = "Per-project npm settings — registry URL, auth tokens, save-exact behavior. Treat auth-token lines as secrets and keep them out of git." },
    .{ .key = ".nvmrc", .lang = "Node version pin", .body = "A single line naming the Node version this project expects. `nvm use` (or an nvm-aware shell hook) reads it automatically on `cd`." },
    .{ .key = "docker-compose.yml", .lang = "Compose file", .body = "Defines the multi-container stack — services, networks, volumes — for `docker compose up`. Indentation-sensitive YAML, same as any other `.yml`; syntax-only highlighting." },
    .{ .key = "docker-compose.yaml", .lang = "Compose file", .body = "Defines the multi-container stack — services, networks, volumes — for `docker compose up`. Indentation-sensitive YAML, same as any other `.yml`; syntax-only highlighting." },
    .{ .key = "compose.yml", .lang = "Compose file", .body = "Defines the multi-container stack — services, networks, volumes — for `docker compose up`. Indentation-sensitive YAML, same as any other `.yml`; syntax-only highlighting." },
    .{ .key = "compose.yaml", .lang = "Compose file", .body = "Defines the multi-container stack — services, networks, volumes — for `docker compose up`. Indentation-sensitive YAML, same as any other `.yml`; syntax-only highlighting." },
    .{ .key = "readme", .lang = "Project readme", .body = "The first thing a visitor to this repo or folder reads. mnml renders it like any other Markdown file when `ui.render_markdown` is on; `:e` opens the raw source." },
    .{ .key = "readme.md", .lang = "Project readme", .body = "The first thing a visitor to this repo or folder reads. mnml renders it like any other Markdown file when `ui.render_markdown` is on; `:e` opens the raw source." },
    .{ .key = "license", .lang = "License text", .body = "The legal terms this project is distributed under. Plain text or Markdown depending on the project; mnml applies syntax-only highlighting either way." },
    .{ .key = "copying", .lang = "License text (GNU convention)", .body = "Same role as LICENSE — the GNU-project convention for the license filename, common on GPL-licensed code. Plain text; no highlighting." },
};

/// Extension rows (Rust `tree_row_copy`), lower-cased.
const by_ext = [_]Row{
    .{ .key = "rs", .lang = "Rust source", .body = "Compiled with cargo. Hover a symbol in the buffer for LSP info (once the LSP has warmed up)." },
    .{ .key = "ts", .lang = "TypeScript source", .body = "TypeScript / TSX. LSP fires once tsserver is up — takes a few seconds on first open of the workspace." },
    .{ .key = "tsx", .lang = "TypeScript source", .body = "TypeScript / TSX. LSP fires once tsserver is up — takes a few seconds on first open of the workspace." },
    .{ .key = "py", .lang = "Python source", .body = "Python. LSP via pyright once mnml detects a Python interpreter." },
    .{ .key = "md", .lang = "Markdown", .body = "Rendered inline by default when `ui.render_markdown` is on. `:e path.md` opens the raw editor instead." },
    .{ .key = "mdx", .lang = "Markdown", .body = "Rendered inline by default when `ui.render_markdown` is on. `:e path.md` opens the raw editor instead." },
    .{ .key = "toml", .lang = "TOML config", .body = "TOML config file. No LSP; syntax-only highlighting." },
    .{ .key = "json", .lang = "JSON data", .body = "JSON file. Syntax-only highlighting; use a `.http` or `.curl` file to send this as a request body." },
    .{ .key = "go", .lang = "Go source", .body = "Go. LSP fires once gopls is on PATH; module boundary comes from the nearest `go.mod`." },
    .{ .key = "sh", .lang = "Shell script", .body = "POSIX / bash / zsh script. No LSP by default; `:!chmod +x` on a new script makes it executable." },
    .{ .key = "bash", .lang = "Shell script", .body = "POSIX / bash / zsh script. No LSP by default; `:!chmod +x` on a new script makes it executable." },
    .{ .key = "zsh", .lang = "Shell script", .body = "POSIX / bash / zsh script. No LSP by default; `:!chmod +x` on a new script makes it executable." },
    .{ .key = "yaml", .lang = "YAML config", .body = "YAML config file. Indentation-sensitive — mnml paints trailing whitespace red when `ui.highlight_trailing_ws` is on." },
    .{ .key = "yml", .lang = "YAML config", .body = "YAML config file. Indentation-sensitive — mnml paints trailing whitespace red when `ui.highlight_trailing_ws` is on." },
    .{ .key = "js", .lang = "JavaScript", .body = "JavaScript / JSX. tsserver handles both TS and JS when it warms up, so LSP hover works even without types." },
    .{ .key = "jsx", .lang = "JavaScript", .body = "JavaScript / JSX. tsserver handles both TS and JS when it warms up, so LSP hover works even without types." },
    .{ .key = "html", .lang = "HTML markup", .body = "HTML. No LSP; syntax-only highlighting. Pair with a `.http` file next to it if this is a request-body template." },
    .{ .key = "htm", .lang = "HTML markup", .body = "HTML. No LSP; syntax-only highlighting. Pair with a `.http` file next to it if this is a request-body template." },
    .{ .key = "css", .lang = "Stylesheet", .body = "CSS / SCSS / SASS. Syntax-only highlighting; no LSP." },
    .{ .key = "scss", .lang = "Stylesheet", .body = "CSS / SCSS / SASS. Syntax-only highlighting; no LSP." },
    .{ .key = "sass", .lang = "Stylesheet", .body = "CSS / SCSS / SASS. Syntax-only highlighting; no LSP." },
    .{ .key = "sql", .lang = "SQL", .body = "SQL script. Syntax-only highlighting; no linter. Run against a live connection through your usual client — mnml doesn't execute." },
    .{ .key = "vue", .lang = "Vue single-file component", .body = "Vue 3 SFC — `<template>` / `<script>` / `<style>` blocks in one file. Syntax-only highlighting; no dedicated LSP yet." },
    .{ .key = "svelte", .lang = "Svelte component", .body = "Svelte single-file component — markup, script, and scoped styles together. Syntax-only highlighting; no LSP." },
    .{ .key = "c", .lang = "C source", .body = "C source file. Syntax-only highlighting; no LSP wired in yet." },
    .{ .key = "cpp", .lang = "C++ source", .body = "C++ source file. Syntax-only highlighting; no LSP wired in yet." },
    .{ .key = "h", .lang = "C/C++ header", .body = "Declarations only, no implementation. Syntax-only highlighting; no LSP." },
    .{ .key = "hpp", .lang = "C/C++ header", .body = "Declarations only, no implementation. Syntax-only highlighting; no LSP." },
    .{ .key = "java", .lang = "Java source", .body = "Java source file. Syntax-only highlighting; no LSP (jdtls isn't wired in yet)." },
    .{ .key = "kt", .lang = "Kotlin source", .body = "Kotlin source file. Syntax-only highlighting; no LSP." },
    .{ .key = "swift", .lang = "Swift source", .body = "Swift source file. Syntax-only highlighting; no LSP." },
    .{ .key = "cs", .lang = "C# source", .body = "C# source file. Syntax-only highlighting; no LSP wired in yet." },
    .{ .key = "csproj", .lang = "MSBuild project file", .body = "References, target framework, and package refs for a .NET project. XML under the hood; syntax-only highlighting." },
    .{ .key = "sln", .lang = "Visual Studio solution", .body = "Groups one or more `.csproj` projects for Visual Studio or `dotnet build`. Plain-text format; syntax-only highlighting." },
    .{ .key = "cshtml", .lang = "Razor page", .body = "ASP.NET Razor page — HTML markup with embedded C# `@` blocks. Syntax-only highlighting." },
    .{ .key = "razor", .lang = "Razor component", .body = "Blazor Razor component — HTML markup with embedded C#. Syntax-only highlighting." },
    .{ .key = "fs", .lang = "F# source", .body = "F# source file. Syntax-only highlighting; no LSP." },
    .{ .key = "xml", .lang = "XML data", .body = "XML markup. Syntax-only highlighting; no schema validation." },
    .{ .key = "svg", .lang = "SVG image", .body = "Scalable vector graphic — technically XML, but mnml treats it as an image. No inline preview; open it in a browser to see it rendered." },
    .{ .key = "png", .lang = "Image", .body = "Raster image. mnml shows it in an image pane when the terminal can draw one." },
    .{ .key = "jpg", .lang = "Image", .body = "Raster image. mnml shows it in an image pane when the terminal can draw one." },
    .{ .key = "jpeg", .lang = "Image", .body = "Raster image. mnml shows it in an image pane when the terminal can draw one." },
    .{ .key = "gif", .lang = "Image", .body = "Raster image. mnml shows it in an image pane when the terminal can draw one." },
    .{ .key = "webp", .lang = "Image", .body = "Raster image. mnml shows it in an image pane when the terminal can draw one." },
    .{ .key = "http", .lang = "HTTP request file", .body = "mnml's own request format — method, URL, headers, and body in one file. Opening it launches the Request pane UI instead of a plain-text editor." },
    .{ .key = "curl", .lang = "HTTP request file", .body = "mnml's own request format — method, URL, headers, and body in one file. Opening it launches the Request pane UI instead of a plain-text editor." },
    .{ .key = "rest", .lang = "HTTP request file", .body = "mnml's own request format — method, URL, headers, and body in one file. Opening it launches the Request pane UI instead of a plain-text editor." },
    .{ .key = "request", .lang = "HTTP request file", .body = "mnml's own request format — method, URL, headers, and body in one file. Opening it launches the Request pane UI instead of a plain-text editor." },
    .{ .key = "cjs", .lang = "CommonJS module", .body = "Explicit CommonJS (`require` / `module.exports`) — same JS runtime as plain `.js`, but the extension forces CommonJS even inside a `\"type\": \"module\"` package. Syntax-only highlighting." },
    .{ .key = "mjs", .lang = "ES module", .body = "Explicit ES module (`import` / `export`) — the extension forces ESM even inside a package that defaults to CommonJS. Syntax-only highlighting." },
    .{ .key = "less", .lang = "Less stylesheet", .body = "Variables, nesting, and mixins that precompile to plain CSS. Syntax-only highlighting; no LSP." },
    .{ .key = "csv", .lang = "CSV data", .body = "Comma-separated tabular data. mnml renders it as plain text, not a spreadsheet grid — no column alignment or sorting." },
    .{ .key = "ini", .lang = "INI config", .body = "Key=value settings grouped into `[section]` blocks. No LSP; syntax-only highlighting." },
    .{ .key = "conf", .lang = "INI config", .body = "Key=value settings grouped into `[section]` blocks. No LSP; syntax-only highlighting." },
    .{ .key = "rb", .lang = "Ruby source", .body = "Ruby source file. Syntax-only highlighting; no LSP (solargraph isn't wired in yet)." },
    .{ .key = "php", .lang = "PHP source", .body = "PHP source file. Syntax-only highlighting; no LSP (intelephense isn't wired in yet)." },
    .{ .key = "lua", .lang = "Lua source", .body = "Lua source file. Syntax-only highlighting; no LSP." },
    .{ .key = "ps1", .lang = "PowerShell script", .body = "PowerShell script. Syntax-only highlighting; no LSP." },
    .{ .key = "txt", .lang = "Plain text", .body = "No syntax highlighting applied — mnml opens it exactly as written." },
    .{ .key = "lock", .lang = "Dependency lockfile", .body = "Pins exact resolved dependency versions (Cargo.lock-style). Generated by the package manager — hand-editing it is unusual and gets overwritten on the next install." },
    .{ .key = "log", .lang = "Log file", .body = "Append-only runtime output, not source. `Ctrl+F` (find) is usually the fastest way to jump around a large one." },
    .{ .key = "exe", .lang = "Windows executable", .body = "Binary Windows executable. mnml doesn't render binary content — opening it shows raw bytes, not source." },
    .{ .key = "dll", .lang = "Windows library", .body = "Binary Windows dynamic-link library. mnml doesn't render binary content — opening it shows raw bytes, not source." },
    .{ .key = "zip", .lang = "Compressed archive", .body = "mnml doesn't unpack it inline — extract with a terminal pane (`tar` / `unzip`) to browse the contents." },
    .{ .key = "gz", .lang = "Compressed archive", .body = "mnml doesn't unpack it inline — extract with a terminal pane (`tar` / `unzip`) to browse the contents." },
    .{ .key = "tgz", .lang = "Compressed archive", .body = "mnml doesn't unpack it inline — extract with a terminal pane (`tar` / `unzip`) to browse the contents." },
};

/// The curated copy for a tree row: a directory, a `.d.ts`, a known
/// filename, a known extension — else null.
pub fn treeRowCopy(arena: Allocator, label: []const u8, is_dir: bool) Allocator.Error!?Copy {
    if (is_dir) return .{
        .title = try std.fmt.allocPrint(arena, "{s}/", .{label}),
        .body = "Directory. Enter or click to expand; walk the tree with arrows or j/k. Right-click for rename / cut / copy / new file.",
        .shortcuts = &dir_shortcuts,
    };
    var buf: [256]u8 = undefined;
    if (label.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, label);
    if (std.mem.endsWith(u8, lower, ".d.ts")) return .{
        .title = try std.fmt.allocPrint(arena, "{s} — TypeScript declarations", .{label}),
        .body = "`.d.ts` — TypeScript type declarations. No runtime code; describes the shape of a JS module for tsserver to consume. Editing here changes types, not behavior.",
        .shortcuts = &open_shortcuts,
    };
    for (by_name) |r| if (std.mem.eql(u8, r.key, lower)) return .{
        .title = try std.fmt.allocPrint(arena, "{s} — {s}", .{ label, r.lang }),
        .body = r.body,
        .shortcuts = &open_shortcuts,
    };
    const ext = icons.extensionOf(lower) orelse return null;
    for (by_ext) |r| if (std.mem.eql(u8, r.key, ext)) return .{
        .title = try std.fmt.allocPrint(arena, "{s} — {s}", .{ label, r.lang }),
        .body = r.body,
        .shortcuts = &open_shortcuts,
    };
    return null;
}

const run_it = [_]view.Link{.{ .label = "Run it" }};

/// A header chip's copy (Rust `TreeIcon`), with a `Run it` link.
pub fn chipCopy(app: *App, c: tree_view.Chip) Copy {
    app.info_view.links[0] = tree_mod.chipCommand(c);
    return switch (c) {
        .new_file => .{ .title = "New file", .body = "Creates an empty file in the workspace root and opens it in a fresh tab, prompting for a name first.", .try_it = &run_it },
        .new_folder => .{ .title = "New folder", .body = "Creates a new directory in the workspace root after prompting for a name. The tree jumps to show it.", .try_it = &run_it },
        .refresh => .{ .title = "Refresh tree", .body = "Re-scans the workspace root from disk and repaints the tree — use it after external changes mnml's file-watcher might have missed (bulk git operations, another process writing files).", .try_it = &run_it },
        .collapse => .{ .title = "Collapse / expand all", .body = "Folds every open directory in the tree closed, or opens every directory when the tree is already fully collapsed. One click toggles the whole rail.", .try_it = &run_it },
        .pull => .{ .title = "Pull (workspace header)", .body = "Runs `git pull --ff-only` against the repo that owns this workspace root, right from the tree header.", .try_it = &run_it },
        .add_workspace => .{ .title = "Add workspace folder", .body = "Opens a path prompt to add another folder as an extra workspace root alongside the current one — the tree grows a second top-level section instead of replacing what's open. Type a path (`~` expands); missing intermediate folders are NOT created here.", .try_it = &run_it },
    };
}

// ─── mouse ──────────────────────────────────────────────────────────────

/// A press or wheel on the box: the kebab drops its menu, a link row
/// runs its command, the wheel scrolls, anything else is swallowed.
pub fn mouse(app: *App, part: Part, m: Mouse) Allocator.Error!void {
    const st = &app.info_view;
    switch (m.kind) {
        .scroll_up => st.scroll -|= app.cfg.ui.wheel_lines,
        .scroll_down => st.scroll = @min(st.scroll + app.cfg.ui.wheel_lines, st.max_scroll),
        .press => {
            // right-click: the kebab's menu on either button.
            if (m.button == .right and part == .kebab) return openKebabMenu(app, m.x, m.y + 1);
            if (m.button != .left) return;
            switch (part) {
                .kebab => try openKebabMenu(app, m.x, m.y + 1),
                .try_it => |i| if (i < max_links) if (st.links[i]) |id| {
                    command.run(app, .{ .static = id }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {},
                    };
                },
                .body => {},
            }
        },
        else => {},
    }
    app.needs_render = true;
}

/// The sidebar menu: the one row Rust has.
pub fn openKebabMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.alloc(command.MenuItem, 1);
    errdefer app.gpa.free(items);
    items[0] = .{ .label = "Turn off info panel (Settings → UI to bring back)", .action = .{ .command = .@"view.toggle_hover_help" } };
    try app.openMenu("Sidebar", items, x, y);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

fn realRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

test "the ladder: Sidebar at rest, the row past the first when the tree walks, the file summary once one is open, the Editor line on a scratch" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "# demo\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    const arena = app.frame.allocator();
    // Row 0 (`src`) at rest: the Sidebar one-liner.
    const rest = try pick(&app, arena);
    try t.expectEqualStrings("Sidebar", rest.title);
    try t.expect(std.mem.startsWith(u8, rest.body, "Arrows or j/k walk rows."));
    // Walk to main.rs: the curated Rust copy, flattened with its chords.
    app.tree.cursor = 1;
    const rs = try pick(&app, arena);
    try t.expectEqualStrings("main.rs — Rust source", rs.title);
    try t.expect(std.mem.indexOf(u8, rs.body, "Compiled with cargo.") != null);
    try t.expect(std.mem.indexOf(u8, rs.body, "[Enter] Open in the active pane  [Ctrl+Enter] Open in a horizontal split") != null);
    try t.expectEqual(@as(usize, 0), rs.shortcuts.len);
    // A directory row.
    app.tree.cursor = 0;
    app.tree.cursor = app.tree.rowOf("src").?;
    try t.expectEqualStrings("Sidebar", (try pick(&app, arena)).title);
    // Open README.md: focus moves to the pane and the summary names it.
    app.tree.cursor = app.tree.rowOf("README.md").?;
    try app.tree.activate(&app, app.tree.cursor);
    const md = try pick(&app, arena);
    try t.expect(std.mem.startsWith(u8, md.title, "README.md"));
    try t.expect(std.mem.indexOf(u8, md.title, "MD") != null or std.mem.indexOf(u8, md.title, "L1:1") != null or app.panes.get(app.active.?).?.* == .md_preview);
    // A scratch buffer at 1:1 on empty text: the quiet fallback with L:C.
    _ = try app.openScratch();
    app.focus = .{ .pane = app.active.? };
    const scratch = try pick(&app, arena);
    try t.expect(std.mem.indexOf(u8, scratch.title, "L1:1") != null);
    try t.expect(std.mem.indexOf(u8, scratch.title, "1 lines") != null);
    try t.expect(std.mem.indexOf(u8, scratch.body, "[gd] Definition") != null);
}

test "the ladder under an overlay: the surface beneath, as Rust's focus never leaves it — the picker over the tree says Sidebar, the delete box keeps the row, a menu from the tree too; the git palette says Sidebar; a hovered chip beats them all" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "# demo\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    const arena = app.frame.allocator();
    const sidebar = "Sidebar";
    // The picker (any overlay without a way back) over the tree with
    // nothing open: the Sidebar line, not the Editor's.
    app.overlay = .discovery;
    app.focus = .overlay;
    try t.expectEqualStrings(sidebar, (try pick(&app, arena)).title);
    // The git palette with nothing open (its graph pane says nothing of
    // its own): the sidebar's words from its panel, and from a prompt
    // over it with no way back; the panel's own name once it is off.
    app.overlay = .none;
    app.git_palette.active = true;
    app.focus = .{ .panel = .git };
    try t.expectEqualStrings(sidebar, (try pick(&app, arena)).title);
    app.overlay = .{ .prompt = .{ .state = .{ .title = "Commit" }, .purpose = .goto_line } };
    app.focus = .overlay;
    try t.expectEqualStrings(sidebar, (try pick(&app, arena)).title);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.git_palette.active = false;
    app.focus = .{ .panel = .git };
    try t.expectEqualStrings("Source control", (try pick(&app, arena)).title);
    // The tree walked to main.rs, then its delete box (the confirm's way
    // back is the tree): the row's doc stays under the box.
    app.overlay = .none;
    app.focus = .tree;
    app.tree.cursor = app.tree.rowOf("src/main.rs") orelse app.tree.rowOf("main.rs").?;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    const msg = try app.gpa.dupe(u8, "Delete src/main.rs?");
    app.overlay = .{ .confirm = .{ .state = .{ .title = "Delete", .message = msg, .choices = &App.close_choices }, .purpose = .quit, .message = msg, .return_focus = .tree } };
    app.focus = .overlay;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    // A confirm with no way back and nothing open falls to the tree too.
    app.overlay.confirm.return_focus = null;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // The kebab's menu opened from the tree remembers the tree.
    app.focus = .tree;
    try openKebabMenu(&app, 5, 5);
    try t.expect(app.focus == .overlay);
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // A hovered chip beats the walked row.
    app.focus = .tree;
    try app.render();
    var chip_at: ?struct { x: u16, y: u16 } = null;
    for (app.hits.items.items) |e| if (e.target == .tree_chip and e.target.tree_chip == .refresh) {
        chip_at = .{ .x = e.rect.x, .y = e.rect.y };
    };
    app.hover = .{ .x = chip_at.?.x, .y = chip_at.?.y };
    app.hover_live = true;
    try t.expectEqualStrings("Refresh tree", (try pick(&app, arena)).title);
    app.hover_live = false;
    // A file open with the tree focused at its first row: Rust's focus
    // rung says nothing there and the active pane's summary shows —
    // walked past it, the row's doc wins over the open file.
    try app.tree.activate(&app, app.tree.cursor);
    try t.expect(app.active != null);
    app.focus = .tree;
    app.tree.cursor = 0;
    const at_rest = try pick(&app, arena);
    try t.expect(std.mem.startsWith(u8, at_rest.title, "fn  ·  RS  ·  main.rs"));
    try t.expectEqualStrings("[gd] Definition · [gr] References · [K] Hover · [F2] Rename", at_rest.body);
    app.tree.cursor = app.tree.rowOf("src/main.rs") orelse app.tree.rowOf("main.rs").?;
    try t.expectEqualStrings("main.rs — Rust source", (try pick(&app, arena)).title);
    // The picker over that: its way back is the pane, so the summary.
    app.overlay = .discovery;
    app.focus = .overlay;
    try t.expect(std.mem.startsWith(u8, (try pick(&app, arena)).title, "fn  ·  RS  ·  main.rs"));
    app.overlay = .none;
    // The pane focused: the summary, whatever the tree's cursor.
    app.focus = .{ .pane = app.active.? };
    try t.expect(std.mem.startsWith(u8, (try pick(&app, arena)).title, "fn  ·  RS  ·  main.rs"));
}

test "the dictionary: five targets — a directory, package.json, a .d.ts, a plain .txt, and an unknown extension" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = (try treeRowCopy(a, "src", true)).?;
    try t.expectEqualStrings("src/", dir.title);
    try t.expectEqual(@as(usize, 2), dir.shortcuts.len);
    try t.expectEqualStrings("Enter", dir.shortcuts[0].chord);
    const pkg = (try treeRowCopy(a, "Package.JSON", false)).?;
    try t.expectEqualStrings("Package.JSON — npm manifest", pkg.title);
    const dts = (try treeRowCopy(a, "types.d.ts", false)).?;
    try t.expectEqualStrings("types.d.ts — TypeScript declarations", dts.title);
    const txt = (try treeRowCopy(a, "notes.txt", false)).?;
    try t.expectEqualStrings("notes.txt — Plain text", txt.title);
    try t.expectEqualStrings("Ctrl+Enter", txt.shortcuts[1].chord);
    try t.expect((try treeRowCopy(a, "weird.xyz", false)) == null);
    try t.expect((try treeRowCopy(a, "Makefile", false)) != null);
    // Every dictionary key is lower-case and unique within its table.
    inline for (.{ by_name, by_ext }) |table| for (table, 0..) |r, i| {
        for (r.key) |c| try t.expect(!std.ascii.isUpper(c));
        for (table[0..i]) |prev| try t.expect(!std.mem.eql(u8, prev.key, r.key));
        try t.expect(r.body.len > 20);
    };
    try t.expectEqualStrings("main", wordUnderCursor("fn main() {}", 4));
    try t.expectEqualStrings("", wordUnderCursor("fn main() {}", 2));
    try t.expectEqualStrings("", wordUnderCursor("", 0));
    try t.expectEqualStrings("x_1", wordUnderCursor("x_1", 3));
}

test "hover: a chip's copy carries a Run it link the app resolves; the kebab menu offers the toggle; the wheel scrolls within the paint's bound" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    const arena = app.frame.allocator();
    const c = chipCopy(&app, .refresh);
    try t.expectEqualStrings("Refresh tree", c.title);
    try t.expectEqual(@as(usize, 1), c.try_it.len);
    try t.expectEqual(command.CommandId.@"tree.refresh", app.info_view.links[0].?);
    // A hovered chip through the hits.
    try app.render();
    var chip_at: ?struct { x: u16, y: u16 } = null;
    for (app.hits.items.items) |e| if (e.target == .tree_chip and e.target.tree_chip == .new_file) {
        chip_at = .{ .x = e.rect.x, .y = e.rect.y };
    };
    app.hover = .{ .x = chip_at.?.x, .y = chip_at.?.y };
    app.hover_live = true;
    const hovered = try pick(&app, arena);
    try t.expectEqualStrings("New file", hovered.title);
    try t.expectEqual(command.CommandId.@"file.new", app.info_view.links[0].?);
    // The link row runs it: a prompt opens.
    try mouse(&app, .{ .try_it = 0 }, .{ .x = 0, .y = 0, .kind = .press, .button = .left });
    try t.expect(app.overlay == .prompt);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // The kebab.
    try mouse(&app, .kebab, .{ .x = 5, .y = 5, .kind = .press, .button = .left });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Turn off info panel (Settings → UI to bring back)", app.overlay.menu.items[0].label);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // The wheel.
    app.info_view.max_scroll = 4;
    try mouse(&app, .body, .{ .x = 5, .y = 5, .kind = .scroll_down, .button = .none });
    try t.expectEqual(@as(u16, 3), app.info_view.scroll);
    try mouse(&app, .body, .{ .x = 5, .y = 5, .kind = .scroll_down, .button = .none });
    try t.expectEqual(@as(u16, 4), app.info_view.scroll);
    try mouse(&app, .body, .{ .x = 5, .y = 5, .kind = .scroll_up, .button = .none });
    try t.expectEqual(@as(u16, 1), app.info_view.scroll);
    // A new topic scrolls back to the top.
    app.hover_live = false;
    _ = try pick(&app, arena);
    try t.expectEqual(@as(u16, 0), app.info_view.scroll);
}
