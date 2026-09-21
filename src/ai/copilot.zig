//! GitHub Copilot as a ghost-text backend — the part that needs no
//! `App`: the privacy gate, the exclusion list, which binary to start,
//! the protocol's own constants, and the two conversions the wire needs
//! (an inline-completion item into the ghost surface's insert text, and
//! a partial accept into the UTF-16 length Copilot's telemetry wants).
//!
//! `src/copilot/client.zig` owns the wire; `src/app/copilot.zig` owns
//! the editor and the commands. This file is what their tests pin.
//!
//! The protocol here is verified, not remembered:
//! `docs/research/copilot-backend-2026-09-21.md` records what was read
//! (`@github/copilot-language-server` 1.548.0's README and its shipped
//! bundle) and which names it refused to code against for lack of proof.
//!
//! ── the privacy rule ────────────────────────────────────────────────
//!
//! Nothing a buffer holds reaches GitHub unless ALL of `Gate.decide`'s
//! conditions hold. It returns a typed `Reason` rather than a bool so
//! the chip, the toast and the tests all name the same one, and so
//! every caller — `didOpen`, `didChange`, `didFocus`, the completion
//! request — is forced through the same door. A file the gate refuses
//! is never opened on the server either: "opened but not completed"
//! still ships the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gitignore = @import("../app/gitignore.zig");
const suggest = @import("suggest.zig");

// ─── what mnml tells Copilot it is ──────────────────────────────────────

/// `initializationOptions.editorInfo` / `.editorPluginInfo`. Copilot
/// keys quota and telemetry off these, so they name mnml honestly.
pub const editor_name = "mnml";
pub const editor_version = "0.3.0-zig";
pub const plugin_name = "mnml-copilot";
pub const plugin_version = "0.1.0";

/// The command the item carries and we execute back after an accept.
/// Never hard-coded into a request: the item's own `command` is echoed
/// verbatim. Named here only so a test can recognise it.
pub const accept_command = "github.copilot.didAcceptCompletionItem";
/// What `signIn` hands back to run once the user has the code.
pub const finish_device_flow_command = "github.copilot.finishDeviceFlow";

/// The binary mnml looks for on `PATH` when `ai.copilot.command` is
/// unset. mnml NEVER downloads it: a missing binary is one toast with
/// `install_hint`, and the backend goes quiet for the session.
pub const default_binary = "copilot-language-server";
pub const default_args = [_][]const u8{"--stdio"};
pub const install_hint = "npm i -g @github/copilot-language-server";

/// What the toast says when the binary is not there. One line, with the
/// command that fixes it — never a crash and never silence.
pub fn missingMessage(arena: Allocator, cmd: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "Copilot: {s} not installed — `{s}`", .{ cmd, install_hint });
}

// ─── the server's status ────────────────────────────────────────────────

/// `didChangeStatus`'s `kind`. The four words are the server's own
/// (README "Status Notification", and the bundle's
/// `sendNotification("didChangeStatus",{busy,kind,message,command})`).
pub const StatusKind = enum {
    normal,
    err,
    warning,
    /// The current file is excluded by size or by a content-exclusion
    /// rule the ORGANISATION set — Copilot's own privacy layer, on top
    /// of ours.
    inactive,
    /// Nothing has been heard yet.
    unknown,

    pub fn parse(s: []const u8) StatusKind {
        if (std.mem.eql(u8, s, "Normal")) return .normal;
        if (std.mem.eql(u8, s, "Error")) return .err;
        if (std.mem.eql(u8, s, "Warning")) return .warning;
        if (std.mem.eql(u8, s, "Inactive")) return .inactive;
        return .unknown;
    }
};

/// `checkStatus`'s `status`. All three literals are in the 1.548.0
/// bundle; `AlreadySignedIn` is `signIn`'s word for the same thing.
pub const SignedIn = enum {
    yes,
    no,
    /// Signed in to GitHub but with no Copilot entitlement.
    not_authorized,
    unknown,

    pub fn parse(s: []const u8) SignedIn {
        if (std.mem.eql(u8, s, "OK") or std.mem.eql(u8, s, "AlreadySignedIn")) return .yes;
        if (std.mem.eql(u8, s, "NotSignedIn")) return .no;
        if (std.mem.eql(u8, s, "NotAuthorized")) return .not_authorized;
        return .unknown;
    }
};

/// What the ghost chip says after `copilot · `. Short enough for the
/// statusline; the hover copy carries the server's own message.
pub fn stateWord(signed_in: SignedIn, kind: StatusKind, opted_in: bool, running: bool) []const u8 {
    if (!opted_in) return "off here";
    return switch (signed_in) {
        .no => "signed out",
        .not_authorized => "no seat",
        .unknown => if (running) "starting" else "off",
        .yes => switch (kind) {
            .err => "error",
            .warning => "warning",
            .inactive => "file excluded",
            .normal, .unknown => "ready",
        },
    };
}

// ─── the privacy gate ───────────────────────────────────────────────────

/// Why a buffer may or may not be shared. Every refusal is a named one:
/// a bool would let a new caller forget which check it skipped.
pub const Reason = enum {
    /// Send it.
    allowed,
    /// `ai.suggest_backend` is not `copilot`.
    not_selected,
    /// This workspace has not opted in (`ai.copilot_here`).
    not_opted_in,
    /// The workspace is untrusted, so its opt-in was stripped.
    workspace_untrusted,
    /// The file's name says secret (`ai/suggest.zig`'s list).
    secret_bearing,
    /// An `ai.copilot.exclude` glob matched.
    excluded,
    /// `.gitignore` matched it.
    gitignored,
    /// The buffer has no path — an unsaved scratch. Copilot keys
    /// everything off a URI, so there is nothing to send it.
    no_path,

    pub fn allowedNow(r: Reason) bool {
        return r == .allowed;
    }

    /// One line for the chip's hover and `ai.copilot_status`. Short
    /// enough that the whole status line fits a toast on an 80-column
    /// screen: a reason the box clips is a reason nobody reads.
    pub fn words(r: Reason) []const u8 {
        return switch (r) {
            .allowed => "sharing this file",
            .not_selected => "backend is not Copilot",
            .not_opted_in => "not opted in (ai.copilot_enable_here)",
            .workspace_untrusted => "workspace not trusted",
            .secret_bearing => "secret-looking file name",
            .excluded => "ai.copilot.exclude matched",
            .gitignored => "gitignored",
            .no_path => "unsaved buffer",
        };
    }
};

/// The globs `ai.copilot.exclude` starts with. A user list REPLACES
/// these only for the glob check — `isSecretBearing` and the gitignore
/// check are not negotiable, because the point of the feature is that
/// the careless case is the safe one.
pub const default_exclude = [_][]const u8{ ".env*", "*.pem", "*.key", "id_*" };

/// Everything the decision needs, so it is testable without an `App`.
pub const Input = struct {
    backend: suggest.Backend = .copilot,
    /// `ai.copilot_here` as the trust layer left it — an untrusted
    /// workspace's `true` has already been stripped to `false`
    /// upstream, and `trusted` records that so the reason can say so.
    opted_in: bool = false,
    trusted: bool = true,
    /// Absolute path of the buffer, or null for a scratch.
    path: ?[]const u8 = null,
    /// Workspace-relative path, for the gitignore match. Null when the
    /// file is outside the workspace (then gitignore cannot apply).
    rel: ?[]const u8 = null,
    /// `ai.copilot.exclude`, or `&default_exclude` when unset.
    exclude: []const []const u8 = &default_exclude,
    /// The workspace's gitignore stack, or null when there is none.
    ignores: ?*const gitignore.Stack = null,
};

pub const Gate = struct {
    /// The one door. Order matters only for which reason is reported;
    /// every check is a veto.
    pub fn decide(in: Input) Reason {
        if (in.backend != .copilot) return .not_selected;
        if (!in.opted_in) return if (in.trusted) .not_opted_in else .workspace_untrusted;
        const path = in.path orelse return .no_path;
        if (suggest.isSecretBearing(path)) return .secret_bearing;
        const base = std.fs.path.basename(path);
        for (in.exclude) |g| {
            // A glob with a slash is matched against the workspace-
            // relative path (`build/**`); a bare one against the
            // basename at any depth, the way gitignore reads them.
            const subject = if (std.mem.indexOfScalar(u8, g, '/') != null) (in.rel orelse base) else base;
            if (gitignore.globMatch(g, subject)) return .excluded;
        }
        if (in.ignores) |st| if (in.rel) |rel| {
            if (st.ignored(rel, false)) return .gitignored;
        };
        return .allowed;
    }
};

// ─── the inline-completion item ─────────────────────────────────────────

/// One `items[]` entry of an `textDocument/inlineCompletion` result.
/// Borrows the response's arena.
pub const Item = struct {
    insert_text: []const u8,
    /// The span the item REPLACES. Copilot usually gives the current
    /// line's start through the cursor, with `insertText` repeating the
    /// text already typed.
    range: ?Range = null,
    /// The item's own `command`, echoed back on accept. JSON text, so
    /// it goes out exactly as it came in — Copilot's telemetry keys off
    /// an opaque id inside it.
    command_json: ?[]const u8 = null,
};

pub const Range = struct { start: Pos, end: Pos };
pub const Pos = struct { line: u32, character: u32 };

/// What mnml's ghost surface can show: text to insert AT the cursor,
/// nothing removed. Copilot's item replaces a range, so the prefix of
/// `insertText` that covers what is already typed between `range.start`
/// and the cursor comes off.
///
/// This is the conversion that silently corrupts a buffer if it is
/// wrong: a wrong answer here duplicates the half-typed word rather
/// than completing it. `line` is the current line's text and `col_u16`
/// the cursor's UTF-16 column in it.
///
/// Returns null when the item cannot become a cursor insert — a range
/// that ends after the cursor (Copilot proposing to eat text ahead of
/// it) or one whose already-typed prefix `insertText` does not repeat.
pub fn ghostText(it: Item, line: []const u8, cursor_line: u32, col_u16: u32) ?[]const u8 {
    const r = it.range orelse return it.insert_text;
    // Single-line ranges only: a multi-line replacement is not an
    // insert at the cursor.
    if (r.start.line != cursor_line or r.end.line != cursor_line) return null;
    if (r.end.character != col_u16 or r.start.character > col_u16) return null;
    const typed_units = col_u16 - r.start.character;
    if (typed_units == 0) return it.insert_text;
    const start_byte = byteAtU16(line, r.start.character);
    const end_byte = byteAtU16(line, col_u16);
    const typed = line[start_byte..end_byte];
    if (!std.mem.startsWith(u8, it.insert_text, typed)) return null;
    return it.insert_text[typed.len..];
}

/// The byte offset of UTF-16 code unit `units` into `line`, clamped.
pub fn byteAtU16(line: []const u8, units: u32) usize {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < line.len and n < units) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        n += if (len == 4) 2 else 1; // outside the BMP is a surrogate pair
        i += len;
    }
    return i;
}

/// UTF-16 code units in `s` — what `didPartiallyAcceptCompletion`'s
/// `acceptedLength` counts, and what an LSP `character` is.
pub fn lenU16(s: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

/// `acceptedLength` for a partial accept: measured from the start of
/// `insertText`, NOT the length of the piece just taken (the README is
/// explicit, and getting it backwards silently skews Copilot's
/// acceptance telemetry rather than failing). `already` is how much of
/// `insertText` the ghost had already consumed before this accept.
pub fn acceptedLength(insert_text: []const u8, already_bytes: usize, taken_bytes: usize) u32 {
    const end = @min(already_bytes + taken_bytes, insert_text.len);
    return lenU16(insert_text[0..end]);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "the gate: every refusal is a named one, and the order reports the right name" {
    // Not the chosen backend: nothing else is even looked at.
    try t.expectEqual(Reason.not_selected, Gate.decide(.{ .backend = .claude_api, .opted_in = true, .path = "/w/a.zig" }));
    try t.expectEqual(Reason.not_selected, Gate.decide(.{ .backend = .unset, .opted_in = true, .path = "/w/a.zig" }));
    // The default: a workspace that has said nothing shares nothing.
    try t.expectEqual(Reason.not_opted_in, Gate.decide(.{ .path = "/w/a.zig" }));
    // An untrusted workspace's opt-in was stripped upstream; the reason
    // says which of the two it was, so the toast can be useful.
    try t.expectEqual(Reason.workspace_untrusted, Gate.decide(.{ .path = "/w/a.zig", .trusted = false }));
    // Opted in: an ordinary source file goes.
    try t.expectEqual(Reason.allowed, Gate.decide(.{ .opted_in = true, .path = "/w/src/main.zig", .rel = "src/main.zig" }));
    // A scratch buffer has no URI to key off.
    try t.expectEqual(Reason.no_path, Gate.decide(.{ .opted_in = true }));
}

test "the gate: the file lists — secrets, the exclude globs, gitignore" {
    // The Claude backends' own secret list guards Copilot too.
    try t.expectEqual(Reason.secret_bearing, Gate.decide(.{ .opted_in = true, .path = "/w/.env", .rel = ".env" }));
    try t.expectEqual(Reason.secret_bearing, Gate.decide(.{ .opted_in = true, .path = "/w/aws_credentials.json", .rel = "aws_credentials.json" }));
    // The shipped exclude globs.
    try t.expectEqual(Reason.excluded, Gate.decide(.{ .opted_in = true, .path = "/w/server.key", .rel = "server.key" }));
    try t.expectEqual(Reason.excluded, Gate.decide(.{ .opted_in = true, .path = "/home/u/.ssh/id_ed25519.pub", .rel = null }));
    // `.env.local` is caught by BOTH lists; secret-bearing is reported
    // first because it is the one the user cannot turn off.
    try t.expectEqual(Reason.secret_bearing, Gate.decide(.{ .opted_in = true, .path = "/w/.env.local", .rel = ".env.local" }));
    // A user list replaces the default globs.
    const mine = [_][]const u8{"*.sql"};
    try t.expectEqual(Reason.excluded, Gate.decide(.{ .opted_in = true, .path = "/w/dump.sql", .rel = "dump.sql", .exclude = &mine }));
    // …and a `.pem` then goes, because the user said what they meant.
    try t.expectEqual(Reason.allowed, Gate.decide(.{ .opted_in = true, .path = "/w/cert.notpem.zig", .rel = "cert.notpem.zig", .exclude = &mine }));
    // A glob with a slash matches the workspace-relative path.
    const dirs = [_][]const u8{"vendor/**"};
    try t.expectEqual(Reason.excluded, Gate.decide(.{ .opted_in = true, .path = "/w/vendor/x/y.zig", .rel = "vendor/x/y.zig", .exclude = &dirs }));
    try t.expectEqual(Reason.allowed, Gate.decide(.{ .opted_in = true, .path = "/w/src/y.zig", .rel = "src/y.zig", .exclude = &dirs }));
}

test "the gate: gitignored files stay home" {
    var st = gitignore.Stack.init(t.allocator);
    defer st.deinit();
    try st.push(try gitignore.Rules.parse(t.allocator, "", "zig-out/\n*.generated.zig\n"));
    try t.expectEqual(Reason.gitignored, Gate.decide(.{ .opted_in = true, .path = "/w/a.generated.zig", .rel = "a.generated.zig", .ignores = &st }));
    try t.expectEqual(Reason.gitignored, Gate.decide(.{ .opted_in = true, .path = "/w/zig-out/bin/x.zig", .rel = "zig-out/bin/x.zig", .ignores = &st }));
    try t.expectEqual(Reason.allowed, Gate.decide(.{ .opted_in = true, .path = "/w/src/a.zig", .rel = "src/a.zig", .ignores = &st }));
    // Outside the workspace there is no relative path, so gitignore
    // cannot have an opinion — the other checks still do.
    try t.expectEqual(Reason.allowed, Gate.decide(.{ .opted_in = true, .path = "/elsewhere/a.generated.zig", .rel = null, .ignores = &st }));
}

test "status words: what the chip says after `copilot · `" {
    try t.expectEqualStrings("off here", stateWord(.yes, .normal, false, true));
    try t.expectEqualStrings("signed out", stateWord(.no, .normal, true, true));
    try t.expectEqualStrings("no seat", stateWord(.not_authorized, .normal, true, true));
    try t.expectEqualStrings("starting", stateWord(.unknown, .unknown, true, true));
    try t.expectEqualStrings("off", stateWord(.unknown, .unknown, true, false));
    try t.expectEqualStrings("ready", stateWord(.yes, .normal, true, true));
    try t.expectEqualStrings("ready", stateWord(.yes, .unknown, true, true));
    try t.expectEqualStrings("file excluded", stateWord(.yes, .inactive, true, true));
    try t.expectEqualStrings("error", stateWord(.yes, .err, true, true));
    try t.expectEqualStrings("warning", stateWord(.yes, .warning, true, true));
    // The server's own words, parsed as it spells them.
    try t.expectEqual(StatusKind.normal, StatusKind.parse("Normal"));
    try t.expectEqual(StatusKind.inactive, StatusKind.parse("Inactive"));
    try t.expectEqual(StatusKind.unknown, StatusKind.parse("normal"));
    try t.expectEqual(SignedIn.yes, SignedIn.parse("OK"));
    try t.expectEqual(SignedIn.yes, SignedIn.parse("AlreadySignedIn"));
    try t.expectEqual(SignedIn.no, SignedIn.parse("NotSignedIn"));
    try t.expectEqual(SignedIn.not_authorized, SignedIn.parse("NotAuthorized"));
}

test "an item becomes ghost text: the already-typed prefix comes off" {
    // The shape Copilot actually sends: the range covers what is typed
    // on the line, and `insertText` repeats it.
    const it: Item = .{ .insert_text = "printLine(\"hi\");", .range = .{ .start = .{ .line = 3, .character = 4 }, .end = .{ .line = 3, .character = 9 } } };
    try t.expectEqualStrings("Line(\"hi\");", ghostText(it, "    print", 3, 9).?);
    // No range at all: the whole thing is an insert.
    try t.expectEqualStrings("abc", ghostText(.{ .insert_text = "abc" }, "", 0, 0).?);
    // A range that starts AT the cursor is a plain insert too.
    const at: Item = .{ .insert_text = "xyz", .range = .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 2 } } };
    try t.expectEqualStrings("xyz", ghostText(at, "ab", 0, 2).?);
    // Refused: the range eats text AHEAD of the cursor…
    const ahead: Item = .{ .insert_text = "q", .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } } };
    try t.expect(ghostText(ahead, "abcde", 0, 2) == null);
    // …it spans lines…
    const multi: Item = .{ .insert_text = "q", .range = .{ .start = .{ .line = 2, .character = 0 }, .end = .{ .line = 3, .character = 0 } } };
    try t.expect(ghostText(multi, "abc", 3, 0) == null);
    // …or `insertText` does not repeat what is typed, which would
    // duplicate the word rather than complete it.
    const wrong: Item = .{ .insert_text = "zzz()", .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } } };
    try t.expect(ghostText(wrong, "pri", 0, 3) == null);
    // A multi-line suggestion is fine — the ghost surface shows it and
    // `ctrl+↓` takes one line.
    const lines: Item = .{ .insert_text = "if (x) {\n    y();\n}", .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } };
    try t.expectEqualStrings("if (x) {\n    y();\n}", ghostText(lines, "", 0, 0).?);
    // Non-ASCII: the column is UTF-16, so `é` is one unit and `𝄞` two.
    const uni: Item = .{ .insert_text = "ééq", .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 2 } } };
    try t.expectEqualStrings("q", ghostText(uni, "éé", 0, 2).?);
}

test "utf-16 lengths: the unit acceptedLength counts" {
    try t.expectEqual(@as(u32, 3), lenU16("abc"));
    try t.expectEqual(@as(u32, 1), lenU16("é"));
    try t.expectEqual(@as(u32, 2), lenU16("𝄞")); // a surrogate pair
    try t.expectEqual(@as(usize, 0), byteAtU16("éx", 0));
    try t.expectEqual(@as(usize, 2), byteAtU16("éx", 1));
    try t.expectEqual(@as(usize, 3), byteAtU16("éx", 9)); // clamped
    // From the START of insertText, not the length of the new piece —
    // a word accept after a word accept is 10, not 5.
    try t.expectEqual(@as(u32, 5), acceptedLength("hello world", 0, 5));
    try t.expectEqual(@as(u32, 11), acceptedLength("hello world", 5, 6));
    try t.expectEqual(@as(u32, 11), acceptedLength("hello world", 5, 999)); // clamped
}

test "the missing-binary message names the install line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings(
        "Copilot: copilot-language-server not installed — `npm i -g @github/copilot-language-server`",
        try missingMessage(arena.allocator(), default_binary),
    );
}
