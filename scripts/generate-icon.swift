#!/usr/bin/env swift
// Renders the BrightSync app icon (dark rounded rect with a sun) at every
// size an .icns needs and packs them with iconutil. The sun is drawn by
// hand - SF Symbols are not licensed for use in app icons.
import AppKit
import Foundation

func usage() {
    print("""
        Render the BrightSync app icon into an .icns (and optionally a PNG).

        Usage: scripts/generate-icon.swift [--output <path>] [--png <path>] [-h|--help]

        Options:
          --output <path>  Destination .icns (default: Packaging/AppIcon.icns)
          --png <path>     Also write a 512px PNG (for the README)
          -h, --help       Show this help.

        Example:
          scripts/generate-icon.swift --png Packaging/AppIcon.png
        """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

var output = "Packaging/AppIcon.icns"
var pngOutput: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help":
        usage()
        exit(0)
    case "--output":
        guard !arguments.isEmpty else { fail("--output needs a value") }
        output = arguments.removeFirst()
    case "--png":
        guard !arguments.isEmpty else { fail("--png needs a value") }
        pngOutput = arguments.removeFirst()
    default:
        fail("unknown argument: \(argument)")
    }
}

/// Draws the icon at a given pixel size. Geometry is authored on a 1024
/// canvas and scaled: an 824-point rounded rect plate (the macOS icon grid)
/// with a vertical dark gradient, and a yellow sun - disc plus eight
/// round-capped rays.
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { fail("cannot create bitmap for \(pixels)px") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(pixels) / 1024

    let plate = NSBezierPath(
        roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
        xRadius: 186 * s, yRadius: 186 * s)
    NSGradient(
        starting: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.30, alpha: 1),
        ending: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.12, alpha: 1)
    )!.draw(in: plate, angle: -90)

    let sun = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
    let center = NSPoint(x: 512 * s, y: 512 * s)
    sun.setFill()
    NSBezierPath(
        ovalIn: NSRect(x: center.x - 170 * s, y: center.y - 170 * s, width: 340 * s, height: 340 * s)
    ).fill()
    sun.setStroke()
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4
        let ray = NSBezierPath()
        ray.lineWidth = 70 * s
        ray.lineCapStyle = .round
        ray.move(to: NSPoint(x: center.x + cos(angle) * 245 * s, y: center.y + sin(angle) * 245 * s))
        ray.line(to: NSPoint(x: center.x + cos(angle) * 330 * s, y: center.y + sin(angle) * 330 * s))
        ray.stroke()
    }

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

do {
    let iconset = FileManager.default.temporaryDirectory
        .appendingPathComponent("brightsync-\(ProcessInfo.processInfo.processIdentifier).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    for (name, pixels) in sizes {
        let rep = drawIcon(pixels: pixels)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fail("cannot encode \(name).png")
        }
        try png.write(to: iconset.appendingPathComponent("\(name).png"))
    }

    let outputURL = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
    print("wrote \(output)")

    if let pngOutput {
        guard let png = drawIcon(pixels: 512).representation(using: .png, properties: [:]) else {
            fail("cannot encode PNG")
        }
        try png.write(to: URL(fileURLWithPath: pngOutput))
        print("wrote \(pngOutput)")
    }
} catch {
    fail("\(error)")
}
