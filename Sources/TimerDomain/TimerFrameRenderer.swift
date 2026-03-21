// TimerFrameRenderer — CoreText rendering for timer overlay frames.
// Renders countdown text to BGRA pixel data for IOSurface push.

import CoreGraphics
import CoreText
import Foundation

enum TimerFrameRenderer {
    static func render(
        width: Int,
        height: Int,
        title: String,
        subtitle: String,
        timeText: String,
        isRunning: Bool
    ) -> Data? {
        let lineStride = width * 4
        let byteCount = lineStride * height
        guard byteCount > 0 else { return nil }

        var pixelData = Data(count: byteCount)
        let widthF = CGFloat(width)
        let heightF = CGFloat(height)
        let didRender = pixelData.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: lineStride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                return false
            }

            // Background — dark
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
            context.fill(bounds)

            // Top accent bar — gold when running, grey when stopped
            let accent = isRunning
                ? CGColor(red: 0.96, green: 0.69, blue: 0.20, alpha: 1)  // BrandTokens.gold approx
                : CGColor(red: 0.38, green: 0.41, blue: 0.48, alpha: 1)
            let barHeight = max(10, height / 28)
            context.setFillColor(accent)
            context.fill(CGRect(x: 0, y: height - barHeight, width: width, height: barHeight))

            // Bottom strip
            context.setFillColor(CGColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: max(10, height / 5)))

            // Title
            drawText(
                title.uppercased(),
                in: CGRect(x: widthF * 0.07, y: heightF * 0.79, width: widthF * 0.86, height: heightF * 0.12),
                fontSize: max(26, heightF * 0.055),
                color: CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1),
                alignment: .center,
                context: context
            )

            // Time display
            drawText(
                timeText,
                in: CGRect(x: widthF * 0.08, y: heightF * 0.34, width: widthF * 0.84, height: heightF * 0.32),
                fontSize: max(88, heightF * 0.18),
                color: CGColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1),
                alignment: .center,
                context: context
            )

            // Subtitle
            drawText(
                subtitle,
                in: CGRect(x: widthF * 0.07, y: heightF * 0.14, width: widthF * 0.86, height: heightF * 0.12),
                fontSize: max(24, heightF * 0.04),
                color: CGColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1),
                alignment: .center,
                context: context
            )
            return true
        }

        return didRender ? pixelData : nil
    }

    private static func drawText(
        _ string: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: CGColor,
        alignment: CTTextAlignment,
        context: CGContext
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil),
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x: CGFloat
        switch alignment {
        case .center:
            x = rect.midX - (bounds.width / 2)
        case .right:
            x = rect.maxX - bounds.width
        default:
            x = rect.minX
        }
        let y = rect.midY - (bounds.height / 2)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
