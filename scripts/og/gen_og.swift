// gen_og.swift — emit a 1200x630 OpenGraph / Twitter card hero image
// for mnml.
//
//   swift scripts/og/gen_og.swift                  # writes site/public/og/hero.png
//   swift scripts/og/gen_og.swift path/to/out.png  # writes to a custom path
//
// Design: same family aesthetic as gen_icon.swift — deep-charcoal
// rounded body with the shell-prompt `> mnml` wordmark, mnml's cool
// blue accent on the `>`, near-white on the name. A small tagline
// sits under the wordmark. 1200x630 (Twitter's recommended card
// size — also fits Open Graph spec).

import Foundation
import AppKit

let outputPath: String = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "site/public/og/hero.png"

let WIDTH: Int = 1200
let HEIGHT: Int = 630
let TAGLINE = "A terminal IDE for the people who do everything in a terminal."

func render() -> Data? {
    let w = CGFloat(WIDTH)
    let h = CGFloat(HEIGHT)
    let cs = NSColorSpace.sRGB.cgColorSpace!
    guard let ctx = CGContext(
        data: nil,
        width: WIDTH,
        height: HEIGHT,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Background — full-bleed dark gradient (no bezel inset; OG images
    // get cropped/letterboxed by clients, so we want edge-to-edge
    // content).
    let topColor = CGColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1.0)
    let botColor = CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [topColor, botColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: h),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Inner rounded-square "card" — gives the hero the same identity
    // as the app icon (rounded charcoal body, cool-blue prompt accent).
    // We place it on the left and use the right column for the tagline
    // and tiny family chip.
    let cardSide: CGFloat = h * 0.66
    let cardX: CGFloat = w * 0.08
    let cardY: CGFloat = (h - cardSide) / 2
    let cardRect = CGRect(x: cardX, y: cardY, width: cardSide, height: cardSide)
    let cardRadius = cardSide * 0.22
    let cardPath = CGMutablePath()
    cardPath.addRoundedRect(in: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius)

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let cardTop = CGColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0)
    let cardBot = CGColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1.0)
    let cardGradient = CGGradient(
        colorsSpace: cs,
        colors: [cardTop, cardBot] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        cardGradient,
        start: CGPoint(x: cardX, y: cardY + cardSide),
        end: CGPoint(x: cardX, y: cardY),
        options: []
    )
    ctx.restoreGState()

    // Subtle stroke around the card so it has a defined edge against
    // the full-bleed background.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.setLineWidth(2)
    ctx.addPath(cardPath)
    ctx.strokePath()
    ctx.restoreGState()

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let accent = NSColor(red: 0.35, green: 0.60, blue: 0.95, alpha: 1.0) // cool blue
    let textColor = NSColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0)
    let mutedColor = NSColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 1.0)

    // Card wordmark — `> mnml`, centered inside the rounded card.
    let cardFontSize = cardSide * 0.30
    let cardFont = NSFont.monospacedSystemFont(ofSize: cardFontSize, weight: .bold)
    let cardPara = NSMutableParagraphStyle()
    cardPara.alignment = .center
    let cardWordmark = NSMutableAttributedString()
    cardWordmark.append(NSAttributedString(string: "> ", attributes: [
        .font: cardFont,
        .foregroundColor: accent,
        .paragraphStyle: cardPara,
        .kern: -cardFontSize * 0.04,
    ]))
    cardWordmark.append(NSAttributedString(string: "mnml", attributes: [
        .font: cardFont,
        .foregroundColor: textColor,
        .paragraphStyle: cardPara,
        .kern: -cardFontSize * 0.04,
    ]))
    let cardWordmarkSize = cardWordmark.size()
    let cardWordmarkRect = CGRect(
        x: cardRect.minX + (cardRect.width - cardWordmarkSize.width) / 2,
        y: cardRect.midY - cardWordmarkSize.height / 2,
        width: cardWordmarkSize.width,
        height: cardWordmarkSize.height
    )
    cardWordmark.draw(in: cardWordmarkRect)

    // Right column — large wordmark + tagline + family chip.
    let rightX = cardRect.maxX + w * 0.05
    let rightW = w - rightX - w * 0.06

    // Headline wordmark on the right, larger and aligned with the card.
    let headFontSize: CGFloat = 92
    let headFont = NSFont.monospacedSystemFont(ofSize: headFontSize, weight: .bold)
    let leftPara = NSMutableParagraphStyle()
    leftPara.alignment = .left
    let head = NSMutableAttributedString()
    head.append(NSAttributedString(string: "> ", attributes: [
        .font: headFont,
        .foregroundColor: accent,
        .paragraphStyle: leftPara,
        .kern: -headFontSize * 0.04,
    ]))
    head.append(NSAttributedString(string: "mnml", attributes: [
        .font: headFont,
        .foregroundColor: textColor,
        .paragraphStyle: leftPara,
        .kern: -headFontSize * 0.04,
    ]))
    let headSize = head.size()
    let headRect = CGRect(
        x: rightX,
        y: h * 0.58,
        width: rightW,
        height: headSize.height
    )
    head.draw(in: headRect)

    // Tagline — multi-line, wraps inside the right column.
    let tagFontSize: CGFloat = 30
    let tagFont = NSFont.systemFont(ofSize: tagFontSize, weight: .regular)
    let tagPara = NSMutableParagraphStyle()
    tagPara.alignment = .left
    tagPara.lineSpacing = 4
    let tag = NSAttributedString(string: TAGLINE, attributes: [
        .font: tagFont,
        .foregroundColor: mutedColor,
        .paragraphStyle: tagPara,
    ])
    let tagRect = CGRect(
        x: rightX,
        y: h * 0.30,
        width: rightW,
        height: 130
    )
    tag.draw(in: tagRect)

    // Family chip at the bottom — small caps, muted.
    let chipFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .medium)
    let chip = NSAttributedString(string: "MNML  ·  TMNL  ·  MIXR", attributes: [
        .font: chipFont,
        .foregroundColor: NSColor(red: 0.45, green: 0.50, blue: 0.58, alpha: 1.0),
        .paragraphStyle: leftPara,
        .kern: 4.0,
    ])
    let chipRect = CGRect(
        x: rightX,
        y: h * 0.13,
        width: rightW,
        height: 28
    )
    chip.draw(in: chipRect)

    NSGraphicsContext.restoreGraphicsState()

    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])
}

guard let data = render() else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
    exit(1)
}

let outURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try data.write(to: outURL)
print("wrote \(outURL.path) (\(WIDTH)x\(HEIGHT))")
