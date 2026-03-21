// AudioMeterView — per-channel L/R dBFS bars from real MeterSnapshot XPC events.
// Peak hold lines. Mute indicator. Updates at ≥10Hz (driven by XPC push, not polling).

import SwiftUI
import RoomControlXPCContracts

// MARK: - Output Card Audio Meter

struct OutputCardAudioMeter: View {
    let sourceID: String?
    @ObservedObject var state: ShellViewState

    private var snapshot: MeterSnapshot? {
        guard let sourceID else { return nil }
        return state.meterSnapshots[sourceID]
    }

    var body: some View {
        HStack(spacing: 3) {
            if let snapshot, !snapshot.channelLevelsDBFS.isEmpty {
                // L/R channels (or mono)
                ForEach(Array(snapshot.channelLevelsDBFS.prefix(2).enumerated()), id: \.offset) { index, level in
                    AudioMeterBar(
                        levelDBFS: level,
                        peakDBFS: snapshot.peakDBFS,
                        clipping: snapshot.clipping,
                        channelLabel: channelLabel(index: index, count: snapshot.channelLevelsDBFS.count)
                    )
                }
            } else {
                // No meter data — show inactive bars
                AudioMeterBar(levelDBFS: -96, peakDBFS: -96, clipping: false, channelLabel: "L")
                AudioMeterBar(levelDBFS: -96, peakDBFS: -96, clipping: false, channelLabel: "R")
            }
        }
        .frame(height: 48)
    }

    private func channelLabel(index: Int, count: Int) -> String {
        if count == 1 { return "M" }
        return index == 0 ? "L" : "R"
    }
}

// MARK: - Individual Meter Bar

struct AudioMeterBar: View {
    let levelDBFS: Float
    let peakDBFS: Float
    let clipping: Bool
    let channelLabel: String

    /// Map dBFS to 0.0–1.0 bar fill.
    /// Range: -60 dBFS (empty) to 0 dBFS (full).
    private var fillFraction: CGFloat {
        let clamped = max(-60, min(0, CGFloat(levelDBFS)))
        return (clamped + 60) / 60
    }

    private var peakFraction: CGFloat {
        let clamped = max(-60, min(0, CGFloat(peakDBFS)))
        return (clamped + 60) / 60
    }

    private var meterColor: Color {
        if clipping { return BrandTokens.red }
        if levelDBFS > -6 { return BrandTokens.red }
        if levelDBFS > -12 { return BrandTokens.gold }
        return BrandTokens.pgnGreen
    }

    var body: some View {
        VStack(spacing: 2) {
            // Channel label
            Text(channelLabel)
                .font(BrandTokens.mono(size: 7))
                .foregroundStyle(BrandTokens.warmGrey)

            // Meter bar
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    // Background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BrandTokens.cardBlack)

                    // Fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(meterColor)
                        .frame(height: geometry.size.height * fillFraction)

                    // Peak hold line
                    if peakDBFS > -60 {
                        Rectangle()
                            .fill(peakDBFS > -6 ? BrandTokens.red : BrandTokens.offWhite)
                            .frame(height: 1)
                            .offset(y: -geometry.size.height * peakFraction + geometry.size.height * 0.5)
                    }

                    // Clipping indicator
                    if clipping {
                        Rectangle()
                            .fill(BrandTokens.red)
                            .frame(height: 3)
                            .frame(maxWidth: .infinity)
                            .position(x: geometry.size.width / 2, y: 1.5)
                    }
                }
            }
            .frame(width: 6)
        }
    }
}

// MARK: - Mute Indicator

struct MuteIndicator: View {
    let isMuted: Bool

    var body: some View {
        if isMuted {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 9))
                .foregroundStyle(BrandTokens.red)
        }
    }
}
