//! The macOS window server, as much of it as driving one terminal window
//! needs: which window belongs to which process, where it is on screen,
//! posting a key or a click AT a process, and reading pixels back.
//!
//! These are `extern` declarations, not an `@cImport`. translate-c on
//! Apple's umbrella headers (`ApplicationServices/ApplicationServices.h`)
//! pulls in thousands of declarations and fights over CF's macros for
//! every one of them; the two dozen symbols below are a frozen C ABI that
//! has not changed in fifteen years, and spelling them out is both
//! shorter and something a reader can check against the man pages.
//!
//! One rule runs through the whole file: **events go to a process id, never
//! to the screen.** `CGEventPost(.cghidEventTap, …)` — what every
//! screenshot-and-click script on the internet does, the Rust repo's
//! `scripts/macclick.swift` included — delivers to whatever is frontmost,
//! which on a developer's machine is their own editor with unsaved work in
//! it. `CGEventPostToPid` delivers to one process whether or not it is
//! focused, which is also why the harness never has to raise its window.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos) @compileError("tools/drive is macOS-only; the build gates it on -Ddrive and the host os");
}

// ─── CoreFoundation / CoreGraphics ──────────────────────────────────────

pub const CFTypeRef = ?*const anyopaque;

const kCFStringEncodingUTF8: u32 = 0x08000100;
/// `CFNumberType`: the two we read. Window ids and layers are ints; a
/// window's bounds are doubles.
const kCFNumberSInt32Type: i32 = 3;
const kCFNumberIntType: i32 = 9;
const kCFNumberDoubleType: i32 = 13;

extern "c" fn CFRelease(t: CFTypeRef) void;
extern "c" fn CFArrayGetCount(a: CFTypeRef) isize;
extern "c" fn CFArrayGetValueAtIndex(a: CFTypeRef, i: isize) CFTypeRef;
extern "c" fn CFDictionaryGetValue(d: CFTypeRef, k: CFTypeRef) CFTypeRef;
extern "c" fn CFNumberGetValue(n: CFTypeRef, kind: i32, out: *anyopaque) bool;
extern "c" fn CFStringGetCString(s: CFTypeRef, buf: [*]u8, size: isize, enc: u32) bool;
extern "c" fn CFStringCreateWithCString(alloc: CFTypeRef, c: [*:0]const u8, enc: u32) CFTypeRef;
extern "c" fn CFDataGetBytePtr(d: CFTypeRef) [*]const u8;
extern "c" fn CFDataGetLength(d: CFTypeRef) isize;

pub const CGPoint = extern struct { x: f64, y: f64 };
pub const CGSize = extern struct { width: f64, height: f64 };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };

/// `CGWindowListOption`: on-screen windows only, and never the desktop
/// picture. A window the user minimised or sent to another Space is then
/// simply absent, which is the answer the safety check wants.
const kCGWindowListOptionOnScreenOnly: u32 = 1 << 0;
const kCGWindowListExcludeDesktopElements: u32 = 1 << 4;
const kCGWindowListOptionIncludingWindow: u32 = 1 << 3;

extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) CFTypeRef;
extern "c" fn CGWindowListCreateImage(rect: CGRect, option: u32, window_id: u32, image_option: u32) CFTypeRef;
extern "c" fn CGImageGetWidth(img: CFTypeRef) usize;
extern "c" fn CGImageGetHeight(img: CFTypeRef) usize;
extern "c" fn CGImageGetBytesPerRow(img: CFTypeRef) usize;
extern "c" fn CGImageGetBitsPerPixel(img: CFTypeRef) usize;
extern "c" fn CGImageGetDataProvider(img: CFTypeRef) CFTypeRef;
extern "c" fn CGDataProviderCopyData(p: CFTypeRef) CFTypeRef;

extern "c" fn CGEventCreateKeyboardEvent(source: CFTypeRef, keycode: u16, down: bool) CFTypeRef;
extern "c" fn CGEventKeyboardSetUnicodeString(event: CFTypeRef, len: isize, chars: [*]const u16) void;
extern "c" fn CGEventCreateMouseEvent(source: CFTypeRef, kind: u32, at: CGPoint, button: u32) CFTypeRef;
extern "c" fn CGEventCreateScrollWheelEvent(source: CFTypeRef, units: u32, wheels: u32, w1: i32) CFTypeRef;
extern "c" fn CGEventSetFlags(event: CFTypeRef, flags: u64) void;
extern "c" fn CGEventSetIntegerValueField(event: CFTypeRef, field: u32, value: i64) void;
extern "c" fn CGEventPostToPid(pid: i32, event: CFTypeRef) void;
extern "c" fn CGEventCreate(source: CFTypeRef) CFTypeRef;
extern "c" fn CGEventGetLocation(event: CFTypeRef) CGPoint;
extern "c" fn CGWarpMouseCursorPosition(p: CGPoint) i32;
extern "c" fn CGAssociateMouseAndMouseCursorPosition(connected: bool) i32;

extern "c" fn CGMainDisplayID() u32;
extern "c" fn CGDisplayBounds(display: u32) CGRect;

extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn CGPreflightScreenCaptureAccess() bool;

/// `CGEventType`, the mouse subset.
const ev_left_down: u32 = 1;
const ev_left_up: u32 = 2;
const ev_right_down: u32 = 3;
const ev_right_up: u32 = 4;
const ev_mouse_moved: u32 = 5;
const ev_left_dragged: u32 = 6;

/// `CGEventField.mouseEventClickState` — 1 for a single click, 2 for the
/// second of a double. A double-click is not two clicks; it is one event
/// pair that says "2", and a terminal that implements word-select reads
/// exactly this field.
const field_click_state: u32 = 1;

/// `CGEventFlags`.
pub const flag_shift: u64 = 1 << 17;
pub const flag_control: u64 = 1 << 18;
pub const flag_alternate: u64 = 1 << 19;
pub const flag_command: u64 = 1 << 20;

/// The main display in screen POINTS. The harness fits its window inside
/// this; a window ghostty clamped to the display comes up with fewer cells
/// than asked for, and every cell→pixel sum after that is wrong.
pub fn mainDisplayBounds() CGRect {
    return CGDisplayBounds(CGMainDisplayID());
}

// ─── windows ────────────────────────────────────────────────────────────

pub const Window = struct {
    id: u32,
    pid: i32,
    /// Screen POINTS, top-left origin — the same space `CGEventPost*`
    /// takes and `screencapture -R` uses, so a cell centre computed here
    /// can be both clicked and photographed without a conversion.
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    title_buf: [256]u8,
    title_len: usize,

    pub fn title(self: *const Window) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// Every on-screen window owned by `pid`, biggest first. Ghostty puts its
/// terminal surface on layer 0; anything else it owns (a sheet, a tooltip)
/// sits on another layer and is skipped, so "the window" is unambiguous
/// without asking the window to identify itself.
pub fn windowsOf(pid: i32, out: []Window) []Window {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, 0) orelse return out[0..0];
    defer CFRelease(list);
    const k_owner = CFStringCreateWithCString(null, "kCGWindowOwnerPID", kCFStringEncodingUTF8);
    defer CFRelease(k_owner);
    const k_number = CFStringCreateWithCString(null, "kCGWindowNumber", kCFStringEncodingUTF8);
    defer CFRelease(k_number);
    const k_layer = CFStringCreateWithCString(null, "kCGWindowLayer", kCFStringEncodingUTF8);
    defer CFRelease(k_layer);
    const k_name = CFStringCreateWithCString(null, "kCGWindowName", kCFStringEncodingUTF8);
    defer CFRelease(k_name);
    const k_bounds = CFStringCreateWithCString(null, "kCGWindowBounds", kCFStringEncodingUTF8);
    defer CFRelease(k_bounds);
    const k_x = CFStringCreateWithCString(null, "X", kCFStringEncodingUTF8);
    defer CFRelease(k_x);
    const k_y = CFStringCreateWithCString(null, "Y", kCFStringEncodingUTF8);
    defer CFRelease(k_y);
    const k_w = CFStringCreateWithCString(null, "Width", kCFStringEncodingUTF8);
    defer CFRelease(k_w);
    const k_h = CFStringCreateWithCString(null, "Height", kCFStringEncodingUTF8);
    defer CFRelease(k_h);

    var n: usize = 0;
    var i: isize = 0;
    const count = CFArrayGetCount(list);
    while (i < count and n < out.len) : (i += 1) {
        const d = CFArrayGetValueAtIndex(list, i);
        var owner: i32 = 0;
        if (CFDictionaryGetValue(d, k_owner)) |v| _ = CFNumberGetValue(v, kCFNumberSInt32Type, &owner) else continue;
        if (owner != pid) continue;
        var layer: i32 = 0;
        if (CFDictionaryGetValue(d, k_layer)) |v| _ = CFNumberGetValue(v, kCFNumberSInt32Type, &layer);
        if (layer != 0) continue;
        var win: Window = .{ .id = 0, .pid = owner, .x = 0, .y = 0, .w = 0, .h = 0, .title_buf = undefined, .title_len = 0 };
        if (CFDictionaryGetValue(d, k_number)) |v| _ = CFNumberGetValue(v, kCFNumberIntType, &win.id);
        if (CFDictionaryGetValue(d, k_bounds)) |b| {
            if (CFDictionaryGetValue(b, k_x)) |v| _ = CFNumberGetValue(v, kCFNumberDoubleType, &win.x);
            if (CFDictionaryGetValue(b, k_y)) |v| _ = CFNumberGetValue(v, kCFNumberDoubleType, &win.y);
            if (CFDictionaryGetValue(b, k_w)) |v| _ = CFNumberGetValue(v, kCFNumberDoubleType, &win.w);
            if (CFDictionaryGetValue(b, k_h)) |v| _ = CFNumberGetValue(v, kCFNumberDoubleType, &win.h);
        }
        win.title_buf[0] = 0;
        if (CFDictionaryGetValue(d, k_name)) |v| {
            if (CFStringGetCString(v, &win.title_buf, win.title_buf.len, kCFStringEncodingUTF8)) {
                win.title_len = std.mem.sliceTo(&win.title_buf, 0).len;
            }
        }
        if (win.w <= 0 or win.h <= 0) continue;
        out[n] = win;
        n += 1;
    }
    const found = out[0..n];
    std.mem.sort(Window, found, {}, struct {
        fn less(_: void, a: Window, b: Window) bool {
            return a.w * a.h > b.w * b.h;
        }
    }.less);
    return found;
}

/// The one on-screen window with this id, if it is still there AND still
/// belongs to `pid`. Both halves matter: window ids are recycled, so an id
/// that resolves to a window owned by somebody else is exactly the case
/// where posting an event would reach a stranger.
pub fn windowOwnedBy(pid: i32, id: u32) ?Window {
    var buf: [32]Window = undefined;
    for (windowsOf(pid, &buf)) |w| {
        if (w.id == id) return w;
    }
    return null;
}

/// Is this process alive and ours to signal? `kill(pid, 0)` answers both
/// (ESRCH: gone; EPERM: alive but someone else's, which for a harness we
/// launched means the pid was recycled).
pub fn processAlive(pid: i32) bool {
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

// ─── permissions ────────────────────────────────────────────────────────

pub const Permissions = struct {
    accessibility: bool,
    screen_recording: bool,

    pub fn ok(p: Permissions) bool {
        return p.accessibility and p.screen_recording;
    }
};

/// Neither call prompts: `AXIsProcessTrusted` is the non-prompting form of
/// the accessibility check, and `CGPreflight…` is by definition the ask-
/// nothing one. A harness that popped a system dialog in the middle of a
/// corpus run would be worse than one that refuses and says why.
pub fn permissions() Permissions {
    return .{ .accessibility = AXIsProcessTrusted(), .screen_recording = CGPreflightScreenCaptureAccess() };
}

// ─── events ─────────────────────────────────────────────────────────────

/// One key down+up at `pid`, by virtual keycode.
pub fn postKey(pid: i32, keycode: u16, flags: u64) void {
    for ([_]bool{ true, false }) |down| {
        const e = CGEventCreateKeyboardEvent(null, keycode, down) orelse continue;
        defer CFRelease(e);
        CGEventSetFlags(e, flags);
        CGEventPostToPid(pid, e);
    }
}

/// One codepoint as literal text. Keycode 0 with a unicode payload is how
/// macOS delivers characters no key on the layout produces; it means `type`
/// never needs a keyboard-layout table, and an accented or CJK character
/// arrives the same way the user pasting it would.
pub fn postText(pid: i32, utf16: []const u16) void {
    for ([_]bool{ true, false }) |down| {
        const e = CGEventCreateKeyboardEvent(null, 0, down) orelse continue;
        defer CFRelease(e);
        CGEventSetFlags(e, 0);
        CGEventKeyboardSetUnicodeString(e, @intCast(utf16.len), utf16.ptr);
        CGEventPostToPid(pid, e);
    }
}

pub const MouseButton = enum { left, right };

pub fn postMouseMove(pid: i32, p: CGPoint) void {
    const e = CGEventCreateMouseEvent(null, ev_mouse_moved, p, 0) orelse return;
    defer CFRelease(e);
    CGEventPostToPid(pid, e);
}

/// A press/release pair at `p`. `click_state` is 1 for a single click and
/// 2 for the second press of a double.
pub fn postClick(pid: i32, p: CGPoint, button: MouseButton, click_state: i64) void {
    const down: u32 = if (button == .right) ev_right_down else ev_left_down;
    const up: u32 = if (button == .right) ev_right_up else ev_left_up;
    const btn: u32 = if (button == .right) 1 else 0;
    for ([_]u32{ down, up }) |kind| {
        const e = CGEventCreateMouseEvent(null, kind, p, btn) orelse continue;
        defer CFRelease(e);
        CGEventSetIntegerValueField(e, field_click_state, click_state);
        CGEventPostToPid(pid, e);
    }
}

pub fn postDragStep(pid: i32, p: CGPoint, kind: enum { down, move, up }) void {
    const ev: u32 = switch (kind) {
        .down => ev_left_down,
        .move => ev_left_dragged,
        .up => ev_left_up,
    };
    const e = CGEventCreateMouseEvent(null, ev, p, 0) orelse return;
    defer CFRelease(e);
    CGEventSetIntegerValueField(e, field_click_state, 1);
    CGEventPostToPid(pid, e);
}

/// One wheel notch. `units` 1 is "lines" — the discrete form; ghostty
/// multiplies a notch by its own `mouse-scroll-multiplier`, so one call
/// here is one detent to the user and several events to mnml (see
/// docs/DRIVE.md, "a notch is not an event").
pub fn postScroll(pid: i32, p: CGPoint, lines: i32) void {
    // The wheel event carries no location of its own, so the pointer has
    // to be where the scroll is meant to land first.
    postMouseMove(pid, p);
    const e = CGEventCreateScrollWheelEvent(null, 1, 1, lines) orelse return;
    defer CFRelease(e);
    CGEventPostToPid(pid, e);
}

/// Where the pointer is now, so a verb can put it back. The harness moves
/// the real cursor because a terminal decides hover state from where the
/// pointer IS, not from the coordinate on the event; leaving it parked
/// over somebody's window afterwards would be rude.
pub fn cursorPosition() CGPoint {
    const e = CGEventCreate(null) orelse return .{ .x = 0, .y = 0 };
    defer CFRelease(e);
    return CGEventGetLocation(e);
}

pub fn warpCursor(p: CGPoint) void {
    _ = CGWarpMouseCursorPosition(p);
    // Without this the hardware cursor stays decoupled from the warp for
    // about a quarter second and the next real mouse move snaps back.
    _ = CGAssociateMouseAndMouseCursorPosition(true);
}

// ─── pixels ─────────────────────────────────────────────────────────────

pub const Image = struct {
    data: CFTypeRef,
    img: CFTypeRef,
    bytes: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    bytes_per_pixel: usize,

    pub fn deinit(self: *Image) void {
        CFRelease(self.data);
        CFRelease(self.img);
        self.* = undefined;
    }

    /// The pixel at device (x, y), as RGB. The capture is in the display's
    /// backing resolution, so on a Retina screen one cell is two device
    /// pixels per point — callers scale with `width / point_width`.
    pub fn rgb(self: *const Image, x: usize, y: usize) ?[3]u8 {
        if (x >= self.width or y >= self.height) return null;
        const off = y * self.stride + x * self.bytes_per_pixel;
        if (off + 3 > self.bytes.len) return null;
        // CGWindowListCreateImage hands back little-endian BGRA.
        return .{ self.bytes[off + 2], self.bytes[off + 1], self.bytes[off] };
    }
};

/// A fresh capture of one window by id. Null when the window is gone or
/// Screen Recording was revoked between the check and the call.
pub fn captureWindow(id: u32) ?Image {
    const null_rect: CGRect = .{ .origin = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) }, .size = .{ .width = 0, .height = 0 } };
    const img = CGWindowListCreateImage(null_rect, kCGWindowListOptionIncludingWindow, id, 0) orelse return null;
    const provider = CGImageGetDataProvider(img) orelse {
        CFRelease(img);
        return null;
    };
    const data = CGDataProviderCopyData(provider) orelse {
        CFRelease(img);
        return null;
    };
    const len: usize = @intCast(@max(CFDataGetLength(data), 0));
    const bpp = CGImageGetBitsPerPixel(img) / 8;
    if (bpp < 3) {
        CFRelease(data);
        CFRelease(img);
        return null;
    }
    return .{
        .data = data,
        .img = img,
        .bytes = CFDataGetBytePtr(data)[0..len],
        .width = CGImageGetWidth(img),
        .height = CGImageGetHeight(img),
        .stride = CGImageGetBytesPerRow(img),
        .bytes_per_pixel = bpp,
    };
}
