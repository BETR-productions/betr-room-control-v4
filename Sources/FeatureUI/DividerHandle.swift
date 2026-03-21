// DividerHandle — draggable column/row divider, preserved from v3.

import SwiftUI

struct DividerHandle: View {
    enum Axis {
        case vertical
        case horizontal
    }

    let axis: Axis
    let onDrag: (Double) -> Void
    let onEnded: () -> Void
    @State private var lastTranslation: CGSize = .zero

    init(_ axis: Axis, onDrag: @escaping (Double) -> Void, onEnded: @escaping () -> Void) {
        self.axis = axis
        self.onDrag = onDrag
        self.onEnded = onEnded
    }

    var body: some View {
        Rectangle()
            .fill(BrandTokens.charcoal.opacity(0.65))
            .frame(width: axis == .vertical ? 6 : nil, height: axis == .horizontal ? 6 : nil)
            .overlay(
                Rectangle()
                    .fill(BrandTokens.gold.opacity(0.2))
                    .frame(width: axis == .vertical ? 2 : nil, height: axis == .horizontal ? 2 : nil)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        switch axis {
                        case .vertical:
                            onDrag(value.translation.width - lastTranslation.width)
                        case .horizontal:
                            onDrag(value.translation.height - lastTranslation.height)
                        }
                        lastTranslation = value.translation
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        onEnded()
                    }
            )
    }
}
