import AppKit
import SwiftUI

enum BrandTokens {
    static let gold = Color(hex: 0xFFAD33)
    static let dark = Color(hex: 0x1A1A1A)
    static let red = Color(hex: 0xF9512D)
    static let charcoal = Color(hex: 0x494645)
    static let warmGrey = Color(hex: 0x918C88)
    static let offWhite = Color(hex: 0xF4F3F1)
    static let warmLight = Color(hex: 0xEBE8E5)
    static let white = Color.white
    // Match the v2 operator shell's muted live-state toolbar tint.
    static let liveRed = Color(hex: 0x2A1A1A)
    static let surfaceDark = Color(hex: 0x2A2A2A)
    static let toolbarDark = Color(hex: 0x222222)
    static let panelDark = Color(hex: 0x202020)
    static let cardBlack = Color(hex: 0x111111)
    static let timerGreen = Color(hex: 0x22C55E)
    static let timerYellow = Color(hex: 0xFFC107)
    static let pgnGreen = Color(hex: 0x1F9D55)
    static let pvwRed = Color(hex: 0xC73B33)

    static let displayFont = "Inter"
    static let monoFont = "SF Mono"

    static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(displayFont, size: size).weight(weight)
    }

    static func mono(size: CGFloat) -> Font {
        .custom(monoFont, size: size)
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

extension NSColor {
    static let betrGold: NSColor = {
        if #available(macOS 11.0, *) {
            return NSColor(BrandTokens.gold)
        }
        return NSColor(red: 0xFF / 255.0, green: 0xAD / 255.0, blue: 0x33 / 255.0, alpha: 1)
    }()
}
