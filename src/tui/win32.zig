//! The Win32 console surface Zig 0.16's std does not declare, once, for
//! `term_windows.zig` and `input_windows.zig`. std reaches the kernel
//! through ntdll and knows `CreateProcessW` and little else of kernel32;
//! the console API only exists as Win32, so these are our own externs.
//! Signatures follow the SDK headers (libvaxis's `tty.zig` declares the
//! same handful for its own Windows tty; we do not reach into it).
//!
//! Declarations are analyzed lazily, so the records and the constants
//! also serve `input_windows.zig`'s fold tests on a POSIX host; the
//! externs themselves are only reached on Windows.

const std = @import("std");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const DWORD = windows.DWORD;
pub const BOOL = windows.BOOL;
pub const WORD = windows.WORD;
pub const SHORT = windows.SHORT;
pub const UINT = windows.UINT;
pub const COORD = windows.COORD;

pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const FILE_SHARE_WRITE: DWORD = 0x2;
pub const OPEN_EXISTING: DWORD = 3;

/// `CP_UTF8`.
pub const utf8_codepage: UINT = 65001;

/// `GetConsoleMode` / `SetConsoleMode` on an input handle.
pub const InputMode = packed struct(u32) {
    processed_input: bool = false,
    line_input: bool = false,
    echo_input: bool = false,
    /// Window-buffer-size records reach `ReadConsoleInputW`.
    window_input: bool = false,
    mouse_input: bool = false,
    insert_mode: bool = false,
    /// The console's own text selection: it swallows every mouse event
    /// while on. Only changes when `extended_flags` is set too.
    quick_edit_mode: bool = false,
    extended_flags: bool = false,
    auto_position: bool = false,
    /// Keys arrive as VT sequences (`ESC [ A`, `CSI u`, …), the way a
    /// POSIX tty delivers them.
    virtual_terminal_input: bool = false,
    _: u22 = 0,
};

/// `GetConsoleMode` / `SetConsoleMode` on an output handle.
pub const OutputMode = packed struct(u32) {
    processed_output: bool = false,
    wrap_at_eol_output: bool = false,
    /// The console interprets ANSI escapes instead of printing them.
    virtual_terminal_processing: bool = false,
    /// A write ending at the last column does not scroll.
    disable_newline_auto_return: bool = false,
    /// Reverse video and underline via the LVB attribute bits.
    lvb_grid_worldwide: bool = false,
    _: u27 = 0,
};

pub const SMALL_RECT = extern struct {
    Left: SHORT,
    Top: SHORT,
    Right: SHORT,
    Bottom: SHORT,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    /// The visible window, inclusive on both ends: the terminal's size.
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: extern union {
        UnicodeChar: u16,
        AsciiChar: u8,
    },
    dwControlKeyState: DWORD,
};

pub const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: COORD,
    dwButtonState: DWORD,
    dwControlKeyState: DWORD,
    dwEventFlags: DWORD,
};

pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    dwSize: COORD,
};

pub const MENU_EVENT_RECORD = extern struct {
    dwCommandId: UINT,
};

pub const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: BOOL,
};

pub const INPUT_RECORD = extern struct {
    EventType: WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        MenuEvent: MENU_EVENT_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
    },

    pub const KEY_EVENT: WORD = 0x0001;
    pub const MOUSE_EVENT: WORD = 0x0002;
    pub const WINDOW_BUFFER_SIZE_EVENT: WORD = 0x0004;
    pub const MENU_EVENT: WORD = 0x0008;
    pub const FOCUS_EVENT: WORD = 0x0010;
};

// `dwControlKeyState` bits.
pub const RIGHT_ALT_PRESSED: DWORD = 0x0001;
pub const LEFT_ALT_PRESSED: DWORD = 0x0002;
pub const RIGHT_CTRL_PRESSED: DWORD = 0x0004;
pub const LEFT_CTRL_PRESSED: DWORD = 0x0008;
pub const SHIFT_PRESSED: DWORD = 0x0010;

// `MOUSE_EVENT_RECORD.dwEventFlags`.
pub const MOUSE_MOVED: DWORD = 0x0001;
pub const MOUSE_WHEELED: DWORD = 0x0004;

// `MOUSE_EVENT_RECORD.dwButtonState`, low word.
pub const FROM_LEFT_1ST_BUTTON_PRESSED: u16 = 0x0001;
pub const RIGHTMOST_BUTTON_PRESSED: u16 = 0x0002;
pub const FROM_LEFT_2ND_BUTTON_PRESSED: u16 = 0x0004;

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES, bManualReset: BOOL, bInitialState: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(nCount: DWORD, lpHandles: [*]const HANDLE, bWaitAll: BOOL, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

/// The handle's console mode, or null when it is not a console (a pipe,
/// a file) — the test `Io.File.isTty` cannot make for an *input* handle.
pub fn consoleMode(h: HANDLE) ?u32 {
    var mode: DWORD = 0;
    if (GetConsoleMode(h, &mode) == .FALSE) return null;
    return mode;
}

/// Blocking, unbuffered write straight to a handle — the panic path,
/// where the session's writer may be mid-frame. Errors are ignored: the
/// process is on its way out.
pub fn writeAll(h: HANDLE, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        var written: DWORD = 0;
        const n: DWORD = @intCast(@min(bytes.len - off, std.math.maxInt(DWORD)));
        if (WriteFile(h, bytes.ptr + off, n, &written, null) == .FALSE) return;
        if (written == 0) return;
        off += written;
    }
}
