// CapacityStatusBar — bottom status bar showing capacity, NIC throughput, NDI counts.
// Wired to EngineHealthSnapshot via XPC events + CapacitySampler (1Hz host metrics).

import SwiftUI

struct CapacityStatusBar: View {
    @ObservedObject var state: ShellViewState

    var body: some View {
        HStack(spacing: 12) {
            badge("\(state.capacity.configuredOutputs)", label: "outputs")
            badge("\(state.capacity.discoveredSources)", label: "sources")
            badge(formatCPU(state.capacity.cpuPercent), label: "cpu")
            badge(formatGPU(state.capacity.estimatedGPUPressure), label: "gpu")
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

    private func formatGPU(_ value: Double?) -> String {
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
