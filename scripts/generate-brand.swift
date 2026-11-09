#!/usr/bin/env swift
// Packages the approved imagegen 05A artwork and a geometric menu-bar adaptation.
// Run from the repository root: swift scripts/generate-brand.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("OrielApp/Resources/Brand")
let artwork = root.appendingPathComponent("docs/brand")
let iconset = root.appendingPathComponent(".build/brand/Oriel.iconset")
for directory in [resources, artwork, iconset] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
guard let source = NSImage(contentsOf: artwork.appendingPathComponent("oriel-05a-source.png")) else {
    fatalError("Missing approved 05A source artwork; see docs/brand/README.md")
}

// A deliberately simplified, transparent vector template: two windows and eyes.
func menuMark() {
    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64))
    clip.append(NSBezierPath(roundedRect: NSRect(x: 17, y: 30, width: 47, height: 34), xRadius: 10, yRadius: 10))
    clip.windingRule = .evenOdd
    clip.addClip()
    let rear = NSBezierPath(roundedRect: NSRect(x: 4, y: 5, width: 46, height: 47), xRadius: 9, yRadius: 9)
    rear.windingRule = .evenOdd
    for x: CGFloat in [12, 20, 28] {
        rear.append(NSBezierPath(ovalIn: NSRect(x: x - 1.8, y: 11, width: 3.6, height: 3.6)))
    }
    for x: CGFloat in [28, 39] {
        rear.append(NSBezierPath(ovalIn: NSRect(x: x, y: 23, width: 10, height: 13)))
    }
    NSColor.black.setFill()
    rear.fill()
    for x: CGFloat in [33, 44] {
        NSBezierPath(ovalIn: NSRect(x: x, y: 27, width: 4.5, height: 7)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let front = NSBezierPath(roundedRect: NSRect(x: 20, y: 33, width: 42, height: 27), xRadius: 7, yRadius: 7)
    front.windingRule = .evenOdd
    for x: CGFloat in [28, 35, 42] {
        front.append(NSBezierPath(ovalIn: NSRect(x: x - 1.6, y: 38, width: 3.2, height: 3.2)))
    }
    NSColor.black.setFill()
    front.fill()
}

func placedMenu(in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scaleX(by: rect.width / 64, yBy: rect.height / 64)
    transform.concat()
    menuMark()
    NSGraphicsContext.restoreGraphicsState()
}

func icon(in rect: NSRect, rounded: Bool = true) {
    NSGraphicsContext.saveGraphicsState()
    if rounded {
        NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22).addClip()
    }
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

func png(_ url: URL, width: Int, height: Int, logical: NSSize, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSGraphicsContext.current?.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(width) / logical.width, y: CGFloat(height) / logical.height)
    context.cgContext.translateBy(x: 0, y: logical.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

func pdf(_ name: String, draw: () -> Void) throws {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 64, height: 64)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: 64)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try (data as Data).write(to: resources.appendingPathComponent(name))
}

// Color PDF embeds the selected raster; the menu PDF is true vector artwork.
try pdf("OrielMark.pdf") { icon(in: NSRect(x: 0, y: 0, width: 64, height: 64)) }
try pdf("OrielMenuTemplate.pdf", draw: menuMark)
try png(artwork.appendingPathComponent("oriel-icon.png"), width: 1024, height: 1024,
        logical: NSSize(width: 1024, height: 1024)) {
    icon(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), rounded: false)
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png(iconset.appendingPathComponent(name), width: size * scale, height: size * scale,
                logical: NSSize(width: 1024, height: 1024)) {
            icon(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), rounded: false)
        }
    }
}
try png(artwork.appendingPathComponent("oriel-preview.png"), width: 1680, height: 720,
        logical: NSSize(width: 840, height: 360)) {
    NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 840, height: 360).fill()
    icon(in: NSRect(x: 22, y: 20, width: 300, height: 300))
    icon(in: NSRect(x: 350, y: 76, width: 96, height: 96))
    ("Oriel" as NSString).draw(at: NSPoint(x: 460, y: 95), withAttributes: [
        .font: NSFont.systemFont(ofSize: 48, weight: .semibold), .foregroundColor: NSColor.labelColor])
    for (i, size) in [18, 22, 32, 48].enumerated() {
        placedMenu(in: NSRect(x: 362 + i * 65, y: 224, width: size, height: size))
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <title>Oriel Curious — monochrome menu mark</title>
  <defs><clipPath id="rear"><path fill-rule="evenodd" clip-rule="evenodd" d="M0 0h64v64H0Z M27 30h27a10 10 0 0 1 10 10v14a10 10 0 0 1-10 10H27a10 10 0 0 1-10-10V40a10 10 0 0 1 10-10Z"/></clipPath></defs>
  <g clip-path="url(#rear)" fill="black">
    <path fill-rule="evenodd" d="M13 5h28a9 9 0 0 1 9 9v29a9 9 0 0 1-9 9H13a9 9 0 0 1-9-9V14a9 9 0 0 1 9-9Z M13.8 12.8a1.8 1.8 0 1 0-3.6 0 1.8 1.8 0 1 0 3.6 0Z M21.8 12.8a1.8 1.8 0 1 0-3.6 0 1.8 1.8 0 1 0 3.6 0Z M29.8 12.8a1.8 1.8 0 1 0-3.6 0 1.8 1.8 0 1 0 3.6 0Z M38 29.5a5 6.5 0 1 0-10 0 5 6.5 0 1 0 10 0Z M49 29.5a5 6.5 0 1 0-10 0 5 6.5 0 1 0 10 0Z"/>
    <ellipse cx="35.25" cy="30.5" rx="2.25" ry="3.5"/><ellipse cx="46.25" cy="30.5" rx="2.25" ry="3.5"/>
  </g>
  <path fill="black" fill-rule="evenodd" d="M27 33h28a7 7 0 0 1 7 7v13a7 7 0 0 1-7 7H27a7 7 0 0 1-7-7V40a7 7 0 0 1 7-7Z M29.6 39.6a1.6 1.6 0 1 0-3.2 0 1.6 1.6 0 1 0 3.2 0Z M36.6 39.6a1.6 1.6 0 1 0-3.2 0 1.6 1.6 0 1 0 3.2 0Z M43.6 39.6a1.6 1.6 0 1 0-3.2 0 1.6 1.6 0 1 0 3.2 0Z"/>
</svg>
"""
try svg.write(to: artwork.appendingPathComponent("oriel-menu.svg"), atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Oriel.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Packaged approved 05A app/sidebar artwork and monochrome menu mark.")
