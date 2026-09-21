//! Inline ghost text — the part that needs no app: which backend the
//! config names, the context window sent around the cursor, the files
//! that never leave the machine, the debounce clock, and the word / line
//! boundaries a partial accept takes. `src/app/ai.zig` owns the worker
//! and the editor; this file is what its tests pin.
//!
//! Local FIM is not in 0.3.0 (DESIGN "Dependencies"): `local` resolves
//! to a migration note, never to a request.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `[ai] suggest_backend`. `unset` means the user has not chosen yet —
/// enabling the feature opens the setup picker instead of guessing.
pub const Backend = enum {
    unset,
    claude_code,
    claude_api,
    /// GitHub Copilot's own language server, over stdio
    /// (`ai/copilot.zig`, `app/copilot.zig`). Off until the workspace
    /// opts in — picking it here shares nothing by itself.
    copilot,
    local,

    pub fn parse(s: []const u8) Backend {
        const tok = std.mem.trim(u8, s, " \t\"");
        if (eqlAny(tok, &.{ "claude-code", "cc", "sub", "subscription" })) return .claude_code;
        if (eqlAny(tok, &.{ "claude-api", "claude", "api" })) return .claude_api;
        if (eqlAny(tok, &.{ "copilot", "github-copilot", "gh" })) return .copilot;
        if (eqlAny(tok, &.{ "local", "candle" })) return .local;
        return .unset;
    }

    /// The config token, stable across releases.
    pub fn token(b: Backend) []const u8 {
        return switch (b) {
            .unset => "unset",
            .claude_code => "claude-code",
            .claude_api => "claude-api",
            .copilot => "copilot",
            .local => "local",
        };
    }

    pub fn label(b: Backend) []const u8 {
        return switch (b) {
            .unset => "not set up",
            .claude_code => "Claude Code sub",
            .claude_api => "Claude API",
            .copilot => "GitHub Copilot",
            .local => "Local model",
        };
    }

    /// Whether the backend answers from a worker of our own (`app/ai.zig`)
    /// rather than from the Copilot client. The one place the two
    /// families are told apart.
    pub fn isClaude(b: Backend) bool {
        return b == .claude_code or b == .claude_api;
    }
};

fn eqlAny(s: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.ascii.eqlIgnoreCase(s, l)) return true;
    return false;
}

/// Idle time after the last edit before a request goes out — Cursor's
/// feel. `[ai] suggest_idle_ms` overrides it per machine.
pub const debounce_ms: i64 = 300;
/// The wall-clock budget one request gets (`[ai] suggest_timeout_ms`).
/// Past it the child is killed and the outcome reads `timeout`: an
/// answer that arrives after four seconds is for a cursor that has
/// moved on, and silence longer than that reads as broken.
pub const default_timeout_ms: u64 = 4000;
/// Code points sent before / after the cursor. A 100 KB file per
/// keystroke-pause is waste; the model wants the neighbourhood.
pub const prefix_chars: usize = 2000;
pub const suffix_chars: usize = 1000;
/// The fast model, unless `[ai] suggest_model` says otherwise.
pub const default_model = "claude-haiku-4-5";
pub const max_tokens: u32 = 256;

pub const migration_note = "AI ghost-text: the local model is not in this release — pick Claude API or Claude Code in ai.setup_suggestions";
pub const setup_hint = "Tip: AI ghost-text suggestions are available but not set up · run ai.setup_suggestions or Settings → AI";
pub const hint_toast_id = "ghost-text-hint";

pub const Context = struct { prefix: []const u8, suffix: []const u8 };

/// The window around `cursor`, capped in code points and cut only on
/// UTF-8 boundaries. Borrows `text`.
pub fn context(text: []const u8, cursor_in: usize) Context {
    const cursor = @min(cursor_in, text.len);
    var start = cursor;
    var n: usize = 0;
    while (start > 0 and n < prefix_chars) {
        start -= 1;
        while (start > 0 and (text[start] & 0xC0) == 0x80) start -= 1;
        n += 1;
    }
    var end = cursor;
    n = 0;
    while (end < text.len and n < suffix_chars) {
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        n += 1;
    }
    return .{ .prefix = text[start..cursor], .suffix = text[cursor..@min(end, text.len)] };
}

/// Files whose names say "secret": never sent to a remote backend,
/// whatever the setting. The list is by name, not by content — a
/// heuristic that errs towards keeping things home.
pub fn isSecretBearing(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, ".env")) return true;
    const exact = [_][]const u8{ "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".netrc", ".npmrc", ".pypirc", ".pgpass", ".htpasswd" };
    for (exact) |e| if (std.mem.eql(u8, name, e)) return true;
    const subs = [_][]const u8{ "credential", "secret", "token", "password", "keychain" };
    for (subs) |s| if (containsIgnoreCase(name, s)) return true;
    const exts = [_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".kdbx", ".jks", ".keystore", ".gpg", ".asc" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// The language the prompt names: the file extension, or nothing.
pub fn languageOf(path: ?[]const u8) []const u8 {
    const p = path orelse return "";
    const ext = std.fs.path.extension(p);
    return if (ext.len > 1) ext[1..] else "";
}

/// Bytes a `ctrl+right` takes: leading whitespace plus one word. Never
/// zero on a non-empty suggestion.
pub fn wordBoundary(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i < s.len and s[i] == '\n') return i + 1;
    while (i < s.len and !std.ascii.isWhitespace(s[i])) i += 1;
    return @max(i, @min(s.len, 1));
}

/// Bytes a `ctrl+down` takes: through the first newline, or all of it.
pub fn lineBoundary(s: []const u8) usize {
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| return nl + 1;
    return s.len;
}

/// The idle clock: an edit arms it, `due` fires once, and every fire
/// is a generation so a result from before the next edit is dropped.
pub const Debounce = struct {
    dirty_ms: ?i64 = null,
    generation: u32 = 0,
    /// The generation whose request is out; null when none is.
    in_flight: ?u32 = null,
    /// `[ai] suggest_idle_ms`, refreshed from the config each fire.
    idle_ms: i64 = debounce_ms,
    /// `App.now_ms` when the in-flight request went out, for the
    /// elapsed the chip paints and the latency the log line records.
    fired_ms: i64 = 0,

    pub fn noteEdit(d: *Debounce, now: i64) void {
        d.dirty_ms = now;
        // Whatever was in flight answers a buffer that no longer exists.
        d.generation +%= 1;
        d.in_flight = null;
    }

    pub fn due(d: *const Debounce, now: i64) bool {
        const at = d.dirty_ms orelse return false;
        return d.in_flight == null and now - at >= d.idle_ms;
    }

    /// The moment `due` turns true, for the loop's deadline.
    pub fn deadline(d: *const Debounce) ?i64 {
        const at = d.dirty_ms orelse return null;
        if (d.in_flight != null) return null;
        return at + d.idle_ms;
    }

    /// Arm a request; the returned generation travels with it.
    pub fn fire(d: *Debounce, now: i64) u32 {
        d.dirty_ms = null;
        d.in_flight = d.generation;
        d.fired_ms = now;
        return d.generation;
    }

    /// A result arrived: true when it is the one still wanted.
    pub fn settle(d: *Debounce, generation: u32) bool {
        if (d.in_flight == generation) d.in_flight = null;
        return generation == d.generation;
    }

    pub fn cancel(d: *Debounce) void {
        d.dirty_ms = null;
        d.generation +%= 1;
        d.in_flight = null;
    }
};

pub const system_prompt =
    "You are an inline code-completion engine inside a text editor. " ++
    "You receive the code BEFORE the cursor and the code AFTER the cursor. " ++
    "Output ONLY the exact text that should be inserted at the cursor position " ++
    "to continue the code naturally. No explanation, no markdown fences, no " ++
    "repetition of the surrounding code. Prefer short completions — usually " ++
    "the rest of the current line or a few lines. If no useful completion is " ++
    "possible, output nothing.";

/// The user turn: language, the two windows, the ask.
pub fn userPrompt(arena: Allocator, language: []const u8, ctx: Context) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "Language: {s}\n\n<code-before-cursor>\n{s}\n</code-before-cursor>\n\n<code-after-cursor>\n{s}\n</code-after-cursor>\n\nOutput the text to insert at the cursor:", .{ language, ctx.prefix, ctx.suffix });
}

/// What the model said, cleaned: fences stripped, a trailing newline
/// kept only when the completion is multi-line, empty when it is noise.
pub fn cleanCompletion(arena: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var s = std.mem.trimEnd(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, s, "```")) {
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return arena.dupe(u8, "");
        s = s[nl + 1 ..];
        if (std.mem.lastIndexOf(u8, s, "```")) |close| s = std.mem.trimEnd(u8, s[0..close], " \t\r\n");
    }
    return arena.dupe(u8, s);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "backend tokens parse their synonyms and round-trip" {
    try t.expectEqual(Backend.claude_code, Backend.parse("claude-code"));
    try t.expectEqual(Backend.claude_code, Backend.parse(" SUB "));
    try t.expectEqual(Backend.claude_api, Backend.parse("api"));
    try t.expectEqual(Backend.local, Backend.parse("candle"));
    try t.expectEqual(Backend.copilot, Backend.parse("copilot"));
    try t.expectEqual(Backend.copilot, Backend.parse(" GitHub-Copilot "));
    try t.expectEqual(Backend.unset, Backend.parse("nope"));
    inline for (.{ Backend.claude_code, Backend.claude_api, Backend.copilot, Backend.local, Backend.unset }) |b| {
        try t.expectEqual(b, Backend.parse(b.token()));
    }
    try t.expect(Backend.claude_api.isClaude());
    try t.expect(!Backend.copilot.isClaude());
    try t.expectEqualStrings("GitHub Copilot", Backend.copilot.label());
}

test "context caps the window in code points on utf-8 boundaries" {
    const text = "héllo wörld";
    const c = context(text, 7); // after "héllo " (é is two bytes)
    try t.expectEqualStrings("héllo ", c.prefix);
    try t.expectEqualStrings("wörld", c.suffix);
    // A long prefix is cut at 2000 code points, never inside a glyph.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(t.allocator);
    for (0..2500) |_| try big.appendSlice(t.allocator, "é");
    const cc = context(big.items, big.items.len);
    try t.expectEqual(@as(usize, prefix_chars * 2), cc.prefix.len);
    try t.expect(std.unicode.utf8ValidateSlice(cc.prefix));
    try t.expectEqual(@as(usize, 0), cc.suffix.len);
    const past = context("ab", 9);
    try t.expectEqualStrings("ab", past.prefix);
}

test "secret-bearing names stay home; ordinary sources go" {
    try t.expect(isSecretBearing("/w/.env"));
    try t.expect(isSecretBearing("/w/.env.local"));
    try t.expect(isSecretBearing("/home/u/.ssh/id_rsa"));
    try t.expect(isSecretBearing("aws_credentials.json"));
    try t.expect(isSecretBearing("server.PEM"));
    try t.expect(isSecretBearing("MySecrets.toml"));
    try t.expect(!isSecretBearing("/w/src/main.zig"));
    try t.expect(!isSecretBearing("environment.md"));
    try t.expect(!isSecretBearing("keyboard.rs"));
}

test "word and line boundaries: leading whitespace plus one word; through the first newline" {
    try t.expectEqual(@as(usize, 5), wordBoundary("ALPHA BETA"));
    try t.expectEqual(@as(usize, 5), wordBoundary(" BETA"));
    try t.expectEqual(@as(usize, 1), wordBoundary("\nnext"));
    try t.expectEqual(@as(usize, 1), wordBoundary("x"));
    try t.expectEqual(@as(usize, 0), wordBoundary(""));
    try t.expectEqual(@as(usize, 6), lineBoundary("LINE1\nLINE2"));
    try t.expectEqual(@as(usize, 5), lineBoundary("LINE1"));
    try t.expectEqualStrings("zig", languageOf("/a/b/main.zig"));
    try t.expectEqualStrings("", languageOf("Makefile"));
    try t.expectEqualStrings("", languageOf(null));
}

test "debounce: an edit arms it, it fires once after 300 ms, a later edit invalidates the flight" {
    var d: Debounce = .{};
    try t.expect(!d.due(1000));
    d.noteEdit(1000);
    try t.expect(!d.due(1299));
    try t.expect(d.due(1300));
    try t.expectEqual(@as(?i64, 1300), d.deadline());
    const g = d.fire(1300);
    try t.expectEqual(@as(i64, 1300), d.fired_ms);
    try t.expect(!d.due(5000));
    try t.expect(d.deadline() == null);
    // Typing again: the result for `g` is stale when it lands.
    d.noteEdit(1400);
    try t.expect(!d.settle(g));
    try t.expect(d.due(1700));
    const g2 = d.fire(1700);
    try t.expect(d.settle(g2));
    try t.expect(d.in_flight == null);
    d.noteEdit(2000);
    d.cancel();
    try t.expect(!d.due(9000));
}

test "debounce: `[ai] suggest_idle_ms` moves the clock without touching the default" {
    try t.expectEqual(@as(i64, 300), debounce_ms);
    var d: Debounce = .{ .idle_ms = 900 };
    d.noteEdit(1000);
    try t.expect(!d.due(1300)); // the shipped default would have fired here
    try t.expect(d.due(1900));
    try t.expectEqual(@as(?i64, 1900), d.deadline());
}

test "prompt and cleaning" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try userPrompt(a, "rust", .{ .prefix = "fn x() {", .suffix = "}" });
    try t.expect(std.mem.indexOf(u8, p, "<code-before-cursor>\nfn x() {\n</code-before-cursor>") != null);
    try t.expectEqualStrings("return 1;", try cleanCompletion(a, "```rust\nreturn 1;\n```\n"));
    try t.expectEqualStrings("a\nb", try cleanCompletion(a, "a\nb\n"));
    try t.expectEqualStrings("", try cleanCompletion(a, "```"));
}
