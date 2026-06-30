#!/usr/bin/env swift
//
// Generate AppIcon.icns for ThreadTidy.
//
// Draws a clean icon at every iconset size (16…1024 plus retina @2x),
// writes the iconset folder, and invokes `iconutil` to produce the
// final .icns. Run from the repo root:
//
//     swift script/make-icon.swift <output.icns>
//
// Default output: src/ThreadTidy/Resources/AppIcon.icns

import Foundation
import AppKit
import CoreGraphics
import CoreText

// MARK: - Iconset sizes
// macOS expects pairs of @1x and @2x; iconutil maps these to the
// densities a .icns container needs.
private struct IconSize {
    let name: String
    let pixels: Int
}
private let sizes: [IconSize] = [
    .init(name: "icon_16x16.png",       pixels: 16),
    .init(name: "icon_16x16@2x.png",    pixels: 32),
    .init(name: "icon_32x32.png",       pixels: 32),
    .init(name: "icon_32x32@2x.png",    pixels: 64),
    .init(name: "icon_128x128.png",     pixels: 128),
    .init(name: "icon_128x128@2x.png",  pixels: 256),
    .init(name: "icon_256x256.png",     pixels: 256),
    .init(name: "icon_256x256@2x.png",  pixels: 512),
    .init(name: "icon_512x512.png",     pixels: 512),
    .init(name: "icon_512x512@2x.png",  pixels: 1024),
]

// MARK: - Drawing

// Renders one icon at `pixels` × `pixels` and returns the PNG data.
private func renderIcon(pixels: Int) -> Data? {
    let scale = CGFloat(pixels) / 1024
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(in: ctx, size: 1024)

    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: pixels, height: pixels)
    return rep.representation(using: .png, properties: [:])
}

// Draws the icon into a 1024×1024 logical context. The CGContext
// passed in has already been scaled, so we always think in 1024 units.
private func drawIcon(in ctx: CGContext, size: CGFloat) {
    // ---- Rounded-square background with vertical gradient ----
    // macOS Big Sur+ icon "squircle" radius is ~22.37% of side length.
    let inset: CGFloat = 100
    let bg = CGRect(x: inset, y: inset,
                    width: size - 2 * inset, height: size - 2 * inset)
    let radius = bg.width * 0.2237
    let path = CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Gradient: top = bright blue, bottom = deep indigo. Calm,
    // document-y palette without screaming primary blue.
    let topColor    = CGColor(red: 0.30, green: 0.55, blue: 0.92, alpha: 1.0)
    let bottomColor = CGColor(red: 0.16, green: 0.28, blue: 0.62, alpha: 1.0)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor, bottomColor] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: bg.maxY),
        end:   CGPoint(x: 0, y: bg.minY),
        options: []
    )
    ctx.restoreGState()

    // Subtle inner highlight for that glass-icon depth.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 0.6]
    )!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: 0, y: bg.maxY),
        end:   CGPoint(x: 0, y: bg.midY),
        options: []
    )
    ctx.restoreGState()

    // ---- Document / page shape ----
    // White rounded-rect with a folded top-right corner. Sized so it
    // sits comfortably inside the squircle with breathing room.
    let docW: CGFloat = 480
    let docH: CGFloat = 600
    let docX = (size - docW) / 2
    let docY = (size - docH) / 2 - 20
    let foldSize: CGFloat = 110

    let docPath = CGMutablePath()
    let docCornerR: CGFloat = 24
    // Build the page outline going clockwise from the top-left, with
    // a corner-fold cut at the top-right.
    docPath.move(to: CGPoint(x: docX + docCornerR, y: docY + docH))
    docPath.addLine(to: CGPoint(x: docX + docW - foldSize, y: docY + docH))
    docPath.addLine(to: CGPoint(x: docX + docW, y: docY + docH - foldSize))
    docPath.addLine(to: CGPoint(x: docX + docW, y: docY + docCornerR))
    docPath.addArc(
        center: CGPoint(x: docX + docW - docCornerR, y: docY + docCornerR),
        radius: docCornerR, startAngle: 0, endAngle: -.pi / 2, clockwise: true
    )
    docPath.addLine(to: CGPoint(x: docX + docCornerR, y: docY))
    docPath.addArc(
        center: CGPoint(x: docX + docCornerR, y: docY + docCornerR),
        radius: docCornerR, startAngle: -.pi / 2, endAngle: .pi, clockwise: true
    )
    docPath.addLine(to: CGPoint(x: docX, y: docY + docH - docCornerR))
    docPath.addArc(
        center: CGPoint(x: docX + docCornerR, y: docY + docH - docCornerR),
        radius: docCornerR, startAngle: .pi, endAngle: .pi / 2, clockwise: true
    )
    docPath.closeSubpath()

    // Drop shadow under the page.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12),
        blur: 30,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(docPath)
    ctx.fillPath()
    ctx.restoreGState()

    // Folded corner triangle, slightly darker than page.
    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: docX + docW - foldSize, y: docY + docH))
    foldPath.addLine(to: CGPoint(x: docX + docW - foldSize, y: docY + docH - foldSize))
    foldPath.addLine(to: CGPoint(x: docX + docW, y: docY + docH - foldSize))
    foldPath.closeSubpath()
    ctx.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 0.93, alpha: 1))
    ctx.addPath(foldPath)
    ctx.fillPath()
    // Fold-edge line.
    ctx.setStrokeColor(CGColor(red: 0.65, green: 0.70, blue: 0.78, alpha: 1))
    ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: docX + docW - foldSize, y: docY + docH - foldSize))
    ctx.addLine(to: CGPoint(x: docX + docW, y: docY + docH - foldSize))
    ctx.move(to: CGPoint(x: docX + docW - foldSize, y: docY + docH - foldSize))
    ctx.addLine(to: CGPoint(x: docX + docW - foldSize, y: docY + docH))
    ctx.strokePath()

    // ---- Centered "PDF" wordmark ----
    let label = "PDF"
    let fontSize: CGFloat = 180
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: 0.16, green: 0.28, blue: 0.62, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: label, attributes: attrs)
    )
    let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let textX = docX + (docW - textBounds.width) / 2 - textBounds.minX
    let textY = docY + (docH - textBounds.height) / 2 - textBounds.minY - 40
    ctx.textPosition = CGPoint(x: textX, y: textY)
    CTLineDraw(line, ctx)

    // ---- Sparkle / "cleaned" indicator ----
    // Small four-point star at upper-right of the page to suggest
    // the "cleaned" output state.
    let sparkleX = docX + docW - 70
    let sparkleY = docY + docH - 80
    drawSparkle(in: ctx, center: CGPoint(x: sparkleX, y: sparkleY), size: 70,
                color: CGColor(red: 1, green: 0.78, blue: 0.20, alpha: 1))
}

private func drawSparkle(in ctx: CGContext, center: CGPoint, size: CGFloat, color: CGColor) {
    let half = size / 2
    let waist = size / 12
    let p = CGMutablePath()
    p.move(to:    CGPoint(x: center.x,        y: center.y + half))
    p.addLine(to: CGPoint(x: center.x + waist, y: center.y + waist))
    p.addLine(to: CGPoint(x: center.x + half, y: center.y))
    p.addLine(to: CGPoint(x: center.x + waist, y: center.y - waist))
    p.addLine(to: CGPoint(x: center.x,        y: center.y - half))
    p.addLine(to: CGPoint(x: center.x - waist, y: center.y - waist))
    p.addLine(to: CGPoint(x: center.x - half, y: center.y))
    p.addLine(to: CGPoint(x: center.x - waist, y: center.y + waist))
    p.closeSubpath()
    ctx.saveGState()
    ctx.setFillColor(color)
    ctx.addPath(p)
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Driver

let args = CommandLine.arguments
let outICNS: String = args.count >= 2
    ? args[1]
    : FileManager.default.currentDirectoryPath
        + "/src/ThreadTidy/Resources/AppIcon.icns"

let tmp = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: tmp)
try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

print("Rendering iconset → \(tmp)")
for s in sizes {
    guard let data = renderIcon(pixels: s.pixels) else {
        FileHandle.standardError.write(Data("error: render failed at \(s.pixels)px\n".utf8))
        exit(1)
    }
    let path = "\(tmp)/\(s.name)"
    try data.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(s.name) (\(s.pixels)px)")
}

// Ensure parent directory of output exists.
let parent = (outICNS as NSString).deletingLastPathComponent
try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

print("Compiling .icns → \(outICNS)")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", "-o", outICNS, tmp]
try p.run()
p.waitUntilExit()
if p.terminationStatus != 0 {
    FileHandle.standardError.write(Data("error: iconutil failed (\(p.terminationStatus))\n".utf8))
    exit(p.terminationStatus)
}
print("Done.")
