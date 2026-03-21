#!/usr/bin/env swift
// round-icon.swift — Apply macOS-style rounded rect + proper padding to an app icon
// Usage: swift round-icon.swift <input.png> <output.png>
// Follows Apple's macOS icon grid: artwork fills ~80% of canvas, with ~10% padding per side

import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift round-icon.swift <input.png> <output.png>\n", stderr)
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let canvasSize: CGFloat = 1024

// Apple macOS icon grid: icon body is ~824px in a 1024 canvas (~80%)
let iconSize: CGFloat = canvasSize * 0.80
let padding = (canvasSize - iconSize) / 2
let radius = iconSize * 0.225  // ~23% of the icon body

guard let srcImage = NSImage(contentsOfFile: inputPath) else {
    fputs("Error: Cannot load image at \(inputPath)\n", stderr)
    exit(1)
}

let outImage = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
outImage.lockFocus()

// Transparent background (full canvas)
NSColor.clear.set()
NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

// Draw artwork centered with padding, clipped to rounded rect
let iconRect = NSRect(x: padding, y: padding, width: iconSize, height: iconSize)
let path = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)
path.addClip()

srcImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
outImage.unlockFocus()

guard let tiffData = outImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiffData),
      let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Error: Failed to generate PNG\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
