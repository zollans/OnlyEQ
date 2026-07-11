#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let destination = URL(fileURLWithPath: arguments.first ?? "Resources/AppIcon.icns")
let previewDestination = arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory
    .appendingPathComponent("OnlyEQ-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

let variants: [(name: String, pixels: Int)] = [
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

func renderIcon(pixels: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(pixels)
    context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
    let tileRect = CGRect(x: side * 0.08, y: side * 0.08, width: side * 0.84, height: side * 0.84)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: side * 0.19, yRadius: side * 0.19)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.10, green: 0.58, blue: 1.00, alpha: 1),
        NSColor(red: 0.00, green: 0.38, blue: 0.92, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: -90)

    let pointSize = side * 0.43
    let baseConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white])
    guard let symbol = NSImage(
        systemSymbolName: "chart.bar.fill",
        accessibilityDescription: "OnlyEQ"
    )?.withSymbolConfiguration(baseConfiguration.applying(colorConfiguration)) else {
        throw CocoaError(.featureUnsupported)
    }
    let symbolWidth = min(symbol.size.width, side * 0.50)
    let symbolHeight = min(symbol.size.height, side * 0.50)
    symbol.draw(
        in: CGRect(
            x: (side - symbolWidth) / 2,
            y: (side - symbolHeight) / 2,
            width: symbolWidth,
            height: symbolHeight
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

for variant in variants {
    try renderIcon(pixels: variant.pixels, to: iconset.appendingPathComponent(variant.name))
}

if let previewDestination {
    try fileManager.createDirectory(
        at: previewDestination.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? fileManager.removeItem(at: previewDestination)
    try fileManager.copyItem(
        at: iconset.appendingPathComponent("icon_512x512@2x.png"),
        to: previewDestination
    )
}

try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Generated \(destination.path)")
