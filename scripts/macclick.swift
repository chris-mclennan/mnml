// macclick — post synthetic mouse events to the focused app at global
// (display-point, top-left-origin) coordinates. Used to drive the *real*
// running mnml in its ghostty window (paired with scripts/shot.sh to see the
// result). No dependencies beyond the system Swift toolchain.
//
// Coordinates are display POINTS, not retina pixels, and share the same space
// as `System Events` window position and `screencapture -R`. To turn a spot in
// a shot.sh PNG into a click point: pt = window_origin + (pixel / backing_scale).
//
// Usage:
//   macclick move  X Y
//   macclick click X Y            # left single
//   macclick rclick X Y           # right single
//   macclick dblclick X Y         # left double
//   macclick scroll X Y DELTA     # wheel at X,Y (DELTA>0 scrolls up)
import CoreGraphics
import Foundation

let a = CommandLine.arguments
func num(_ i: Int) -> Double { i < a.count ? (Double(a[i]) ?? 0) : 0 }
let cmd = a.count > 1 ? a[1] : ""
let p = CGPoint(x: num(2), y: num(3))

func move(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func click(_ p: CGPoint, button: CGMouseButton, count: Int) {
    let down: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
    let up:   CGEventType = (button == .right) ? .rightMouseUp   : .leftMouseUp
    move(p)
    for n in 1...count {
        for t in [down, up] {
            let e = CGEvent(mouseEventSource: nil, mouseType: t,
                            mouseCursorPosition: p, mouseButton: button)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            e?.post(tap: .cghidEventTap)
        }
    }
}

switch cmd {
case "move":     move(p)
case "click":    click(p, button: .left,  count: 1)
case "rclick":   click(p, button: .right, count: 1)
case "dblclick": click(p, button: .left,  count: 2)
case "scroll":
    move(p)
    CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 1, wheel1: Int32(num(4)), wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
default:
    FileHandle.standardError.write(Data("macclick: unknown command '\(cmd)'\n".utf8))
    exit(2)
}
