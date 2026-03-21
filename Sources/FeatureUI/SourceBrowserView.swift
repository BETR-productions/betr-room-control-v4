// SourceBrowserView — left column source list with live NDI sources.
// Driven by sourcesChanged XPC events. Live indicator dot per source.
// Count badge on column header.

import SwiftUI
import RoutingDomain

struct SourceBrowserHeader: View {
    let sourceCount: Int

    var body: some View {
        HStack {
            Text("SOURCES")
                .font(BrandTokens.mono(size: 10))
                .foregroundStyle(BrandTokens.warmGrey)
            Spacer()
            Text("\(sourceCount)")
                .font(BrandTokens.mono(size: 10))
                .foregroundStyle(BrandTokens.offWhite)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(BrandTokens.charcoal)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SourceBrowserView: View {
    @ObservedObject var state: ShellViewState

    var body: some View {
        VStack(spacing: 0) {
            SourceBrowserHeader(sourceCount: state.sources.count)

            Divider()
                .background(BrandTokens.charcoal)

            if state.sources.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.sources) { source in
                            SourceRow(source: source, warmBadge: source.warmBadge)
                                .draggable(source.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(BrandTokens.warmGrey.opacity(0.5))
            Text("No NDI sources")
                .font(BrandTokens.display(size: 12, weight: .medium))
                .foregroundStyle(BrandTokens.warmGrey)
            Text("Sources will appear when discovered")
                .font(BrandTokens.mono(size: 9))
                .foregroundStyle(BrandTokens.warmGrey.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Source Row

struct SourceRow: View {
    let source: SourceState
    let warmBadge: WarmBadge

    var body: some View {
        HStack(spacing: 8) {
            // Live indicator dot
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(BrandTokens.display(size: 11, weight: .medium))
                    .foregroundStyle(source.isOnline ? BrandTokens.offWhite : BrandTokens.warmGrey)
                    .lineLimit(1)

                Text(statusLabel)
                    .font(BrandTokens.mono(size: 8))
                    .foregroundStyle(BrandTokens.warmGrey)
            }

            Spacer()

            if warmBadge == .warming {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }

    private var indicatorColor: Color {
        if !source.isOnline { return BrandTokens.warmGrey.opacity(0.4) }
        switch warmBadge {
        case .warm: return BrandTokens.pgnGreen
        case .warming: return BrandTokens.gold
        case .failed: return BrandTokens.red
        case .cold: return BrandTokens.offWhite.opacity(0.6)
        }
    }

    private var statusLabel: String {
        if !source.isOnline { return "Offline" }
        switch warmBadge {
        case .warm: return "Warm"
        case .warming: return "Warming..."
        case .failed: return "Failed"
        case .cold: return "Online"
        }
    }
}
