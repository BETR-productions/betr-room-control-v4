// TimerControlView — timer panel with start/stop/pause/resume/restart controls.
// Task 59: Duration mode and end-time mode both functional.

import SwiftUI
import TimerDomain

// MARK: - Timer Control View

public struct TimerControlView: View {
    @ObservedObject var store: TimerControlStore

    public init(store: TimerControlStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            timerHeader
            Divider().background(BrandTokens.charcoal)
            timeDisplay
            Divider().background(BrandTokens.charcoal)
            modeSelector
            Divider().background(BrandTokens.charcoal)
            transportBar
        }
        .background(BrandTokens.panelDark)
    }

    // MARK: - Header

    private var timerHeader: some View {
        HStack {
            Text("Timer")
                .font(BrandTokens.display(size: 13, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BrandTokens.toolbarDark)
    }

    private var statusBadge: some View {
        Text(store.runState.displayLabel)
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(store.runState.badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Time Display

    private var timeDisplay: some View {
        VStack(spacing: 4) {
            Text(store.displayText)
                .font(BrandTokens.mono(size: 48))
                .foregroundStyle(store.runState == .running ? BrandTokens.gold : BrandTokens.offWhite)
                .monospacedDigit()
            Text(store.modeLabel)
                .font(BrandTokens.display(size: 11))
                .foregroundStyle(BrandTokens.warmGrey)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(BrandTokens.surfaceDark)
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $store.selectedMode) {
                Text("Duration").tag(TimerControlStore.Mode.duration)
                Text("End Time").tag(TimerControlStore.Mode.endTime)
            }
            .pickerStyle(.segmented)

            switch store.selectedMode {
            case .duration:
                durationInput
            case .endTime:
                endTimeInput
            }
        }
        .padding(12)
    }

    private var durationInput: some View {
        HStack(spacing: 8) {
            Text("Duration:")
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(BrandTokens.warmGrey)

            HStack(spacing: 4) {
                durationField(value: $store.durationMinutes, label: "m")
                Text(":")
                    .font(BrandTokens.mono(size: 14))
                    .foregroundStyle(BrandTokens.warmGrey)
                durationField(value: $store.durationSeconds, label: "s")
            }

            Spacer()

            Button("Set") {
                store.applyDuration()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(BrandTokens.gold)
        }
    }

    private func durationField(value: Binding<Int>, label: String) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(BrandTokens.mono(size: 14))
                .foregroundStyle(BrandTokens.offWhite)
                .frame(width: 36)
                .multilineTextAlignment(.trailing)
            Text(label)
                .font(BrandTokens.display(size: 10))
                .foregroundStyle(BrandTokens.warmGrey)
        }
    }

    private var endTimeInput: some View {
        HStack(spacing: 8) {
            Text("End at:")
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(BrandTokens.warmGrey)

            DatePicker("", selection: $store.endTimeDate, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .frame(width: 100)

            Spacer()

            Button("Set") {
                store.applyEndTime()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(BrandTokens.gold)
        }
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 16) {
            switch store.runState {
            case .stopped:
                transportButton(systemName: "play.fill", label: "Start", action: store.start, highlighted: true)
            case .running:
                transportButton(systemName: "pause.fill", label: "Pause", action: store.pause)
                transportButton(systemName: "stop.fill", label: "Stop", action: store.stop)
            case .paused:
                transportButton(systemName: "play.fill", label: "Resume", action: store.resume, highlighted: true)
                transportButton(systemName: "stop.fill", label: "Stop", action: store.stop)
            }

            Spacer()

            if store.runState != .stopped {
                transportButton(systemName: "arrow.counterclockwise", label: "Restart", action: store.restart)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BrandTokens.toolbarDark)
    }

    private func transportButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void,
        highlighted: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 12))
                Text(label)
                    .font(BrandTokens.display(size: 11))
            }
            .foregroundStyle(highlighted ? BrandTokens.gold : BrandTokens.offWhite)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timer Run State Extensions

private extension TimerRunState {
    var displayLabel: String {
        switch self {
        case .stopped: "READY"
        case .running: "RUNNING"
        case .paused: "PAUSED"
        }
    }

    var badgeColor: Color {
        switch self {
        case .stopped: BrandTokens.charcoal
        case .running: BrandTokens.gold
        case .paused: BrandTokens.warmGrey
        }
    }
}

// MARK: - Timer Control Store

public final class TimerControlStore: ObservableObject {
    public enum Mode: String, CaseIterable {
        case duration
        case endTime
    }

    @Published public var runState: TimerRunState = .stopped
    @Published public var displayText: String = "10:00"
    @Published public var selectedMode: Mode = .duration
    @Published public var durationMinutes: Int = 10
    @Published public var durationSeconds: Int = 0
    @Published public var endTimeDate: Date = Date().addingTimeInterval(600)

    private let producer: TimerProducer

    public init(producer: TimerProducer) {
        self.producer = producer
    }

    public var modeLabel: String {
        switch selectedMode {
        case .duration: "Duration countdown"
        case .endTime: "End-time countdown"
        }
    }

    // MARK: - Mode Apply

    public func applyDuration() {
        let totalSeconds = durationMinutes * 60 + durationSeconds
        Task { await producer.setDuration(seconds: max(1, totalSeconds)) }
    }

    public func applyEndTime() {
        Task { await producer.setEndTime(target: endTimeDate) }
    }

    // MARK: - Transport

    public func start() {
        switch selectedMode {
        case .duration:
            applyDuration()
        case .endTime:
            applyEndTime()
        }
        Task { await producer.start() }
    }

    public func stop() {
        Task { await producer.stop() }
    }

    public func pause() {
        Task { await producer.pause() }
    }

    public func resume() {
        Task { await producer.resume() }
    }

    public func restart() {
        Task { await producer.restart() }
    }

    // MARK: - Sync

    public func refreshFromProducer() {
        Task {
            let snapshot = await producer.snapshot()
            await MainActor.run {
                runState = snapshot.runState
                displayText = snapshot.displayText
            }
        }
    }
}
