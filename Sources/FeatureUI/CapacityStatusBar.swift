// CapacityStatusBar — bottom status bar showing capacity, NIC throughput, NDI counts.
// Task 144: Polish to match v3 layout — fallback count, rx/tx, timer status, NIC name.
// Wired to EngineHealthSnapshot via XPC events + CapacitySampler (1Hz host metrics).

import SwiftUI
import TimerDomain

struct CapacityStatusBar: View {
    @ObservedObject var state: ShellViewState

    var body: some View {
        HStack(spacing: 12) {
            // Output capacity indicator (Task 129)
            outputCapacityBadge
            badge("\(state.capacity.discoveredSources)", label: "sources")
            badge("\(state.capacity.fallbackOutputs)", label: "fallback")
            badge("\(state.capacity.activeRx)", label: "rx")
            badge("\(state.capacity.activeTx)", label: "tx")
            timerBadge
            badge(formatCPU(state.capacity.cpuPercent), label: "cpu")
            badge(formatNetwork(), label: "nic")
            badge(formatNICUtil(state.capacity.nicUtilizationPercent), label: "util")
            if let headroom = state.capacity.remainingHeadroom {
                badge("\(headroom)", label: "headroom")
            }
            Spacer()
            Text(state.capacity.sdkVersion ?? "NDI runtime unavailable")
                .font(BrandTokens.mono(size: 10))
                .foregroundStyle(BrandTokens.warmGrey)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(BrandTokens.toolbarDark)
    }

    /// Output capacity: "Outputs: 2/5 (3 available)" with gold at 80%, red at max (Task 129).
    private var outputCapacityBadge: some View {
        let count = state.cards.count
        let max = ShellViewState.maxOutputs
        let available = max - count
        let color: Color = {
            if count >= max { return BrandTokens.red }
            if count >= Int(ceil(Double(max) * 0.8)) { return BrandTokens.gold }
            return BrandTokens.offWhite
        }()

        return HStack(spacing: 4) {
            Text("\(count)/\(max)")
                .font(BrandTokens.mono(size: 12))
                .foregroundStyle(color)
            Text("OUTPUTS")
                .font(BrandTokens.mono(size: 9))
                .foregroundStyle(BrandTokens.warmGrey)
            Text("(\(available) avail)")
                .font(BrandTokens.mono(size: 9))
                .foregroundStyle(BrandTokens.warmGrey)
        }
    }

    /// Timer status badge — shows whether timer producer is active.
    private var timerBadge: some View {
        let timerActive = state.timerStore?.runState == .running
        return badge(timerActive ? "on" : "off", label: "timer")
    }

    private func badge(_ value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(BrandTokens.mono(size: 12))
                .foregroundStyle(BrandTokens.offWhite)
            Text(label.uppercased())
                .font(BrandTokens.mono(size: 9))
                .foregroundStyle(BrandTokens.warmGrey)
        }
    }

    private func formatCPU(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.0f%%", value)
    }

    private func formatNetwork() -> String {
        guard let inbound = state.capacity.nicInboundMbps,
              let outbound = state.capacity.nicOutboundMbps else { return "n/a" }
        return String(format: "%.0f/%.0f", inbound, outbound)
    }

    private func formatNICUtil(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.0f%%", value)
    }
}
