#!/usr/bin/env swift
// Renders the Zephr app icon into Zephr/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root:  swift tools/make-icon.swift
//
// Design: the macOS Big Sur rounded-rect canvas, a sky gradient (Zephr =
// west wind), and the product itself as the glyph — one tall tile beside
// two stacked tiles, gaps included, matching the menu-bar symbol.

import AppKit

let canvas: CGFloat = 1024

func drawIcon(into ctx: CGContext) {
    ctx.saveGState()

    // macOS icon grid: ~824pt rounded rect centered on the 1024 canvas.
    let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let plate = CGPath(
        roundedRect: plateRect,
        cornerWidth: 185, cornerHeight: 185,
        transform: nil
    )

    // Soft drop shadow like system icons.
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12),
        blur: 36,
        color: CGColor(gray: 0, alpha: 0.35)
    )
    ctx.addPath(plate)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Sky gradient, light at the top.
    ctx.addPath(plate)
    ctx.clip()
    let colors = [
        CGColor(red: 0.42, green: 0.72, blue: 0.98, alpha: 1),
        CGColor(red: 0.16, green: 0.38, blue: 0.84, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )

    // Subtle diagonal sheen.
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))
    ctx.move(to: CGPoint(x: 100, y: 924))
    ctx.addLine(to: CGPoint(x: 924, y: 924))
    ctx.addLine(to: CGPoint(x: 100, y: 420))
    ctx.closePath()
    ctx.fillPath()

    // The glyph: one tall tile + two stacked tiles with an inner gap —
    // Zephr's layout tree in miniature.
    let glyph = CGRect(x: 262, y: 262, width: 500, height: 500)
    let gap: CGFloat = 42
    let corner: CGFloat = 44
    let leftWidth = (glyph.width - gap) * 0.52
    let rightWidth = glyph.width - gap - leftWidth
    let topHeight = (glyph.height - gap) * 0.56

    func tile(_ rect: CGRect, alpha: CGFloat) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: corner, cornerHeight: corner,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
        ctx.fillPath()
    }

    tile(CGRect(x: glyph.minX, y: glyph.minY, width: leftWidth, height: glyph.height), alpha: 0.96)
    tile(CGRect(x: glyph.minX + leftWidth + gap, y: glyph.minY + glyph.height - topHeight,
                width: rightWidth, height: topHeight), alpha: 0.88)
    tile(CGRect(x: glyph.minX + leftWidth + gap, y: glyph.minY,
                width: rightWidth, height: glyph.height - topHeight - gap), alpha: 0.78)

    ctx.restoreGState()
}

func writePNG(pixels: Int, to url: URL) {
    let ctx = CGContext(
        data: nil,
        width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(into: ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = repoRoot.appendingPathComponent("Zephr/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var contents: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    writePNG(pixels: points * scale, to: iconset.appendingPathComponent(name))
    contents.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(scale)x",
        "size": "\(points)x\(points)",
    ])
}

let json: [String: Any] = [
    "images": contents,
    "info": ["author": "xcode", "version": 1],
]
let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(contents.count) icons to \(iconset.path)")
