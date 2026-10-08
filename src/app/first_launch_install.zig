//! The first-launch wizard's install actions: a Nerd Font, the Claude
//! Code and Codex CLIs, the `code` shim. Each runs its command in a pty
//! pane labelled `install: …` below the wizard's pane, so the user sees
//! the output and can answer a sudo prompt; the wizard closes for the
//! pane (as "ask me later" — nothing persists) and comes back on its own
//! once the pane ends.
//!
//! The commands are pure functions of the OS so they can be pinned
//! without running anything: `nerdFontCommand`, `aiCliCommand`,
//! `codeShimCommand`, and `terminalHint` for the step no installer can
//! do — pointing the terminal at the new font. The hint toasts on the
//! pane's exit 0 and never before: a failed install used to be told it
//! had worked.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const pty = @import("pty");
const pty_pane = @import("pty_pane.zig");
const runners = @import("runners.zig");
const first_launch = @import("first_launch.zig");
const cli = @import("../ai/cli.zig");
const Config = @import("../config/Config.zig");

pub const Os = enum { macos, linux, windows, other };

pub fn osOf(tag: std.Target.Os.Tag) Os {
    return switch (tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => .other,
    };
}

pub const host_os = osOf(builtin.os.tag);

const symbols_zip = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip";

/// The shell line that installs Symbols Nerd Font Mono for the user;
/// null where there is no auto-install (the toast points at
/// nerdfonts.com). macOS is the cask — on macOS 26 the only path that
/// registers an unsigned Nerd Font; Linux is the release zip into the
/// XDG font dir and `fc-cache`; Windows is the same zip through
/// PowerShell into the per-user font dir with an HKCU registration (no
/// admin, no winget package exists).
pub fn nerdFontCommand(os: Os) ?[]const u8 {
    return switch (os) {
        .macos => "brew install --cask font-symbols-only-nerd-font",
        .linux => "set -e; " ++
            "mkdir -p ~/.local/share/fonts/nerd-symbols; " ++
            "cd ~/.local/share/fonts/nerd-symbols; " ++
            "curl -fsSL '" ++ symbols_zip ++ "' -o pack.zip; " ++
            "unzip -o pack.zip; " ++
            "rm pack.zip; " ++
            "fc-cache -f; " ++
            "echo 'Symbols Nerd Font Mono installed to ~/.local/share/fonts/nerd-symbols'",
        // Runs through `cmd /d /c`, so the script is one PowerShell
        // `-Command` argument; it uses single quotes only.
        .windows => "powershell -NoProfile -ExecutionPolicy Bypass -Command \"" ++
            "$ErrorActionPreference='Stop'; " ++
            "$zip=Join-Path $env:TEMP 'NerdFontsSymbolsOnly.zip'; " ++
            "$tmp=Join-Path $env:TEMP 'nerd-symbols'; " ++
            "$dest=Join-Path $env:LOCALAPPDATA 'Microsoft\\Windows\\Fonts'; " ++
            "$reg='HKCU:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts'; " ++
            "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; " ++
            "Invoke-WebRequest -Uri '" ++ symbols_zip ++ "' -OutFile $zip -UseBasicParsing; " ++
            "Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; " ++
            "Expand-Archive -Path $zip -DestinationPath $tmp -Force; " ++
            "New-Item -ItemType Directory -Force -Path $dest | Out-Null; " ++
            "if(-not (Test-Path $reg)){New-Item -Path $reg -Force | Out-Null}; " ++
            "Get-ChildItem (Join-Path $tmp '*.ttf') | ForEach-Object { " ++
            "Copy-Item $_.FullName $dest -Force; " ++
            "New-ItemProperty -Path $reg -Name ($_.BaseName + ' (TrueType)') -Value (Join-Path $dest $_.Name) -PropertyType String -Force | Out-Null }; " ++
            "Remove-Item $zip -Force -ErrorAction SilentlyContinue; " ++
            "Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; " ++
            "Write-Host 'Symbols Nerd Font installed for the current user.'\"",
        .other => null,
    };
}

/// The short form the wizard row shows.
pub fn nerdFontSummary(os: Os) []const u8 {
    return switch (os) {
        .macos => "brew install --cask font-symbols-only-nerd-font",
        .linux => "curl the NerdFontsSymbolsOnly zip into ~/.local/share/fonts, fc-cache -f",
        .windows => "PowerShell: download the NerdFontsSymbolsOnly zip into your user fonts",
        .other => "no auto-install for this OS — https://www.nerdfonts.com",
    };
}

/// What the user does once the font is on disk, keyed off
/// `$TERM_PROGRAM` (macOS-canonical; ghostty and kitty export it on
/// Linux; unreliable on Windows). The symbols-only face has no letters,
/// so it is never the primary font: ghostty wants a full patched mono
/// plus the codepoint map for mnml's baked glyphs; iTerm2 has a
/// non-ASCII slot; Terminal.app has none; Windows Terminal has no
/// fallback-list setting at all.
pub fn terminalHint(term_program: ?[]const u8, os: Os) []const u8 {
    const term = term_program orelse "";
    if (std.mem.eql(u8, term, "ghostty"))
        return "in `~/.config/ghostty/config` set `font-family = JetBrainsMono Nerd Font Mono` (any full Nerd-Font-patched mono works — NOT the symbols-only face), plus `font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols` for mnml's baked glyphs. Fully quit (Cmd+Q) + reopen ghostty.";
    if (std.mem.eql(u8, term, "iTerm.app"))
        return "iTerm2 → Settings → Profiles → Text → tick 'Use a different font for non-ASCII text' and set that to Symbols Nerd Font Mono (leave the main font as your normal mono). Restart iTerm2.";
    if (std.mem.eql(u8, term, "Apple_Terminal"))
        return "Terminal.app has no non-ASCII font slot, so pick a full Nerd-Font-patched mono (e.g. CaskaydiaCove NFM) under Settings → Profiles → Text → Font. Restart Terminal.app.";
    if (std.mem.eql(u8, term, "WezTerm"))
        return "add `Symbols Nerd Font Mono` to `font` fallback in `~/.wezterm.lua`, restart WezTerm.";
    if (os == .windows)
        return "restart Windows Terminal and see whether icons resolve — there is no fallback-list setting to change. If they still render as boxes, set Settings → your profile → Appearance → Font face to a full Nerd-Font-patched mono such as CaskaydiaCove NFM (not the symbols-only face — it has no letters).";
    return "point your terminal's font (or its fallback list) at 'Symbols Nerd Font Mono'. Restart the terminal so it re-reads the font list.";
}

/// The vendors' own installers, per each product's docs: `curl … | sh`
/// (PowerShell `irm | iex` on Windows). One line for what is missing,
/// joined with `&&`; null when both are present.
pub fn aiCliCommand(arena: Allocator, os: Os, claude_missing: bool, codex_missing: bool) Allocator.Error!?[]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    if (claude_missing) try parts.append(arena, if (os == .windows)
        "powershell -c \"irm https://claude.ai/install.ps1 | iex\""
    else
        "curl -fsSL https://claude.ai/install.sh | bash");
    if (codex_missing) try parts.append(arena, if (os == .windows)
        "powershell -ExecutionPolicy ByPass -c \"irm https://chatgpt.com/codex/install.ps1 | iex\""
    else
        "curl -fsSL https://chatgpt.com/codex/install.sh | sh");
    if (parts.items.len == 0) return null;
    return try std.mem.join(arena, " && ", parts.items);
}

/// The `code` CLI inside the VS Code bundle on macOS — the same path the
/// detection probes.
pub const code_bundle_shim = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code";
pub const code_shim_target = "/usr/local/bin/code";

/// `sudo ln` needs a terminal for the password, hence a pane.
pub fn codeShimCommand() []const u8 {
    return "sudo ln -sf \"" ++ code_bundle_shim ++ "\" " ++ code_shim_target;
}

pub const nerd_font_label = "install: nerd font";
pub const ai_cli_label = "install: ai clis";
pub const code_shim_label = "install: code shim";

/// Is `bin` on the PATH the app's children see?
pub fn installed(app: *App, bin: []const u8) bool {
    return runners.onPath(app, bin);
}

pub fn claudeInstalled(app: *App) bool {
    return installed(app, cli.claude_binary);
}

pub fn codexInstalled(app: *App) bool {
    return installed(app, cli.codex_binary);
}

pub fn codeShimInstalled(app: *App) bool {
    return installed(app, "code");
}

/// How long the chips trust a PATH walk before walking again.
pub const probe_ttl_ms: i64 = 10_000;

/// `claudeInstalled` / `codexInstalled` for the frame: one PATH walk
/// per `probe_ttl_ms`, so the chips can ask every render. An install
/// pane's exit drops the cache.
pub fn cliOnPath(app: *App, product: Config.AiProduct) bool {
    const probe = &app.cli_probe;
    const stale = if (probe.checked_ms) |at| app.now_ms - at >= probe_ttl_ms or app.now_ms < at else true;
    if (stale) {
        probe.claude = claudeInstalled(app);
        probe.codex = codexInstalled(app);
        probe.checked_ms = app.now_ms;
    }
    return switch (product) {
        .claude => probe.claude,
        .codex => probe.codex,
    };
}

/// Forget the PATH walk: the next frame looks again.
pub fn forgetProbe(app: *App) void {
    app.cli_probe.checked_ms = null;
}

/// Whether the bundle's `code` exists, so the shim can point at it.
pub fn codeBundlePresent(app: *App) bool {
    _ = std.Io.Dir.cwd().statFile(app.io, code_bundle_shim, .{}) catch return false;
    return true;
}

/// Space on the Nerd Font section with "no" answered: run the install
/// in a pane; the hint waits for the pane.
pub fn installNerdFont(app: *App) CommandError!void {
    // Offline (`http/offline.zig`): the installers download; not run.
    if (app.offline() != .online) return app.toast("{s} \u{2014} the installer downloads, so it is not run", .{app.offline().label()});
    const line = nerdFontCommand(host_os) orelse {
        app.toast("No auto-install for this OS — download Symbols Nerd Font Mono from https://www.nerdfonts.com", .{});
        return;
    };
    first_launch.closeForInstall(app);
    _ = try spawnInstall(app, nerd_font_label, line, .nerd_font_install);
    app.toast("Installing — watch the `{s}` pane. If it reports an error the font is NOT installed.", .{nerd_font_label});
}

/// Space on the Claude Code + Codex section: the missing ones' installers.
pub fn installAiClis(app: *App) CommandError!void {
    // Offline (`http/offline.zig`): the installers download; not run.
    if (app.offline() != .online) return app.toast("{s} \u{2014} the installer downloads, so it is not run", .{app.offline().label()});
    const arena = app.frame.allocator();
    const line = (try aiCliCommand(arena, host_os, !claudeInstalled(app), !codexInstalled(app))) orelse {
        app.toast("Claude Code + Codex already installed.", .{});
        return;
    };
    first_launch.closeForInstall(app);
    _ = try spawnInstall(app, ai_cli_label, line, .ai_cli_install);
    app.toast("Installing — watch the `{s}` pane; the wizard returns when it ends.", .{ai_cli_label});
}

/// Space on the `code` shim section.
pub fn installCodeShim(app: *App) CommandError!void {
    if (codeShimInstalled(app)) {
        app.toast("`code` is already on PATH.", .{});
        return;
    }
    if (host_os != .macos) {
        app.toast("The `code` shim is a macOS bundle symlink; elsewhere install VS Code's `code` command from VS Code itself (Shell Command: Install 'code' command in PATH).", .{});
        return;
    }
    if (!codeBundlePresent(app)) {
        app.toast("VS Code.app not found at /Applications/Visual Studio Code.app. Install VS Code first, then reopen the wizard.", .{});
        return;
    }
    first_launch.closeForInstall(app);
    _ = try spawnInstall(app, code_shim_label, codeShimCommand(), .code_shim_install);
    app.toast("Linking — watch the `{s}` pane for the sudo prompt.", .{code_shim_label});
}

fn spawnInstall(app: *App, label: []const u8, line: []const u8, after: pty_pane.AfterExit) CommandError!app_mod.PaneId {
    var shell_buf: [4][]const u8 = undefined;
    return pty_pane.open(app, .{
        .argv = pty.shellArgv(&shell_buf, &app.env, line),
        .cwd = app.workspace,
        .label = label,
        .placement = .below,
        .kind = .task,
        .after_exit = after,
    });
}

/// The pane ended. On success the Nerd Font hint toasts and the CLI
/// rows re-detect; either way the wizard comes back (focused on the
/// section the pane came from) when nothing else is up and setup is
/// still pending. Runs from inside the pane walk: no panes are opened
/// or closed here.
pub fn afterExit(app: *App, follow: pty_pane.AfterExit, exit: pty_pane.Exit) void {
    const ok = exit.ok();
    forgetProbe(app);
    const section: first_launch.Section = switch (follow) {
        .nerd_font_install => .nerd_font,
        .ai_cli_install => .claude_codex,
        .code_shim_install => .vscode_shim,
    };
    if (ok) switch (follow) {
        .nerd_font_install => app.toast("Symbols Nerd Font Mono installed. Now {s}", .{terminalHint(app.env.get("TERM_PROGRAM"), host_os)}),
        .ai_cli_install => app.toast("Install finished — Claude Code: {s} · Codex: {s}", .{ foundWord(claudeInstalled(app)), foundWord(codexInstalled(app)) }),
        .code_shim_install => app.toast("`code` shim: {s}", .{if (codeShimInstalled(app)) "on PATH" else "still not on PATH — open a new shell, or check the pane"}),
    } else {
        const label = switch (follow) {
            .nerd_font_install => nerd_font_label,
            .ai_cli_install => ai_cli_label,
            .code_shim_install => code_shim_label,
        };
        switch (exit) {
            .code => |c| app.toast("`{s}` failed (exit {d}) — nothing was installed; the pane has the error.", .{ label, c }),
            .signal => |sig| app.toast("`{s}` ended by signal {d} — nothing was installed.", .{ label, sig }),
        }
    }
    first_launch.refresh(app, section);
}

fn foundWord(present: bool) []const u8 {
    return if (present) "found" else "not found";
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the Nerd Font command per OS: the cask, the zip + fc-cache, the PowerShell per-user install; none elsewhere" {
    try t.expectEqualStrings("brew install --cask font-symbols-only-nerd-font", nerdFontCommand(.macos).?);
    const linux = nerdFontCommand(.linux).?;
    try t.expect(std.mem.startsWith(u8, linux, "set -e; mkdir -p ~/.local/share/fonts/nerd-symbols; "));
    try t.expect(std.mem.indexOf(u8, linux, "curl -fsSL 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip' -o pack.zip") != null);
    try t.expect(std.mem.indexOf(u8, linux, "unzip -o pack.zip; rm pack.zip; fc-cache -f;") != null);
    const win = nerdFontCommand(.windows).?;
    try t.expect(std.mem.startsWith(u8, win, "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$ErrorActionPreference='Stop'; "));
    try t.expect(std.mem.indexOf(u8, win, "Invoke-WebRequest -Uri 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip' -OutFile $zip -UseBasicParsing") != null);
    try t.expect(std.mem.indexOf(u8, win, "Expand-Archive -Path $zip -DestinationPath $tmp -Force") != null);
    try t.expect(std.mem.indexOf(u8, win, "$dest=Join-Path $env:LOCALAPPDATA 'Microsoft\\Windows\\Fonts'") != null);
    try t.expect(std.mem.indexOf(u8, win, "$reg='HKCU:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts'") != null);
    try t.expect(std.mem.indexOf(u8, win, "New-ItemProperty -Path $reg -Name ($_.BaseName + ' (TrueType)')") != null);
    // one -Command argument: the script has no double quote of its own
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, win, "\""));
    try t.expect(std.mem.endsWith(u8, win, "\""));
    try t.expect(nerdFontCommand(.other) == null);
    try t.expectEqualStrings("no auto-install for this OS — https://www.nerdfonts.com", nerdFontSummary(.other));
    try t.expectEqual(Os.macos, osOf(.macos));
    try t.expectEqual(Os.other, osOf(.freebsd));
}

test "the terminal hint follows TERM_PROGRAM, then the OS" {
    try t.expect(std.mem.indexOf(u8, terminalHint("ghostty", .macos), "font-family = JetBrainsMono Nerd Font Mono") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint("ghostty", .macos), "font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint("ghostty", .linux), "Cmd+Q") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint("iTerm.app", .macos), "non-ASCII text") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint("Apple_Terminal", .macos), "no non-ASCII font slot") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint("WezTerm", .linux), "~/.wezterm.lua") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint(null, .windows), "Windows Terminal") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint("", .windows), "no fallback-list setting") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint(null, .linux), "fallback list") != null);
    try t.expect(std.mem.indexOf(u8, terminalHint("kitty", .macos), "Symbols Nerd Font Mono") != null);
}

test "the AI CLI installers are the vendors' curl | sh lines, PowerShell on Windows, only for what is missing" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("curl -fsSL https://claude.ai/install.sh | bash && curl -fsSL https://chatgpt.com/codex/install.sh | sh", (try aiCliCommand(a, .macos, true, true)).?);
    try t.expectEqualStrings("curl -fsSL https://claude.ai/install.sh | bash", (try aiCliCommand(a, .linux, true, false)).?);
    try t.expectEqualStrings("curl -fsSL https://chatgpt.com/codex/install.sh | sh", (try aiCliCommand(a, .linux, false, true)).?);
    try t.expectEqualStrings("powershell -c \"irm https://claude.ai/install.ps1 | iex\" && powershell -ExecutionPolicy ByPass -c \"irm https://chatgpt.com/codex/install.ps1 | iex\"", (try aiCliCommand(a, .windows, true, true)).?);
    try t.expect((try aiCliCommand(a, .macos, false, false)) == null);
    try t.expectEqualStrings("sudo ln -sf \"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code\" /usr/local/bin/code", codeShimCommand());
}
