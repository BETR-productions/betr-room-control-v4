import CoreGraphics
import CoreText
import Foundation

public enum TimerFrameRenderer {
    public static func render(
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
        let widthValue = CGFloat(width)
        let heightValue = CGFloat(height)
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

            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
            context.fill(bounds)

            let accent = isRunning
                ? CGColor(red: 0.96, green: 0.69, blue: 0.20, alpha: 1)
                : CGColor(red: 0.38, green: 0.41, blue: 0.48, alpha: 1)
            context.setFillColor(accent)
            context.fill(CGRect(x: 0, y: height - max(10, height / 28), width: width, height: max(10, height / 28)))

            context.setFillColor(CGColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: max(10, height / 5)))

            drawText(
                title.uppercased(),
                in: CGRect(x: widthValue * 0.07, y: heightValue * 0.79, width: widthValue * 0.86, height: heightValue * 0.12),
                fontSize: max(26, heightValue * 0.055),
                color: CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1),
                alignment: .center,
                context: context
            )

            drawText(
                timeText,
                in: CGRect(x: widthValue * 0.08, y: heightValue * 0.34, width: widthValue * 0.84, height: heightValue * 0.32),
                fontSize: max(88, heightValue * 0.18),
                color: CGColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1),
                alignment: .center,
                context: context
            )

            drawText(
                subtitle,
                in: CGRect(x: widthValue * 0.07, y: heightValue * 0.14, width: widthValue * 0.86, height: heightValue * 0.12),
                fontSize: max(24, heightValue * 0.04),
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
