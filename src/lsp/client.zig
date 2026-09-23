//! One language server: the JSON-RPC envelope over `rpc/jsonrpc`'s
//! transport, the `initialize` handshake and the capabilities mnml
//! reads off its reply, document sync (`didOpen` / `didChange` —
//! incremental when the server takes it — / `didSave` / `didClose`),
//! and the requests the app makes by `ReqKind`. The app side
//! (`app/lsp.zig`) owns the reactions; this file owns the wire.
//!
//! A document opened before the server is ready is queued and flushed
//! after `initialized`, so an editor never waits on a server start.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../rpc/jsonrpc.zig");
const Transport = jsonrpc.Transport;
const Value = jsonrpc.Value;
const event = @import("../core/event.zig");
const types = @import("types.zig");
const semantic = @import("semantic.zig");
const highlight = @import("highlight");

pub const Encoding = types.Encoding;

/// A `Pending.kind` back as words, for a message about a reply that
/// never arrived.
pub fn reqKindName(kind: u16) ?[]const u8 {
    inline for (@typeInfo(ReqKind).@"enum".fields) |f| {
        if (f.value == kind) return "the " ++ f.name ++ " reply";
    }
    return null;
}

pub const ReqKind = enum(u16) {
    initialize,
    shutdown,
    completion,
    completion_resolve,
    hover,
    signature_help,
    definition,
    declaration,
    type_definition,
    implementation,
    references,
    rename,
    formatting,
    code_action,
    code_action_resolve,
    execute_command,
    document_symbol,
    workspace_symbol,
    incoming_prepare,
    incoming_calls,
    outgoing_prepare,
    outgoing_calls,
    type_prepare,
    supertypes,
    subtypes,
    document_highlight,
    selection_range,
    folding_range,
    inlay_hint,
    code_lens,
    code_lens_resolve,
    semantic_full,
    semantic_delta,
    semantic_range,
    document_color,
    document_link,
    on_type_formatting,
    will_save_wait_until,
    range_formatting,
};

/// The word of context a request carries: the pane it was made for and
/// a second word the app uses as it likes (a byte offset, a flag).
pub const Ctx = packed struct(u64) {
    pane: u32 = std.math.maxInt(u32),
    extra: u32 = 0,

    pub fn pack(c: Ctx) u64 {
        return @bitCast(c);
    }
    pub fn unpack(v: u64) Ctx {
        return @bitCast(v);
    }
};

pub const SendError = jsonrpc.SendError || Allocator.Error;

/// What the app asks the server about, read once from `initialize`.
pub const Caps = struct {
    completion: bool = false,
    /// Owned; each byte a trigger character (multi-byte ones dropped).
    trigger_chars: []u8 = &.{},
    hover: bool = false,
    signature_help: bool = false,
    definition: bool = false,
    declaration: bool = false,
    type_definition: bool = false,
    implementation: bool = false,
    references: bool = false,
    rename: bool = false,
    formatting: bool = false,
    code_action: bool = false,
    document_symbol: bool = false,
    workspace_symbol: bool = false,
    call_hierarchy: bool = false,
    type_hierarchy: bool = false,
    document_highlight: bool = false,
    selection_range: bool = false,
    folding_range: bool = false,
    /// `completionProvider.resolveProvider`: accept asks for the full item.
    completion_resolve: bool = false,
    /// `textDocumentSync.change == 2`.
    incremental: bool = false,
    inlay_hint: bool = false,
    code_lens: bool = false,
    /// `codeLensProvider.resolveProvider`: a lens without a command asks.
    code_lens_resolve: bool = false,
    /// Owned: `executeCommandProvider.commands` — the only commands
    /// `workspace/executeCommand` may name.
    execute_commands: [][]u8 = &.{},
    document_color: bool = false,
    document_link: bool = false,
    range_formatting: bool = false,
    /// `textDocumentSync.willSaveWaitUntil`.
    will_save_wait_until: bool = false,
    /// Owned; each byte an on-type formatting trigger (multi-byte ones
    /// dropped). Empty when the server does not format as you type.
    on_type_triggers: []u8 = &.{},
    /// `semanticTokensProvider`: which request shapes the server takes
    /// and its legend, decoded once into mnml's roles.
    semantic_full: bool = false,
    semantic_delta: bool = false,
    semantic_range: bool = false,
    /// Owned: the legend's `tokenTypes` as `semantic.Role` values and
    /// `tokenModifiers` as `semantic.Modifier` values, by index.
    token_types: []semantic.Role = &.{},
    token_modifiers: []semantic.Modifier = &.{},

    pub fn deinit(c: *Caps, gpa: Allocator) void {
        gpa.free(c.trigger_chars);
        gpa.free(c.on_type_triggers);
        for (c.execute_commands) |n| gpa.free(n);
        gpa.free(c.execute_commands);
        gpa.free(c.token_types);
        gpa.free(c.token_modifiers);
        c.* = .{};
    }

    /// Did the server list `name` in `executeCommandProvider.commands`?
    pub fn executesCommand(c: *const Caps, name: []const u8) bool {
        for (c.execute_commands) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    pub fn semanticTokens(c: *const Caps) bool {
        return c.semantic_full or c.semantic_delta or c.semantic_range;
    }
};

/// How long `deinit` waits for a server to leave on `exit` before the
/// pipes close under it.
pub const default_exit_grace_ms: u32 = 250;

/// The live budget. A `var` only so a test that asserts what the server
/// wrote on its way out can hand itself a budget a loaded box can meet;
/// the app never assigns it, and quitting still costs at most 250 ms
/// per server that will not leave.
pub var exit_grace_ms: u32 = default_exit_grace_ms;

/// A builtin server: what mnml starts for an extension unless
/// `.lsp.<name>` says otherwise.
pub const Builtin = struct {
    name: []const u8,
    cmd: []const u8,
    args: []const []const u8,
    extensions: []const []const u8,
    root_markers: []const []const u8,
    /// The markers rank: the walk looks for the first one all the way
    /// up before it looks for the second. Off, the nearest directory
    /// holding any marker wins.
    root_markers_ranked: bool = false,
};

pub const builtins = [_]Builtin{
    .{ .name = "rust", .cmd = "rust-analyzer", .args = &.{}, .extensions = &.{"rs"}, .root_markers = &.{"Cargo.toml"} },
    .{ .name = "python", .cmd = "pyright-langserver", .args = &.{"--stdio"}, .extensions = &.{"py"}, .root_markers = &.{ "pyproject.toml", "setup.py", "requirements.txt" } },
    .{ .name = "typescript", .cmd = "typescript-language-server", .args = &.{"--stdio"}, .extensions = &.{ "ts", "tsx", "js", "jsx" }, .root_markers = &.{ "tsconfig.json", "jsconfig.json", "package.json" } },
    .{ .name = "go", .cmd = "gopls", .args = &.{}, .extensions = &.{"go"}, .root_markers = &.{"go.mod"} },
    .{ .name = "c", .cmd = "clangd", .args = &.{}, .extensions = &.{ "c", "h", "cpp", "hpp", "cc" }, .root_markers = &.{ "compile_commands.json", ".clangd" } },
    .{ .name = "zig", .cmd = "zls", .args = &.{}, .extensions = &.{"zig"}, .root_markers = &.{"build.zig"} },
    // // changed (lua-track): `init.lua` gets a server; Rust's list has
    // no lua row.
    .{ .name = "lua", .cmd = "lua-language-server", .args = &.{}, .extensions = &.{"lua"}, .root_markers = &.{ ".luarc.json", ".git" } },
    // // changed (lsp-defaults): the four the lua-track left out — a
    // default server that is not installed no longer toasts (see
    // `app/lsp.zig`'s missing-default path and
    // `.editor.lsp_missing_defaults`), so `package.json` in every
    // workspace is no longer a warning in every session. The binaries
    // are the npm registry's `bin` names for `vscode-langservers-
    // extracted` and `yaml-language-server`; both families speak LSP
    // over stdio only with `--stdio`.
    .{ .name = "json", .cmd = "vscode-json-language-server", .args = &.{"--stdio"}, .extensions = &.{ "json", "jsonc" }, .root_markers = &.{ "package.json", ".git" } },
    .{ .name = "yaml", .cmd = "yaml-language-server", .args = &.{"--stdio"}, .extensions = &.{ "yml", "yaml" }, .root_markers = &.{".git"} },
    .{ .name = "html", .cmd = "vscode-html-language-server", .args = &.{"--stdio"}, .extensions = &.{ "html", "htm" }, .root_markers = &.{ "package.json", ".git" } },
    .{ .name = "css", .cmd = "vscode-css-language-server", .args = &.{"--stdio"}, .extensions = &.{ "css", "scss", "less" }, .root_markers = &.{ "package.json", ".git" } },
    // C#: `csharp-ls` (a dotnet tool; stdio is its only transport, no
    // flag) where Rust's table runs OmniSharp `-lsp`. A solution first
    // (`.sln`, then the XML `.slnx`), then a project, then an SDK-style
    // `global.json`; `*` is a glob (`markerMatches`). Ranked: a file in
    // `tests/Acme.Tests/` roots at the `Acme.sln` above its `.csproj`,
    // so every project of the solution shares one Roslyn host and
    // definition, references and rename cross projects — as Neovim's
    // `root_pattern('*.sln')(f) or root_pattern('*.csproj')(f)`.
    .{ .name = "csharp", .cmd = "csharp-ls", .args = &.{}, .extensions = &.{ "cs", "csx" }, .root_markers = &.{ "*.sln", "*.slnx", "*.csproj", "global.json" }, .root_markers_ranked = true },
    // Shell: bash-language-server (`start` is its stdio mode) for
    // `.sh` / `.bash` — and `.zsh`, which it opens like any other
    // document and which no other row would ever send it. The
    // `shellscript` languageId is `languageIdFor`'s for all three. A
    // `bin/run-all` under `#!/usr/bin/env bash` and a `.zshrc` reach
    // this row by the language the detector names for them
    // (`app/lsp.zig`'s `specFor`). Rust's table has no shell row.
    .{ .name = "bash", .cmd = "bash-language-server", .args = &.{"start"}, .extensions = &.{ "sh", "bash", "zsh" }, .root_markers = &.{".git"} },
};

/// Does the entry `name` satisfy `marker`? A literal marker is the name
/// itself; a leading `*` matches any name ending with the rest
/// (`*.sln` → `Acme.sln`), as Rust's `marker_matches` does. The root
/// walk (`app/lsp.zig`'s `findRoot`) stats a literal and scans the
/// directory for a glob.
pub fn markerMatches(name: []const u8, marker: []const u8) bool {
    if (isGlobMarker(marker)) return std.mem.endsWith(u8, name, marker[1..]) and name.len > marker.len - 1;
    return std.mem.eql(u8, name, marker);
}

pub fn isGlobMarker(marker: []const u8) bool {
    return marker.len > 1 and marker[0] == '*';
}

/// The install hint for a well-known server, by the command's basename.
pub fn installHint(cmd: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(cmd);
    const Hint = struct { []const u8, []const u8 };
    const hints = [_]Hint{
        .{ "rust-analyzer", "rustup component add rust-analyzer" },
        .{ "typescript-language-server", "npm i -g typescript typescript-language-server" },
        .{ "pyright-langserver", "npm i -g pyright" },
        .{ "pyright", "npm i -g pyright" },
        .{ "pylsp", "pip install python-lsp-server" },
        .{ "gopls", "go install golang.org/x/tools/gopls@latest" },
        .{ "clangd", "brew install llvm  /  apt install clangd" },
        .{ "zls", "brew install zls" },
        .{ "lua-language-server", "brew install lua-language-server" },
        .{ "bash-language-server", "npm i -g bash-language-server" },
        .{ "yaml-language-server", "npm i -g yaml-language-server" },
        .{ "vscode-json-language-server", "npm i -g vscode-langservers-extracted" },
        .{ "vscode-html-language-server", "npm i -g vscode-langservers-extracted" },
        .{ "vscode-css-language-server", "npm i -g vscode-langservers-extracted" },
        .{ "marksman", "brew install marksman" },
        .{ "csharp-ls", "dotnet tool install -g csharp-ls" },
    };
    for (hints) |h| if (std.mem.eql(u8, h[0], base)) return h[1];
    return null;
}

/// The LSP `languageId` for a file: by extension, else by what
/// `highlight.detect` makes of the name and the first line of `text`
/// (`bin/run-all` under `#!/usr/bin/env bash` is `shellscript`, a
/// `.zshrc` too), else `plaintext`.
pub fn languageIdFor(path: []const u8, text: []const u8) []const u8 {
    const ext_full = std.fs.path.extension(path);
    var lower: [16]u8 = undefined;
    if (ext_full.len >= 2 and ext_full.len - 1 <= lower.len) {
        const ext = std.ascii.lowerString(&lower, ext_full[1..]);
        if (languageIdForKey(ext)) |id| return id;
    }
    if (highlight.detect.keyFor(path, text)) |key| return languageIdForKey(key) orelse key;
    if (ext_full.len >= 2) return ext_full[1..];
    return "plaintext";
}

/// The `languageId` for an extension or a table key, or null when the
/// table has no row for it.
fn languageIdForKey(ext: []const u8) ?[]const u8 {
    const KV = struct { []const u8, []const u8 };
    const table = [_]KV{
        .{ "rs", "rust" },               .{ "py", "python" },           .{ "ts", "typescript" }, .{ "tsx", "typescriptreact" }, .{ "js", "javascript" },   .{ "mjs", "javascript" },
        .{ "cjs", "javascript" },        .{ "jsx", "javascriptreact" }, .{ "go", "go" },         .{ "c", "c" },                 .{ "h", "c" },             .{ "cpp", "cpp" },
        .{ "cc", "cpp" },                .{ "hpp", "cpp" },             .{ "cxx", "cpp" },       .{ "zig", "zig" },             .{ "json", "json" },       .{ "md", "markdown" },
        .{ "html", "html" },             .{ "css", "css" },             .{ "scss", "scss" },     .{ "yaml", "yaml" },           .{ "yml", "yaml" },        .{ "toml", "toml" },
        .{ "sh", "shellscript" },        .{ "bash", "shellscript" },    .{ "lua", "lua" },       .{ "rb", "ruby" },             .{ "java", "java" },       .{ "kt", "kotlin" },
        .{ "swift", "swift" },           .{ "cs", "csharp" },           .{ "php", "php" },       .{ "vue", "vue" },             .{ "svelte", "svelte" },   .{ "sql", "sql" },
        .{ "jsonc", "jsonc" },           .{ "htm", "html" },            .{ "less", "less" },     .{ "csx", "csharp" },          .{ "zsh", "shellscript" }, .{ "make", "makefile" },
        .{ "dockerfile", "dockerfile" }, .{ "ex", "elixir" },           .{ "hcl", "terraform" }, .{ "proto", "proto" },
    };
    for (table) |kv| if (std.mem.eql(u8, kv[0], ext)) return kv[1];
    return null;
}

/// One content change of an incremental `didChange`.
pub const Change = struct { range: ?types.Range, text: []const u8 };

const OpenDoc = struct { version: i64 };
const QueuedOpen = struct { path: []u8, language_id: []u8, text: []u8 };

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    events: *event.EventQueue,
    id: u32,
    transport: *Transport,
    /// The config name (`rust`, `typescript`). Owned.
    name: []u8,
    /// The command, for toasts. Owned.
    cmd: []u8,
    /// The project root the server was started in. Owned.
    root: []u8,
    /// `initialize` replied and `initialized` went out.
    ready: bool = false,
    /// `$/progress` begins without their end — the server is loading
    /// or indexing, and answers it gives meanwhile are partial.
    progress_open: u32 = 0,
    encoding: Encoding = .utf16,
    caps: Caps = .{},
    /// Open documents by absolute path (owned keys).
    docs: std.StringHashMapUnmanaged(OpenDoc) = .empty,
    queued: std.ArrayListUnmanaged(QueuedOpen) = .empty,
    /// JSON for `initializationOptions` / `workspace/didChangeConfiguration`; owned, may be empty.
    init_options: []u8,
    settings: []u8,

    pub const SpawnError = Transport.SpawnError || Io.ConcurrentError;

    pub const Options = struct {
        name: []const u8,
        argv: []const []const u8,
        root: []const u8,
        env: ?*const std.process.Environ.Map = null,
        /// JSON objects, `{}` when the config has none.
        init_options: []const u8 = "{}",
        settings: []const u8 = "{}",
    };

    pub fn spawn(gpa: Allocator, io: Io, events: *event.EventQueue, id: u32, o: Options) SpawnError!*Server {
        const t = try Transport.spawn(gpa, io, o.argv, o.root, o.env);
        errdefer t.shutdown();
        return initWith(gpa, io, events, id, t, o);
    }

    /// Over two open files (tests: a fake server in process).
    pub fn initFiles(gpa: Allocator, io: Io, events: *event.EventQueue, id: u32, stdin: Io.File, stdout: Io.File, o: Options) SpawnError!*Server {
        const t = try Transport.initFiles(gpa, io, stdin, stdout);
        errdefer t.shutdown();
        return initWith(gpa, io, events, id, t, o);
    }

    fn initWith(gpa: Allocator, io: Io, events: *event.EventQueue, id: u32, t: *Transport, o: Options) SpawnError!*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        const name = try gpa.dupe(u8, o.name);
        errdefer gpa.free(name);
        const cmd = try gpa.dupe(u8, if (o.argv.len > 0) o.argv[0] else o.name);
        errdefer gpa.free(cmd);
        const root = try gpa.dupe(u8, o.root);
        errdefer gpa.free(root);
        const init_options = try gpa.dupe(u8, o.init_options);
        errdefer gpa.free(init_options);
        const settings = try gpa.dupe(u8, o.settings);
        errdefer gpa.free(settings);
        s.* = .{ .gpa = gpa, .io = io, .events = events, .id = id, .transport = t, .name = name, .cmd = cmd, .root = root, .init_options = init_options, .settings = settings };
        try t.start(.{ .ctx = s, .message = onMessage, .closed = onClosed, .oversize = onOversize });
        return s;
    }

    /// `shutdown` + `exit` (best effort), a moment for the server to
    /// act on them, then the transport goes — Rust sends the same pair
    /// and kills at once; the grace lets a well-behaved server (and the
    /// fake one's `--log`) see its `exit` before the pipes close.
    pub fn deinit(self: *Server) void {
        const gpa = self.gpa;
        if (!self.transport.isDead()) {
            _ = self.request(.shutdown, "shutdown", null, .{}) catch 0;
            self.notify("exit", null) catch {};
            var waited: u32 = 0;
            while (!self.transport.isDead() and waited < exit_grace_ms) : (waited += 5) {
                self.io.sleep(.fromMilliseconds(5), .awake) catch break;
            }
        }
        self.transport.shutdown();
        var it = self.docs.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.docs.deinit(gpa);
        for (self.queued.items) |q| freeQueued(gpa, q);
        self.queued.deinit(gpa);
        self.caps.deinit(gpa);
        gpa.free(self.init_options);
        gpa.free(self.settings);
        gpa.free(self.root);
        gpa.free(self.cmd);
        gpa.free(self.name);
        gpa.destroy(self);
    }

    fn freeQueued(gpa: Allocator, q: QueuedOpen) void {
        gpa.free(q.path);
        gpa.free(q.language_id);
        gpa.free(q.text);
    }

    // ─── the sink (reader task) ───

    fn onMessage(ctx: *anyopaque, msg: *jsonrpc.Incoming) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        const ev = self.gpa.create(event.LspEvent) catch {
            msg.destroy(self.gpa);
            return;
        };
        ev.* = .{ .message = msg };
        self.events.post(self.io, .{ .lsp = .{ .server = self.id, .msg = ev } });
    }

    /// A frame the transport refused to parse. Said out loud, with the
    /// method or the request id it names itself by; the pending entry
    /// for a dropped reply is cleared on the app thread, so whatever
    /// asked for it stops waiting.
    fn onOversize(ctx: *anyopaque, len: usize, head: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        const ev = self.gpa.create(event.LspEvent) catch return;
        var o: event.LspEvent.Oversize = .{ .len = len, .id = jsonrpc.peekId(head) };
        if (jsonrpc.peekMethod(head)) |m| {
            const n = @min(m.len, o.method_buf.len);
            @memcpy(o.method_buf[0..n], m[0..n]);
            o.method_len = @intCast(n);
        }
        ev.* = .{ .oversize = o };
        self.events.post(self.io, .{ .lsp = .{ .server = self.id, .msg = ev } });
    }

    fn onClosed(ctx: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        const ev = self.gpa.create(event.LspEvent) catch return;
        ev.* = .closed;
        self.events.post(self.io, .{ .lsp = .{ .server = self.id, .msg = ev } });
    }

    // ─── the envelope ───

    /// A request; `params` is any Stringify-able value or null.
    pub fn request(self: *Server, kind: ReqKind, method: []const u8, params: anytype, ctx: Ctx) SendError!i64 {
        const id = self.transport.allocId();
        const body = try jsonrpc.stringify(self.gpa, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        defer self.gpa.free(body);
        try self.transport.expect(id, .{ .kind = @intFromEnum(kind), .ctx = ctx.pack() });
        self.transport.send(body) catch |err| {
            _ = self.transport.forget(id);
            return err;
        };
        return id;
    }

    pub fn notify(self: *Server, method: []const u8, params: anytype) SendError!void {
        const body = try jsonrpc.stringify(self.gpa, .{ .jsonrpc = "2.0", .method = method, .params = params });
        defer self.gpa.free(body);
        try self.transport.send(body);
    }

    /// Answer a server→client request with `result` (JSON text; `null`).
    pub fn respond(self: *Server, id: jsonrpc.Id, result_json: []const u8) SendError!void {
        // The id goes back as the server sent it — zls's are strings.
        const id_json = try id.json(self.gpa);
        defer self.gpa.free(id_json);
        const body = try std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json });
        defer self.gpa.free(body);
        try self.transport.send(body);
    }

    /// `$/cancelRequest` and forget the reply.
    pub fn cancel(self: *Server, id: i64) void {
        _ = self.transport.forget(id);
        self.notify("$/cancelRequest", .{ .id = id }) catch {};
    }

    // ─── the handshake ───

    pub fn initialize(self: *Server) SendError!void {
        const arena_state = std.heap.ArenaAllocator.init(self.gpa);
        var arena = arena_state;
        defer arena.deinit();
        const a = arena.allocator();
        const root_uri = try types.uriFromPath(a, self.root);
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        const id = self.transport.allocId();
        initializeInto(&js, id, root_uri, std.fs.path.basename(self.root), self.init_options) catch return error.OutOfMemory;
        try self.transport.expect(id, .{ .kind = @intFromEnum(ReqKind.initialize) });
        self.transport.send(aw.written()) catch |err| {
            _ = self.transport.forget(id);
            return err;
        };
    }

    fn initializeInto(js: *std.json.Stringify, id: i64, root_uri: []const u8, root_name: []const u8, init_options: []const u8) std.json.Stringify.Error!void {
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("method");
        try js.write("initialize");
        try js.objectField("params");
        try js.beginObject();
        try js.objectField("processId");
        try js.write(null);
        try js.objectField("clientInfo");
        try js.write(.{ .name = "mnml", .version = "0.3.0-zig" });
        try js.objectField("rootUri");
        try js.write(root_uri);
        try js.objectField("workspaceFolders");
        try js.write(&[_]struct { uri: []const u8, name: []const u8 }{.{ .uri = root_uri, .name = root_name }});
        // Every capability is an object with at least one field: an
        // empty `.{}` is a tuple to `std.json` and goes out as `[]`,
        // which rust-analyzer's serde refuses (`expected struct
        // DynamicRegistrationClientCapabilities`) — the server then
        // exits before `initialize` answers.
        try js.objectField("capabilities");
        try js.write(.{
            .general = .{ .positionEncodings = &[_][]const u8{ "utf-8", "utf-16" } },
            .workspace = .{ .applyEdit = true, .workspaceEdit = .{ .documentChanges = true }, .configuration = true, .workspaceFolders = true, .didChangeConfiguration = .{ .dynamicRegistration = false } },
            .window = .{ .workDoneProgress = true },
            .textDocument = .{
                .synchronization = .{ .didSave = true, .willSave = false, .willSaveWaitUntil = true },
                .publishDiagnostics = .{ .relatedInformation = false, .versionSupport = false },
                .completion = .{ .completionItem = .{ .snippetSupport = true, .documentationFormat = &[_][]const u8{ "plaintext", "markdown" }, .resolveSupport = .{ .properties = &[_][]const u8{ "documentation", "detail", "additionalTextEdits" } } }, .contextSupport = true },
                .hover = .{ .contentFormat = &[_][]const u8{ "plaintext", "markdown" } },
                .signatureHelp = .{ .signatureInformation = .{ .documentationFormat = &[_][]const u8{"plaintext"} } },
                .definition = .{ .linkSupport = true },
                .declaration = .{ .linkSupport = true },
                .typeDefinition = .{ .linkSupport = true },
                .implementation = .{ .linkSupport = true },
                .references = .{ .dynamicRegistration = false },
                .documentSymbol = .{ .hierarchicalDocumentSymbolSupport = true },
                .codeAction = .{ .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = &[_][]const u8{ "quickfix", "refactor", "source", "source.organizeImports" } } }, .resolveSupport = .{ .properties = &[_][]const u8{"edit"} } },
                .rename = .{ .prepareSupport = false },
                .formatting = .{ .dynamicRegistration = false },
                .rangeFormatting = .{ .dynamicRegistration = false },
                .onTypeFormatting = .{ .dynamicRegistration = false },
                .documentHighlight = .{ .dynamicRegistration = false },
                .selectionRange = .{ .dynamicRegistration = false },
                .foldingRange = .{ .dynamicRegistration = false },
                .callHierarchy = .{ .dynamicRegistration = false },
                .typeHierarchy = .{ .dynamicRegistration = false },
                .inlayHint = .{ .dynamicRegistration = false },
                .codeLens = .{ .dynamicRegistration = false },
                .colorProvider = .{ .dynamicRegistration = false },
                .documentLink = .{ .tooltipSupport = false },
                .semanticTokens = .{
                    .requests = .{ .full = .{ .delta = true }, .range = true },
                    .tokenTypes = &semantic.token_type_names,
                    .tokenModifiers = &semantic.modifier_names,
                    .formats = &[_][]const u8{"relative"},
                    .multilineTokenSupport = false,
                    .overlappingTokenSupport = false,
                },
            },
        });
        try js.objectField("initializationOptions");
        try js.beginWriteRaw();
        try js.writer.writeAll(if (init_options.len == 0) "{}" else init_options);
        js.endWriteRaw();
        try js.endObject();
        try js.endObject();
    }

    /// `initialize`'s reply: read the capabilities, say `initialized`,
    /// push the settings, flush the queued opens.
    pub fn onInitialized(self: *Server, result: ?Value) Allocator.Error!void {
        if (result) |r| if (jsonrpc.getObj(r, "capabilities")) |c| try self.readCaps(c);
        self.ready = true;
        // An empty object: a tuple would go out positional (`[]`), which
        // tsserver logs as a malformed notification.
        self.notify("initialized", struct {}{}) catch {};
        if (!std.mem.eql(u8, std.mem.trim(u8, self.settings, " \t\n"), "{}")) {
            const body = std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{{\"settings\":{s}}}}}", .{self.settings}) catch return error.OutOfMemory;
            defer self.gpa.free(body);
            self.transport.send(body) catch {};
        }
        for (self.queued.items) |q| {
            self.didOpen(q.path, q.language_id, q.text) catch {};
            freeQueued(self.gpa, q);
        }
        self.queued.clearRetainingCapacity();
    }

    fn readCaps(self: *Server, c: Value) Allocator.Error!void {
        var caps: Caps = .{};
        caps.hover = provided(c, "hoverProvider");
        caps.signature_help = provided(c, "signatureHelpProvider");
        caps.definition = provided(c, "definitionProvider");
        caps.declaration = provided(c, "declarationProvider");
        caps.type_definition = provided(c, "typeDefinitionProvider");
        caps.implementation = provided(c, "implementationProvider");
        caps.references = provided(c, "referencesProvider");
        caps.rename = provided(c, "renameProvider");
        caps.formatting = provided(c, "documentFormattingProvider");
        caps.code_action = provided(c, "codeActionProvider");
        caps.document_symbol = provided(c, "documentSymbolProvider");
        caps.workspace_symbol = provided(c, "workspaceSymbolProvider");
        caps.call_hierarchy = provided(c, "callHierarchyProvider");
        caps.type_hierarchy = provided(c, "typeHierarchyProvider");
        caps.document_highlight = provided(c, "documentHighlightProvider");
        caps.selection_range = provided(c, "selectionRangeProvider");
        caps.folding_range = provided(c, "foldingRangeProvider");
        caps.inlay_hint = provided(c, "inlayHintProvider");
        caps.document_color = provided(c, "colorProvider");
        caps.document_link = provided(c, "documentLinkProvider");
        caps.range_formatting = provided(c, "documentRangeFormattingProvider");
        errdefer caps.deinit(self.gpa);
        if (jsonrpc.getObj(c, "codeLensProvider")) |lp| {
            caps.code_lens = true;
            caps.code_lens_resolve = jsonrpc.getBool(lp, "resolveProvider") orelse false;
        }
        if (jsonrpc.getObj(c, "executeCommandProvider")) |ep| if (jsonrpc.getArr(ep, "commands")) |arr| {
            var names: std.ArrayListUnmanaged([]u8) = .empty;
            errdefer {
                for (names.items) |n| self.gpa.free(n);
                names.deinit(self.gpa);
            }
            for (arr) |t| if (jsonrpc.asStr(t)) |n| {
                const owned = try self.gpa.dupe(u8, n);
                errdefer self.gpa.free(owned);
                try names.append(self.gpa, owned);
            };
            caps.execute_commands = try names.toOwnedSlice(self.gpa);
        };
        if (jsonrpc.getObj(c, "documentOnTypeFormattingProvider")) |ot| {
            var chars: std.ArrayListUnmanaged(u8) = .empty;
            errdefer chars.deinit(self.gpa);
            if (jsonrpc.getStr(ot, "firstTriggerCharacter")) |s| if (s.len == 1) try chars.append(self.gpa, s[0]);
            if (jsonrpc.getArr(ot, "moreTriggerCharacter")) |arr| for (arr) |t| {
                const s = jsonrpc.asStr(t) orelse continue;
                if (s.len == 1) try chars.append(self.gpa, s[0]);
            };
            caps.on_type_triggers = try chars.toOwnedSlice(self.gpa);
        }
        if (jsonrpc.getObj(c, "semanticTokensProvider")) |sp| {
            if (jsonrpc.getField(sp, "full")) |full| switch (full) {
                .bool => |b| caps.semantic_full = b,
                .object => {
                    caps.semantic_full = true;
                    caps.semantic_delta = jsonrpc.getBool(full, "delta") orelse false;
                },
                else => {},
            };
            if (jsonrpc.getField(sp, "range")) |range| caps.semantic_range = switch (range) {
                .bool => |b| b,
                .object => true,
                else => false,
            };
            if (jsonrpc.getObj(sp, "legend")) |legend| {
                caps.token_types = try semantic.readTypes(self.gpa, jsonrpc.getArr(legend, "tokenTypes") orelse &.{});
                caps.token_modifiers = try semantic.readModifiers(self.gpa, jsonrpc.getArr(legend, "tokenModifiers") orelse &.{});
            }
        }
        if (jsonrpc.getObj(c, "completionProvider")) |cp| {
            caps.completion = true;
            var chars: std.ArrayListUnmanaged(u8) = .empty;
            errdefer chars.deinit(self.gpa);
            if (jsonrpc.getArr(cp, "triggerCharacters")) |arr| for (arr) |t| {
                const s = jsonrpc.asStr(t) orelse continue;
                if (s.len == 1) try chars.append(self.gpa, s[0]);
            };
            caps.trigger_chars = try chars.toOwnedSlice(self.gpa);
            caps.completion_resolve = jsonrpc.getBool(cp, "resolveProvider") orelse false;
        }
        if (jsonrpc.getField(c, "textDocumentSync")) |sync| switch (sync) {
            .integer => |i| caps.incremental = i == 2,
            .object => {
                caps.incremental = (jsonrpc.getInt(sync, "change") orelse 0) == 2;
                caps.will_save_wait_until = jsonrpc.getBool(sync, "willSaveWaitUntil") orelse false;
            },
            else => {},
        };
        if (jsonrpc.getStr(c, "positionEncoding")) |enc| self.encoding = if (std.mem.eql(u8, enc, "utf-8")) .utf8 else .utf16;
        self.caps.deinit(self.gpa);
        self.caps = caps;
    }

    fn provided(c: Value, key: []const u8) bool {
        const v = jsonrpc.getField(c, key) orelse return false;
        return switch (v) {
            .bool => |b| b,
            .object => true,
            else => false,
        };
    }

    // ─── documents ───

    pub fn isOpen(self: *const Server, path: []const u8) bool {
        return self.docs.contains(path);
    }

    /// Before `ready` the open is queued (owned copies); after, it goes.
    pub fn didOpen(self: *Server, path: []const u8, language_id: []const u8, text: []const u8) SendError!void {
        if (!self.ready) {
            const q: QueuedOpen = .{ .path = try self.gpa.dupe(u8, path), .language_id = undefined, .text = undefined };
            errdefer self.gpa.free(q.path);
            var qq = q;
            qq.language_id = try self.gpa.dupe(u8, language_id);
            errdefer self.gpa.free(qq.language_id);
            qq.text = try self.gpa.dupe(u8, text);
            errdefer self.gpa.free(qq.text);
            try self.queued.append(self.gpa, qq);
            return;
        }
        if (self.docs.contains(path)) return;
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.docs.put(self.gpa, key, .{ .version = 1 });
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const uri = try types.uriFromPath(arena.allocator(), path);
        try self.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = language_id, .version = 1, .text = text } });
    }

    /// One or more changes; a `null` range means "the whole text".
    pub fn didChange(self: *Server, path: []const u8, changes: []const Change) SendError!void {
        const doc = self.docs.getPtr(path) orelse return;
        doc.version += 1;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const uri = try types.uriFromPath(a, path);
        const Wire = struct { range: ?types.Range = null, text: []const u8 };
        const list = try a.alloc(Wire, changes.len);
        for (changes, 0..) |ch, i| list[i] = .{ .range = ch.range, .text = ch.text };
        try self.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = doc.version }, .contentChanges = list });
    }

    pub fn didSave(self: *Server, path: []const u8, text: []const u8) SendError!void {
        if (!self.docs.contains(path)) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const uri = try types.uriFromPath(arena.allocator(), path);
        try self.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri }, .text = text });
    }

    pub fn didClose(self: *Server, path: []const u8) SendError!void {
        const kv = self.docs.fetchRemove(path) orelse return;
        self.gpa.free(kv.key);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const uri = try types.uriFromPath(arena.allocator(), path);
        try self.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    }

    /// `{textDocument, position}` for a path + byte offset in `text`.
    pub const DocPos = struct { textDocument: struct { uri: []const u8 }, position: types.Position };

    pub fn docPos(self: *const Server, arena: Allocator, path: []const u8, text: []const u8, byte: usize) Allocator.Error!DocPos {
        return .{ .textDocument = .{ .uri = try types.uriFromPath(arena, path) }, .position = types.positionOf(text, byte, self.encoding) };
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn pipeFiles() ![2]Io.File {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try Io.Threaded.pipe2(.{});
    return .{ .{ .handle = fds[0], .flags = .{ .nonblocking = false } }, .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
}

test "languageIdFor and the builtin table" {
    try testing.expectEqualStrings("typescriptreact", languageIdFor("/a/b.tsx", ""));
    try testing.expectEqualStrings("python", languageIdFor("x.PY", ""));
    try testing.expectEqualStrings("plaintext", languageIdFor("README", "# readme\n"));
    // The detector's word for what the extension does not say: an
    // extension-less script by its shebang, a dotfile by its name.
    try testing.expectEqualStrings("shellscript", languageIdFor("/x/bin/run-all", "#!/usr/bin/env bash\nset -e\n"));
    try testing.expectEqualStrings("shellscript", languageIdFor("/home/me/.zshrc", "export X=1\n"));
    try testing.expectEqualStrings("shellscript", languageIdFor("/x/report.zsh", ""));
    try testing.expectEqualStrings("makefile", languageIdFor("/x/Makefile", ""));
    try testing.expectEqualStrings("python", languageIdFor("/x/tool", "#!/usr/bin/env python3\n"));
    try testing.expectEqualStrings("npm i -g pyright", installHint("/usr/local/bin/pyright-langserver").?);
    try testing.expect(installHint("mystery-ls") == null);
    // // changed (lsp-defaults): the five rows, each with a hint, so a
    // missing one can offer its install.
    for ([_][]const u8{ "json", "yaml", "html", "css", "csharp", "bash" }) |name| {
        var found = false;
        for (builtins) |b| if (std.mem.eql(u8, b.name, name)) {
            found = true;
            try testing.expect(installHint(b.cmd) != null);
        };
        try testing.expect(found);
    }
    try testing.expectEqualStrings("dotnet tool install -g csharp-ls", installHint("csharp-ls").?);
    try testing.expectEqualStrings("npm i -g vscode-langservers-extracted", installHint("vscode-json-language-server").?);
}

test "markerMatches: a literal is the name, a leading `*` a suffix" {
    try testing.expect(markerMatches("Cargo.toml", "Cargo.toml"));
    try testing.expect(!markerMatches("Cargo.toml.bak", "Cargo.toml"));
    try testing.expect(markerMatches("Acme.sln", "*.sln"));
    try testing.expect(markerMatches("Acme.Web.csproj", "*.csproj"));
    try testing.expect(!markerMatches(".sln", "*.sln"));
    try testing.expect(!markerMatches("Acme.slnx", "*.sln"));
    try testing.expect(isGlobMarker("*.sln"));
    try testing.expect(!isGlobMarker("*"));
    try testing.expect(!isGlobMarker("global.json"));
}

/// A fake server: replies to `initialize` with utf-8 + a trigger char +
/// incremental sync, then publishes one diagnostic for whatever gets
/// opened, and echoes a hover.
fn fakeServer(io: Io, gpa: Allocator, in: Io.File, out: Io.File, seen: *std.ArrayListUnmanaged(u8), lock: *Io.Mutex) Io.Cancelable!void {
    var buf: [8192]u8 = undefined;
    var fr = in.readerStreaming(io, &buf);
    while (true) {
        const body = jsonrpc.readBody(gpa, &fr.interface) catch return;
        defer gpa.free(body);
        var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        switch (jsonrpc.classify(parsed.value)) {
            .request => |rq| {
                if (std.mem.eql(u8, rq.method, "initialize")) {
                    const reply = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{\"positionEncoding\":\"utf-8\",\"textDocumentSync\":{{\"change\":2}},\"hoverProvider\":true,\"completionProvider\":{{\"triggerCharacters\":[\".\",\"::\"]}},\"definitionProvider\":{{}}}}}}}}", .{rq.id.int}) catch return;
                    defer gpa.free(reply);
                    jsonrpc.writeFrame(io, out, reply) catch return;
                } else if (std.mem.eql(u8, rq.method, "shutdown")) {
                    // The client may have closed its read end already
                    // (deinit does not wait for the reply): keep reading
                    // for the `exit` that follows.
                    const reply = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{rq.id.int}) catch return;
                    defer gpa.free(reply);
                    jsonrpc.writeFrame(io, out, reply) catch {};
                }
            },
            .notification => |n| {
                lock.lockUncancelable(io);
                seen.appendSlice(gpa, n.method) catch {};
                seen.append(gpa, ' ') catch {};
                lock.unlock(io);
                if (std.mem.eql(u8, n.method, "exit")) return;
                if (std.mem.eql(u8, n.method, "textDocument/didOpen")) {
                    const uri = jsonrpc.getStr(jsonrpc.getObj(n.params.?, "textDocument").?, "uri").?;
                    const note = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"{s}\",\"diagnostics\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":2}}}},\"severity\":1,\"message\":\"nope\"}}]}}}}", .{uri}) catch return;
                    defer gpa.free(note);
                    jsonrpc.writeFrame(io, out, note) catch return;
                }
            },
            else => {},
        }
    }
}

test "initialize's capabilities are all objects: an empty struct would serialize as `[]` and rust-analyzer exits on it" {
    const gpa = testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    try Server.initializeInto(&js, 1, "file:///ws/src", "src", "{}");
    const body = aw.written();
    try testing.expect(std.mem.indexOf(u8, body, ":[]") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"references\":{\"dynamicRegistration\":false}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"formatting\":{") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"rootUri\":\"file:///ws/src\"") != null);
}

test "initialize reads caps and encoding; an early didOpen is queued and flushed; the server's notification arrives as an event" {
    const gpa = testing.allocator;
    const io = testing.io;
    var events = try event.EventQueue.init(gpa, 16);
    defer events.deinit(io);
    const c2s = try pipeFiles();
    const s2c = try pipeFiles();
    var seen: std.ArrayListUnmanaged(u8) = .empty;
    defer seen.deinit(gpa);
    var lock: Io.Mutex = .init;
    var group: Io.Group = .init;
    try group.concurrent(io, fakeServer, .{ io, gpa, c2s[0], s2c[1], &seen, &lock });
    const s = try Server.initFiles(gpa, io, &events, 7, c2s[1], s2c[0], .{ .name = "fake", .argv = &.{"fake-ls"}, .root = "/ws", .settings = "{\"a\":1}" });
    try s.initialize();
    // Opened before the reply: queued.
    try s.didOpen("/ws/a.rs", "rust", "fn x() {}");
    try testing.expectEqual(@as(usize, 1), s.queued.items.len);
    try testing.expect(!s.isOpen("/ws/a.rs"));
    // Drain: the initialize reply, then the diagnostics notification.
    var got_diag = false;
    var spins: usize = 0;
    while (!got_diag) : (spins += 1) {
        if (spins > 500) return error.Timeout;
        var buf: [8]event.AppEvent = undefined;
        const n = events.drain(io, &buf);
        for (buf[0..n]) |ev| {
            defer event.freeEvent(gpa, ev);
            const msg = ev.lsp.msg.message;
            switch (jsonrpc.classify(msg.root())) {
                .response => |r| {
                    const p = s.transport.take(r.id).?;
                    try testing.expectEqual(@intFromEnum(ReqKind.initialize), p.kind);
                    try s.onInitialized(r.result);
                },
                .notification => |nt| if (std.mem.eql(u8, nt.method, "textDocument/publishDiagnostics")) {
                    got_diag = true;
                    const path = (try types.pathFromUri(gpa, jsonrpc.getStr(nt.params.?, "uri").?)).?;
                    defer gpa.free(path);
                    try testing.expectEqualStrings("/ws/a.rs", path);
                },
                else => {},
            }
        }
        if (n == 0) try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(s.ready);
    try testing.expectEqual(Encoding.utf8, s.encoding);
    try testing.expect(s.caps.incremental and s.caps.hover and s.caps.completion and s.caps.definition and !s.caps.rename);
    try testing.expectEqualStrings(".", s.caps.trigger_chars);
    try testing.expect(s.isOpen("/ws/a.rs"));
    try testing.expectEqual(@as(usize, 0), s.queued.items.len);
    try s.didChange("/ws/a.rs", &.{.{ .range = .{ .start = .{ .line = 0, .character = 3 }, .end = .{ .line = 0, .character = 4 } }, .text = "y" }});
    try s.didSave("/ws/a.rs", "fn y() {}");
    try s.didClose("/ws/a.rs");
    try testing.expect(!s.isOpen("/ws/a.rs"));
    s.deinit();
    try group.await(io);
    lock.lockUncancelable(io);
    try testing.expectEqualStrings("initialized workspace/didChangeConfiguration textDocument/didOpen textDocument/didChange textDocument/didSave textDocument/didClose exit ", seen.items);
    lock.unlock(io);
    c2s[0].close(io);
    s2c[1].close(io);
}
