#!/usr/bin/env swift
// generate-dmg-background.swift
// Generates a 600x400 BËTR-branded dark DMG background PNG.
// Usage: swift generate-dmg-background.swift <output.png>
//
// Colors:
//   Background: #1A1A1A (BrandTokens.dark)
//   Accent line: #FFAD33 (BrandTokens.gold)
//   Text: #918C88 (BrandTokens.warmGrey)

import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-dmg-background.swift <output.png>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let width: CGFloat = 600
let height: CGFloat = 400

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// Background: BËTR dark
NSColor(srgbRed: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Gold accent line at top
let accentGold = NSColor(srgbRed: 0xFF/255.0, green: 0xAD/255.0, blue: 0x33/255.0, alpha: 1.0)
accentGold.setFill()
NSRect(x: 0, y: height - 3, width: width, height: 3).fill()

// Subtle separator line at bottom
NSColor(srgbRed: 0xFF/255.0, green: 0xAD/255.0, blue: 0x33/255.0, alpha: 0.3).setFill()
NSRect(x: 0, y: 0, width: width, height: 1).fill()

// Drag-to-install label
let warmGrey = NSColor(srgbRed: 0x91/255.0, green: 0x8C/255.0, blue: 0x88/255.0, alpha: 1.0)
let labelAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: warmGrey,
    .font: NSFont.systemFont(ofSize: 13, weight: .regular)
]
let label = NSAttributedString(string: "Drag BËTR Room Control to Applications to install", attributes: labelAttrs)
let labelSize = label.size()
let labelRect = NSRect(
    x: (width - labelSize.width) / 2,
    y: 24,
    width: labelSize.width,
    height: labelSize.height
)
label.draw(in: labelRect)

// Arrow between icons (subtle)
let arrowAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: NSColor(srgbRed: 0xFF/255.0, green: 0xAD/255.0, blue: 0x33/255.0, alpha: 0.6),
    .font: NSFont.systemFont(ofSize: 28, weight: .thin)
]
let arrow = NSAttributedString(string: "→", attributes: arrowAttrs)
let arrowSize = arrow.size()
let arrowRect = NSRect(
    x: (width - arrowSize.width) / 2,
    y: (height - arrowSize.height) / 2 + 10,
    width: arrowSize.width,
    height: arrowSize.height
)
arrow.draw(in: arrowRect)

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
