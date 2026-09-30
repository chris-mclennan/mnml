// winplace — keep ONE harness window drawing while it sits behind others.
//
//   winplace --pid PID --window ID
//
// Ghostty stops rendering a window macOS reports as fully occluded, so a
// harness window buried under the person's own windows records a frozen
// picture (ScreenCaptureKit reads the backing store, which stops
// changing). This moves OUR window — found by pid AND window id, never
// raised, never focused — to the spot on a display where the most of it
// is uncovered by the windows in front of it; a sliver is enough for
// ghostty to keep drawing. Prints `{"x":…,"y":…,"uncovered":0..1}`.
// Exit 0 moved (or already best), 3 not our window, 5 fully covered
// everywhere (nothing a recording can do; say so).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

var pid: pid_t = 0
var wid: CGWindowID = 0
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--pid" { pid = pid_t(it.next() ?? "") ?? 0 }
    if a == "--window" { wid = CGWindowID(it.next() ?? "") ?? 0 }
}
guard pid > 0, wid > 0 else { print("usage: winplace --pid PID --window ID"); exit(2) }
_ = NSApplication.shared

func rect(_ w: [String: Any]) -> CGRect {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
guard let me = list.first(where: { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } == wid }),
      (me[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid else {
    FileHandle.standardError.write("winplace: window \(wid) is not on screen or not owned by pid \(pid)\n".data(using: .utf8)!)
    exit(3)
}
let mine = rect(me)
// Everything in front of us (the list is front to back), any layer.
var covers: [CGRect] = []
for w in list {
    if (w[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }) == wid { break }
    if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
    covers.append(rect(w))
}
func uncovered(_ r: CGRect) -> Double {
    var free = 0, all = 0
    var y = r.minY + 4
    while y < r.maxY {
        var x = r.minX + 4
        while x < r.maxX {
            all += 1
            if !covers.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { free += 1 }
            x += 16
        }
        y += 16
    }
    return all == 0 ? 0 : Double(free) / Double(all)
}
var best = (p: mine.origin, u: uncovered(mine))
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
for d in ids.prefix(Int(n)) {
    let b = CGDisplayBounds(d)
    guard b.width >= mine.width, b.height - 30 >= mine.height else { continue }
    var y = b.minY + 30
    while y + mine.height <= b.maxY {
        var x = b.minX
        while x + mine.width <= b.maxX {
            let u = uncovered(CGRect(x: x, y: y, width: mine.width, height: mine.height))
            if u > best.u + 0.001 { best = (CGPoint(x: x, y: y), u) }
            x += 32
        }
        if y + mine.height == b.maxY { break }
        y = min(y + 32, b.maxY - mine.height)
    }
}
if best.u <= 0 {
    print("{\"x\":\(Int(mine.minX)),\"y\":\(Int(mine.minY)),\"uncovered\":0}")
    exit(5)
}
if best.p != mine.origin {
    let app = AXUIElementCreateApplication(pid)
    var val: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &val)
    for w in (val as? [AXUIElement]) ?? [] {
        var pv: CFTypeRef?, sv: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv)
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv)
        var p = CGPoint.zero, s = CGSize.zero
        if let pv { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        guard abs(p.x - mine.minX) < 2, abs(p.y - mine.minY) < 2, abs(s.width - mine.width) < 2 else { continue }
        var np = best.p
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &np)!)
    }
}
print("{\"x\":\(Int(best.p.x)),\"y\":\(Int(best.p.y)),\"uncovered\":\(String(format: "%.3f", best.u))}")
