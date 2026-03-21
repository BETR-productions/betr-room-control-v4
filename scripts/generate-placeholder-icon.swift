#!/usr/bin/env swift
// generate-placeholder-icon.swift
// Creates a 1024x1024 placeholder AppIcon.png with BËTR dark background and gold "B" mark.
// Replace Resources/AppIcon.png with the final BËTR logomark before release.
// Usage: swift generate-placeholder-icon.swift <output.png>

import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-placeholder-icon.swift <output.png>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Dark background (#111111 — cardBlack)
NSColor(srgbRed: 0x11/255.0, green: 0x11/255.0, blue: 0x11/255.0, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// Gold "B" lettermark centered
let gold = NSColor(srgbRed: 0xFF/255.0, green: 0xAD/255.0, blue: 0x33/255.0, alpha: 1.0)
let font = NSFont.systemFont(ofSize: 580, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: gold,
    .font: font
]
let letter = NSAttributedString(string: "B", attributes: attrs)
let letterSize = letter.size()
let letterRect = NSRect(
    x: (size - letterSize.width) / 2,
    y: (size - letterSize.height) / 2,
    width: letterSize.width,
    height: letterSize.height
)
letter.draw(in: letterRect)

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
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
