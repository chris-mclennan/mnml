//! App state, grouped by subsystem (D7). Render-free. `*App` is the
//! parameter for commands and event handlers — components never see it.
//!
//! This file is the state and its lifecycle: panes, layouts, focus,
//! overlays, toasts, the keymap and chord chain. Behaviour lives beside
//! it in `src/app/`: `dispatch.zig` (keys, mouse, the 22 `AppCommand`s),
//! `render.zig` (one frame), `ex.zig` (the `:` interpreter), the
//! `cmd_*.zig` runner tables, and `driver.zig` (the `.test` / headless
//! seam).
//!
//! // changed: D3 resets the frame arena at the top of the loop. Here it
//! is reset at the top of `render` instead — the hit map the components
//! register lives on the frame arena and has to survive until the next
//! mouse event, which arrives at the top of the following iteration.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const alloc = @import("core/alloc.zig");
const os_path = @import("core/os_path.zig");
const command = @import("core/command.zig");
const event = @import("core/event.zig");
const keymap = @import("core/keymap.zig");
const key_mod = @import("core/key.zig");
const ids = @import("core/ids.zig");
const hooks = @import("core/hooks.zig");
const input = @import("input/mod.zig");
const config = @import("config/root.zig");
const buffer_mod = @import("editor/buffer.zig");
const editorconfig = @import("editor/editorconfig.zig");
const edit_op = @import("editor/edit_op.zig");
const edit_op_editor = @import("editor/editor.zig");
const pane_mod = @import("app/pane.zig");
const side_mod = @import("app/side.zig");
const bottom_mod = @import("app/bottom.zig");
const layout_mod = @import("app/layout.zig");
const find_mod = @import("app/find.zig");
const syntax = @import("app/syntax.zig");
const doc_store = @import("app/doc_store.zig");
pub const DocStore = doc_store.DocStore;
const snippets = @import("app/snippets.zig");
const md_preview = @import("app/md_preview.zig");
const discovery_app = @import("app/discovery.zig");
const image = @import("image/root.zig");
const image_pane = @import("app/image_pane.zig");
const whichkey = @import("app/whichkey.zig");
const tree_mod = @import("app/tree.zig");
const info_view_app = @import("app/info_view.zig");
const ex = @import("app/ex.zig");
const ex_verbs = @import("app/ex_verbs.zig");
const cmd_find = @import("app/cmd_find.zig");
const dispatch = @import("app/dispatch.zig");
const cmd_picker = @import("app/cmd_picker.zig");
const render_mod = @import("app/render.zig");
const theme_mod = @import("ui/theme.zig");
const hit = @import("ui/hit.zig");
const prompt_mod = @import("ui/prompt.zig");
const confirm_mod = @import("ui/confirm.zig");
const picker_mod = @import("ui/picker.zig");
const find_bar_mod = @import("ui/find_bar.zig");
const toast_mod = @import("ui/toast.zig");
const editor_view = @import("ui/editor_view.zig");
const cursor_mod = @import("app/cursor.zig");
const todos = @import("todos.zig");
const notes = @import("notes.zig");
const findings = @import("findings.zig");
const debug_panel = @import("app/debug_panel.zig");
const sessions = @import("sessions.zig");
const welcome_mod = @import("app/welcome.zig");
const session_changes_mod = @import("app/session_changes.zig");
const dock = @import("app/dock.zig");
const hover_zones = @import("app/hover_zones.zig");
const sidebar_auto = @import("app/sidebar_auto.zig");
const focus_follow = @import("app/focus_follow.zig");
const launcher_dock_mod = @import("app/launcher_dock.zig");
const activity_bar_mod = @import("app/activity_bar.zig");
const panel_mod = @import("core/panel.zig");
const trust_app = @import("app/trust.zig");
const settings_app = @import("app/settings.zig");
const first_launch = @import("app/first_launch.zig");
const scroll_mod = @import("app/scroll.zig");
const flash_mod = @import("app/flash.zig");
const Rect = @import("ui/rect.zig");
const Ui = @import("ui/context.zig");
const Canvas = @import("ui/canvas.zig");
const pty_pane = @import("app/pty_pane.zig");
const runners = @import("app/runners.zig");
const tasks_mod = @import("app/tasks.zig");
const watch = @import("app/watch.zig");
const git_app = @import("app/git.zig");
const git_palette_app = @import("app/git_palette.zig");
const ai_app = @import("app/ai.zig");
const copilot_app = @import("app/copilot.zig");
const spend = @import("app/spend.zig");
const usage_pane = @import("app/usage_pane.zig");
const tests_pane = @import("app/tests_pane.zig");
const flaky = @import("app/flaky.zig");
const ipc = @import("ipc/root.zig");
const grep = @import("app/grep.zig");
const jumplist = @import("app/jumplist.zig");
const dap = @import("app/dap.zig");
const lsp = @import("app/lsp.zig");
const script_decor = @import("app/script_decor.zig");
const idle = @import("app/idle.zig");
const autosave = @import("app/autosave.zig");
const script_task = @import("app/script_task.zig");
const syntax_jobs = @import("app/syntax_jobs.zig");
const jobs_mod = @import("app/jobs.zig");
const http_app = @import("app/http.zig");
const http_panel = @import("app/http_panel.zig");
const request_pane = @import("app/request_pane.zig");
const ws_pane = @import("app/ws_pane.zig");
const browser_pane = @import("app/browser_pane.zig");
const mount_pane = @import("app/mount_pane.zig");
const integrations = @import("app/integrations.zig");
const marketplace = @import("app/marketplace.zig");
const font_scan = @import("app/font_scan.zig");
const glyph_audit = @import("app/glyph_audit.zig");
const http_parse = @import("http/parse.zig");
const scripting = @import("scripting/lua.zig");
const script_api = @import("scripting/api.zig");
const cmd_script = @import("app/cmd_script.zig");
const scripts_panel = @import("app/scripts_panel.zig");
const scripts_mod = @import("app/scripts.zig");
const script_list = @import("app/script_list.zig");
const script_section = @import("app/script_section.zig");
const search_section = @import("app/search_section.zig");
const grep_picker = @import("app/grep_picker.zig");
const messages = @import("app/messages.zig");
const harpoon = @import("app/harpoon.zig");
const stress = @import("app/stress.zig");
const undo_store = @import("app/undo_store.zig");
const macros_store = @import("app/macros_store.zig");
const find_history = @import("app/find_history.zig");
const auto_refresh = @import("app/auto_refresh.zig");
const clock = @import("app/clock.zig");
const coverage = @import("app/coverage.zig");
const now_playing = @import("app/now_playing.zig");
const integration_poll = @import("app/integration_poll.zig");
const broker_app = @import("app/broker.zig");
const menu_bar = @import("app/menu_bar.zig");
const marks_store = @import("app/marks_store.zig");
const update = @import("app/update.zig");
const session = @import("app/session.zig");
const startup_picker = @import("app/startup_picker.zig");
const files_pane = @import("app/files_pane.zig");
const file_clipboard = @import("app/file_clipboard.zig");
const trash = @import("app/trash.zig");
const transfers = @import("app/transfers.zig");
const builtin = @import("builtin");
const test_workspace = @import("app/test_workspace.zig");

pub const PaneId = ids.PaneId;
pub const PanelId = panel_mod.PanelId;
pub const FocusId = ids.FocusId;
pub const Pane = pane_mod.Pane;
pub const EditorPane = pane_mod.EditorPane;
pub const PaneStore = pane_mod.PaneStore;
pub const ListPane = pane_mod.ListPane;
pub const Buffer = buffer_mod.Buffer;
pub const Clipboard = buffer_mod.Clipboard;
pub const Key = key_mod.Key;
pub const Layout = layout_mod.Layout;
pub const LayoutState = layout_mod.LayoutState;
pub const AppEvent = event.AppEvent;
pub const Prompt = prompt_mod;
pub const Confirm = confirm_mod;
pub const Picker = picker_mod;
pub const HelpUi = @import("ui/help_overlay.zig");
pub const JobsView = @import("ui/jobs_view.zig");
pub const FindBar = find_bar_mod;
pub const FindState = find_mod.FindState;

/// The ZON config (E1): `Config{}` is the shipped default, `config.load`
/// the three-layer merge. Every field the app honours is read off
/// `App.cfg`; the loader's arena (`App.loaded`) owns its strings.
pub const Config = config.Config;

/// What `init` needs beyond the allocator and the io.
pub const InitOptions = struct {
    /// The merged config. Borrows `loaded`'s arena when there is one.
    cfg: Config = .{},
    /// The loader's result, when the config came from files. The App
    /// takes ownership — success or failure — and frees it in `deinit`.
    loaded: ?config.Loaded = null,
    /// Absolute. Defaults to the process cwd's name as given.
    workspace: []const u8 = ".",
    data_root: []const u8 = "",
    cols: u16 = 120,
    rows: u16 = 40,
    /// The environment children inherit (a pty's shell). The process's
    /// own when null.
    env: ?*const std.process.Environ.Map = null,
    /// Whether `<workspace>/.mnml/init.lua` may run. Null derives it
    /// from `loaded` (the trust store); the `.test` runner sets it for
    /// the temp workspace it made itself.
    workspace_trusted: ?bool = null,
    /// Whether an IPC `notify` may also reach the OS (`osascript` /
    /// `notify-send` / PowerShell). The terminal loop says yes; headless
    /// and the tests never spawn a notifier.
    native_notify: bool = false,
    /// Whether a real terminal will draw the cursor a frame asks for
    /// (`Screen.cursor_vis` / `cursor_shape` out through vaxis). The
    /// terminal loop says yes; headless and the tests have no such
    /// cursor, so the focused pty pane paints its own into the cells.
    term_cursor: bool = false,

    /// // changed (sidebar-autohide): frames are going to a live
    /// terminal at a human's rate, so a chrome animation has somewhere
    /// to play. The terminal loop says yes; `--headless`, the `.test`
    /// harness and the unit tests render one frame at a time and want
    /// every animation at its end state on the first of them.
    live_frames: bool = false,
};

/// How long an ordinary toast stays.
pub const toast_ttl_ms: i64 = 4000;

pub const PromptPurpose = union(enum) {
    goto_line,
    /// `:` from a pane with no editor (a request pane): the line runs
    /// as an ex command (Rust's `no_pane_cmdline`).
    ex_line,
    /// The statusline indent chip: a new `editor.tab_width`.
    tab_width,
    /// `view.image_open`: a path to open as `Pane.image`.
    image_open,
    replace,
    filter_shell,
    new_todo,
    /// A git prompt; `git.State.prompt` says which.
    git,
    /// Runners: the npm script / the `go run` path typed into the prompt.
    npm_run_script,
    go_run_path,
    /// `launcher.add_local`: the path of a `.zon` manifest to install.
    launcher_add_local,
    /// A workspace-relative path typed into the prompt; the payload is
    /// the directory it is created in (owned).
    new_file: []u8,
    new_folder: []u8,
    /// `file.save_as`: the editor pane the typed path is saved from.
    save_as: PaneId,
    /// A note / finding name typed into the seeded prompt; the payload
    /// is the panel's directory, workspace-relative (owned).
    new_note: []u8,
    new_finding: []u8,
    /// SESSIONS: the alias for this session id (owned).
    sessions_rename: []u8,
    /// // changed (sessions-worktree): the branch name of a new session
    /// worktree; the payload names the product and the launch profile
    /// (owned) the session then starts with.
    session_worktree_name: SessionWorktreeName,
    /// // changed (sessiondiff): the commit message for a session's
    /// changes view; the payload is the repo id it commits in.
    session_commit: u32,
    /// A cloud run's ticket; the wizard's first step; its second, the
    /// model, carrying the ticket (owned).
    cloud_run_ticket,
    cloud_run_wizard_ticket,
    cloud_run_model: []u8,
    /// Dock: a new note / tail lands in this corner; an edit / rename
    /// names the widget.
    dock_new_text: dock.Corner,
    dock_new_log: dock.Corner,
    dock_edit: u32,
    dock_rename: u32,
    /// The workspace-relative path being renamed (owned).
    rename: []u8,
    /// `file.move_to` from a Files pane: the absolute paths to move
    /// (owned) into the folder typed into the prompt.
    move_paths: [][]u8,
    /// AI: a bare question; a question with the file + selection;
    /// a transcript search; a branch description.
    ai_ask,
    ai_chat,
    ai_search,
    ai_branch_name,
    /// The usage reader's accounts (`app/usage_pane.zig`): a new
    /// account's name; the OAuth token for the named account; the new
    /// name for the named account. The payload owns the name and the
    /// prompt's title, which names the account.
    claude_account_add,
    claude_account_token: AccountPrompt,
    claude_account_rename: AccountPrompt,
    /// DAP: a watch expression.
    dap_add_watch,
    /// DAP: a condition / hit-count for the breakpoint on `line` of `path` (owned).
    dap_bp_condition: BpTarget,
    dap_hit_count: BpTarget,
    /// DAP: a new value for `name` under `parent_ref` (owned name).
    dap_set_variable: struct { parent_ref: i64, name: []u8 },
    /// The watch expression being replaced (owned).
    dap_edit_watch: []u8,
    dap_bp_log: BpTarget,
    /// LSP: the new name for the symbol at the cursor.
    lsp_rename,
    /// // changed (lua-install): `script.install` — the git URL,
    /// archive or folder to install from; the payload is the owned
    /// prompt title (`app/scripts.zig`).
    script_install: []u8,
    /// // changed (lua-track): *Bind in init.lua…* — the key spec for
    /// `id`; the prompt's title is `title` (both owned).
    lua_bind: LuaBind,
    /// LSP: a `workspace/symbol` query.
    lsp_workspace_symbol,

    /// HTTP: `KEY=VALUE` for a new env var; the value for `key` (owned).
    http_env_add_key,
    http_env_edit_value: []u8,
    http_auth_value: @import("app/cmd_http.zig").AuthKind,
    /// The Auth tab's Options rows: a timeout, a redirect cap, a proxy.
    http_option: @import("app/http.zig").OptionKind,
    /// The value of the `:name` path segment (owned name).
    http_path_param: []u8,
    /// `http.rename_request`: the file or block to rename (owned).
    http_rename: @import("app/http_ops.zig").Target,
    /// `# @description` / `# @tags` for the active request.
    http_description,
    http_tags,
    auth_preset_name,
    http_save_as,
    http_save_response,
    http_new_env,
    http_new_chain,
    http_new_collection,
    http_new_request,
    http_lookup_var,
    ws_url,
    ws_message,
    browser_url,
    browser_navigate,
    browser_eval,
    /// The answer to a page's `prompt()` dialog.
    browser_dialog,
    browser_add_cookie,
    browser_add_storage,
    /// `mount.open`: the binary and args to host.
    mount_open,
    /// `term.rename`: the new tab label for this pty pane.
    term_rename: PaneId,
    /// Workspace grep: the query; the replacement for every enabled hit.
    grep_query,
    grep_replace,
    /// `view.add_workspace`: a folder (Tab completes path segments).
    add_workspace,
    /// `view.terminal_glyph_custom`: the SVG to bake as the terminal
    /// mark (`app/terminal_glyph.zig`).
    terminal_glyph_svg,
    /// `view.claude_mark_custom`: the SVG to bake as Claude's mark
    /// (`app/claude_mark.zig`). Its twin above; both are
    /// `app/mark_bake.zig`.
    claude_mark_svg,
    /// `layout.save`: the layout's name (`app/named_layouts.zig`). Load
    /// and delete pick from the list instead (`layout.pick`).
    layout_save,
    /// `marketplace.add_source`: a folder or `owner/repo` to add to the
    /// marketplace's sources (`app/marketplace.zig` `addSource`); the
    /// payload says who asked.
    marketplace_add_source: AddSourceFrom,

    pub const AddSourceFrom = enum { palette };

    pub const BpTarget = struct { path: []u8, line: u32 };
    pub const AccountPrompt = struct { name: []u8, title: []u8 };
    pub const SessionWorktreeName = struct { product: Config.AiProduct, profile: []u8 };

    pub fn deinit(p: PromptPurpose, gpa: Allocator) void {
        switch (p) {
            .new_file, .new_folder, .new_note, .new_finding, .sessions_rename, .cloud_run_model, .rename, .http_env_edit_value, .http_path_param, .script_install => |s| gpa.free(s),
            .claude_account_token, .claude_account_rename => |a| {
                gpa.free(a.name);
                gpa.free(a.title);
            },
            .session_worktree_name => |w| gpa.free(w.profile),
            .move_paths => |ps| {
                for (ps) |q| gpa.free(q);
                gpa.free(ps);
            },
            .dap_bp_condition, .dap_hit_count, .dap_bp_log => |b| gpa.free(b.path),
            .dap_set_variable => |sv| gpa.free(sv.name),
            .dap_edit_watch => |w| gpa.free(w),
            .http_rename => |t| t.deinit(gpa),
            .lua_bind => |b| {
                gpa.free(b.id);
                gpa.free(b.title);
            },
            else => {},
        }
    }
};
pub const LuaBind = struct { id: []u8, title: []u8 };
pub const ConfirmPurpose = union(enum) {
    close_pane: PaneId,
    quit,
    /// // changed (quit-confirm): the same box raised with nothing
    /// unsaved — two choices, so the accepted index means something
    /// else (0 = Quit, 1 = Cancel). Payload-free like `.quit`, which
    /// `dispatch.zig` also uses as its ownership-moved sentinel.
    quit_clean,
    /// `app.restart` with unsaved work: Save all / Restart anyway /
    /// Cancel, the quit box's answers for a relaunch.
    restart,
    /// Run the workspace's exec-bearing config (`trust.zig`).
    trust_workspace,
    /// `workspace.review_trust` on a trusted workspace: Keep / Forget.
    review_trust,
    /// Install the missing tool (`runners.zig`); the payload indexes the installer table.
    install_tool: u16,
    /// Update an installed Nerd Font family (`font_scan.zig`); the
    /// payload indexes the scanned families.
    font_update: u16,
    /// A git yes/no; `git.State.confirm` holds the payload.
    git,
    /// Delete one workspace-relative path directly (owned) — the
    /// NOTES / FINDINGS row delete (`tree.acceptDelete`).
    delete_path: []u8,
    /// Delete these absolute paths (owned); `permanent_only` when they
    /// are already in the trash (`trash.confirmDelete`).
    delete_paths: DeletePaths,
    /// `files.empty_trash`.
    empty_trash,
    /// Move `from` into directory `into` (both workspace-relative, owned).
    /// `copy`: an Alt-drag — the file is copied into the folder.
    move_path: struct { from: []u8, into: []u8, copy: bool = false },
    /// An AI job's write_file waits on this box (the job id).
    ai_tool: u64,
    /// SIGTERM these sessions (owned).
    kill_pids: []u32,
    /// Stop this cloud run's ECS task (the ARN, owned).
    cloud_cancel: []u8,
    /// `integrations.remove`: the manifest id to delete (owned).
    remove_integration: []u8,
    /// `ai.claude_remove_account`: the account's name (owned).
    remove_claude_account: []u8,
    /// SESSIONS: the absolute transcript path to delete (owned).
    delete_session: []u8,
    /// // changed (sessions-worktree): merge the session worktree at
    /// this path into the main tree (owned); remove it (and its
    /// branch), `force` past an unmerged branch (`session_worktree.zig`).
    session_worktree_merge: []u8,
    session_worktree_remove: SessionWorktreeRemove,
    /// `http.delete_request`: the file or block to delete (owned).
    http_delete_request: @import("app/http_ops.zig").Target,
    /// `:s///c`: one match's yes / no / all / quit / last (`ex_verbs.zig`).
    replace_confirm,
    /// `app.choose_data_layout`: Yes = portable, No = normal (`setup.zig`).
    choose_data_layout,
    /// `app.reset_to_defaults`: Reset renames the home config and restarts.
    reset_to_defaults,
    /// // changed (lua-install): `script.install` — the staged copy is
    /// on disk and its claims are on screen; Install commits it, and
    /// anything else throws the copy away (`app/scripts.zig`).
    script_install: ScriptInstall,
    /// // changed (lua-install): `script.remove` — the script's name.
    remove_script: []u8,
    /// A named layout's load over a page with unsaved panes: the name
    /// (owned). Load keeps them as background tabs (`named_layouts.zig`).
    layout_load: []u8,
    /// A save over a layout that exists: the name (owned). Replace
    /// writes it; the file may be committed and shared, so it asks.
    layout_overwrite: []u8,
    /// A named layout's delete (`named_layouts.zig`): the name (owned),
    /// and whether the layouts picker opens again after it.
    layout_delete: LayoutDelete,

    pub const DeletePaths = struct { paths: [][]u8, permanent_only: bool };
    pub const LayoutDelete = struct { name: []u8, from_picker: bool };
    pub const ScriptInstall = struct { dir: []u8, name: []u8, url: []u8, source: @import("scripting/manifest.zig").Source };
    /// `stage`: the first confirm (`.tree`: Remove, or Keep the files /
    /// Remove anyway when `dirty` files are in the tree) or the one
    /// past an unmerged branch (`.branch`), which carries the first
    /// one's answer in `force_tree`.
    pub const SessionWorktreeRemove = struct {
        path: []u8,
        stage: enum { tree, branch } = .tree,
        force_tree: bool = false,
        dirty: u32 = 0,
    };

    pub fn deinit(c: ConfirmPurpose, gpa: Allocator) void {
        switch (c) {
            .delete_path, .remove_integration, .remove_claude_account, .delete_session, .session_worktree_merge, .remove_script, .layout_load, .layout_overwrite => |s| gpa.free(s),
            .layout_delete => |d| gpa.free(d.name),
            .script_install => |i| {
                gpa.free(i.dir);
                gpa.free(i.name);
                gpa.free(i.url);
            },
            .session_worktree_remove => |r| gpa.free(r.path),
            .http_delete_request => |t| t.deinit(gpa),
            .delete_paths => |d| {
                for (d.paths) |p| gpa.free(p);
                gpa.free(d.paths);
            },
            .kill_pids => |p| gpa.free(p),
            .cloud_cancel => |p| gpa.free(p),
            .move_path => |m| {
                gpa.free(m.from);
                gpa.free(m.into);
            },
            else => {},
        }
    }
};
pub const PickerKind = enum {
    integrations_details,
    integrations_manifest,
    integrations_toggle,
    integrations_remove,
    integrations_copy_id,
    integrations_pin,
    integrations_unpin,
    integrations_toggle_bar,
    buffers,
    files,
    recent,
    /// `find.live_grep`: the workspace grep behind the picker overlay —
    /// the query is the pattern, not a filter (`app/grep_picker.zig`).
    grep,
    commands,
    tabs,
    themes,
    go_run_cmd,
    tools,
    tasks,
    lua,
    git,
    ai_suggest_backend,
    ai_session,
    dap_remove_watch,
    dap_exceptions,
    dap_threads,
    lsp_locations,
    lsp_code_actions,
    lsp_symbols,
    snippets,
    http_env_vars,
    http_env_delete,
    http_env_pick,
    http_history,
    http_captured,
    http_chains,
    auth_presets,
    cookies_show,
    cookies_delete,
    http_insert_header,
    http_copy_as,
    http_lookup_file,
    http_lookup_item,
    /// `http.find_request`: every block of every request file.
    http_find_request,
    /// `http.move_request`: the collection folders.
    http_move_target,
    ws_history,
    browser_device,
    browser_throttle,
    browser_url_history,
    /// `browser.switch_tab`: the pane's page and the popups it opened.
    browser_tab,
    /// `integrations.icon_picker`: the Nerd Font catalog (`app/icon_picker.zig`).
    icon_glyphs,
    /// `bookmarks.open`: the label rows, the URL as the detail.
    bookmarks,
    /// A picker whose accept is the opener's own function
    /// (`Overlay.picker.on_accept`): messages, harpoon, the startup picker.
    custom,
};

/// The accept of a `.custom` picker: the row's unfiltered index and its
/// label (a frame copy — the overlay is already gone when this runs).
pub const PickerAccept = *const fn (app: *App, idx: usize, label: []const u8) Allocator.Error!void;

/// The on-demand read-only overlays: `view.about` /
/// `view.discovery`. A click anywhere dismisses them.
pub const InfoKind = enum { about };

/// One row of the live-grep picker: where its hit is, so the preview
/// column and the accept both know the file without re-parsing a label.
pub const GrepRow = struct { path: []u8, line: u32, col: u32, len: u32 };

pub const Overlay = union(enum) {
    none,
    prompt: struct {
        state: Prompt.State,
        purpose: PromptPurpose,
        /// A title built at open time (`Replace 3× "q" with`); the
        /// state borrows it.
        title_owned: ?[]u8 = null,
        /// Where focus goes when the prompt closes — Esc or Enter. The
        /// tree's prompts name `.tree`, so cancelling a rename does not
        /// leave the arrow keys editing the file (`FocusId` is a plain
        /// value; null is the active pane).
        return_focus: ?FocusId = null,
    },
    confirm: struct {
        state: Confirm.State,
        purpose: ConfirmPurpose,
        message: []u8,
        /// As the prompt's: where focus goes when the box closes. The
        /// tree's delete names `.tree`, so the mode chip reads TREE
        /// under the box and the arrows keep walking rows after it.
        return_focus: ?FocusId = null,
    },
    info: InfoKind,
    /// `view.discovery`: the click-target panel (`app/discovery.zig`).
    discovery,
    /// `view.help` / F1: the keymap reference (`ui/help_overlay.zig`,
    /// rows from `app/help.zig`).
    help: HelpUi.State,
    which_key: whichkey.State,
    picker: struct {
        state: Picker.State,
        kind: PickerKind,
        /// Owned labels, one per candidate (a workspace-relative path
        /// for the files picker).
        labels: [][]u8,
        /// Parallel to `labels` for the buffers picker; empty otherwise.
        panes: []PaneId,
        /// Parallel to `labels`: the muted right-hand text (a command
        /// id, a path); empty when the picker has none.
        details: [][]u8 = &.{},
        /// Parallel to `labels`: the chord hint after the label; an
        /// empty string paints nothing.
        hints: [][]u8 = &.{},
        /// Parallel to `labels` (or empty): what the accept acts on when
        /// that is not the label — the session picker's rows are named
        /// for people and accept the session id.
        values: [][]u8 = &.{},
        /// Parallel to `labels` (or empty): Rust's `PickerItem.priority`
        /// — a tier that always beats the score (the file picker pins
        /// workspace files over cross-workspace recents with it).
        priority: []u8 = &.{},
        /// Parallel to `labels` (or empty): Rust's `score_bonus`, added
        /// to the fuzzy score (the palette's pane-scoped +20).
        score_bonus: []i64 = &.{},
        /// Parallel to `labels` (or empty): the tie-break before index
        /// (the palette's recents, newest first; `Picker.RankOpts.order`).
        order: []u32 = &.{},
        /// Indices into `labels` in filtered order.
        filtered: std.ArrayListUnmanaged(u32),
        /// The themes picker previews as the cursor moves; Esc puts
        /// this one back.
        restore_theme: ?*const theme_mod = null,
        /// `.custom` only.
        on_accept: ?PickerAccept = null,
        /// `.custom` only: Shift+Delete on a row asks this to remove
        /// what the row names (the layouts picker's delete). It answers
        /// through the shared confirm; the title says the key.
        on_delete: ?PickerAccept = null,
        /// // changed (lua-plumbing): parallel to `labels` — the row's
        /// glyph, empty for none.
        icons: [][]u8 = &.{},
        /// Parallel to `labels`: Tab-marked rows of a multi-select
        /// picker. Empty when the picker is single-select.
        marked: []bool = &.{},
        /// The cursor row's preview column, gpa-owned (its segment texts
        /// too), refilled when the cursor moves.
        preview: [][]Picker.PreviewSegment = &.{},
        /// Parallel to `labels` on a `.grep` picker: the hit each row
        /// points at. Empty for every other kind.
        grep_hits: []GrepRow = &.{},
        /// A `.lua` source that answers again as the query changes: its
        /// id, the Lua state that registered it, and when the debounced
        /// re-run is due.
        lua_source: []u8 = &.{},
        lua_state: u16 = 0,
        requery_at_ms: ?i64 = null,
        /// Where Esc sends focus: the tree or a panel the picker was
        /// opened from (VS Code's Esc from Quick Open goes back to the
        /// Explorer); null is the active pane. An accept goes to what
        /// it opened.
        return_focus: ?FocusId = null,
    },
    /// A context menu (a panel row's kebab, a chip's right-click).
    menu: MenuState,
    /// The settings overlay (`view.settings`).
    settings: settings_app.State,
    /// The first-launch wizard (`first_launch.show`).
    wizard: first_launch.State,
    /// `jobs.show`: the background jobs (`app/jobs.zig`).
    jobs: JobsView.Panel.State,

    /// The preview column's rows and their segment texts (gpa).
    pub fn freePreview(gpa: Allocator, rows: [][]Picker.PreviewSegment) void {
        for (rows) |row| {
            for (row) |seg| gpa.free(seg.text);
            gpa.free(row);
        }
        gpa.free(rows);
    }

    pub fn deinit(self: *Overlay, gpa: Allocator) void {
        switch (self.*) {
            .none, .which_key, .info, .discovery, .wizard => {},
            .help => |*h| h.deinit(gpa),
            .settings => |*s| s.deinit(gpa),
            .jobs => |*j| j.deinit(gpa),
            .menu => |*m| {
                m.closeSub(gpa);
                gpa.free(m.items);
                gpa.free(m.title);
                if (m.mem) |*arena| arena.deinit();
            },
            .prompt => |*p| {
                Prompt.deinit(&p.state, gpa);
                if (p.title_owned) |t| gpa.free(t);
                p.purpose.deinit(gpa);
            },
            .confirm => |*c| {
                gpa.free(c.message);
                c.purpose.deinit(gpa);
            },
            .picker => |*p| {
                p.state.deinit(gpa);
                for (p.labels) |l| gpa.free(l);
                gpa.free(p.labels);
                gpa.free(p.panes);
                for (p.details) |d| gpa.free(d);
                gpa.free(p.details);
                for (p.hints) |h| gpa.free(h);
                gpa.free(p.hints);
                for (p.values) |v| gpa.free(v);
                gpa.free(p.values);
                for (p.icons) |i| gpa.free(i);
                gpa.free(p.icons);
                gpa.free(p.marked);
                freePreview(gpa, p.preview);
                for (p.grep_hits) |h| gpa.free(h.path);
                gpa.free(p.grep_hits);
                gpa.free(p.lua_source);
                gpa.free(p.priority);
                gpa.free(p.score_bonus);
                gpa.free(p.order);
                p.filtered.deinit(gpa);
            },
        }
        self.* = .none;
    }
};

/// A context menu: rows the opener built (gpa-owned slice, literal
/// labels), anchored at the cell that was clicked. `MenuAction` names a
/// static command by enum, so a row cannot point at a missing id.
pub const MenuFollow = enum { cursor, window };

pub const MenuState = struct {
    /// gpa-owned: `openMenu` copies what the opener passed, so a title
    /// built in the frame arena (a SEARCH row's `path:line`) or a
    /// snapshot arena survives the frame and the next rescan.
    title: []u8,
    items: []command.MenuItem,
    x: u16,
    y: u16,
    cursor: usize = 0,
    /// The first row painted when the menu is taller than the screen;
    /// the paint clamps it and, per `follow`, pulls it after the cursor
    /// (a key moved the cursor) or the cursor after it (the wheel
    /// moved the window).
    scroll: usize = 0,
    follow: MenuFollow = .cursor,
    /// Where the keyboard goes back to when the menu closes.
    return_focus: FocusId,
    /// The `+` menu: rows can be pinned / hidden (`→` on a leaf row
    /// opens the curation submenu; the kebab at the row's end too).
    curatable: bool = false,
    /// The open child menu, if any — its rows are a gpa copy.
    sub: ?SubMenu = null,
    /// A menu-bar dropdown: Rust's `menu_bar.rs` row shape (a marker
    /// column, the icon column, no title) rather than the context
    /// menu's (`app/render.zig`'s `drawMenu`).
    dropdown: bool = false,
    /// Whether the cursor row paints highlighted. A mouse-opened
    /// dropdown starts without one, as Rust's; a hover or an arrow
    /// turns it on. Enter still runs the cursor row either way.
    highlight: bool = true,
    /// Owns labels built for this open (a count in a label, an
    /// integration's name); freed with the menu.
    mem: ?std.heap.ArenaAllocator = null,

    pub const SubMenu = struct {
        /// The parent row it hangs off.
        parent: usize,
        items: []command.MenuItem,
        cursor: usize = 0,
        scroll: usize = 0,
        follow: MenuFollow = .cursor,
        /// A fresh child paints no highlight until it is hovered or
        /// arrowed (Rust's child `ContextMenu` starts un-`interacted`).
        highlight: bool = false,
        /// Where the frame painted it (`drawMenu`), for a click.
        rect: @import("ui/rect.zig") = .{},
    };

    pub fn closeSub(m: *MenuState, gpa: Allocator) void {
        if (m.sub) |sub| gpa.free(sub.items);
        m.sub = null;
    }

    /// The row the keyboard is on: the child's when one is open.
    pub fn focusedItem(m: *const MenuState) ?command.MenuItem {
        if (m.sub) |sub| return if (sub.cursor < sub.items.len) sub.items[sub.cursor] else null;
        return if (m.cursor < m.items.len) m.items[m.cursor] else null;
    }
};

/// The find bar docked under the active pane while it is open.
pub const FindBarState = struct {
    state: FindBar.State = .{},
    pane: PaneId,
    /// The pane's find state when the bar opened; Esc restores it.
    snapshot: ?FindState,
    snapshot_cursor: usize,
    /// vim `?`: the accept lands on the closest match before the cursor.
    reverse: bool = false,
    /// `d/pat<CR>`: the bar is a pending operator's motion; Enter hands
    /// the match to the operator, Esc (or no match) drops it.
    operator: bool = false,
    /// Enter chains straight into the replace prompt (VS Code `Ctrl+H`).
    chain_to_replace: bool = false,
    /// An Enter (or a step) has put the cursor on a match of this
    /// query; the next Enter steps instead of landing again.
    landed: bool = false,
    /// Where `↑` / `↓` are in `App.find_history`; `len` is the live query.
    hist_cursor: usize = 0,
    /// vim's `/b<Up>`: the query typed before the walk began — only the
    /// entries that start with it are recalled (`:help c_<Up>`).
    /// gpa-owned; null outside a walk.
    hist_prefix: ?[]u8 = null,
};

/// Visual-block `I` / `A` / `c` in flight: the typed run on the first
/// row is replayed on the others once Insert mode ends.
/// `eol`: `$A` — the typed run goes to every row's end, whatever its length.
/// A visual-block `I` / `A` / `c` in flight. `col` is a display column:
/// where `I` / `c` type, or the column after the block for `A`.
pub const BlockInsert = struct { pane: PaneId, first_row: usize, last_row: usize, col: usize, start_byte: usize, len_before: usize, eol: bool = false, append: bool = false, left_col: usize = 0 };
/// `<count>i` / `I` / `a` / `A` / `o` / `O` in flight: what was typed
/// replicates on Esc — as whole new lines for `o` / `O`, in place for
/// the other four (`:help count`).
pub const RepeatInsert = struct { pane: PaneId, count: u32, kind: input.RepeatInsertKind, start_byte: usize, len_before: usize };

pub const ClosedBuffer = struct { path: []u8, cursor: usize };

/// `ui.click_echo`: a byte range of one pane underlined for `click_echo_ms`.
pub const ClickEcho = struct { pane: PaneId, start: usize, end: usize, until_ms: i64 };
pub const click_echo_ms: i64 = 120;

/// A closed tab page, for `tab.reopen`: the files it showed (absolute,
/// owned) and which of them was active. The page's split tree is not
/// kept — closing a page closes its clean panes, so the files come
/// back as tabs of one leaf.
pub const ClosedTab = struct {
    paths: [][]u8,
    active: usize,

    pub fn deinit(self: *ClosedTab, gpa: Allocator) void {
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
    }
};

/// A mouse gesture in flight: what the press landed on, until release.
pub const Drag = union(enum) {
    /// A left press on a button (`dispatch.firesOnRelease`): armed, not
    /// fired. The release fires it when it lands on the same target —
    /// a press the pointer slides off is taken back, as a GUI button's
    /// is. A tab's close badge dragged off becomes that tab's drag.
    button: struct { target: PressedButton, rect: Rect, x: u16, y: u16 },
    /// A split's divider, by the split node it belongs to.
    divider: struct { split: layout_mod.NodeId, dir: layout_mod.SplitDir },
    tree_divider,
    right_divider,
    /// // changed (bottom-dock): the row above the dock.
    bottom_divider,
    /// The rule above the info view: its height (`info_view.dragTo`).
    info_divider,
    /// A tab off a leaf's strip. `moved` once the pointer has left
    /// the cell it pressed on — a press-and-release is a click.
    tab: struct { pane: PaneId, x: u16, y: u16, moved: bool = false },
    /// A tree row: a file opens in the pane it is released over, or
    /// moves into the folder it is released on.
    /// `copy`: the press carried Alt — the drop copies instead of moving.
    /// `clicks` is the press's place in a run (`dispatch.clickCount`):
    /// one opens the row as a glance, two keeps it.
    tree: struct { idx: usize, moved: bool = false, copy: bool = false, clicks: u8 = 1 },
    /// A text selection: char / word / line granularity from the click
    /// count, anchored where the press landed.
    select: struct { pane: PaneId, unit: SelectUnit, anchor: usize },
    /// The editor scrollbar thumb; `grab` is the row inside the thumb
    /// the pointer took hold of.
    scrollbar: struct { pane: PaneId, grab: u16 },
    /// Any other scrollbar (a panel's, the tree's, a list pane's, the
    /// picker's): the pointer's row on the track lands the view
    /// proportionally until the release, wherever the pointer goes.
    bar: hit.Owner,
    /// A dock widget's title bar; `moved` once the pointer left the cell.
    dock: DockDrag,
    /// A graph pane's detail divider.
    graph_divider: PaneId,
    /// A diff pane's row press: the rows dragged over select
    /// (`git.dragDiffSelect`); `anchor` is the pressed row.
    diff_select: struct { pane: PaneId, anchor: usize },
    /// A terminal pane's text: the pane keeps the anchor
    /// (`pty_pane.selectDrag`).
    pty_select: PaneId,
};
pub const DockDrag = struct { id: u32, x: u16, y: u16, moved: bool = false };
pub const SelectUnit = enum { char, word, line };

/// The last left press, for double / triple clicks.
pub const LastClick = struct { at_ms: i64, x: u16, y: u16, count: u8 };
pub const double_click_ms: i64 = 450;

/// Where `g;` / `g,` stand in the change list; `len` detects a list that
/// grew since (a fresh edit restarts from the newest entry).
pub const ChangeNav = struct { idx: usize, len: usize };

/// An insert-mode `Ctrl+N` / `Ctrl+P` cycle in progress
/// (`cmd_editor.zig`). A press that finds the buffer where the last
/// one left it steps to the next candidate; anything else starts over.
pub const KeywordComplete = struct {
    pane: PaneId,
    /// The byte range of the prefix typed before the first press.
    prefix: [2]usize,
    /// Distinct words extending the prefix, in the first press's order
    /// (nearest first, wrapping). gpa-owned.
    candidates: [][]u8,
    /// The candidate in the buffer now; `candidates.len` is the bare prefix.
    idx: usize,
    /// Bytes sitting after the prefix right now.
    inserted: usize,
    /// The first press was `Ctrl+P`.
    back: bool,
    /// The buffer after our last edit; a drift means another edit happened.
    cursor: usize,
    len: usize,

    pub fn deinit(self: *KeywordComplete, gpa: Allocator) void {
        for (self.candidates) |w| gpa.free(w);
        gpa.free(self.candidates);
    }
};

/// The target a `Drag.button` armed; only payloads that outlive the
/// frame (no slices into the frame's hit map).
pub const PressedButton = union(enum) {
    tab_close: hit.TabRef,
    button: u32,

    pub fn target(b: PressedButton) hit.HitTarget {
        return switch (b) {
            .tab_close => |t| .{ .tab_close = t },
            .button => |id| .{ .button = id },
        };
    }
};

pub const ChordChain = struct {
    seq: [keymap.max_seq]key_mod.Chord = undefined,
    len: usize = 0,
    deadline_ms: ?i64 = null,
    fallback: ?keymap.Target = null,
    /// The standard profile's `Ctrl+K` popup is up: the chain outlived
    /// the chord timeout and waits for its next key with no deadline,
    /// as VS Code waits after `Ctrl+K` (`dispatch.expireChords`); the
    /// popup lists the keymap's continuations of `seq`.
    menu: bool = false,

    pub fn clear(c: *ChordChain, gpa: Allocator) void {
        c.len = 0;
        c.deadline_ms = null;
        c.menu = false;
        if (c.fallback) |f| switch (f) {
            .named => |s| gpa.free(s),
            .static => {},
        };
        c.fallback = null;
    }
};

pub const ToastLevel = enum { info, warn, err };

/// The thing to DO about a message, offered on the toast that carries
/// it as a ` label ` button.
///
/// A toast that reports a missing dependency and then vanishes leaves
/// the user to copy a command out of a widget that is already gone. The
/// two shapes are deliberately the only two: neither installs anything
/// behind the user's back.
pub const ToastAction = union(enum) {
    /// Run a command in a VISIBLE terminal pane — never a silent
    /// background install. The user sees the command, its output and
    /// its exit status; a three-second widget is not the place to hide
    /// `brew install` behind one click.
    run_in_terminal: struct { label: []u8, cmd: []u8 },
    /// Open the integration's marketplace row, where its description,
    /// version and source are readable before anything is fetched.
    marketplace: struct { label: []u8, id: []u8 },
    /// Relaunch mnml. Nothing is installed and nothing is hidden: the
    /// offer is mnml acting on itself, for the changes a running
    /// process cannot pick up — a font it has already handed to the
    /// terminal, a config the loader read at start.
    restart: struct { label: []u8 },
    /// Run a command by id. What a mounted integration's toast offers
    /// (`wire.ToastAction.command`) — its own id or one of mnml's,
    /// resolved through the registry a key or the palette would use.
    /// Never a shell line: a pane cannot name one here.
    ///
    /// `pane` is the pane whose toast it was, focused before the
    /// command runs: a `Retry` offered by a refresh that failed has to
    /// land on the pane that failed, not on whichever one happens to
    /// be in front when the reader gets round to pressing it.
    command: struct { label: []u8, id: []u8, pane: ?PaneId = null },
    /// Open a page. The other half of an integration's offer
    /// (`wire.ToastAction.url`), and the reason the merge that took
    /// the pull request off the list still has a door to it.
    open_url: struct { label: []u8, url: []u8 },

    pub fn label(self: ToastAction) []const u8 {
        return switch (self) {
            inline else => |a| a.label,
        };
    }

    pub fn deinit(self: ToastAction, gpa: Allocator) void {
        switch (self) {
            inline else => |a| {
                gpa.free(a.label);
                switch (self) {
                    .run_in_terminal => |r| gpa.free(r.cmd),
                    .marketplace => |m| gpa.free(m.id),
                    .command => |c| gpa.free(c.id),
                    .open_url => |u| gpa.free(u.url),
                    .restart => {},
                }
            },
        }
    }
};

pub const Toast = struct {
    text: []u8,
    level: ToastLevel,
    expires_ms: i64,
    /// Stays until dismissed by id (IPC `toast_persistent`).
    id: ?[]u8 = null,
    /// The same text again while this one is up bumps this instead of
    /// stacking a twin.
    repeats: u32 = 1,
    /// What to do about the message. Owned — never the frame arena: the
    /// toast outlives the frame it was made on.
    action: ?ToastAction = null,
    /// The command invocation that raised it, when a command did — what
    /// a later toast from the same command replaces (`toastLevel`).
    source: ?ToastSource = null,
    /// `now_ms` when it was raised (or last replaced).
    raised_ms: i64 = 0,
};

/// Who raised a toast: the command (`App.running_cmd`) and which run of
/// it (`App.running_serial`), so a command's second run replaces its
/// first run's toast while the toasts of one run still stack.
pub const ToastSource = struct {
    cmd: command.CommandRef,
    run: u64,

    pub fn sameCommand(a: ToastSource, b: ToastSource) bool {
        return switch (a.cmd) {
            .static => |id| b.cmd == .static and b.cmd.static == id,
            .dyn => |slot| b.cmd == .dyn and b.cmd.dyn == slot,
        };
    }
};

/// A toast from the same command within this long of the last one
/// replaces it rather than stacking (`dock: hidden` then `dock: always`
/// is one box that changed, not two).
pub const toast_coalesce_ms: i64 = 4000;

/// How long the Undo chip stays offered.
pub const undo_chip_ttl_ms: i64 = 10_000;

/// The Undo chip: what a click puts back.
pub const UndoChip = struct {
    /// Owned: `closed 3 tabs`.
    label: []u8,
    action: Action,
    expires_ms: i64,

    pub const Action = union(enum) {
        /// `buffer.reopen` this many times; then the tab "close others"
        /// kept goes back to index `keep_at` of its strip (the reopens
        /// land after it) and is active again, if it is still open.
        reopen: struct { n: usize, keep: ?PaneId = null, keep_at: usize = 0 },
    };
};

/// Tab-completion state on the `:` line: the candidates for the prefix
/// typed, and which one is showing.
pub const CmdComplete = struct {
    prefix: []u8,
    candidates: [][]u8,
    idx: usize,
    /// Esc on the `:` line put the popup away for this prefix
    /// (`app/cmdline_popup.zig`); the ring still serves Tab.
    dismissed: bool = false,

    pub fn deinit(self: *CmdComplete, gpa: Allocator) void {
        gpa.free(self.prefix);
        for (self.candidates) |c| gpa.free(c);
        gpa.free(self.candidates);
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    frame: alloc.FrameArena,
    /// On the heap, not in the struct: the App is built on `initWith`'s
    /// stack and moved to its caller, and a worker a script starts while
    /// it loads (`init.lua`'s `task.run`) keeps the queue's address. A
    /// queue inside the struct would leave that worker posting into a
    /// dead stack frame — no event ever arrived, and the post parked
    /// forever, so quitting hung in `App.deinit`.
    events: *event.EventQueue,
    diag: command.Diag = .{},
    /// The command `command.run` is inside, for a runner that has to
    /// come back to it later (an LSP request that waited for its server).
    running_cmd: ?command.CommandRef = null,
    /// Which run of `running_cmd` this is — `command.run` numbers every
    /// run (`cmd_runs`); a toast keeps it (`ToastSource`).
    running_serial: u64 = 0,
    cmd_runs: u64 = 0,
    cfg: Config,
    /// Owns the arena `cfg` borrows from; null when `cfg` is `Config{}`.
    loaded: ?config.Loaded = null,
    /// `cfg.editor.input_style` in the input layer's own enum — the one
    /// place the two are reconciled (`setInputStyle` keeps them level).
    input_style: input.Style,
    theme: theme_mod = theme_mod.default,
    /// Absolute. Owned.
    workspace: []u8,
    /// `workspace` is the scratch folder `initWith` made for this App
    /// (`scratch_workspace`); `deinit` removes it.
    owns_workspace: bool = false,
    data_root: []u8,
    /// What a spawned child inherits. Owned.
    env: std.process.Environ.Map,
    /// The terminal mnml runs in has the focus (its own focus reports;
    /// true until one says otherwise).
    host_focused: bool = true,
    quit: bool = false,
    /// What the process exits with once `quit` is set: `:cq` asks for 1.
    exit_code: u8 = 0,
    /// The pane that was active before the current one (`buffer.last`).
    prev_active: ?PaneId = null,
    /// Every pane in most-recently-focused order, the active one first
    /// (`buffer.last` reads the second entry, `buffer.clear_mru` wipes
    /// it). A closed pane leaves the list.
    pane_mru: std.ArrayListUnmanaged(PaneId) = .empty,
    /// The tab pages closed by `tab.close` / `tab.only`, oldest first;
    /// `tab.reopen` pops the last. Capped at `max_closed_tabs`.
    closed_tabs: std.ArrayListUnmanaged(ClosedTab) = .empty,
    restart: bool = false,

    panes: PaneStore,
    /// The open documents — one per file however many panes show it.
    /// Outlives `panes`: a pane's buffer releases its document here.
    docs: *DocStore,
    layouts: LayoutState,
    tree: tree_mod.Tree,
    /// The sidebar's info view (`app/info_view.zig`).
    info_view: info_view_app.State = .{},
    /// Which side each activity section lives on and what each column
    /// shows (`app/side.zig`). Seeded from the config in `init`.
    side: side_mod.State,
    /// // changed (bottom-dock): the dock's hosted panes — the section
    /// it shows is `side.open.get(.bottom)` like any other host.
    bottom: bottom_mod.State = .{},
    /// The outline drawn in a column (`PanelId.outline`): a pane kept in
    /// the store, outside the layout. `outline.show` routes here when
    /// the outline's column is open.
    outline_panel: ?PaneId = null,
    todos: todos.State,
    /// The parse workers of documents too large to parse in a frame.
    syntax_jobs: syntax_jobs.State = .{},
    /// Every background job, running and the last fifty finished
    /// (`app/jobs.zig`) — the statusline chip and the JOBS overlay.
    jobs: jobs_mod.State = .{},
    notes: notes.State,
    findings: findings.State,
    sessions: sessions.State,
    /// // changed (welcome): the start surface's cursors
    /// (`app/welcome.zig`).
    welcome: welcome_mod.State = .{},
    /// // changed (sessiondiff): what each AI session changed — the
    /// records live on their pty panes; this is the token counter.
    session_changes: session_changes_mod.State = .{},
    /// // changed (lua-track): the SCRIPTS section's list state.
    scripts_panel: scripts_panel.State = .{},
    /// // changed (lua-plumbing): the lists `mnml.list{}` registered —
    /// the pane form and the rail-section form both read them. Cleared
    /// with the Lua state on `script.reload`.
    script_lists: script_list.Store = .{},
    /// // changed (lua-plumbing): the rail sections `mnml.section{}`
    /// registered (`app/script_section.zig`).
    script_sections: script_section.Store = .{},
    /// // changed (search-section): the SEARCH section's query and hits.
    search_section: search_section.State,
    /// The live-grep picker's worker (`app/grep_picker.zig`).
    grep_picker: grep_picker.State,
    dock: dock.State = .{},
    /// The editor body before the dock's inline strips came off it.
    dock_area: Rect = .{},
    git: git_app.State,
    /// Git mode: the palette in the sidebar (`app/git_palette.zig`).
    git_palette: git_palette_app.State = .{},
    snippets: snippets.State,
    ai: ai_app.State = .{},
    copilot: copilot_app.State = .{},
    dap: dap.State = .{},
    /// The DEBUG section's cursor, folds and last-stop values.
    debug_panel: debug_panel.State = .{},
    lsp: lsp.State = .{},
    /// The hidden tasks a script started (`app/script_task.zig`).
    script_tasks: script_task.State = .{},
    /// The two debounced hooks the tick fires (`app/idle.zig`).
    idle: idle.State = .{},
    autosave: autosave.State = .{},
    /// What the scripts painted into the editors and published as
    /// diagnostics (`app/script_decor.zig`); dropped by a reload.
    script_decor: script_decor.State = .{},
    focus: FocusId = .tree,
    active: ?PaneId = null,
    /// The editor pane most recently active — a runner pane taking
    /// focus must not lose the file's directory (monorepo detection).
    last_editor: ?PaneId = null,
    runners: runners.State = .{},
    /// The workspace's one scratch terminal (`term.scratch_toggle`),
    /// alive while hidden; null until the first toggle or once closed.
    scratch_pty: ?PaneId = null,
    /// The split ratio the scratch terminal had when Ctrl+` hid it — a
    /// dragged divider comes back where it was, as VS Code's panel does.
    scratch_ratio: ?u16 = null,
    tasks: tasks_mod.State = .{},
    http: http_app.State,
    http_panel: http_panel.State,
    integrations: integrations.State,
    marketplace: marketplace.State = .{},
    /// The installed Nerd Fonts and the latest release (`app/font_scan.zig`).
    fonts: font_scan.State,
    /// A host's statusline segments and activity badges (`ipc/effects.zig`).
    ipc_fx: ipc.effects.State = .{},
    /// The workspace's Playwright outcome history (`app/flaky.zig`).
    flaky: flaky.State = .{},
    native_notify: bool = false,
    /// A real terminal is drawing the cursor this frame asks for. The
    /// terminal loop says yes; headless and the tests paint their own.
    term_cursor: bool = false,
    /// See `InitOptions.live_frames`.
    live_frames: bool = false,
    hits: hit.HitMap = .{},
    /// Where the pointer last was; the frame paints hover affordances
    /// (a row's kebab) from it.
    hover: ?struct { x: u16, y: u16 } = null,
    /// The pointer got here by moving, not by a press: the hover
    /// tooltip and the rail's info box read this (`discovery.zig`).
    hover_live: bool = false,
    /// // changed (sidebar-autohide): the frame's dwell zones — which
    /// chrome the pointer is resting on, and since when
    /// (`app/hover_zones.zig`). The menu bar, the activity bar and the
    /// side columns all read their `auto` answer out of it.
    hover_zones: hover_zones.State = .{},
    /// // changed (sidebar-autohide): `ui.sidebar = .auto` — which
    /// column the overlay is carrying, where it is in its slide, and
    /// the session's pin (`app/sidebar_auto.zig`).
    sidebar_auto: sidebar_auto.State = .{},
    /// `ui.focus_follows_mouse`: the held button and the dwell (`app/focus_follow.zig`).
    focus_follow: focus_follow.State = .{},
    /// // changed (launcher-dock): `ui.dock` — the launcher strip's
    /// reveal, its session pin and its keyboard cursor
    /// (`app/launcher_dock.zig`). Neither the bottom panel (`bottom`)
    /// nor the dock widgets (`dock`).
    launcher_dock: launcher_dock_mod.State = .{},
    /// // changed (railmove): `ui.rail.hidden` after a hide / show —
    /// the config field points at a slice this owns until the next
    /// reload (`app/activity_bar.zig`).
    activity_bar: activity_bar_mod.State = .{},
    /// The mouse gesture in flight, press to release.
    drag: ?Drag = null,
    /// Set while `dispatch.mouse` replays an armed button's press on its
    /// release, so the replay routes instead of arming again.
    firing_button: ?PressedButton = null,
    last_click: ?LastClick = null,
    /// Wheel events folded until the next tick (`scroll.zig`).
    wheel: scroll_mod.Coalescer = .{},
    /// The wheel's acceleration state (`scroll.zig`).
    accel: scroll_mod.Accel = .{},
    /// The lines the batch being dispatched may move once budgeted
    /// (`dispatch.wheelLines`); null until an arm asks, cleared per
    /// dispatch so the budget is spent once.
    wheel_budget: ?u16 = null,
    /// The last event dispatched was a wheel batch: nothing but a
    /// scroll has changed since the frame that registered the hit map,
    /// so the next batch routes against it without a render between —
    /// as Rust's every wheel event routes against its last frame's
    /// rects. Any other event clears it.
    last_was_wheel: bool = false,
    /// A host's `mouse_down` over the channel is held until its
    /// `mouse_up`, so a `mouse_move` between them is a drag
    /// (`ipc.effects.applyInput`).
    ipc_button_held: bool = false,
    /// The split tree's area at the last render — what a divider drag
    /// and the focus motions measure against.
    panes_area: Rect = .{},
    /// Files opened, newest last (`picker.recent`). Owned paths.
    recent: std.ArrayListUnmanaged([]u8) = .empty,
    /// The `:` lines run, oldest first (`q:`). Owned.
    cmd_history: std.ArrayListUnmanaged([]u8) = .empty,
    /// The ids of the commands that ran, newest first, de-duplicated,
    /// at most `max_recent_commands` (Rust's `recent_commands`):
    /// `picker.recent_commands` lists them and the empty palette pins
    /// them first, `★`-marked. `command.run` notes each success;
    /// `session.zon` keeps the list.
    recent_commands: std.ArrayListUnmanaged([]u8) = .empty,
    screen: vaxis.Screen,
    /// Rows / text columns of the active pane at the last render; they
    /// size page motions and the wrap width.
    pane_rows: usize = 20,
    /// // changed (sessions-merge): a session needs input and
    /// `ui.session_bell` is on — the loop rings the terminal once.
    bell_pending: bool = false,
    /// Bytes for the host terminal itself, not the screen: a session
    /// notification's OSC 777 / OSC 9 and the bell riding with it
    /// (`hostWrite`). Only a terminal loop fills it (`host_tty`); it
    /// writes them raw after the tick and empties it.
    host_out: std.ArrayListUnmanaged(u8) = .empty,
    /// The terminal loop drains `host_out` — headless and the tests do
    /// not, so nothing collects there.
    host_tty: bool = false,
    /// The last `host_log_max` host writes, each whole, oldest first —
    /// what `status.json` reports as `hostEscapes`, so a headless run
    /// and a `.test` can see what the terminal would have been sent.
    /// Owned.
    host_log: std.ArrayListUnmanaged([]u8) = .empty,
    pane_cols: usize = 80,
    /// Where the last render put the terminal cursor, if visible.
    /// Written by every surface that takes typing as it draws; draw
    /// order is the precedence, so the last writer of a frame is the
    /// frontmost one (`app/cursor.zig`).
    cursor_pos: ?editor_view.Cursor = null,
    /// The shape that goes with `cursor_pos`. Reset to `bar` every
    /// frame — a text field is always a bar — and set by the two panes
    /// that have an opinion: an editor (from its mode) and a terminal
    /// pane (from its child's DECSCUSR).
    cursor_shape: cursor_mod.Shape = .bar,
    /// Whether that cursor blinks. Reset to `editor.cursor_blink` every
    /// frame; a terminal pane's child asks for its own.
    cursor_blink: bool = false,
    /// A pty child asked for this cursor, so `ui.cursor_shape` leaves
    /// it alone.
    cursor_from_child: bool = false,
    /// What the frame resolved: the one cursor, or null for hidden.
    /// `render` fills it, the terminal draws it, and `status.json`
    /// reports it so a headless script can see it too.
    cursor_out: ?cursor_mod.Want = null,

    clipboard: Clipboard,
    /// `mA`…`mZ`: cross-file marks, persisted (`marks_store.zig`).
    global_marks: marks_store.Map = .empty,
    keymap: keymap.Keymap,
    chord: ChordChain = .{},
    toasts: std.ArrayListUnmanaged(Toast) = .empty,
    /// The toast a right-click menu was opened on (an index into
    /// `toasts`); `toast.dismiss_clicked` / `copy_clicked` read it.
    toast_ctx: ?usize = null,
    /// The Undo chip beside the toast stack (`armUndo`): one click puts
    /// a destructive action back, a right-click drops the offer.
    undo_chip: ?UndoChip = null,
    /// The statusline clock (`app/clock.zig`).
    clock: clock.State = .{},
    /// The statusline coverage chip (`app/coverage.zig`).
    coverage: coverage.State = .{},
    now_playing: now_playing.State = .{},
    /// The statusline poller (`app/integration_poll.zig`): a manifest's
    /// counts stay live with no pane open.
    integration_poll: integration_poll.State = .{},
    /// The API brokers this mnml hosts while it runs
    /// (`app/broker.zig`): one queue per service in front of the
    /// shared token bucket, so the pane on screen goes before the
    /// warmers and the batch scripts.
    broker: broker_app.State = .{},
    /// The menu bar: the open menu, where its words painted (`app/menu_bar.zig`).
    menu_bar: menu_bar.State = .{},
    /// `ui.click_echo`: the word under a click, underlined until `until_ms`.
    click_echo: ?ClickEcho = null,
    /// `debug.toggle_click_inspector`: every press toasts the hit target
    /// under the pointer before it is handled.
    debug_click_inspector: bool = false,
    /// The panels whose automatic rescan is off (`app/auto_refresh.zig`).
    auto_refresh_off: std.EnumSet(PanelId) = std.EnumSet(PanelId).initEmpty(),
    /// The `+` menu's curation, seeded from `ui.plus_menu_pinned` /
    /// `plus_menu_hidden` and written back there (owned ids).
    plus_pinned: std.ArrayListUnmanaged([]u8) = .empty,
    plus_hidden: std.ArrayListUnmanaged([]u8) = .empty,
    /// The command a curation submenu was opened on (`menu.pin_row`…).
    menu_ctx: ?command.CommandId = null,
    /// How images reach the terminal (`image.detect`, set by the loop;
    /// `.none` headless — the text fallback paints instead).
    image_transport: image.Transport = .none,
    /// What this frame wants drawn over its cells (frame arena; reset
    /// at the top of `render`).
    image_paints: std.ArrayListUnmanaged(image.PaintRequest) = .empty,
    overlay: Overlay = .none,
    /// The wizard's answers while one of its install panes runs; the
    /// pane's exit puts them back (`first_launch.refresh`).
    wizard_stash: ?first_launch.State = null,
    /// Whether `claude` / `codex` resolve on PATH, as of `checked_ms`
    /// — the AI chips read it every frame (`first_launch_install.cliOnPath`).
    cli_probe: struct { claude: bool = false, codex: bool = false, checked_ms: ?i64 = null } = .{},
    /// The click-discovery panel's flash: the family a row press lit,
    /// until when (`discovery.flashRow`).
    discovery_flash: ?discovery_app.Flash = null,
    find_bar: ?FindBarState = null,
    /// Vim's one quickfix list (`app/quickfix.zig`).
    quickfix: @import("app/quickfix.zig").State = .{},
    /// The find bar's accepted queries, oldest first (`app/find_history.zig`).
    find_history: std.ArrayListUnmanaged([]u8) = .empty,
    closed: std.ArrayListUnmanaged(ClosedBuffer) = .empty,
    abbrevs: std.StringHashMapUnmanaged([]u8) = .empty,
    dyn_commands: command.DynRegistry,
    plugin_invocations: std.ArrayListUnmanaged([]u8) = .empty,
    hooks: hooks.Hooks,
    /// The `init.lua` state (D10), id 0. Reach it through `script()`,
    /// which points it at this App — the struct moves after `initWith`
    /// returns. Installed scripts get their OWN states, in `scripts`.
    lua: ?*scripting.Lua = null,
    /// // changed (lua-install): the installed scripts — one directory,
    /// one manifest and one Lua state each (`app/scripts.zig`).
    scripts: scripts_mod.Store = .{},
    /// Whether the workspace's exec-bearing config and `init.lua` apply.
    workspace_trusted: bool = false,
    /// A 0.2 `.mnml/config.toml` in the workspace with no `config.zon`
    /// beside it (gpa-owned path): never read, so the statusline's
    /// RESTRICTED chip is up and `workspace.review_trust` says why.
    /// `probeWorkspaceToml` keeps it current.
    workspace_toml: ?[]u8 = null,
    block_insert: ?BlockInsert = null,
    repeat_insert: ?RepeatInsert = null,
    /// Flash-motion labels while armed (`s<a><b>` on several matches).
    /// Reach it through `flash.current`, which drops a stale one.
    flash: ?flash_mod.State = null,
    cmd_complete: ?CmdComplete = null,
    /// The app's own `:` line (`app/cmdline.zig`) — the one `Ctrl+;`
    /// and a click on the bottom row open, in either profile and from
    /// any focus. The vim handler's per-buffer `:` is separate.
    cmdline: ?@import("app/cmdline.zig").State = null,
    /// The line range a `!` filter prompt applies to.
    filter_rows: ?[2]usize = null,
    /// vim `:set ic` / `noic`; null = smart case.
    search_case: ?bool = null,
    /// `g;` / `g,` position in the active editor's change list.
    change_nav: ?ChangeNav = null,
    /// The insert-mode keyword completion being cycled, if any.
    keyword_complete: ?KeywordComplete = null,
    /// `:command` definitions, name → expansion (both owned); persisted
    /// at `<data root>/commands.zon` (`ex_verbs.zig`).
    user_commands: std.StringHashMapUnmanaged([]u8) = .empty,
    /// `:!!` and `:r !!` repeat it. Owned.
    last_shell_cmd: ?[]u8 = null,
    /// The scratch pane `:!` writes its output to, while it is open.
    shell_pane: ?PaneId = null,
    /// What `:&` / a bare `:s` repeat.
    last_substitute: ?ex_verbs.LastSub = null,
    /// Vim's ONE "last search pattern" (`:help last-pattern`): `/`, `?`,
    /// `*`, `#`, `:s/pat/` and `:g/pat/` all write it, and an empty
    /// pattern in `:s//new/` or `:g//cmd` reads it back. Owned.
    last_search_pattern: ?[]u8 = null,
    /// The standard profile's search term: the find bar's query and
    /// toggles as Esc left them. F3 / Shift+F3 on a pane with no find
    /// live search for it (VS Code). Owned.
    find_term: ?cmd_find.FindTerm = null,
    /// A `:s///c` walking its matches.
    replace_confirm: ?ex_verbs.ReplaceConfirm = null,
    /// `:g` → user command → `:norm` → `:`… nesting, bounded by `ex_verbs.max_depth`.
    ex_depth: u8 = 0,
    /// A `:g` is running (a nested one is vim's E147).
    in_global: bool = false,
    now_ms: i64 = 0,
    /// `theme.auto_system`: when the OS appearance is next polled.
    theme_auto_poll_ms: ?i64 = null,
    /// When the file watcher last stat'ed the open files.
    last_watch_ms: i64 = 0,
    /// Frames since something changed; the loop skips idle renders.
    needs_render: bool = true,
    /// The picker preview column's highlighter (`app/picker_preview.zig`).
    /// One per app rather than one per build: it caches every grammar it
    /// loads, so walking a list of Zig files compiles that query once.
    preview_hl: ?@import("highlight").Highlighter = null,
    /// The toast history (`:messages`).
    messages: messages.State = .{},
    /// Zen: the editor and the `:` line, nothing else painted.
    zen: bool = false,
    /// When a plain Esc last armed the way out of full screen; a
    /// second within the chord timeout leaves (`zen.escKey`).
    zen_esc_ms: ?i64 = null,
    /// The `@a` replay in progress (`app/macro_replay.zig`), if any.
    macro_run: ?*@import("app/macro_replay.zig").Run = null,
    /// How deeply `dispatch.keyUnrecorded` is nested: a replay feeds its
    /// keys one level down from the key that started it.
    key_depth: u16 = 0,
    /// The key just dispatched failed the way vim beeps — a motion that
    /// could not move, a search with no match — which ends a replay.
    key_failed: bool = false,
    /// `Ctrl-W` from a non-editor pane: the next key names the window
    /// verb (`dispatch.paneCtrlWCommand`).
    pane_ctrl_w_pending: bool = false,
    /// Nine pinned files (`harpoon.*`).
    harpoon: harpoon.State = .{},
    /// Render durations for the statusline stress meter.
    stress: stress.Meter = .{},
    update: update.State = .{},
    session: session.State = .{},
    /// Background copies / moves (`transfers.zig`); the statusline chip
    /// and the `:qa` guard read it.
    transfers: transfers.State = .{},
    /// The file clipboard (`file.cut` / `file.copy` / `file.paste`).
    file_clipboard: file_clipboard.State = .{},
    /// The workspace trash's prune clock and bounds.
    trash: trash.State = .{},
    /// `nav.back` / `nav.forward`: where the cursor was before big jumps.
    jumplist: jumplist.State = .{},

    /// Every toast, sticky ones included — a guard, not a policy.
    pub const max_toasts = 32;
    /// Rust's `TOAST_STACK_MAX`: the transient stack keeps the five
    /// newest and drops the oldest, so a burst never queues up behind
    /// the `+K more…` chip for the next twenty seconds.
    pub const max_transient_toasts = 5;
    pub const max_closed = 32;
    pub const max_closed_tabs = 8;
    pub const max_recent = 50;
    pub const max_cmd_history = 200;
    pub const max_recent_commands = 50;

    /// An App on the defaults: 120×40, the standard keymap, workspace `.`.
    pub fn init(gpa: Allocator, io: Io) !App {
        return initWith(gpa, io, .{});
    }

    /// A test's "some directory": `initWith` makes a private empty
    /// folder for this App (`app/test_workspace.zig`) and `deinit`
    /// removes it. Tests only; the value is a marker, not a path.
    pub const scratch_workspace: []const u8 = "<scratch workspace>";

    pub fn initWith(gpa: Allocator, io: Io, opts_in: InitOptions) !App {
        var opts = opts_in;
        errdefer if (opts.loaded) |*l| l.deinit();
        const scratch = builtin.is_test and std.mem.eql(u8, opts.workspace, scratch_workspace);
        const ws = if (scratch) try test_workspace.create(gpa, io) else try gpa.dupe(u8, opts.workspace);
        errdefer {
            if (scratch) test_workspace.remove(io, ws);
            gpa.free(ws);
        }
        const dr = try gpa.dupe(u8, opts.data_root);
        errdefer gpa.free(dr);
        var env = if (opts.env) |e| try e.clone(gpa) else try processEnv(gpa);
        errdefer env.deinit();
        const events = try gpa.create(event.EventQueue);
        errdefer gpa.destroy(events);
        events.* = try event.EventQueue.init(gpa, 256);
        errdefer events.deinit(io);
        const style = styleOf(opts.cfg.editor.input_style);
        var km = try buildKeymap(gpa, style, opts.cfg.keys);
        errdefer km.deinit();
        var layouts = try LayoutState.init(gpa);
        errdefer layouts.deinit();
        var screen = try vaxis.Screen.init(gpa, .{ .cols = opts.cols, .rows = opts.rows, .x_pixel = 0, .y_pixel = 0 });
        errdefer screen.deinit(gpa);
        const docs = try DocStore.create(gpa);
        errdefer docs.destroy();
        screen.width_method = .unicode;
        var app: App = .{
            .gpa = gpa,
            .io = io,
            .frame = .init(gpa),
            .events = events,
            .cfg = opts.cfg,
            .loaded = opts.loaded,
            .input_style = style,
            .workspace = ws,
            .data_root = dr,
            .env = env,
            .panes = PaneStore.init(gpa, io),
            .docs = docs,
            .layouts = layouts,
            .tree = tree_mod.Tree.init(gpa),
            .side = side_mod.State.init(&opts.cfg),
            .todos = todos.State.init(gpa, panel_mod.ListSort.fromConfig(opts.cfg.ui.todos_sort)),
            .search_section = try search_section.State.init(gpa),
            .grep_picker = try grep_picker.State.init(gpa),
            .notes = notes.State.init(gpa, panel_mod.ListSort.fromConfig(opts.cfg.ui.notes_sort)),
            .findings = findings.State.init(gpa, panel_mod.ListSort.fromConfig(opts.cfg.ui.findings_sort)),
            .sessions = sessions.State.init(gpa, opts.cfg.ui.sessions_sort),
            .git = git_app.State.init(gpa),
            .snippets = snippets.State.init(gpa),
            .http = http_app.State.init(gpa),
            .http_panel = http_panel.State.init(gpa),
            .integrations = integrations.State.init(gpa),
            .fonts = font_scan.State.init(gpa),
            .screen = screen,
            .clipboard = Clipboard.init(gpa),
            .keymap = km,
            .dyn_commands = .init(gpa),
            .hooks = hooks.Hooks.init(gpa),
        };
        errdefer app.hooks.deinit();
        opts.loaded = null; // owned by `app` from here
        app.workspace_trusted = opts.workspace_trusted orelse (if (app.loaded) |l| l.workspace_trusted else false);
        app.owns_workspace = scratch;
        app.native_notify = opts.native_notify;
        app.term_cursor = opts.term_cursor;
        app.live_frames = opts.live_frames;
        // The `g<letter>` operator table is process-global (the vim
        // handler has no App). A state reopening clears only its own
        // claims, so a fresh App wipes the whole table once — otherwise
        // the last App's installed scripts would still own letters here.
        @import("input/script_ops.zig").clear(gpa);
        app.lua = try scripting.Lua.create(gpa, io, &app);
        errdefer app.lua.?.destroy();
        // D10.2: the first Zig hook subscriber — a save rescans the TODOs.
        try app.hooks.subscribe(.save_post, .{ .zig = &todos.onSavePost });
        try app.hooks.subscribe(.open, .{ .zig = &notes.onPathTouched });
        try app.hooks.subscribe(.save_post, .{ .zig = &notes.onPathTouched });
        try app.hooks.subscribe(.open, .{ .zig = &findings.onPathTouched });
        try app.hooks.subscribe(.save_post, .{ .zig = &findings.onPathTouched });
        try app.hooks.subscribe(.startup, .{ .zig = &tasks_mod.onStartup });
        try app.hooks.subscribe(.startup, .{ .zig = &ex_verbs.onStartup });
        try app.hooks.subscribe(.save_post, .{ .zig = &watch.onSavePost });
        try app.hooks.subscribe(.save_post, .{ .zig = &git_app.onSavePost });
        try app.hooks.subscribe(.open, .{ .zig = &git_app.onOpen });
        // A file opened / saved reaches its language server.
        try app.hooks.subscribe(.open, .{ .zig = &lsp.onOpen });
        try app.hooks.subscribe(.save_pre, .{ .zig = &lsp.onSavePre });
        try app.hooks.subscribe(.save_post, .{ .zig = &lsp.onSavePost });
        // Breakpoints that followed an edit reach a live adapter on save.
        try app.hooks.subscribe(.save_post, .{ .zig = &dap.onSavePost });
        // A saved `init.lua` reloads the scripts (`cmd_script.zig`);
        // a save under a dev root reloads that one script.
        try app.hooks.subscribe(.save_post, .{ .zig = &cmd_script.onSavePost });
        try app.hooks.subscribe(.save_post, .{ .zig = &scripts_mod.onSavePost });
        // The session comes back before anything else the startup hook
        // does, so the picker lands on the restored frame. The update
        // check is not a subscriber: it reaches GitHub, so only the
        // terminal loop starts it (`update.startupCheck`).
        try app.hooks.subscribe(.startup, .{ .zig = &session.onStartup });
        try app.hooks.subscribe(.startup, .{ .zig = &startup_picker.onStartup });
        try app.hooks.subscribe(.exit, .{ .zig = &session.onExit });
        try app.hooks.subscribe(.open, .{ .zig = &undo_store.onOpen });
        try app.hooks.subscribe(.save_post, .{ .zig = &undo_store.onSavePost });
        try app.hooks.subscribe(.startup, .{ .zig = &macros_store.onStartup });
        try app.hooks.subscribe(.exit, .{ .zig = &macros_store.onExit });
        try app.hooks.subscribe(.startup, .{ .zig = &find_history.onStartup });
        try app.hooks.subscribe(.exit, .{ .zig = &find_history.onExit });
        try app.hooks.subscribe(.startup, .{ .zig = &marks_store.onStartup });
        try app.hooks.subscribe(.exit, .{ .zig = &marks_store.onExit });
        // Installed integrations are scanned once the app is up.
        try app.hooks.subscribe(.startup, .{ .zig = &integrations.onStartup });
        // The installed Nerd Fonts, then the tofu check over the
        // manifests just scanned and the fonts just found.
        try app.hooks.subscribe(.startup, .{ .zig = &font_scan.onStartup });
        try app.hooks.subscribe(.startup, .{ .zig = &glyph_audit.onStartup });
        app.now_ms = nowMs(io);
        app.http.auto_format_body = app.cfg.http.auto_format_body;
        app.http.sync_normalize = app.cfg.http.sync_normalize;
        app.tree.width = app.cfg.ui.tree_width;
        // The sides come from the config; the explorer opens in its
        // column; `ui.right_panel_visible` opens the right column on
        // the first section that lives there. A restored session (the
        // `startup` hook) then overrides all of it.
        app.side = side_mod.State.init(&app.cfg);
        side_mod.place(&app, .explorer, false);
        if (app.cfg.ui.right_panel_visible) {
            var sbuf: [side_mod.Section.all.len]side_mod.Section = undefined;
            const on_right = side_mod.sectionsOn(&app, .right, &sbuf);
            if (on_right.len > 0) side_mod.place(&app, on_right[0], false);
        }
        // // changed (bottom-dock): the same for the dock — the
        // diagnostics live there, so that is what opens.
        if (app.cfg.ui.bottom_panel_visible) {
            var bbuf: [side_mod.Section.all.len]side_mod.Section = undefined;
            const on_bottom = side_mod.sectionsOn(&app, .bottom, &bbuf);
            if (on_bottom.len > 0) side_mod.place(&app, on_bottom[0], false);
        }
        try app.seedPlusMenu();
        auto_refresh.seed(&app);
        clock.seed(&app);
        try app.snippets.absorbConfig(app.cfg.snippets);
        try integrations.loadSettings(&app);
        try app.toastConfigDiagnostics();
        try app.noticeUnreadToml();
        try app.applyTheme();
        try trust_app.promptIfNeeded(&app);
        // D10: the scripts subscribe before the `startup` hook fires.
        // A hidden task one of them starts waits for the App's final
        // address (`script_task.State.defer_spawns`).
        app.script_tasks.defer_spawns = true;
        try app.script().loadInitFiles();
        // // changed (lua-install): then the installed scripts, each in
        // its own state (`app/scripts.zig`).
        try scripts_mod.scan(&app);
        app.script_tasks.defer_spawns = false;
        return app;
    }

    /// The `init.lua` state, pointed at this App for the call about to
    /// happen. Every installed script's state is re-pointed with it:
    /// the App struct moves after `initWith` returns, so a state made
    /// during init holds the address of a stack frame that is gone.
    pub fn script(self: *App) *scripting.Lua {
        self.syncScriptStates();
        const l = self.lua.?;
        l.app = self;
        return l;
    }

    /// Point every installed script's state at this App. Cheap: a
    /// handful of entries, a pointer each.
    pub fn syncScriptStates(self: *App) void {
        for (self.scripts.entries.items) |*e| if (e.state) |l| {
            l.app = self;
        };
    }

    /// The state a `LuaRef` belongs to: 0 is `init.lua`'s, 1.. an
    /// installed script's. Null when that script is disabled, removed
    /// or failed to load — the ref is stale and the caller does
    /// nothing rather than reaching into another script's registry.
    pub fn luaState(self: *App, id: u16) ?*scripting.Lua {
        if (id == 0) return self.script();
        const l = self.scripts.state(id) orelse return null;
        l.app = self;
        return l;
    }

    /// The state of the installed script `name`, pointed at this App.
    pub fn scriptNamed(self: *App, name: []const u8) ?*scripting.Lua {
        const e = self.scripts.find(name) orelse return null;
        return self.luaState(e.id);
    }

    /// Every live Lua state, `init.lua`'s first, on `arena`.
    pub fn luaStates(self: *App, arena: Allocator) Allocator.Error![]*scripting.Lua {
        var out: std.ArrayListUnmanaged(*scripting.Lua) = .empty;
        try out.append(arena, self.script());
        for (self.scripts.entries.items) |*e| if (e.state) |l| {
            l.app = self;
            try out.append(arena, l);
        };
        return out.toOwnedSlice(arena);
    }

    /// Load the three layers again with `trust` and switch to the result:
    /// the keymap, the input style, the tree width and the theme follow.
    /// The old `Loaded` is retired after `cfg` has stopped borrowing it.
    pub fn reloadConfig(self: *App, trust: config.Trust) Allocator.Error!void {
        const old = &(self.loaded orelse return);
        var fresh = try old.reload(self.gpa, self.io, trust);
        errdefer fresh.deinit();
        var km = try buildKeymap(self.gpa, styleOf(fresh.config.editor.input_style), fresh.config.keys);
        errdefer km.deinit();
        const was_trusted = self.workspace_trusted;
        self.workspace_trusted = fresh.workspace_trusted;
        self.cfg = fresh.config;
        old.deinit();
        self.loaded = fresh;
        lsp.configReloaded(self);
        self.keymap.deinit();
        self.keymap = km;
        self.chord.clear(self.gpa);
        const style = styleOf(self.cfg.editor.input_style);
        if (style != self.input_style) try self.setInputStyle(style);
        try self.syncBufferPrefs();
        self.tree.width = self.cfg.ui.tree_width;
        try self.seedPlusMenu();
        auto_refresh.seed(self);
        clock.seed(self);
        try self.snippets.absorbConfig(self.cfg.snippets);
        try self.toastConfigDiagnostics();
        self.probeWorkspaceToml();
        try self.applyTheme();
        try script_api.rebind(self);
        // The reload may have taken the Copilot opt-in away (the key
        // edited out, or trust withdrawn). The server goes with it —
        // leaving it running would keep answering for a workspace that
        // has just said no.
        copilot_app.stopIfNotAllowed(self);
        // A workspace just trusted gets its `.mnml/init.lua` now, and
        // its manifests join the integrations.
        if (!was_trusted and self.workspace_trusted) {
            try self.script().reset();
            try self.script().loadInitFiles();
            // …and the script folders its config names
            // (`scripts.dev_roots` / `private_sources`), which an
            // untrusted layer had stripped.
            try scripts_mod.scan(self);
            if (self.integrations.scanned) try integrations.refresh(self);
        }
        self.needs_render = true;
    }

    /// `ui.theme` → `theme`. An unknown name keeps what is painted and
    /// says so — a typo in the config must never blank the screen.
    pub fn applyTheme(self: *App) Allocator.Error!void {
        if (theme_mod.byName(self.cfg.ui.theme)) |t| {
            self.setTheme(t);
        } else {
            try self.toastLevel(.warn, "config: ui.theme \"{s}\" is not a bundled theme; keeping {s}", .{ self.cfg.ui.theme, self.theme.name });
        }
    }

    /// Paint with `t` from the next frame; every editor re-highlights in
    /// its colours.
    pub fn setTheme(self: *App, t: *const theme_mod) void {
        self.theme = t.*;
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| e.syntax.dirty = true,
            else => {},
        };
        self.needs_render = true;
    }

    /// What the loader could not use, one warning toast each.
    fn toastConfigDiagnostics(self: *App) Allocator.Error!void {
        const l = self.loaded orelse return;
        for (l.diagnostics.items.items) |d| try self.toastLevel(.warn, "config: {f}", .{d});
    }

    /// `workspace_toml` from the workspace as it is on disk now: a
    /// `.mnml/config.toml` with no `.mnml/config.zon` beside it.
    pub fn probeWorkspaceToml(self: *App) void {
        if (self.workspace_toml) |p| self.gpa.free(p);
        self.workspace_toml = null;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const zon = std.fs.path.join(arena, &.{ self.workspace, ".mnml", config.data_root.config_file }) catch return;
        const toml = (config.load.tomlBeside(arena, self.io, zon) catch return) orelse return;
        self.workspace_toml = self.gpa.dupe(u8, toml) catch null;
    }

    /// What the notice says: the file is 0.2's and never read, and the
    /// converter that turns it into the `.zon` this build reads.
    pub fn unreadTomlText(self: *App, arena: Allocator, path: []const u8, workspace: bool) Allocator.Error![]const u8 {
        if (workspace) return std.fmt.allocPrint(arena, "config: this workspace's .mnml/config.toml is mnml 0.2's and is not read — run `mnml export-config-zon --out .mnml/config.zon` (0.2.22) in {s} to convert it; RESTRICTED on the statusline says so", .{self.relPath(self.workspace)});
        return std.fmt.allocPrint(arena, "config: {s} is mnml 0.2's and is not read — run `mnml export-config-zon` (0.2.22) to convert it", .{path});
    }

    /// The one thing mnml-zig says about a 0.2 `config.toml` it found
    /// where a `config.zon` should be (E2: no TOML reader, ever): a
    /// toast once per data root (`ui.config_toml_notice_shown`, written
    /// the first time), `:messages` every launch, and for the workspace
    /// file the RESTRICTED chip for as long as it stands. A diagnostic
    /// toasted the path-first message on every launch, clipped so the
    /// converter never showed (walkthrough 1.10).
    fn noticeUnreadToml(self: *App) Allocator.Error!void {
        self.probeWorkspaceToml();
        const home: ?[]const u8 = if (self.loaded) |l| l.home_toml else null;
        if (self.workspace_toml == null and home == null) return;
        const arena = self.frame.allocator();
        const show = !self.cfg.ui.config_toml_notice_shown;
        if (home) |p| {
            const text = try self.unreadTomlText(arena, p, false);
            if (show) try self.toastLevel(.warn, "{s}", .{text}) else try self.messages.record(self.gpa, text, .warn, self.now_ms);
        }
        if (self.workspace_toml) |p| {
            const text = try self.unreadTomlText(arena, p, true);
            if (show) try self.toastLevel(.warn, "{s}", .{text}) else try self.messages.record(self.gpa, text, .warn, self.now_ms);
        }
        if (show) {
            self.cfg.ui.config_toml_notice_shown = true;
            _ = try settings_app.persist(self, .home, &.{ "ui", "config_toml_notice_shown" }, true);
        }
    }

    /// The home the loader saw (`$HOME`, else `%USERPROFILE%` —
    /// `os_path.home`); null without a loaded config or a home (the
    /// `.test` runner's apps have neither).
    pub fn homeDir(self: *const App) ?[]const u8 {
        const l = self.loaded orelse return null;
        return os_path.home(l.opts.env.vars);
    }

    /// `homeDir`, else the App's own environment's home: what a feature
    /// that wants *a* home (tilde display, `~` expansion, per-user
    /// caches) asks. Windows has no `HOME`; `USERPROFILE` answers there.
    pub fn userHome(self: *const App) ?[]const u8 {
        return self.homeDir() orelse os_path.home(&self.env);
    }

    /// The input layer's scalar config, read off `cfg.editor`.
    pub fn editorConfig(self: *const App) input.Config {
        return .{ .tab_width = self.cfg.editor.tab_width, .text_width = self.cfg.editor.text_width };
    }

    /// The save-time preferences from `cfg.editor`, then what the file's
    /// `.editorconfig` chain says (`src/editor/editorconfig.zig`) — run
    /// on every buffer before it joins the store, so the per-file
    /// overrides land before the first edit. A scratch buffer takes the
    /// config's defaults only.
    pub fn applyBufferPrefs(self: *App, buf: *Buffer) Allocator.Error!void {
        buf.doc.ensure_trailing_newline = self.cfg.editor.ensure_trailing_newline;
        buf.doc.trim_trailing_ws_on_save = self.cfg.editor.trim_trailing_ws_on_save;
        buf.doc.auto_indent = self.cfg.editor.auto_indent;
        buf.doc.auto_pair = self.cfg.editor.auto_pair;
        const path = buf.doc.path orelse return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        buf.applyEditorconfig(try editorconfig.resolveFor(self.io, arena_state.allocator(), path, self.workspace));
    }

    /// `[keys.global]` + `[keys.<profile>]` over the profile's defaults.
    fn buildKeymap(gpa: Allocator, style: input.Style, keys: Config.Keys) Allocator.Error!keymap.Keymap {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        return keymap.Keymap.build(gpa, profileOf(style), .{
            .global = try bindings(a, keys.global),
            .vim = try bindings(a, keys.vim),
            .standard = try bindings(a, keys.standard),
        });
    }

    fn bindings(a: Allocator, m: config.Map([]const u8)) Allocator.Error![]keymap.Binding {
        const out = try a.alloc(keymap.Binding, m.count());
        for (m.keys(), m.values(), 0..) |k, v, i| out[i] = .{ .spec = k, .command = v };
        return out;
    }

    pub fn deinit(self: *App) void {
        const gpa = self.gpa;
        // Close the queue before a single group is cancelled. Nothing
        // drains it once the loop has stopped, so a worker that posts
        // into a full ring waits for room that never comes — and a
        // `cancel` waiting on that worker waits with it. Closed, every
        // post fails at once and frees its payload, so each worker
        // runs to its end and the cancels below return. What was
        // already queued is freed with the ring, last.
        self.events.close(self.io);
        // Workers first: they borrow `workspace` and post into `events`.
        self.syntax_jobs.deinit(self.io);
        self.transfers.deinit(gpa, self.io);
        self.update.deinit(gpa, self.io);
        self.autosave.deinit(gpa);
        self.ai.deinit(gpa, self.io);
        self.copilot.deinit(gpa);
        self.now_playing.deinit(self.io);
        self.integration_poll.deinit(gpa, self.io);
        // After the poller: its children were told where the sockets
        // are, and a broker torn down first would strand them.
        self.broker.deinit(gpa, self.io);
        self.todos.deinit(gpa, self.io);
        self.search_section.deinit(gpa, self.io);
        self.grep_picker.deinit(gpa, self.io);
        self.notes.deinit(gpa, self.io);
        self.findings.deinit(gpa, self.io);
        self.scripts_panel.deinit(gpa);
        self.script_lists.deinit(gpa);
        self.script_sections.deinit(gpa);
        self.debug_panel.deinit(gpa);
        self.sessions.deinit(gpa, self.io);
        self.welcome.deinit(gpa);
        self.info_view.deinit();
        self.dock.deinit(gpa, self.io);
        self.bottom.deinit(gpa);
        self.http.deinit(gpa, self.io);
        self.http_panel.deinit(gpa);
        self.git.deinit(gpa, self.io);
        self.git_palette.deinit(gpa);
        self.marketplace.deinit(gpa, self.io);
        self.fonts.deinit(gpa, self.io);
        self.ipc_fx.deinit(gpa);
        self.flaky.deinit(gpa);
        self.dap.deinit(gpa);
        // Panes go before the manifests their mount runners borrow, and
        // before the documents their buffers release.
        self.panes.deinit();
        self.docs.destroy();
        self.integrations.deinit(gpa);
        self.activity_bar.deinit(gpa);
        self.lsp.deinit(gpa, self.io);
        self.snippets.deinit();
        self.overlay.deinit(gpa);
        self.menu_bar.deinit();
        if (self.find_bar) |*fb| {
            fb.state.deinit(gpa);
            if (fb.snapshot) |*s| s.deinit();
        }
        for (self.toasts.items) |t| freeToast(gpa, t);
        self.toasts.deinit(gpa);
        if (self.undo_chip) |u| gpa.free(u.label);
        for (self.plus_pinned.items) |p| gpa.free(p);
        self.plus_pinned.deinit(gpa);
        for (self.plus_hidden.items) |p| gpa.free(p);
        self.plus_hidden.deinit(gpa);
        self.messages.deinit(gpa);
        self.jobs.deinit(gpa);
        self.harpoon.deinit(gpa);
        self.file_clipboard.deinit(gpa);
        self.jumplist.deinit(gpa);
        for (self.closed.items) |c| gpa.free(c.path);
        self.closed.deinit(gpa);
        self.quickfix.deinit(gpa);
        for (self.find_history.items) |q| gpa.free(q);
        self.find_history.deinit(gpa);
        self.pane_mru.deinit(gpa);
        if (self.keyword_complete) |*k| k.deinit(gpa);
        for (self.closed_tabs.items) |*c| c.deinit(gpa);
        self.closed_tabs.deinit(gpa);
        var it = self.abbrevs.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.abbrevs.deinit(gpa);
        ex_verbs.deinitState(self);
        if (self.find_term) |t| self.gpa.free(t.query);
        for (self.plugin_invocations.items) |p| gpa.free(p);
        self.plugin_invocations.deinit(gpa);
        if (self.cmd_complete) |*c| c.deinit(gpa);
        if (self.cmdline) |*c| c.deinit(gpa);
        if (self.preview_hl) |*h| h.deinit();
        if (self.flash) |*f| f.deinit(gpa);
        for (self.recent.items) |r| gpa.free(r);
        self.recent.deinit(gpa);
        for (self.cmd_history.items) |c| gpa.free(c);
        self.cmd_history.deinit(gpa);
        for (self.recent_commands.items) |c| gpa.free(c);
        self.recent_commands.deinit(gpa);
        self.host_out.deinit(gpa);
        for (self.host_log.items) |e| gpa.free(e);
        self.host_log.deinit(gpa);
        self.runners.deinit(gpa);
        self.tasks.deinit(gpa);
        self.chord.clear(gpa);
        self.hooks.deinit();
        self.dyn_commands.deinit();
        self.keymap.deinit();
        self.clipboard.deinit();
        marks_store.deinitMap(gpa, &self.global_marks);
        self.layouts.deinit();
        self.tree.deinit();
        // Script panes unref'd into the state when the pane store went
        // (above, before the manifests); the state closes after them.
        self.scripts.deinit(gpa);
        if (self.lua) |l| l.destroy();
        self.script_tasks.deinit(gpa, self.io);
        self.script_decor.deinit(gpa);
        if (self.workspace_toml) |p| gpa.free(p);
        self.screen.deinit(gpa);
        self.events.deinit(self.io);
        gpa.destroy(self.events);
        self.frame.deinit();
        self.env.deinit();
        gpa.free(self.data_root);
        if (self.owns_workspace) test_workspace.remove(self.io, self.workspace);
        gpa.free(self.workspace);
        // Last: `cfg` borrowed from it until here.
        if (self.loaded) |*l| l.deinit();
    }

    /// The process environment as a map: libc's `environ` on POSIX,
    /// the PEB's block on Windows (where `Environ.Block` is the global
    /// switch, not a pointer).
    fn processEnv(gpa: Allocator) Allocator.Error!std.process.Environ.Map {
        const environ: std.process.Environ = if (builtin.os.tag == .windows) .{ .block = .global } else blk: {
            const raw: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            break :blk .{ .block = .{ .slice = std.mem.span(raw) } };
        };
        return std.process.Environ.createMap(environ, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .init(gpa),
        };
    }

    pub fn profileOf(style: input.Style) keymap.Profile {
        return switch (style) {
            .vim => .vim,
            .standard => .standard,
        };
    }

    /// The config's enum → the input layer's. Same tags, two modules
    /// that must not import each other.
    pub fn styleOf(s: Config.InputStyle) input.Style {
        return switch (s) {
            .vim => .vim,
            .standard => .standard,
        };
    }

    pub fn configStyleOf(s: input.Style) Config.InputStyle {
        return switch (s) {
            .vim => .vim,
            .standard => .standard,
        };
    }

    pub fn nowMs(io: Io) i64 {
        return Io.Timestamp.now(io, .awake).toMilliseconds();
    }

    // ─── toasts ───

    fn freeToast(gpa: Allocator, t: Toast) void {
        gpa.free(t.text);
        if (t.id) |id| gpa.free(id);
        if (t.action) |a| a.deinit(gpa);
    }

    /// A toast that carries something to DO about itself. The offer is
    /// attached to the box the message landed in — including the box a
    /// repeat coalesced into, so a dependency that goes missing three
    /// times keeps one offer and gains a count.
    pub fn toastWithAction(self: *App, level: ToastLevel, action: ToastAction, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const s = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(s);
        try self.toastLevel(level, "{s}", .{s});
        // `toastLevel` may have dropped it (inside `:g`) or coalesced it
        // into an older box; find the one that holds this text.
        var i = self.toasts.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.toasts.items[i].text, s)) {
                if (self.toasts.items[i].action) |old| old.deinit(self.gpa);
                self.toasts.items[i].action = action;
                return;
            }
        }
        action.deinit(self.gpa);
    }

    /// Attach an offer to the toast with `id` (a `toastReplace*` one).
    /// Takes ownership either way: a toast that is no longer up frees it
    /// rather than leaking.
    pub fn attachToastAction(self: *App, id: []const u8, action: ToastAction) void {
        for (self.toasts.items) |*t| if (t.id) |tid| if (std.mem.eql(u8, tid, id)) {
            if (t.action) |old| old.deinit(self.gpa);
            t.action = action;
            return;
        };
        action.deinit(self.gpa);
    }

    /// Perform a toast's offer.
    pub fn runToastAction(self: *App, action: ToastAction) Allocator.Error!void {
        switch (action) {
            // A VISIBLE pane, not a background spawn: the user sees the
            // command, its output and whether it worked.
            .run_in_terminal => |r| {
                const cmd = try self.frame.allocator().dupe(u8, r.cmd);
                @import("app/cmd_term.zig").termEx(self, cmd) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => self.toast("could not start `{s}`", .{cmd}),
                };
            },
            // The marketplace row, NOT a direct install: the
            // description, version and source are visible there first.
            .marketplace => |m| {
                const id = try self.frame.allocator().dupe(u8, m.id);
                @import("app/integrations.zig").revealInMarketplace(self, id) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => self.toast("could not open the marketplace for {s}", .{id}),
                };
            },
            // `app.restart`'s own path: the unsaved-changes guard and
            // the relaunch are the command's, not a second copy here.
            .restart => command.run(self, .{ .static = .@"app.restart" }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => self.toast("could not restart", .{}),
            },
            // A mounted pane's offer: an id the host already knows,
            // run the way a key or the palette would run it. An id
            // nobody registered says so rather than failing silently.
            .command => |c| {
                const id = try self.frame.allocator().dupe(u8, c.id);
                if (c.pane) |pid| if (self.panes.get(pid) != null) self.setActive(pid);
                command.runNamed(self, id) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => self.toast("no such command: {s}", .{id}),
                };
            },
            // …and the other half: a page. The http(s) rule is the
            // host's, not the pane's.
            .open_url => |u| {
                const url = try self.frame.allocator().dupe(u8, u.url);
                @import("app/git.zig").openExternal(self, url);
            },
        }
    }

    /// Queue a toast. Formatting failure drops the toast rather than the frame.
    pub fn toast(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.toastLevel(.info, fmt, args) catch {};
    }

    /// One slot for vim's last search pattern (`:help last-pattern`) —
    /// `/`, `?`, `*`, `#`, `:s/pat/` and `:g/pat/` all write it, so
    /// `:%s//new/g` after a `/pat` substitutes what was just searched.
    /// An empty pattern never clears it, as in vim.
    pub fn noteSearchPattern(self: *App, pattern: []const u8) Allocator.Error!void {
        if (pattern.len == 0) return;
        if (self.last_search_pattern) |old| {
            if (std.mem.eql(u8, old, pattern)) return;
        }
        const copy = try self.gpa.dupe(u8, pattern);
        if (self.last_search_pattern) |old| self.gpa.free(old);
        self.last_search_pattern = copy;
    }

    pub fn toastLevel(self: *App, level: ToastLevel, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        // Inside `:g` the per-line sub-commands say nothing; `:g` reports
        // once for the whole run, as Vim does.
        if (self.in_global) return;
        const s = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(s);
        try self.messages.record(self.gpa, s, level, self.now_ms);
        // An identical message still on screen coalesces, as Rust's
        // stack does: rust-analyzer says `Failed to discover workspace`
        // twice at startup and a retried failure says the same thing
        // three times — one box with a count, not three.
        for (self.toasts.items, 0..) |*t, i| if (t.id == null and t.expires_ms != std.math.maxInt(i64) and std.mem.eql(u8, t.text, s)) {
            // Bumped to the newest slot, where a fresh one would land:
            // `lastToast` and the box nearest the statusline are it.
            var again = self.toasts.orderedRemove(i);
            again.repeats +|= 1;
            again.expires_ms = self.now_ms + toast_ttl_ms;
            again.raised_ms = self.now_ms;
            self.toasts.appendAssumeCapacity(again);
            self.gpa.free(s);
            self.needs_render = true;
            return;
        };
        // A toast from the command whose earlier run raised the one on
        // screen replaces it: one command, one box. The new text takes
        // the newest slot, as a coalesced repeat does, so `lastToast`
        // and the box nearest the statusline are still the latest word
        // (and `toasts.items[len - 1]` still the toast just raised). An
        // error never replaces a non-error: the failure stacks.
        const source = self.toastSource();
        if (source) |src| if (self.replaceableToast(src, level)) |i| {
            freeToast(self.gpa, self.toasts.orderedRemove(i));
            self.toasts.appendAssumeCapacity(.{ .text = s, .level = level, .expires_ms = self.now_ms + toast_ttl_ms, .source = src, .raised_ms = self.now_ms });
            self.needs_render = true;
            return;
        };
        self.capTransient();
        try self.toasts.append(self.gpa, .{ .text = s, .level = level, .expires_ms = self.now_ms + toast_ttl_ms, .source = source, .raised_ms = self.now_ms });
        self.needs_render = true;
    }

    /// The command run raising a toast right now, if any.
    fn toastSource(self: *const App) ?ToastSource {
        const cmd = self.running_cmd orelse return null;
        return .{ .cmd = cmd, .run = self.running_serial };
    }

    /// The index of the transient toast a new one from `src` at `level`
    /// replaces: the
    /// newest up from an EARLIER run of the same command, raised within
    /// `toast_coalesce_ms`. Persistent and id'd (progress) toasts are
    /// never touched, and an error never lands on a non-error.
    fn replaceableToast(self: *const App, src: ToastSource, level: ToastLevel) ?usize {
        var i = self.toasts.items.len;
        while (i > 0) {
            i -= 1;
            const t = &self.toasts.items[i];
            if (t.id != null or !isTransient(t.*)) continue;
            const old = t.source orelse continue;
            if (!old.sameCommand(src) or old.run == src.run) continue;
            if (self.now_ms - t.raised_ms > toast_coalesce_ms) continue;
            if (level == .err and t.level != .err) return null;
            return i;
        }
        return null;
    }

    /// A toast that expires — everything but the sticky ones an owner
    /// dismisses by id.
    fn isTransient(t: Toast) bool {
        return t.expires_ms != std.math.maxInt(i64);
    }

    /// Room for one more transient toast: the oldest transient ones go
    /// while `max_transient_toasts` are up (Rust pops the back of its
    /// stack). Sticky toasts are not counted and never dropped here.
    fn capTransient(self: *App) void {
        var n: usize = 0;
        for (self.toasts.items) |t| if (isTransient(t)) {
            n += 1;
        };
        var i: usize = 0;
        while (n >= max_transient_toasts and i < self.toasts.items.len) {
            if (isTransient(self.toasts.items[i])) {
                freeToast(self.gpa, self.toasts.orderedRemove(i));
                n -= 1;
            } else i += 1;
        }
    }

    /// Esc: every transient toast goes at once — the user said "go
    /// away" to whatever is on screen (Rust clears `toast_stack` on
    /// every Esc, before the overlays see the key). Sticky ones stay.
    pub fn dismissTransientToasts(self: *App) void {
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            if (isTransient(self.toasts.items[i])) {
                freeToast(self.gpa, self.toasts.orderedRemove(i));
                self.needs_render = true;
            } else i += 1;
        }
    }

    /// A toast that replaces its predecessor of the same `id` instead of
    /// stacking on it, and expires like any other — for a message that
    /// repeats on every keystroke of a navigation (`tab 2/3`) so the
    /// column never fills with its history.
    pub fn toastReplace(self: *App, id: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.toastReplaceLevel(id, .info, fmt, args);
    }

    /// `toastReplace` at a level.
    pub fn toastReplaceLevel(self: *App, id: []const u8, level: ToastLevel, comptime fmt: []const u8, args: anytype) void {
        if (self.in_global) return;
        self.dismissToast(id);
        const s = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        errdefer self.gpa.free(s);
        const owned_id = self.gpa.dupe(u8, id) catch {
            self.gpa.free(s);
            return;
        };
        self.messages.record(self.gpa, s, level, self.now_ms) catch {};
        self.capTransient();
        self.toasts.append(self.gpa, .{ .text = s, .level = level, .expires_ms = self.now_ms + toast_ttl_ms, .id = owned_id }) catch {
            self.gpa.free(s);
            self.gpa.free(owned_id);
            return;
        };
        self.needs_render = true;
    }

    /// A toast that stays until `dismissToast(id)`; a repeat with the
    /// same id replaces the text.
    pub fn toastPersistent(self: *App, id: []const u8, text: []const u8, level: ToastLevel) Allocator.Error!void {
        self.dismissToast(id);
        const s = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(s);
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);
        try self.messages.record(self.gpa, text, level, self.now_ms);
        if (self.toasts.items.len >= max_toasts) freeToast(self.gpa, self.toasts.orderedRemove(0));
        try self.toasts.append(self.gpa, .{ .text = s, .level = level, .expires_ms = std.math.maxInt(i64), .id = owned_id });
        self.needs_render = true;
    }

    pub fn dismissToast(self: *App, id: []const u8) void {
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            const t = self.toasts.items[i];
            if (t.id != null and std.mem.eql(u8, t.id.?, id)) {
                freeToast(self.gpa, self.toasts.orderedRemove(i));
                self.needs_render = true;
            } else i += 1;
        }
    }

    /// Drop the toast at `idx` (a click on its box).
    pub fn dismissToastAt(self: *App, idx: usize) void {
        if (idx >= self.toasts.items.len) return;
        freeToast(self.gpa, self.toasts.orderedRemove(idx));
        self.needs_render = true;
    }

    pub const host_log_max: usize = 16;

    /// Queue `bytes` for the host terminal (`host_out`) and keep a copy
    /// in `host_log` — the one door an escape meant for the terminal
    /// itself goes through.
    pub fn hostWrite(self: *App, bytes: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(copy);
        if (self.host_tty) try self.host_out.appendSlice(self.gpa, bytes);
        if (self.host_log.items.len >= host_log_max) self.gpa.free(self.host_log.orderedRemove(0));
        try self.host_log.append(self.gpa, copy);
    }

    pub fn lastToast(self: *const App) ?[]const u8 {
        return if (self.toasts.getLastOrNull()) |t| t.text else null;
    }

    /// Drop every toast — `Esc` in normal mode does this.
    pub fn dismissToasts(self: *App) void {
        for (self.toasts.items) |t| freeToast(self.gpa, t);
        self.toasts.clearRetainingCapacity();
    }

    /// `ui.plus_menu_pinned` / `plus_menu_hidden` → the runtime lists.
    pub fn seedPlusMenu(self: *App) Allocator.Error!void {
        for (self.plus_pinned.items) |p| self.gpa.free(p);
        self.plus_pinned.clearRetainingCapacity();
        for (self.plus_hidden.items) |p| self.gpa.free(p);
        self.plus_hidden.clearRetainingCapacity();
        for (self.cfg.ui.plus_menu_pinned) |id| try self.plus_pinned.append(self.gpa, try self.gpa.dupe(u8, id));
        for (self.cfg.ui.plus_menu_hidden) |id| try self.plus_hidden.append(self.gpa, try self.gpa.dupe(u8, id));
    }

    // ─── the Undo chip ───

    /// Offer to put a destructive action back for `undo_chip_ttl_ms`.
    /// A newer offer replaces an older one.
    pub fn armUndo(self: *App, action: UndoChip.Action, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const label = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(label);
        self.dropUndo();
        self.undo_chip = .{ .label = label, .action = action, .expires_ms = self.now_ms + undo_chip_ttl_ms };
        self.needs_render = true;
    }

    pub fn dropUndo(self: *App) void {
        if (self.undo_chip) |u| self.gpa.free(u.label);
        self.undo_chip = null;
        self.needs_render = true;
    }

    /// The chip was clicked: run the action, then drop the chip.
    pub fn takeUndo(self: *App) Allocator.Error!void {
        const chip = self.undo_chip orelse return;
        const action = chip.action;
        self.dropUndo();
        switch (action) {
            .reopen => |r| {
                var i: usize = 0;
                while (i < r.n) : (i += 1) command.run(self, .{ .static = .@"buffer.reopen" }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break,
                };
                if (r.keep) |k| if (self.panes.get(k) != null) {
                    self.layouts.current().reorderTab(k, r.keep_at);
                    self.setActive(k);
                };
                self.toast("reopened {d} tab(s)", .{i});
            },
        }
    }

    // ─── the ex bridge the dyn registry uses ───

    pub fn runEx(self: *App, line: []const u8) command.CommandError!void {
        return ex.run(self, line);
    }

    /// An IPC-registered command was invoked: the host learns about it
    /// through events.jsonl — each loop drains the list every turn
    /// (`driver.takePluginInvocations`). Bounded all the same: past
    /// `plugin_invocations_max` undrained the oldest goes, so nothing a
    /// loop fails to drain can grow for the life of the process.
    pub fn ackPluginCommand(self: *App, id: []const u8) command.CommandError!void {
        const copy = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(copy);
        if (self.plugin_invocations.items.len >= plugin_invocations_max) self.gpa.free(self.plugin_invocations.orderedRemove(0));
        try self.plugin_invocations.append(self.gpa, copy);
    }

    pub const plugin_invocations_max = 256;

    // ─── panes ───

    pub fn activeEditor(self: *App) ?*EditorPane {
        const id = self.active orelse return null;
        return self.panes.editor(id);
    }

    pub fn activeBuffer(self: *App) ?*Buffer {
        const e = self.activeEditor() orelse return null;
        return &e.buf;
    }

    /// The editor pane, or the `NoActivePane` / `NotAnEditor` a command reports.
    pub fn requireEditor(self: *App) command.CommandError!*EditorPane {
        const id = self.active orelse return error.NoActivePane;
        return self.panes.editor(id) orelse error.NotAnEditor;
    }

    /// Open `path` (absolute): a markdown file goes to its rendered
    /// preview (`markdown_opens_rendered`) unless it is already open in
    /// an editor; anything else to an editor pane. With `auto_md_preview`
    /// a markdown file gets the editor AND a preview split beside it.
    /// `editor.auto_indent` changed (`:set ai`, the settings row): every
    /// open buffer follows.
    /// The per-buffer copies of `editor.tab_width`, `auto_indent`, `auto_pair`,
    /// `trim_trailing_ws_on_save` and `ensure_trailing_newline` follow
    /// the config when it changes (a reload, `:set`, Settings, the
    /// indent chip), so the file already open obeys the toast — except
    /// where the buffer's own value is explicit (`Document.pref_source`):
    /// a file's `.editorconfig` is read again and keeps the last word on
    /// what it names, and a `:setlocal` value is left as it is.
    pub fn syncBufferPrefs(self: *App) Allocator.Error!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const c = self.cfg.editor;
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| {
                const doc = e.buf.doc;
                const src = &doc.pref_source;
                if (src.auto_indent != .local) doc.auto_indent = c.auto_indent;
                doc.auto_pair = c.auto_pair;
                if (src.trim_trailing_ws_on_save != .local) {
                    doc.trim_trailing_ws_on_save = c.trim_trailing_ws_on_save;
                    src.trim_trailing_ws_on_save = .config;
                }
                if (src.ensure_trailing_newline != .local) {
                    doc.ensure_trailing_newline = c.ensure_trailing_newline;
                    src.ensure_trailing_newline = .config;
                }
                // The indent as a fresh open seeds it: both widths from
                // the one config value.
                if (src.tab_width != .local) {
                    e.buf.setIndent(c.tab_width, c.tab_width, doc.use_tabs);
                    doc.indent_pinned = false;
                    src.tab_width = .config;
                }
                const path = doc.path orelse continue;
                _ = arena_state.reset(.retain_capacity);
                e.buf.applyEditorconfig(try editorconfig.resolveFor(self.io, arena_state.allocator(), path, self.workspace));
            },
            else => {},
        };
    }

    /// How an open arrived. A glance (a tree click, an arrow over a
    /// tree row) opens a preview tab; everything explicit — the
    /// picker, `:e`, a jump, the IPC `open`, a session restore — opens
    /// a tab of its own and keeps a preview it lands on.
    pub const OpenOpts = struct { preview: bool = false };

    /// Whether a glance opens a preview tab at all. The vim profile
    /// does not have them (every file is its own tab, as in Neovim),
    /// and `ui.preview_tabs = false` turns them off everywhere.
    pub fn previewTabs(self: *const App) bool {
        return self.input_style == .standard and self.cfg.ui.preview_tabs;
    }

    /// The preview tab of the leaf the active pane sits in. Exactly
    /// one tab per leaf is ever a preview — the next glance there
    /// takes it over.
    pub fn leafPreview(self: *App) ?PaneId {
        const active = self.active orelse return null;
        const layout = self.layouts.current();
        const lid = layout.leafOf(active) orelse return null;
        const leaf = layout.leaf(lid) orelse return null;
        for (leaf.tabs.items) |id| if (self.panes.get(id)) |p| {
            if (p.preview()) return id;
        };
        return null;
    }

    /// Open `path` as a glance (VS Code's preview tab): the name
    /// paints italic and the next glance in this leaf takes the tab
    /// over. A file already open is shown where it is and keeps
    /// whatever it was. A dirty preview is not replaced — its own
    /// edit already kept it, so there is nothing to take over.
    pub fn openPreview(self: *App, path: []const u8) !PaneId {
        if (!self.previewTabs()) return self.openPath(path);
        if (self.panes.findShowing(path)) |id| {
            self.showPane(id);
            return id;
        }
        if (self.leafPreview()) |old| if (self.panes.get(old)) |p| {
            if (!p.dirty()) try self.forceClosePane(old);
        };
        return self.openPathOpts(path, .{ .preview = true });
    }

    pub fn openPath(self: *App, path: []const u8) !PaneId {
        return self.openPathOpts(path, .{});
    }

    pub fn openPathOpts(self: *App, path_in: []const u8, opts: OpenOpts) !PaneId {
        // One spelling per file on Windows, where `D:\ws\a` and
        // `D:\ws/a` name the same one: the native separator throughout,
        // so an open finds the pane the other spelling made.
        const path = if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, path_in, '/') != null) blk: {
            const own = try self.frame.allocator().dupe(u8, path_in);
            std.mem.replaceScalar(u8, own, '/', '\\');
            break :blk own;
        } else path_in;
        try self.noteRecent(path);
        // A request file opens as a request pane on its first block; a
        // file the parser cannot read falls through to the editor.
        if (http_parse.isRequestPath(path) and self.panes.findPath(path) == null) {
            if (http_app.openFile(self, path, opts.preview)) |id| return self.opened(id, opts) else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
        }
        // An image opens in the viewer, replacing the last glanced-at one.
        if (image.isImagePath(path)) return self.opened(try image_pane.open(self, path), opts);
        const is_md = md_preview.isMarkdownPath(path);
        if (is_md and self.cfg.ui.markdown_opens_rendered and !self.cfg.ui.auto_md_preview and self.panes.findPath(path) == null) {
            return self.opened(try md_preview.open(self, path, .here, null), opts);
        }
        const id = try self.openEditor(path);
        if (is_md and self.cfg.ui.auto_md_preview and self.panes.findPreview(path) == null) {
            _ = try md_preview.open(self, path, .beside, id);
            self.setActive(id);
        }
        return self.opened(id, opts);
    }

    /// The tab an open landed on: a glance marks it a preview, and an
    /// explicit open keeps one it landed on (VS Code pins the tab a
    /// double-click, a picker or a `:e` reaches).
    fn opened(self: *App, id: PaneId, opts: OpenOpts) PaneId {
        if (self.panes.get(id)) |p| p.setPreview(opts.preview and self.previewTabs());
        return id;
    }

    /// Open `path` (absolute) in an editor pane and focus it. An already
    /// open file is revealed instead. A missing file is a new buffer.
    pub fn openEditor(self: *App, path: []const u8) !PaneId {
        // Leaving another file is a jump `nav.back` can undo.
        if (!self.jumplist.in_jump) if (try jumplist.current(self)) |here| if (!std.mem.eql(u8, here.path, path)) try jumplist.record(self, here);
        if (self.panes.findPath(path)) |id| {
            self.showPane(id);
            return id;
        }
        const gpa = self.gpa;
        const ecfg = self.editorConfig();
        var buf = Buffer.load(gpa, self.io, path, self.input_style, ecfg) catch |err| switch (err) {
            error.FileNotFound => blk: {
                var b = try Buffer.init(gpa, "", self.input_style, ecfg);
                errdefer b.deinit();
                try b.setPath(path);
                break :blk b;
            },
            else => return err,
        };
        errdefer buf.deinit();
        try self.applyBufferPrefs(&buf);
        // A file closed earlier reopens where the cursor was.
        var i: usize = self.closed.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.closed.items[i];
            if (std.mem.eql(u8, c.path, path)) {
                buf.editor.setCursor(@min(c.cursor, buf.editor.len()));
                gpa.free(c.path);
                _ = self.closed.orderedRemove(i);
                break;
            }
        }
        const entry = try self.docs.adopt(buf.doc);
        entry.syntax.setLanguage(path, buf.editor.bytes());
        // The opt-in size ceiling (`editor.highlight_max_bytes`, 0 = no
        // limit): over it the file opens with no tree-sitter at all, and
        // is never quiet about it — a toast now, the statusline chip for
        // as long as the buffer is up.
        entry.syntax.applyLimit(buf.editor.len(), self.cfg.editor.highlight_max_bytes);
        if (entry.syntax.over_limit) syntax.announceLimit(self, std.fs.path.basename(path), &entry.syntax);
        const id = try self.panes.add(.{ .editor = .{ .buf = buf, .find = FindState.init(gpa), .syntax = &entry.syntax } });
        // Moved into the store: the errdefers above must not run from here.
        watch.restamp(self, self.panes.editor(id).?);
        self.showPane(id);
        self.hooks.emit(self, .{ .open = .{ .path = self.relPath(path), .pane = id } });
        return id;
    }

    /// `path` becomes the newest entry of the recent list.
    pub fn noteRecent(self: *App, path: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < self.recent.items.len) {
            if (std.mem.eql(u8, self.recent.items[i], path)) {
                self.gpa.free(self.recent.orderedRemove(i));
            } else i += 1;
        }
        const copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(copy);
        if (self.recent.items.len >= max_recent) self.gpa.free(self.recent.orderedRemove(0));
        try self.recent.append(self.gpa, copy);
    }

    /// A `:` line goes on the history `q:` lists (blanks and repeats skipped).
    /// A command ran: to the front of `recent_commands`, once.
    pub fn noteRecentCommand(self: *App, id: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < self.recent_commands.items.len) {
            if (std.mem.eql(u8, self.recent_commands.items[i], id)) {
                self.gpa.free(self.recent_commands.orderedRemove(i));
            } else i += 1;
        }
        const copy = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(copy);
        while (self.recent_commands.items.len >= max_recent_commands) self.gpa.free(self.recent_commands.pop().?);
        try self.recent_commands.insert(self.gpa, 0, copy);
    }

    /// Where `id` sits in `recent_commands` (0 = newest), or null.
    pub fn recentCommandRank(self: *const App, id: []const u8) ?usize {
        for (self.recent_commands.items, 0..) |c, i| if (std.mem.eql(u8, c, id)) return i;
        return null;
    }

    pub fn noteCmdLine(self: *App, line: []const u8) Allocator.Error!void {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) return;
        if (self.cmd_history.getLastOrNull()) |last| if (std.mem.eql(u8, last, t)) return;
        const copy = try self.gpa.dupe(u8, t);
        errdefer self.gpa.free(copy);
        if (self.cmd_history.items.len >= max_cmd_history) self.gpa.free(self.cmd_history.orderedRemove(0));
        try self.cmd_history.append(self.gpa, copy);
    }

    /// A second window on the same document (a split's starting point):
    /// vim's `:split` — the same text, dirty flag and undo history, its
    /// own cursor, scroll and folds, starting where the source pane is.
    pub fn duplicatePane(self: *App, id: PaneId) !PaneId {
        const src = self.panes.editor(id) orelse return error.NotAnEditor;
        const gpa = self.gpa;
        var buf = try Buffer.initOn(gpa, src.buf.doc, self.input_style, self.editorConfig());
        errdefer buf.deinit();
        buf.editor.setCursor(src.buf.editor.cursor);
        var it = src.buf.editor.folds.iterator();
        while (it.next()) |f| try buf.editor.folds.put(gpa, f.key_ptr.*, f.value_ptr.*);
        const view = src.view;
        const wrap = src.wrap;
        const syn = src.syntax;
        const new_id = try self.panes.add(.{ .editor = .{ .buf = buf, .find = FindState.init(gpa), .syntax = syn, .wrap = wrap, .view = view } });
        return new_id;
    }

    /// A fresh unnamed buffer, shown and focused.
    pub fn openScratch(self: *App) !PaneId {
        return self.openScratchWith("");
    }

    /// // changed (git-more2): a scratch buffer holding `text` — a file
    /// as a commit had it.
    pub fn openScratchWith(self: *App, text: []const u8) !PaneId {
        const gpa = self.gpa;
        var buf = try Buffer.init(gpa, text, self.input_style, self.editorConfig());
        errdefer buf.deinit();
        try self.applyBufferPrefs(&buf);
        const entry = try self.docs.adopt(buf.doc);
        const id = try self.panes.add(.{ .editor = .{ .buf = buf, .find = FindState.init(gpa), .syntax = &entry.syntax } });
        self.showPane(id);
        return id;
    }

    /// Whether `id` may be shown on more than one tab page: an editor —
    /// a buffer, which vim's tab pages share (`:tabnew`, `:e a.txt`
    /// shows the file there too; `tab.close` keeps a pane another page
    /// still shows). Every other pane — a session's pty above all — lives
    /// in one leaf of one page (`LayoutState.holders`).
    pub fn sharedAcrossPages(self: *App, id: PaneId) bool {
        const p = self.panes.get(id) orelse return false;
        return p.* == .editor;
    }

    /// Reveal `id` and focus it: where it already is on this page, else —
    /// for a pane that lives on one page only — on whichever page holds
    /// it, which becomes the page on screen, else as a new tab of the
    /// focused leaf (or a new leaf). Every "go to that pane" gesture (a
    /// SESSIONS card, the sessions table, the dock, a picker) lands
    /// here, so a session on another page is gone to, never pulled into
    /// this one; a file is shown here, as vim shows a buffer in the
    /// current tab page. A new tab asked for from the scratch strip goes
    /// to the editor area instead (the strip hosts terminals only).
    pub fn showPane(self: *App, id: PaneId) void {
        const ls = &self.layouts;
        const shared = self.sharedAcrossPages(id);
        const here = ls.current();
        if (here.leafOf(id)) |lid| {
            here.leaf(lid).?.active = id;
        } else if (!shared and ls.pageOf(id) != null) {
            self.setActive(null);
            ls.active = ls.pageOf(id).?;
            const layout = ls.current();
            layout.leaf(layout.leafOf(id).?).?.active = id;
        } else {
            var where: ?layout_mod.NodeId = if (self.active) |a| here.leafOf(a) else null;
            // The scratch strip (`term.scratch_toggle`) hosts terminals
            // only: anything else opened while it has the focus goes to
            // the editor area, as VS Code's Quick Open always opens into
            // the editor group, never the terminal panel.
            if (where) |w| if (self.scratchLeaf()) |strip| if (w == strip and !self.isTerminal(id)) {
                where = self.editorAreaLeaf(strip) orelse {
                    // The strip is all there is: the file takes the top,
                    // the strip stays at the bottom edge.
                    const scratch = self.scratch_pty.?;
                    _ = here.split(scratch, .vertical, id) catch {};
                    here.moveToEdge(scratch, .bottom) catch {};
                    self.afterSplitChange();
                    self.setActive(id);
                    if (!shared) std.debug.assert(ls.holders(id) <= 1);
                    return;
                };
            };
            _ = here.showIn(where, id) catch {};
        }
        self.setActive(id);
        if (!shared) std.debug.assert(ls.holders(id) <= 1);
    }

    /// The leaf that shows the scratch strip, when it is on screen.
    fn scratchLeaf(self: *App) ?layout_mod.NodeId {
        const id = self.scratch_pty orelse return null;
        return self.layouts.current().leafOf(id);
    }

    fn isTerminal(self: *App, id: PaneId) bool {
        const p = self.panes.get(id) orelse return false;
        return p.* == .pty;
    }

    /// The editor area's leaf, from the strip's point of view: the leaf
    /// of the most recently focused pane outside the strip, else any
    /// other leaf; null when the strip is the only one.
    fn editorAreaLeaf(self: *App, strip: layout_mod.NodeId) ?layout_mod.NodeId {
        const layout = self.layouts.current();
        for (self.pane_mru.items) |p| if (layout.leafOf(p)) |lid| if (lid != strip) return lid;
        const all = layout.leaves(self.frame.allocator()) catch return null;
        for (all) |lid| if (lid != strip) return lid;
        return null;
    }

    /// Move `id` into leaf `lid` as its active tab and focus it. A pane
    /// that lives on one page and is on another is gone to instead
    /// (`showPane`): the page's leaf is the one it lives in.
    pub fn showPaneIn(self: *App, lid: layout_mod.NodeId, id: PaneId) void {
        const layout = self.layouts.current();
        if (layout.leaf(lid) == null) return self.showPane(id);
        const shared = self.sharedAcrossPages(id);
        if (!shared) if (self.layouts.pageOf(id)) |page| if (page != self.layouts.active) return self.showPane(id);
        _ = layout.showIn(lid, id) catch {};
        self.setActive(id);
        if (!shared) std.debug.assert(self.layouts.holders(id) <= 1);
    }

    pub fn setActive(self: *App, id: ?PaneId) void {
        if (self.active != id) {
            if (self.activeBuffer()) |b| b.input.onBlur();
            self.change_nav = null;
            flash_mod.cancel(self);
            // The alternate (`:b#`, `Ctrl-^`): the pane focus just left.
            if (self.active) |prev| self.prev_active = prev;
        }
        self.active = id;
        // The MRU: the focused pane moves to the front.
        if (id) |i| {
            if (std.mem.indexOfScalar(PaneId, self.pane_mru.items, i)) |at| _ = self.pane_mru.orderedRemove(at);
            self.pane_mru.insert(self.gpa, 0, i) catch {};
        }
        // The focused pane is its leaf's shown tab. On a zoomed page the
        // zoom follows the focus: the page shows the focused split, so a
        // focus step (`Ctrl-W w`, a click in the tree, `:b N`) never
        // lands the keys in a split nobody can see.
        if (id) |i| {
            const layout = self.layouts.current();
            if (layout.leafOf(i)) |lid| {
                layout.leaf(lid).?.active = i;
                if (layout.zoomed != null) layout.zoomed = i;
            }
        }
        if (id) |i| if (self.panes.editor(i) != null) {
            self.last_editor = i;
        };
        self.focus = if (id != null) .{ .pane = id.? } else .tree;
        self.needs_render = true;
        self.hooks.emit(self, .{ .pane_focus = .{ .pane = id } });
    }

    /// True when `id` is an editor whose document another pane also
    /// shows: closing it is a window going, not a buffer.
    pub fn isSharedView(self: *App, id: PaneId) bool {
        const e = self.panes.editor(id) orelse return false;
        return e.buf.doc.hasOtherView(e.buf.editor);
    }

    /// `:bd`: close the buffer — every window on `id`'s document goes,
    /// the last one through `closePane` so a dirty document still gets
    /// its Save / Discard / Cancel box (or `force`).
    pub fn closeDocument(self: *App, id: PaneId, force: bool) Allocator.Error!void {
        const e = self.panes.editor(id) orelse return self.closePane(id, force);
        const doc = e.buf.doc;
        var again = true;
        while (again) {
            again = false;
            for (self.panes.slots.items, 0..) |*slot, i| {
                const p = &(slot.* orelse continue);
                const other = p.asEditor() orelse continue;
                if (other.buf.doc != doc or i == id) continue;
                try self.forceClosePane(@intCast(i));
                again = true;
                break;
            }
        }
        try self.closePane(id, force);
    }

    /// Close `id`. A dirty editor gets the Save / Discard / Cancel box
    /// instead; `force` skips it (discarding). A window on a document
    /// another pane still shows just goes — the text lives on there.
    pub fn closePane(self: *App, id: PaneId, force: bool) Allocator.Error!void {
        const pane = self.panes.get(id) orelse return;
        if (self.isSharedView(id)) return self.forceClosePane(id);
        if (!force and pane.dirty()) {
            const msg = try std.fmt.allocPrint(self.gpa, "{s} has unsaved changes.", .{pane.title()});
            errdefer self.gpa.free(msg);
            self.overlay.deinit(self.gpa);
            self.overlay = .{ .confirm = .{
                .state = .{ .title = "Unsaved changes", .message = msg, .choices = &close_choices },
                .purpose = .{ .close_pane = id },
                .message = msg,
            } };
            self.focus = .overlay;
            return;
        }
        if (force and pane.dirty()) self.toast("discarded unsaved changes", .{});
        try self.forceClosePane(id);
    }

    pub const close_choices = [_]Confirm.Choice{ .{ .key = 's', .label = "Save" }, .{ .key = 'd', .label = "Discard" }, .{ .key = 'c', .label = "Cancel" } };

    /// // changed (bottom-row): the quit box's own buttons. A quit is
    /// not a close: `Discard` says nothing about how many buffers go or
    /// that the session ends, and `Save` reads as "save this one".
    pub const quit_choices = [_]Confirm.Choice{ .{ .key = 's', .label = "Save all" }, .{ .key = 'q', .label = "Quit anyway" }, .{ .key = 'c', .label = "Cancel" } };

    /// // changed (quit-confirm): the same box with nothing to lose.
    /// There is no work to save, so the offer is the quit itself — and
    /// Cancel still holds the focus, because the reason to stop and ask
    /// on a clean workspace is the mis-hit chord, not the unsaved file.
    pub const quit_clean_choices = [_]Confirm.Choice{ .{ .key = 'q', .label = "Quit" }, .{ .key = 'c', .label = "Cancel" } };

    /// `app.restart` over unsaved work: the relaunch starts from the
    /// files on disk, so the dirty buffers are saved or given up first.
    pub const restart_choices = [_]Confirm.Choice{ .{ .key = 's', .label = "Save all" }, .{ .key = 'r', .label = "Restart anyway" }, .{ .key = 'c', .label = "Cancel" } };

    /// The dirty buffers by name, in pane order — what the quit box
    /// lists. A count alone ("2 buffer(s) have unsaved changes") does
    /// not tell the user whether the work about to go is the scratch
    /// note or the file they have been on all morning.
    pub fn dirtyBufferNames(self: *App, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| if (p.dirty()) {
            if (out.items.len > 0) try out.appendSlice(arena, ", ");
            try out.appendSlice(arena, p.title());
        };
        return out.items;
    }

    /// // changed (quit-confirm): the terminals whose child is still
    /// alive, in pane order — what the clean quit box names. A shell
    /// mid-`cargo build`, or a Claude session still answering, is the
    /// one thing a clean workspace still has to lose; a dormant pane
    /// restored from `session.zon` has no child and is not one.
    pub fn runningTerminalNames(self: *App, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| if (p.* == .pty) {
            if (p.pty.exit != null or p.pty.dormant) continue;
            if (out.items.len > 0) try out.appendSlice(arena, ", ");
            try out.appendSlice(arena, p.title());
        };
        return out.items;
    }

    pub fn forceClosePane(self: *App, id: PaneId) Allocator.Error!void {
        const pane = self.panes.get(id) orelse return;
        // // changed (bottom-dock): a closed pane cannot stay hosted.
        bottom_mod.forget(self, id);
        // A graph tab closed is a repo hidden for the session (Rust `close_pane`).
        if (pane.* == .git_graph) if (self.git.repoById(pane.git_graph.repo)) |r| try git_palette_app.noteClosed(self, r.path);
        // Editors and markdown previews are files: they can come back —
        // once the last window on the file goes.
        const shared = self.isSharedView(id);
        const closed_file: ?ClosedBuffer = if (pane.asEditor()) |e|
            (if (!shared) (if (e.buf.doc.path) |p| .{ .path = @constCast(p), .cursor = e.buf.editor.cursor } else null) else null)
        else switch (pane.*) {
            .md_preview => |*m| .{ .path = m.path, .cursor = 0 },
            else => null,
        };
        if (closed_file) |c| {
            const copy = try self.gpa.dupe(u8, c.path);
            errdefer self.gpa.free(copy);
            if (self.closed.items.len >= max_closed) self.gpa.free(self.closed.orderedRemove(0).path);
            try self.closed.append(self.gpa, .{ .path = copy, .cursor = c.cursor });
        }
        if (self.find_bar) |*fb| if (fb.pane == id) self.closeFindBar(false);
        if (self.block_insert) |b| if (b.pane == id) {
            self.block_insert = null;
        };
        if (self.repeat_insert) |r| if (r.pane == id) {
            self.repeat_insert = null;
        };
        // The language server hears about the last editor on a file
        // closing, once the store no longer has it.
        const closed_path: ?[]const u8 = if (pane.asEditor()) |e| (if (e.buf.doc.path) |p| try self.frame.allocator().dupe(u8, p) else null) else null;
        const layout = self.layouts.current();
        const next = layout.removePane(id);
        self.afterSplitChange();
        self.panes.remove(id);
        if (closed_path) |p| lsp.onClose(self, id, p);
        if (closed_path) |p| copilot_app.onClose(self, p);
        files_pane.onPaneClosed(self, id);
        jobs_mod.onPaneClosed(self, id);
        if (self.last_editor == id) self.last_editor = null;
        if (self.outline_panel == id) self.outline_panel = null;
        if (std.mem.indexOfScalar(PaneId, self.pane_mru.items, id)) |at| _ = self.pane_mru.orderedRemove(at);
        if (self.prev_active == id) self.prev_active = null;
        if (self.active == id) {
            const fallback: ?PaneId = next orelse if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null;
            self.active = null;
            self.setActive(fallback);
        }
        self.needs_render = true;
    }

    /// Switch every buffer and the keymap to `style`.
    pub fn setInputStyle(self: *App, style: input.Style) Allocator.Error!void {
        self.input_style = style;
        self.cfg.editor.input_style = configStyleOf(style);
        var km = try buildKeymap(self.gpa, style, self.cfg.keys);
        self.keymap.deinit();
        self.keymap = km;
        km = undefined;
        self.chord.clear(self.gpa);
        if (self.lua != null) try script_api.rebind(self);
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| e.buf.setInputStyle(style, self.editorConfig()),
            else => {},
        };
        self.needs_render = true;
    }

    /// The tree-sitter text-object provider every editor pane gets: the
    /// pane whose editor asked answers from its own syntax state.
    fn objectLookup(ctx: *anyopaque, ed: *const edit_op_editor.Editor, kind: edit_op_editor.ObjectKind, byte: usize, around: bool) ?[2]usize {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| if (e.buf.editor == ed) return e.syntax.objectRange(ed, kind, byte, around),
            else => {},
        };
        return null;
    }

    /// Install the app's seams on an editor pane (idempotent; called on
    /// the way into every key and op).
    pub fn attachSeams(self: *App, e: *EditorPane) void {
        e.buf.editor.objects = .{ .ctx = self, .lookup = &objectLookup };
        e.buf.macros_by_app = true;
    }

    /// Which mnml this is — the installed one or the one being worked
    /// on. It rides in the environment (`MNML_PROFILE`), so a pane, a
    /// spawned integration and the session file all read the same
    /// answer without anything being threaded through
    /// (`src/config/profile.zig`).
    pub fn profile(self: *const App) config.Profile {
        return config.profile.of(&self.env);
    }

    /// Whether this is a `--sandbox` run (`config/sandbox.zig`): `.on`
    /// when `MNML_SANDBOX` is set and the home and data root really are
    /// throwaway, `.unsafe` when the variable is set but they are not.
    pub fn sandboxState(self: *const App) config.sandbox.State {
        return config.sandbox.state(&self.env, self.data_root);
    }

    /// Workspace-relative when inside it, else the path itself. The
    /// separator after the workspace is either one on Windows: a path
    /// `absPath` joined there reads `<ws>\<rel>`, and a `/` never matched
    /// it, so every toast and title named the whole path.
    pub fn relPath(self: *const App, path: []const u8) []const u8 {
        if (std.mem.startsWith(u8, path, self.workspace) and path.len > self.workspace.len and std.fs.path.isSep(path[self.workspace.len])) {
            return path[self.workspace.len + 1 ..];
        }
        return path;
    }

    /// `<workspace>/<rel>` on the frame arena; absolute input passes through.
    /// On Windows the result takes the native separator throughout: the
    /// workspace-relative names the lists keep are `/`-joined, and a
    /// mixed `D:\ws\lib/bb.txt` compares unequal to the buffer's own
    /// `D:\ws\lib\bb.txt` (a delete then left the buffer open).
    pub fn absPath(self: *App, rel: []const u8) Allocator.Error![]const u8 {
        if (std.fs.path.isAbsolute(rel)) return rel;
        const joined = try std.fs.path.join(self.frame.allocator(), &.{ self.workspace, rel });
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, joined, '/', '\\');
        return joined;
    }

    /// `ui.auto_equalize_splits`: a split just opened or closed — even
    /// them out.
    /// `view.toggle_zoom`: the pane whose leaf alone paints over the
    /// body of the page on screen, if the page is zoomed and the pane is
    /// still in its tree (`Layout.zoomed`).
    pub fn zoomedPane(self: *const App) ?PaneId {
        const layout = &self.layouts.layouts.items[self.layouts.active];
        const z = layout.zoomed orelse return null;
        return if (layout.leafOf(z) != null) z else null;
    }

    pub fn afterSplitChange(self: *App) void {
        if (self.cfg.ui.auto_equalize_splits) self.layouts.current().equalize();
    }

    /// `~` / `~/…` (and `~\…` on Windows) → the home directory (the
    /// config's, else the process's); anything else unchanged. Frame arena.
    pub fn expandTilde(self: *App, text: []const u8) Allocator.Error![]const u8 {
        return os_path.expandTilde(self.frame.allocator(), text, self.userHome(), .native);
    }

    // ─── text mutation helpers every subsystem goes through ───

    /// Run editor ops on `pane`. Returns whether the text changed. An op
    /// the editor refuses is toasted by name.
    pub fn applyOps(self: *App, pane: *EditorPane, ops: []const edit_op.EditOp) Allocator.Error!bool {
        self.attachSeams(pane);
        const changed = try pane.buf.applyOps(ops, &self.clipboard, self.pane_rows, self.frame.allocator());
        if (pane.buf.last_unsupported) |name| {
            self.toast("{s}: not supported yet", .{name});
            pane.buf.last_unsupported = null;
        }
        if (changed) {
            pane.syntax.dirty = true;
            self.needs_render = true;
            if (self.paneIdOf(pane)) |id| snippets.afterEdit(self, id, pane);
        }
        return changed;
    }

    /// The id of an editor pane, by address.
    pub fn paneIdOf(self: *App, e: *const EditorPane) ?PaneId {
        for (self.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
            .editor => |*ep| if (ep == e) return @intCast(i),
            else => {},
        };
        return null;
    }

    /// Replace `[start, end)` with `text` as one undo step, cursor after it.
    pub fn splice(self: *App, pane: *EditorPane, start: usize, end: usize, text: []const u8) Allocator.Error!void {
        _ = try self.applyOps(pane, &.{.{ .replace_range = .{ .start = start, .end = end, .text = text } }});
    }

    /// Close the find bar; `restore` puts the pre-open find state back.
    /// Where a picker or prompt opened now sends focus back on Esc: the
    /// tree or a panel it was opened from, or what the overlay it
    /// replaces would have gone back to; null is the active pane.
    pub fn overlayReturnFocus(self: *const App) ?FocusId {
        return switch (self.focus) {
            .tree, .panel => self.focus,
            .overlay => switch (self.overlay) {
                .picker => |p| p.return_focus,
                .prompt => |p| p.return_focus,
                else => null,
            },
            else => null,
        };
    }

    pub fn closeFindBar(self: *App, restore: bool) void {
        const fb = &(self.find_bar orelse return);
        // A terminal's bar leaves its selection on the current match.
        if (self.panes.pty(fb.pane)) |p| @import("app/pty_search.zig").barClosed(self, p, restore);
        // A pending operator whose search was cancelled goes too.
        if (fb.operator) if (self.panes.editor(fb.pane)) |e| if (e.buf.input.isOpPending()) e.buf.input.onBlur();
        if (fb.snapshot) |*snap| {
            if (restore) {
                if (self.panes.editor(fb.pane)) |e| {
                    e.find.deinit();
                    e.find = snap.*;
                    e.buf.editor.setCursor(@min(fb.snapshot_cursor, e.buf.editor.len()));
                    snap.* = undefined;
                    fb.snapshot = null;
                } else if (self.panes.get(fb.pane)) |p| if (p.asRequest()) |rp| {
                    rp.resp_find.deinit();
                    rp.resp_find = snap.*;
                    rp.resp_cursor = @min(fb.snapshot_cursor, rp.respFindText().len);
                    snap.* = undefined;
                    fb.snapshot = null;
                };
            }
            if (fb.snapshot) |*s| s.deinit();
        }
        fb.state.deinit(self.gpa);
        if (fb.hist_prefix) |pfx| self.gpa.free(pfx);
        self.find_bar = null;
        if (self.focus == .overlay) self.focus = if (self.active) |a| .{ .pane = a } else .tree;
        self.needs_render = true;
    }

    /// How many background transfers are still writing.
    pub fn transfersRunning(self: *App) usize {
        return transfers.running(self);
    }

    /// Any pane with unsaved changes?
    pub fn anyDirty(self: *App) bool {
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| if (p.dirty()) return true;
        return false;
    }

    // ─── overlays every subsystem can open ───

    /// Open a context menu. Takes ownership of `items` (gpa); the labels
    /// must be literals or otherwise outlive the menu.
    /// The open overlay's name for `rects.json` (`HitMap.writeRectsJson`):
    /// its rows are labelled `<name>:<idx>` so a dump tells a picker's
    /// rows from a settings row. The command palette is a picker of
    /// commands and reads `palette`. Null with no overlay up.
    pub fn overlayLabel(self: *const App) ?[]const u8 {
        return switch (self.overlay) {
            .none => null,
            .picker => |*p| if (p.kind == .commands) "palette" else "picker",
            inline else => |_, tag| @tagName(tag),
        };
    }

    pub fn openMenu(self: *App, title: []const u8, items: []command.MenuItem, x: u16, y: u16) Allocator.Error!void {
        const owned_title = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(owned_title);
        self.overlay.deinit(self.gpa);
        const back: FocusId = if (self.focus == .overlay) (if (self.active) |a| .{ .pane = a } else .tree) else self.focus;
        self.overlay = .{ .menu = .{ .title = owned_title, .items = items, .x = x, .y = y, .return_focus = back } };
        self.focus = .overlay;
        self.needs_render = true;
    }

    // ─── the loop's three entry points ───

    pub fn handle(self: *App, ev: AppEvent) Allocator.Error!void {
        script_task.startDeferred(self);
        // A wheel burst folds into one motion; anything else flushes
        // what is pending first so order is kept (`scroll.zig`). A
        // wheel event the batch would not take — the other direction,
        // another cell, the cap — starts the next batch after the
        // flush rather than landing raw ahead of it.
        if (ev == .mouse) {
            if (self.wheel.offer(ev.mouse)) return;
            try self.flushWheel();
            if (self.wheel.offer(ev.mouse)) return;
        } else try self.flushWheel();
        self.last_was_wheel = false;
        switch (ev) {
            .key => |k| {
                // // changed (sidebar-autohide): a revealed column
                // whose keys this chord took away (Esc, `Ctrl-W l`, a
                // focus command) goes with them.
                const focus_before = self.focus;
                try dispatch.key(self, k);
                sidebar_auto.afterKey(self, focus_before);
            },
            .mouse => |m| try self.routeMouse(m, 1),
            .winsize => |ws| try self.resize(ws.cols, ws.rows),
            .paste => |text| {
                defer self.gpa.free(text);
                try dispatch.paste(self, text);
            },
            // The host window's focus: a focused terminal pane's child
            // hears it too (DEC 1004, `pty_pane.tickAll`), and a dirty
            // buffer autosaves when the window loses it.
            .focus => |f| {
                self.host_focused = f;
                if (!f) autosave.onFocusLost(self);
            },
            // D1: the payload is the handler's to adopt or free.
            .todos => |result| try todos.handle(self, result),
            .notes => |result| try notes.handle(self, result),
            .findings => |result| try findings.handle(self, result),
            .sessions => |result| try sessions.handle(self, result),
            .dock => |result| try dock.handle(self, result),
            .git => |result| try git_app.handle(self, result),
            .spend => |result| try spend.handle(self, result),
            .usage => |result| try usage_pane.handle(self, result),
            .tests => |result| try tests_pane.handle(self, result),
            .grep => |result| try grep.handle(self, result),
            .script_task => |t| script_task.handle(self, t),
            .syntax => |r| syntax_jobs.handle(self, r),
            .job => |j| jobs_mod.handleEvent(self, j),
            .ai => |a| try ai_app.handle(self, a.job, a.msg),
            .dap => |d| try dap.handle(self, d.session, d.msg),
            .lsp => |l| try lsp.handle(self, l.server, l.msg),
            .copilot => |c| try copilot_app.handle(self, c.msg),
            .http => |result| try http_app.handle(self, result),
            .sse => |chunk| try http_app.handleStream(self, chunk),
            .ws => |wev| try ws_pane.handle(self, wev),
            .cdp => |cev| try browser_pane.handle(self, cev),
            .mount => |mev| try mount_pane.handle(self, mev),
            .marketplace => |r| try marketplace.handle(self, r),
            .fonts => |r| try font_scan.handle(self, r),
            .transfer => |tev| try transfers.handle(self, tev),
            .pty_readable => |id| pty_pane.onReadable(self, id),
            .err => |e| {
                defer self.gpa.free(e.msg);
                if (e.source == .todos) self.todos.scanning = false;
                if (e.source == .notes) self.notes.scanning = false;
                if (e.source == .findings) self.findings.scanning = false;
                if (e.source == .sessions) self.sessions.scanning = false;
                if (e.source == .git) {
                    self.git.status_pending = false;
                    if (self.git.busy > 0) self.git.busy -= 1;
                    git_app.onWorkerErr(self, e.msg);
                }
                // A chain whose worker could not even read its file.
                if (e.source == .http) jobs_mod.endKeyed(self, .http, http_app.chain_job_key, jobs_mod.Outcome.fail(e.msg));
                try self.toastLevel(.err, "{s}: {s}", .{ @tagName(e.source), e.msg });
            },
            .timer => {},
            // `run.sh stop` / `restart` through the IPC command file: the
            // same exits `app.quit` / `app.restart` reach from the palette.
            .ipc => |e| {
                defer e.destroy();
                switch (e.cmd) {
                    .quit => self.quit = true,
                    .restart => {
                        self.restart = true;
                        self.quit = true;
                    },
                    // Everything else goes through the one dispatcher
                    // the headless driver uses, so a segment an
                    // integration publishes lands the same either way.
                    // Input only arrives here when `ipc.allow_input` let
                    // the loop post it (`tui/loop.zig`); it becomes the
                    // key and mouse events a person's hands would.
                    else => {
                        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                        defer arena_state.deinit();
                        if (!try ipc.effects.applyInput(self, arena_state.allocator(), &e.cmd) and
                            !try ipc.effects.applyTier2(self, &e.cmd))
                        {
                            self.toast("ipc {s}: not in this build", .{@tagName(e.cmd)});
                        }
                    },
                }
            },
            else => event.freeEvent(self.gpa, ev),
        }
        self.needs_render = true;
    }

    /// The pending wheel batch, if any, lands as one scroll.
    pub fn flushWheel(self: *App) Allocator.Error!void {
        const batch = self.wheel.take() orelse return;
        if (self.needs_render and !self.last_was_wheel) try self.render();
        self.wheel_budget = null;
        try dispatch.mouse(self, batch.mouse, batch.count);
        self.last_was_wheel = true;
    }

    /// A mouse event against a fresh hit map: a frame that changed
    /// since the last render is re-rendered first, so the rects the
    /// previous frame registered cannot route a click on this one.
    fn routeMouse(self: *App, m: key_mod.Mouse, count: u16) Allocator.Error!void {
        if (self.needs_render) try self.render();
        self.wheel_budget = null;
        // // changed (sidebar-autohide): what the press landed on, and
        // where the keys were, BEFORE it is dispatched — a revealed
        // side column hides itself the moment a click on it opens
        // something, and "opened something" is exactly "the keys left
        // the panel for a pane, or a different pane became active".
        const on_overlay = self.sidebar_auto.open != null and self.sidebar_auto.rect.contains(m.x, m.y);
        // // changed (launcher-dock): the strip holds the keyboard only
        // while the hand is on it — a press anywhere else hands the keys
        // back, so `h` / `l` never go missing in the editor because the
        // dock was focused a minute ago.
        const on_dock = self.launcher_dock.kb and self.launcher_dock.rect.contains(m.x, m.y);
        const focus_before = self.focus;
        const active_before = self.active;
        try dispatch.mouse(self, m, count);
        if (self.launcher_dock.kb and !on_dock and m.kind == .press) launcher_dock_mod.leaveKeyboard(self);
        if (on_overlay) {
            const did_open = (self.focus == .pane and !std.meta.eql(focus_before, self.focus)) or
                (self.active != null and !std.meta.eql(active_before, self.active));
            sidebar_auto.afterClick(self, did_open);
        }
    }

    /// `[editor] wheel_moves_cursor`: whether the wheel and a scrollbar
    /// drag carry the cursor with the view. `always` / `never` say so;
    /// `auto` follows the input style — vim's Ctrl-E / Ctrl-Y canon
    /// moves the cursor, the standard editors pin the view and leave
    /// the cursor where it was.
    pub fn cursorFollowsWheel(self: *const App) bool {
        return switch (self.cfg.editor.wheel_moves_cursor) {
            .always => true,
            .never => false,
            .auto => self.input_style == .vim,
        };
    }

    /// Drain the inbound queue without blocking. The terminal loop does
    /// this itself before `tick`; the headless / `.test` drivers reach it
    /// through `tick`, so a worker's result lands there too.
    /// // changed: D3 has the runner call `pumpEvents` beside `tick`;
    /// `tick` calls it instead so the `e2e.Driver` vtable stays as is.
    pub fn pumpEvents(self: *App) Allocator.Error!void {
        var buf: [64]AppEvent = undefined;
        while (true) {
            const n = self.events.drain(self.io, &buf);
            if (n == 0) break;
            // Terminal output is pumped by `tick` after this drain (see
            // the terminal loop), once per pass and behind the input.
            for (buf[0..n]) |ev| if (ev != .pty_readable) try self.handle(ev);
        }
    }

    pub fn resize(self: *App, cols: u16, rows: u16) Allocator.Error!void {
        if (self.screen.width == cols and self.screen.height == rows) return;
        var fresh = try vaxis.Screen.init(self.gpa, .{ .cols = cols, .rows = rows, .x_pixel = 0, .y_pixel = 0 });
        fresh.width_method = .unicode;
        self.screen.deinit(self.gpa);
        self.screen = fresh;
        self.needs_render = true;
    }

    /// Timers: the chord chain, toast expiry, the deferred replays.
    pub fn tick(self: *App, now: i64) Allocator.Error!void {
        script_task.startDeferred(self);
        self.now_ms = now;
        try self.pumpEvents();
        try self.flushWheel();
        try integrations.tick(self);
        if (self.chord.deadline_ms) |d| if (now >= d) try dispatch.expireChords(self);
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            const t = self.toasts.items[i];
            // A persistent toast sits at maxInt and never gets here.
            if (now >= t.expires_ms) {
                freeToast(self.gpa, self.toasts.orderedRemove(i));
                self.needs_render = true;
            } else i += 1;
        }
        if (self.undo_chip) |u| if (now >= u.expires_ms) self.dropUndo();
        try dispatch.finishDeferredInserts(self);
        if (self.theme_auto_poll_ms) |at| if (now >= at) try @import("app/cmd_view.zig").pollSystemTheme(self);
        pty_pane.tickAll(self);
        try @import("app/pty_search.zig").tickAll(self);
        runners.onFrame(self);
        dap.pollPendingLaunch(self);
        ws_pane.tickAll(self);
        try watch.tick(self, now);
        todos.tick(self, now);
        sessions.tick(self, now);
        clock.tick(self);
        now_playing.tick(self, now);
        integration_poll.tick(self);
        broker_app.tick(self, now);
        if (self.click_echo) |e| if (now >= e.until_ms) {
            self.click_echo = null;
            self.needs_render = true;
        };
        dock.tick(self, now);
        try git_app.tick(self, now);
        try lsp.tick(self, now);
        jobs_mod.tick(self, now);
        try ai_app.tick(self);
        try http_app.tick(self, now);
        idle.tick(self, now);
        autosave.tick(self, now);
        // Every state ticks — an installed script's segments poll and its
        // tasks finish as `init.lua`'s do. By index: a tick may install or
        // remove a script.
        try self.script().tick(now);
        var si: usize = 0;
        while (si < self.scripts.entries.items.len) : (si += 1) if (self.scripts.entries.items[si].state) |l| {
            l.app = self;
            try l.tick(now);
        };
        try cmd_picker.tick(self, now);
        try update.tick(self);
        session.tick(self, now);
        trash.tick(self, now);
        discovery_app.tick(self, now);
        sidebar_auto.tick(self, now);
        launcher_dock_mod.tick(self, now);
        focus_follow.tick(self, now);
        info_view_app.tick(self, now);
    }

    /// The next moment `tick` has something to do, or null when idle.
    pub fn nextDeadlineMs(self: *const App) ?i64 {
        var next: ?i64 = self.chord.deadline_ms;
        // A terminal pane's output is still ringed: another bounded pump
        // is due at once (`pty_pane.backlog`).
        if (pty_pane.backlog(self)) return self.now_ms;
        if (self.theme_auto_poll_ms) |at| next = @min(next orelse std.math.maxInt(i64), at);
        // A pane waiting out the highlight idle gate wants a frame then.
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            // (A document a worker is parsing wakes the loop with its
            // result, not with a deadline.)
            .editor => |*e| if (e.syntax.dirty and e.syntax.pending == null) {
                const due = (e.syntax.since_ms orelse self.now_ms) + syntax.idle_ms;
                next = @min(next orelse std.math.maxInt(i64), due);
            },
            else => {},
        };
        // The TODOS panel's debounced rescan.
        if (self.todos.rescan_at_ms) |at| next = @min(next orelse std.math.maxInt(i64), at);
        // A spinner is animating: keep frames coming.
        if (self.todos.scanning or self.notes.scanning or self.findings.scanning or self.sessions.scanning or self.git.busy > 0 or self.http.sending > 0 or self.lsp.deferred != null or marketplace.busy(self)) next = @min(next orelse std.math.maxInt(i64), self.now_ms + 80);
        // The status TTL: a frame is due when the snapshot goes stale.
        if (self.git.activeRepo() != null and !self.git.status_pending) next = @min(next orelse std.math.maxInt(i64), self.git.status_at_ms + git_app.status_ttl_ms);
        if (ai_app.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (transfers.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (jobs_mod.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (now_playing.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (sessions.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (dock.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (clock.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (coverage.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (@import("app/lsp_format.zig").nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (self.click_echo) |e| next = @min(next orelse std.math.maxInt(i64), e.until_ms);
        if (ws_pane.nextDeadline(@constCast(self))) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (idle.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (autosave.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (hover_zones.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (sidebar_auto.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (focus_follow.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (info_view_app.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (launcher_dock_mod.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (self.lua) |l| if (l.nextDeadlineMs()) |d| {
            next = @min(next orelse std.math.maxInt(i64), d);
        };
        for (self.scripts.entries.items) |*se| if (se.state) |l| if (l.nextDeadlineMs()) |d| {
            next = @min(next orelse std.math.maxInt(i64), d);
        };
        if (cmd_picker.nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        if (@import("app/pty_search.zig").nextDeadlineMs(self)) |d| next = @min(next orelse std.math.maxInt(i64), d);
        for (self.toasts.items) |t| {
            if (t.expires_ms == std.math.maxInt(i64)) continue;
            if (next == null or t.expires_ms < next.?) next = t.expires_ms;
        }
        if (self.undo_chip) |u| next = @min(next orelse std.math.maxInt(i64), u.expires_ms);
        return next;
    }

    /// One frame into the app's own screen (the headless / `.test` path).
    pub fn render(self: *App) Allocator.Error!void {
        try self.renderInto(&self.screen);
    }

    /// One frame into any screen (the terminal loop paints into the
    /// terminal's).
    pub fn renderInto(self: *App, screen: *vaxis.Screen) Allocator.Error!void {
        self.keepEditedPreviews();
        const t0 = Io.Timestamp.now(self.io, .awake);
        try render_mod.render(self, screen);
        const us = @divTrunc(t0.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds, 1000);
        self.stress.push(@intCast(std.math.clamp(us, 0, std.math.maxInt(u32))));
        self.needs_render = false;
    }

    /// The first edit keeps a preview tab: the user is working in the
    /// file, not glancing at it. Swept once a frame rather than hooked
    /// into the editor, so every path that can dirty a buffer — a key,
    /// an LSP edit, a macro replay, a snippet, the IPC channel — is
    /// covered by the one rule.
    pub fn keepEditedPreviews(self: *App) void {
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| if (e.preview and e.buf.doc.dirty) {
                e.preview = false;
            },
            // A request pane records its own edit (`http.findPreview`
            // has always refused to replace an edited one); the tab
            // stops painting italic with it.
            .request => |*r| if (r.is_preview and r.edited) {
                r.is_preview = false;
            },
            else => {},
        };
    }

    /// A `Ui` over the app's own screen and hit map, for a dispatcher
    /// that needs a component's measurements (where the strip's tabs
    /// sit) outside a frame.
    pub fn frameUi(self: *App) Ui {
        return .{
            .canvas = Canvas.init(&self.screen, .{}),
            .hits = &self.hits,
            .theme = &self.theme,
            .arena = self.frame.allocator(),
            .focus = self.focus,
            .ascii = self.cfg.ui.ascii_icons,
            .triangle = self.cfg.ui.expand_indicator == .triangle,
        };
    }

    /// The rendered-toast view for the toast component.
    pub fn visibleToasts(self: *App, arena: Allocator) Allocator.Error![]toast_mod.Toast {
        var out: std.ArrayListUnmanaged(toast_mod.Toast) = .empty;
        // toast.draw wants the newest first: index 0 lands nearest the
        // statusline and the oldest is what folds into "+K more…".
        var i = self.toasts.items.len;
        while (i > 0) : (i -= 1) try out.append(arena, .{
            .text = self.toasts.items[i - 1].text,
            .level = switch (self.toasts.items[i - 1].level) {
                .info => .info,
                .warn => .warn,
                .err => .err,
            },
            .action = if (self.toasts.items[i - 1].action) |a| a.label() else null,
        });
        return out.items;
    }
};

test {
    _ = @import("app/trust.zig");
    _ = @import("app/autosave.zig");
    _ = @import("app/cmdline.zig");
    _ = @import("app/flash.zig");
    _ = @import("app/settings.zig");
    _ = @import("app/line_blame.zig");
    _ = @import("app/first_launch.zig");
    _ = @import("app/key_doctor.zig");
    _ = @import("app/icon_picker.zig");
    _ = @import("app/pane.zig");
    _ = @import("app/outline.zig");
    _ = @import("app/md_preview.zig");
    _ = @import("app/docs.zig");
    _ = @import("app/picker_preview.zig");
    _ = @import("app/zon_pane.zig");
    _ = @import("app/image_pane.zig");
    _ = @import("app/discovery.zig");
    _ = @import("app/workspace_trust.zig");
    _ = @import("image/root.zig");
    _ = @import("image/kitty.zig");
    _ = @import("image/iterm2.zig");
    _ = @import("image/sixel.zig");
    _ = @import("image/painter.zig");
    _ = @import("ui/tooltip.zig");
    _ = @import("ui/menu_glyph.zig");
    _ = @import("ui/contrast.zig");
    _ = @import("app/info_view_copy/panels.zig");
    _ = @import("app/snippets.zig");
    _ = @import("app/sticky.zig");
    _ = @import("ui/outline_view.zig");
    _ = @import("ui/md_view.zig");
    _ = @import("app/layout.zig");
    _ = @import("app/arrange.zig");
    _ = @import("app/find.zig");
    _ = @import("app/syntax.zig");
    _ = @import("app/whichkey.zig");
    _ = @import("app/focus_follow.zig");
    _ = @import("app/tree.zig");
    _ = @import("app/ex.zig");
    _ = @import("app/dispatch.zig");
    _ = @import("app/render.zig");
    _ = @import("app/cmd_file.zig");
    _ = @import("app/cmd_buffer.zig");
    _ = @import("app/cmd_editor.zig");
    _ = @import("app/cmd_find.zig");
    _ = @import("app/pty_search.zig");
    _ = @import("app/cmd_view.zig");
    _ = @import("app/cmd_picker.zig");
    _ = @import("app/cmd_app.zig");
    _ = @import("app/cmd_tab.zig");
    _ = @import("app/scroll.zig");
    _ = @import("app/context_menus.zig");
    _ = @import("app/cheatsheet.zig");
    _ = @import("app/cmd_term.zig");
    _ = @import("app/mount_pane.zig");
    _ = @import("app/integrations.zig");
    _ = @import("app/integrations_tools.zig");
    _ = @import("app/setup.zig");
    _ = @import("app/markdown_links.zig");
    _ = @import("app/bookmarks.zig");
    _ = @import("ui/integrations_view.zig");
    _ = @import("bridge/manifest.zig");
    _ = @import("app/marketplace.zig");
    _ = @import("app/marketplace_catalogue.zig");
    _ = @import("app/marketplace_release.zig");
    _ = @import("ui/mount_view.zig");
    _ = @import("bridge/wire.zig");
    _ = @import("bridge/host.zig");
    _ = @import("app/pty_pane.zig");
    _ = @import("app/pty_env.zig");
    _ = @import("app/shell_integration.zig");
    _ = @import("app/http.zig");
    _ = @import("app/http_panel.zig");
    _ = @import("app/cmd_http.zig");
    _ = @import("app/http_ops.zig");
    _ = @import("app/request_pane.zig");
    _ = @import("ui/request_view.zig");
    _ = @import("http/parse.zig");
    _ = @import("http/env.zig");
    _ = @import("http/client.zig");
    _ = @import("http/mock.zig");
    _ = @import("http/history.zig");
    _ = @import("http/cookies.zig");
    _ = @import("http/jwt.zig");
    _ = @import("http/sse.zig");
    _ = @import("http/script.zig");
    _ = @import("http/schema.zig");
    _ = @import("http/import.zig");
    _ = @import("http/captured.zig");
    _ = @import("http/chain.zig");
    _ = @import("http/bench.zig");
    _ = @import("http/ws.zig");
    _ = @import("cdp/client.zig");
    _ = @import("cdp/profile.zig");
    _ = @import("cdp/console.zig");
    _ = @import("app/ws_pane.zig");
    _ = @import("app/browser_pane.zig");
    _ = @import("app/cmd_browser.zig");
    _ = @import("app/runners.zig");
    _ = @import("app/dotnet.zig");
    _ = @import("app/tasks.zig");
    _ = @import("app/watch.zig");
    _ = @import("ui/pty_view.zig");
    _ = @import("ui/accent_color.zig");
    _ = @import("ui/pane_rail.zig");
    _ = @import("ui/focus_cue.zig");
    _ = @import("app/pane_accent.zig");
    _ = @import("app/ai.zig");
    _ = @import("app/agents.zig");
    _ = @import("app/sessions_table.zig");
    _ = @import("app/welcome.zig");
    _ = @import("app/cloud_agents.zig");
    _ = @import("ui/sessions_table_view.zig");
    _ = @import("app/spend.zig");
    _ = @import("app/grep.zig");
    _ = @import("app/jumplist.zig");
    _ = @import("app/gitignore.zig");
    _ = @import("ai/suggest.zig");
    _ = @import("ai/copilot.zig");
    _ = @import("copilot/client.zig");
    _ = @import("app/copilot.zig");
    _ = @import("ai/transcript.zig");
    _ = @import("ai/api_client.zig");
    _ = @import("ai/cli.zig");
    _ = @import("ai/codex_rollout.zig");
    _ = @import("ui/ai_view.zig");
    _ = @import("ui/spend_view.zig");
    _ = @import("ai/usage.zig");
    _ = @import("app/usage_pane.zig");
    _ = @import("ui/usage_view.zig");
    _ = @import("app/ai_apply.zig");
    _ = @import("app/launch_profiles.zig");
    _ = @import("app/session_worktree.zig");
    _ = @import("app/tests_pane.zig");
    _ = @import("app/flaky.zig");
    _ = @import("ui/tests_view.zig");
    _ = @import("ui/flaky_view.zig");
    _ = @import("ui/ai_apply_view.zig");
    _ = @import("todos.zig");
    _ = @import("notes.zig");
    _ = @import("findings.zig");
    _ = @import("sessions.zig");
    _ = @import("app/dock.zig");
    _ = @import("app/hover_zones.zig");
    _ = @import("app/sidebar_auto.zig");
    _ = @import("ui/sidebar_overlay.zig");
    _ = @import("ui/pin_chip.zig");
    _ = @import("ui/edge_grip.zig");
    _ = @import("app/edge_band_audit.zig");
    // // changed (railmove): the two strips and the section placement
    // were in no reference block, so their tests never ran — a
    // break-check on the dock "passed" with the break in the file.
    _ = @import("app/activity_bar.zig");
    _ = @import("ui/activity_bar.zig");
    _ = @import("app/launcher_dock.zig");
    _ = @import("ui/launcher_dock_view.zig");
    _ = @import("app/side.zig");
    _ = @import("ui/dock_view.zig");
    _ = @import("core/dock.zig");
    _ = @import("app/git.zig");
    _ = @import("app/cmd_git.zig");
    _ = @import("git/parse.zig");
    _ = @import("git/intraline.zig");
    _ = @import("git/remote.zig");
    _ = @import("git/client.zig");
    _ = @import("git/changes.zig");
    _ = @import("ui/git_status_view.zig");
    _ = @import("ui/diff_view.zig");
    _ = @import("ui/git_graph_view.zig");
    _ = @import("rpc/jsonrpc.zig");
    _ = @import("dap/types.zig");
    _ = @import("dap/client.zig");
    _ = @import("lsp/types.zig");
    _ = @import("lsp/client.zig");
    _ = @import("app/dap.zig");
    _ = @import("app/cmd_dap.zig");
    _ = @import("app/debug_panel.zig");
    _ = @import("ui/debug_panel.zig");
    _ = @import("app/lsp.zig");
    // // changed (lsp-defaults): the statusline's own tests (the spec
    // row, the chips) were never reachable from a test block — a file
    // only container-imported contributes no tests.
    _ = @import("app/statusline.zig");
    // The info view's copy tests were container-imported too (2026-09-10).
    _ = @import("app/info_view.zig");
    _ = @import("app/cmd_lsp.zig");
    _ = @import("ui/completion_view.zig");
    _ = @import("ui/cmdline_popup.zig");
    _ = @import("app/cmdline_popup.zig");
    _ = @import("ui/hover_view.zig");
    _ = @import("ui/peek_view.zig");
    _ = @import("ui/diagnostics_view.zig");
    _ = @import("ui/dap_view.zig");
    _ = @import("ui/debug_toolbar.zig");
    _ = @import("ui/hit.zig");
    _ = @import("ui/prompt.zig");
    _ = @import("ui/confirm.zig");
    _ = @import("ui/find_bar.zig");
    _ = @import("ui/picker.zig");
    _ = @import("ui/fuzzy.zig");
    _ = @import("ui/editor_view.zig");
    _ = @import("ui/indent_guides.zig");
    _ = @import("scripting/lua.zig");
    _ = @import("scripting/manifest.zig");
    _ = @import("scripting/api.zig");
    _ = @import("scripting/diag.zig");
    _ = @import("scripting/complete.zig");
    _ = @import("app/script_pane.zig");
    _ = @import("app/cmd_script.zig");
    _ = @import("app/scripts_panel.zig");
    _ = @import("app/scripts.zig");
    _ = @import("app/script_doctor.zig");
    _ = @import("app/search_section.zig");
    _ = @import("app/grep_picker.zig");
    _ = @import("ui/search_section_view.zig");
    _ = @import("ui/script_view.zig");
    _ = @import("ui/script_list.zig");
    _ = @import("app/script_list.zig");
    _ = @import("app/script_section.zig");
    _ = @import("input/script_ops.zig");
    _ = @import("app/messages.zig");
    _ = @import("app/zen.zig");
    _ = @import("app/named_layouts.zig");
    _ = @import("app/harpoon.zig");
    _ = @import("app/cmd_harpoon.zig");
    _ = @import("app/stress.zig");
    _ = @import("app/undo_store.zig");
    _ = @import("app/macros_store.zig");
    _ = @import("app/find_history.zig");
    _ = @import("app/syntax_jobs.zig");
    _ = @import("app/lsp_sync.zig");
    _ = @import("app/conflict_cache.zig");
    _ = @import("app/auto_refresh.zig");
    _ = @import("app/clock.zig");
    _ = @import("core/localtime.zig");
    _ = @import("app/coverage.zig");
    _ = @import("app/now_playing.zig");
    _ = @import("app/integration_poll.zig");
    _ = @import("app/broker.zig");
    _ = @import("app/menu_bar.zig");
    _ = @import("app/browser_open.zig");
    _ = @import("app/glyph_audit.zig");
    _ = @import("app/marks_store.zig");
    _ = @import("app/ex_verbs.zig");
    _ = @import("app/ex_fname.zig");
    _ = @import("app/loclist.zig");
    _ = @import("app/update.zig");
    _ = @import("app/session.zig");
    _ = @import("app/cmd_session.zig");
    _ = @import("app/startup_picker.zig");
    _ = @import("app/files_pane.zig");
    _ = @import("app/file_clipboard.zig");
    _ = @import("app/trash.zig");
    _ = @import("app/transfers.zig");
    _ = @import("ui/files_view.zig");
}

test "run: an unimplemented command toasts and fails; a bad name toasts" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = App.scratch_workspace, .cols = 40, .rows = 10 });
    defer app.deinit();
    // A spec without a runner (found by scanning — every id this test
    // once named, `dock.close_all` last, has grown one) toasts and fails.
    var missing: ?command.CommandId = null;
    for (std.enums.values(command.CommandId)) |id| if (command.runners.get(id) == null) {
        missing = id;
        break;
    };
    if (missing) |id| {
        try std.testing.expectError(error.Failed, command.run(&app, .{ .static = id }));
        try std.testing.expect(std.mem.endsWith(u8, app.lastToast().?, ": not implemented yet"));
    }
    try std.testing.expectError(error.Failed, command.runNamed(&app, "nope.nope"));
    try std.testing.expectEqualStrings("no such command: nope.nope", app.lastToast().?);
    // A dyn command with an ex runner reaches the interpreter.
    _ = try app.dyn_commands.register(.{ .id = "user.hi", .runner = .{ .ex = "frobnicate" }, .owner = .{ .script = 0 } });
    try std.testing.expectError(error.Failed, command.runNamed(&app, "user.hi"));
    try std.testing.expectEqualStrings(":frobnicate — unknown command", app.lastToast().?);
    // An IPC runner is acknowledged through pluginInvocations.
    _ = try app.dyn_commands.register(.{ .id = "p.a", .runner = .ipc, .owner = .ipc });
    try command.runNamed(&app, "p.a");
    try std.testing.expectEqualStrings("p.a", app.plugin_invocations.items[0]);
}

test "config → App: every behaviour-changing field flipped once" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: Config = .{};
    c.editor.input_style = .vim;
    c.editor.tab_width = 2;
    c.editor.text_width = 40;
    c.editor.chord_timeout_ms = 900;
    c.ui.wrap = true;
    c.ui.line_numbers = false;
    c.ui.ascii_icons = true;
    c.ui.tree_width = 17;
    c.ui.theme = "Gruvbox";
    try c.keys.global.put(arena, "ctrl+shift+x", "view.about");
    try c.keys.vim.put(arena, "ctrl+q", "none");
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = c, .workspace = App.scratch_workspace, .cols = 60, .rows = 12 });
    defer app.deinit();

    // input_style: the buffers and the keymap follow the config's enum
    try t.expectEqual(input.Style.vim, app.input_style);
    _ = try app.openScratch();
    try t.expectEqual(input.Style.vim, app.activeBuffer().?.input.style());
    try t.expectEqualStrings("NORMAL", app.activeBuffer().?.input.mode().label().?);
    // tab_width / text_width reach the editor
    try t.expectEqual(@as(usize, 2), app.activeBuffer().?.editor.doc.tab_width);
    try t.expectEqual(@as(usize, 40), app.editorConfig().text_width);
    // chord timeout is the deadline the chain waits for
    try t.expectEqual(@as(u16, 900), app.cfg.editor.chord_timeout_ms);
    // tree width, theme
    try t.expectEqual(@as(u16, 17), app.tree.width);
    try t.expectEqualStrings("gruvbox", app.theme.name);
    try t.expectEqual(@as(usize, 0), app.toasts.items.len);
    // keys: global adds, the profile layer removes
    var buf: [keymap.max_seq]key_mod.Chord = undefined;
    try t.expectEqual(command.CommandId.@"view.about", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+shift+x", &buf).?).run.static);
    try t.expect(app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+q", &buf).?) == .none);
    // wrap / line numbers / ascii reach the frame: no gutter digits, the
    // ascii divider, and a long line that wraps instead of clipping
    app.tree.visible = true;
    try app.activeEditor().?.buf.editor.setText("0123456789 0123456789 0123456789 0123456789 0123456789");
    try app.render();
    const txt = try @import("ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "|") != null);
    try t.expect(std.mem.indexOf(u8, txt, "│") == null);
    try t.expect(std.mem.indexOf(u8, txt, " 1 0123") == null);
    try t.expectEqual(@as(usize, 0), app.cfg.ui.tree_width - app.tree.width);
    try t.expect(std.mem.count(u8, txt, "0123456789") >= 2);

    // switching the style keeps cfg and the input layer level, and the
    // config's key layers survive the rebuild
    try app.setInputStyle(.standard);
    try t.expectEqual(Config.InputStyle.standard, app.cfg.editor.input_style);
    try t.expectEqual(command.CommandId.@"view.about", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+shift+x", &buf).?).run.static);
    try t.expectEqual(command.CommandId.@"app.quit", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+q", &buf).?).run.static);
}

test "config → App: an unknown theme keeps the default and warns; loader diagnostics become toasts" {
    const t = std.testing;
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/config.zon", .data = ".{ .ui = .{ .theme = \"no-such\" }, .bogus = 1 }" });
    var loaded = try config.load.load(t.allocator, t.io, .{ .workspace = root, .env = .{ .vars = &vars } });
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = root, .cols = 60, .rows = 12 });
    loaded = undefined; // the app owns it now
    defer app.deinit();
    try t.expectEqualStrings("onedark", app.theme.name);
    try t.expectEqual(@as(usize, 2), app.toasts.items.len);
    try t.expect(std.mem.indexOf(u8, app.toasts.items[0].text, "unknown section 'bogus'") != null);
    try t.expect(std.mem.indexOf(u8, app.toasts.items[1].text, "no-such") != null);
    try t.expect(app.toasts.items[1].level == .warn);
}

test "persistent toasts survive tick; dismiss removes by id" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    app.toast("gone soon", .{});
    try app.toastPersistent("ex:reg", "stays", .info);
    try app.tick(app.now_ms + 10_000);
    try std.testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    try std.testing.expectEqualStrings("stays", app.lastToast().?);
    app.dismissToast("ex:reg");
    try std.testing.expectEqual(@as(usize, 0), app.toasts.items.len);
}

test "an identical toast while its twin is up coalesces into one box with a count and a fresh expiry" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    app.toast("LSP: Failed to discover workspace.", .{});
    try app.tick(app.now_ms + 1000);
    app.toast("LSP: Failed to discover workspace.", .{});
    try std.testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    try std.testing.expectEqual(@as(u32, 2), app.toasts.items[0].repeats);
    // The second sighting restarts the clock: still up past the first's TTL.
    try app.tick(app.now_ms + toast_ttl_ms - 500);
    try std.testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    // A different text stacks; a persistent one never coalesces.
    app.toast("LSP: rust-analyzer exited", .{});
    try app.toastPersistent("p", "LSP: rust-analyzer exited", .info);
    try std.testing.expectEqual(@as(usize, 3), app.toasts.items.len);
    // The repeat of an older text becomes the newest: `lastToast` is it.
    app.toast("LSP: Failed to discover workspace.", .{});
    try std.testing.expectEqual(@as(usize, 3), app.toasts.items.len);
    try std.testing.expectEqualStrings("LSP: Failed to discover workspace.", app.lastToast().?);
    try std.testing.expectEqual(@as(u32, 3), app.toasts.items[app.toasts.items.len - 1].repeats);
}

test "a command's next run replaces its last run's toast, the new text in the newest slot; one run's toasts stack; sticky, id'd, stale and unsourced ones are left; an error never lands on a non-error" {
    const t = std.testing;
    var app = try App.init(t.allocator, t.io);
    defer app.deinit();
    app.toast("unrelated", .{});
    // `wrap on` then `wrap off`: the second run's toast takes the first's box.
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try t.expectEqual(@as(usize, 2), app.toasts.items.len);
    try t.expectEqualStrings("unrelated", app.toasts.items[0].text);
    try t.expectEqualStrings("wrap off", app.toasts.items[1].text);
    try t.expectEqual(@as(u32, 1), app.toasts.items[1].repeats);
    // With another toast since, the replacement is still one box, and
    // it is the newest: `lastToast` is the latest word.
    app.toast("newer", .{});
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try t.expectEqual(@as(usize, 3), app.toasts.items.len);
    try t.expectEqualStrings("newer", app.toasts.items[1].text);
    try t.expectEqualStrings("wrap on", app.lastToast().?);
    // Past the window it stacks again.
    app.toasts.items[2].raised_ms -= toast_coalesce_ms + 1;
    try command.run(&app, .{ .static = .@"view.toggle_wrap" });
    try t.expectEqual(@as(usize, 4), app.toasts.items.len);
    app.dismissToasts();
    // One run that says two things says both.
    app.running_cmd = .{ .static = .@"view.toggle_wrap" };
    app.running_serial = 1000;
    app.toast("first half", .{});
    app.toast("second half", .{});
    try t.expectEqual(@as(usize, 2), app.toasts.items.len);
    // The next run's error does not land on them; its success after it
    // replaces the error.
    app.running_serial = 1001;
    try app.toastLevel(.err, "it broke", .{});
    try t.expectEqual(@as(usize, 3), app.toasts.items.len);
    app.running_serial = 1002;
    app.toast("fixed", .{});
    try t.expectEqual(@as(usize, 3), app.toasts.items.len);
    try t.expectEqualStrings("fixed", app.lastToast().?);
    try t.expectEqual(ToastLevel.info, app.toasts.items[2].level);
    // Sticky and id'd toasts are never replaced, nor do they replace.
    try app.toastPersistent("job", "indexing…", .info);
    app.toastReplace("nav", "tab 1/2", .{});
    app.running_serial = 1003;
    app.toast("again", .{});
    try t.expectEqualStrings("indexing…", app.toasts.items[2].text);
    try t.expectEqualStrings("tab 1/2", app.toasts.items[3].text);
    try t.expectEqualStrings("again", app.lastToast().?);
    try t.expectEqual(@as(usize, 5), app.toasts.items.len);
    for (app.toasts.items) |x| try t.expect(!std.mem.eql(u8, x.text, "fixed"));
    // Outside a command there is no source: nothing is replaced.
    app.running_cmd = null;
    app.toast("free one", .{});
    app.toast("free two", .{});
    try t.expectEqual(@as(usize, 6), app.toasts.items.len);
}

test "a config reload moves tab_width in a buffer that took the config's, not in one whose .editorconfig or :setlocal set it" {
    const t = std.testing;
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try t.allocator.dupe(u8, pbuf[0..try tmp.dir.realPath(t.io, &pbuf)]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/config.zon", .data = ".{ .editor = .{ .tab_width = 2 } }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".editorconfig", .data = "[*.mk]\nindent_size = 8\n" });
    for ([_][]const u8{ "plain.txt", "build.mk", "local.txt" }) |f| try tmp.dir.writeFile(t.io, .{ .sub_path = f, .data = "\tx\n" });
    var loaded = try config.load.load(t.allocator, t.io, .{ .workspace = root, .env = .{ .vars = &vars } });
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = root, .cols = 60, .rows = 12 });
    loaded = undefined; // the app owns it now
    defer app.deinit();

    const doc_mod = @import("editor/document.zig");
    const docOf = struct {
        fn f(a: *App, name: []const u8) !*doc_mod.Document {
            const path = try std.fs.path.join(a.frame.allocator(), &.{ a.workspace, name });
            const id = a.panes.findPath(path) orelse return error.TestUnexpectedResult;
            return a.panes.editor(id).?.buf.doc;
        }
    }.f;
    for ([_][]const u8{ "plain.txt", "build.mk", "local.txt" }) |f| {
        const path = try std.fs.path.join(app.frame.allocator(), &.{ root, f });
        _ = try app.openEditor(path);
    }
    // The three sources at open: the config's 2, the file's 8, and
    // `:setlocal`'s 6 over the config's.
    try dispatch.runExLine(&app, "setlocal ts=6 sw=6");
    const plain = try docOf(&app, "plain.txt");
    const mk = try docOf(&app, "build.mk");
    const local = try docOf(&app, "local.txt");
    try t.expectEqual(@as(usize, 2), plain.tab_width);
    try t.expectEqual(@as(usize, 8), mk.indent_unit);
    try t.expectEqual(@as(usize, 6), local.tab_width);
    try t.expectEqual(@as(usize, 6), local.indent_unit);
    try t.expectEqual(doc_mod.PrefSource.config, plain.pref_source.tab_width);
    try t.expectEqual(doc_mod.PrefSource.editorconfig, mk.pref_source.tab_width);
    try t.expectEqual(doc_mod.PrefSource.local, local.pref_source.tab_width);

    // The workspace config says 3 and is read again.
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/config.zon", .data = ".{ .editor = .{ .tab_width = 3 } }" });
    try app.reloadConfig(.ask);
    try t.expectEqual(@as(usize, 3), app.cfg.editor.tab_width);
    try t.expectEqual(@as(usize, 3), plain.tab_width);
    try t.expectEqual(@as(usize, 3), plain.indent_unit);
    try t.expectEqual(@as(usize, 8), mk.indent_unit);
    try t.expectEqual(@as(usize, 6), local.tab_width);
    try t.expectEqual(@as(usize, 6), local.indent_unit);

    // `:set ts` is the config's too: the same two stay.
    try dispatch.runExLine(&app, "set ts=5");
    try t.expectEqual(@as(usize, 5), plain.tab_width);
    try t.expectEqual(@as(usize, 8), mk.indent_unit);
    try t.expectEqual(@as(usize, 6), local.tab_width);
}

test "editorconfig reaches an opened buffer; a scratch takes the config's save prefs; the dead config fields are read" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = try t.allocator.dupe(u8, pbuf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".editorconfig", .data = "[*.mk]\nindent_style = tab\ntab_width = 8\ntrim_trailing_whitespace = true\ninsert_final_newline = false\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.mk", .data = "all:\n\techo   \n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "x  " });
    var c: Config = .{};
    c.editor.input_style = .vim;
    c.editor.tab_width = 2;
    c.editor.trim_trailing_ws_on_save = true;
    c.editor.ensure_trailing_newline = true;
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = c, .workspace = root, .cols = 60, .rows = 12 });
    defer app.deinit();
    const mk = try std.fs.path.join(t.allocator, &.{ root, "build.mk" });
    defer t.allocator.free(mk);
    _ = try app.openEditor(mk);
    const e = app.activeEditor().?;
    try t.expect(e.buf.doc.use_tabs);
    try t.expectEqual(@as(usize, 8), e.buf.doc.tab_width);
    try t.expectEqual(@as(usize, 8), e.buf.input.vim.tab_width);
    try t.expect(e.buf.doc.trim_trailing_ws_on_save);
    try t.expect(!e.buf.doc.ensure_trailing_newline);
    // Through the real key path: Tab in insert mode is a `\t`.
    const keys = try buffer_mod.parseKeys(t.allocator, "I<tab><esc>");
    defer t.allocator.free(keys);
    for (keys) |k| try dispatch.key(&app, k);
    try t.expectEqualStrings("\tall:\n\techo   \n", e.buf.editor.bytes());
    try @import("app/cmd_file.zig").saveCurrent(&app);
    const back = try tmp.dir.readFileAlloc(t.io, "build.mk", t.allocator, .limited(256));
    defer t.allocator.free(back);
    try t.expectEqualStrings("\tall:\n\techo\n", back);
    // notes.txt matches no section: the config's own values — spaces,
    // width 2, trim on (the config field is honoured now), newline on.
    const txt = try std.fs.path.join(t.allocator, &.{ root, "notes.txt" });
    defer t.allocator.free(txt);
    _ = try app.openEditor(txt);
    const e2 = app.activeEditor().?;
    try t.expect(!e2.buf.doc.use_tabs);
    try t.expectEqual(@as(usize, 2), e2.buf.doc.tab_width);
    try t.expect(e2.buf.doc.trim_trailing_ws_on_save);
    try t.expect(e2.buf.doc.ensure_trailing_newline);
    try @import("app/cmd_file.zig").saveCurrent(&app);
    const back2 = try tmp.dir.readFileAlloc(t.io, "notes.txt", t.allocator, .limited(256));
    defer t.allocator.free(back2);
    try t.expectEqualStrings("x\n", back2);
    // A scratch buffer: the config's prefs, no file to resolve against.
    _ = try app.openScratch();
    try t.expect(app.activeEditor().?.buf.doc.trim_trailing_ws_on_save);
    try t.expect(app.activeEditor().?.buf.doc.path == null);
}
