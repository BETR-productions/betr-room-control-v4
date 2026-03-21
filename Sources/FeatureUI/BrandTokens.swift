import AppKit
import SwiftUI

public enum BrandTokens {
    public static let gold = Color(hex: 0xFFAD33)
    public static let dark = Color(hex: 0x1A1A1A)
    public static let red = Color(hex: 0xF9512D)
    public static let charcoal = Color(hex: 0x494645)
    public static let warmGrey = Color(hex: 0x918C88)
    public static let offWhite = Color(hex: 0xF4F3F1)
    public static let warmLight = Color(hex: 0xEBE8E5)
    public static let white = Color.white
    // Match the v2 operator shell's muted live-state toolbar tint.
    public static let liveRed = Color(hex: 0x2A1A1A)
    public static let surfaceDark = Color(hex: 0x2A2A2A)
    public static let toolbarDark = Color(hex: 0x222222)
    public static let panelDark = Color(hex: 0x202020)
    public static let cardBlack = Color(hex: 0x111111)
    public static let timerGreen = Color(hex: 0x22C55E)
    public static let timerYellow = Color(hex: 0xFFC107)
    public static let pgnGreen = Color(hex: 0x1F9D55)
    public static let pvwRed = Color(hex: 0xC73B33)

    public static let displayFont = "Inter"
    public static let monoFont = "SF Mono"

    public static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(displayFont, size: size).weight(weight)
    }

    public static func mono(size: CGFloat) -> Font {
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
