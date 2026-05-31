// gen_icon.swift — emit an AppIcon.iconset (all standard sizes) for mnml.
//
//   swift scripts/icon/gen_icon.swift  # writes scripts/icon/AppIcon.iconset
//
// The companion `scripts/icon/build.sh` then runs `iconutil` to
// produce `mnml.app/Contents/Resources/AppIcon.icns`.
//
// Design: a deep-charcoal rounded square with shell-prompt wordmark
// "> mnml" — `>` in mnml's cool blue accent, the name in near-white.
// Matches the prompt-style identity shared across the family (tmnl,
// mnml, mixr) — same bezel, same wordmark layout, different accent.

import Foundation
import AppKit

let iconsetDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "scripts/icon/AppIcon.iconset")

try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func render(_ side: Int) -> Data? {
    let s = CGFloat(side)
    let cs = NSColorSpace.sRGB.cgColorSpace!
    guard let ctx = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Transparent outer margin — macOS expects ~6% padding before the
    // rounded-square art.
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Rounded square body — Big-Sur rounding (~22% of side).
    let inset = s * 0.06
    let body = CGRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let radius = body.width * 0.22
    let path = CGMutablePath()
    path.addRoundedRect(in: body, cornerWidth: radius, cornerHeight: radius)
    ctx.addPath(path)
    let topColor = CGColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0)
    let botColor = CGColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1.0)
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [topColor, botColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // Shell-prompt wordmark — bold monospace `>mnml`. The `>` is the
    // app's accent color (cool blue for mnml), the name is near-white.
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let accent = NSColor(red: 0.35, green: 0.60, blue: 0.95, alpha: 1.0) // mnml: cool blue
    let textColor = NSColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0)
    let fontSize = s * 0.32
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let para = NSMutableParagraphStyle()
    para.alignment = .center

    let attributed = NSMutableAttributedString()
    attributed.append(NSAttributedString(string: "> ", attributes: [
        .font: font,
        .foregroundColor: accent,
        .paragraphStyle: para,
        .kern: -fontSize * 0.04,
    ]))
    attributed.append(NSAttributedString(string: "mnml", attributes: [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: para,
        .kern: -fontSize * 0.04,
    ]))

    let textSize = attributed.size()
    let textRect = CGRect(
        x: body.minX + (body.width - textSize.width) / 2,
        y: body.midY - textSize.height / 2,
        width: textSize.width,
        height: textSize.height
    )
    attributed.draw(in: textRect)

    NSGraphicsContext.restoreGraphicsState()

    // Encode as PNG.
    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])
}

for (name, side) in sizes {
    guard let data = render(side) else {
        FileHandle.standardError.write("render \(side) failed\n".data(using: .utf8)!)
        exit(1)
    }
    let url = iconsetDir.appendingPathComponent(name)
    try data.write(to: url)
    print("wrote \(url.path)")
}
