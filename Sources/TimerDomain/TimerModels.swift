import Foundation

public enum TimerVisibilitySurface: String, Codable, Sendable, Equatable {
    case presenter
    case program
}

public struct SimpleTimerState: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, Equatable {
        case duration
        case endTime = "end_time"
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case durationSeconds
        case endTime
        case startedAt
        case running
        case remainingSeconds
        case visibleSurfaces
        case outputEnabled
    }

    public let mode: Mode
    public let durationSeconds: Int?
    public let endTime: Date?
    public let startedAt: Date?
    public let running: Bool
    public let remainingSeconds: Int?
    public let visibleSurfaces: [TimerVisibilitySurface]
    public let outputEnabled: Bool

    public init(
        mode: Mode,
        durationSeconds: Int? = nil,
        endTime: Date? = nil,
        startedAt: Date? = nil,
        running: Bool = false,
        remainingSeconds: Int? = nil,
        visibleSurfaces: [TimerVisibilitySurface] = [.presenter],
        outputEnabled: Bool = false
    ) {
        self.mode = mode
        self.durationSeconds = durationSeconds
        self.endTime = endTime
        self.startedAt = startedAt
        self.running = running
        self.remainingSeconds = remainingSeconds
        self.visibleSurfaces = visibleSurfaces
        self.outputEnabled = outputEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        remainingSeconds = try container.decodeIfPresent(Int.self, forKey: .remainingSeconds)
        visibleSurfaces = try container.decodeIfPresent([TimerVisibilitySurface].self, forKey: .visibleSurfaces) ?? [.presenter]
        outputEnabled = try container.decodeIfPresent(Bool.self, forKey: .outputEnabled) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encode(running, forKey: .running)
        try container.encodeIfPresent(remainingSeconds, forKey: .remainingSeconds)
        try container.encode(visibleSurfaces, forKey: .visibleSurfaces)
        try container.encode(outputEnabled, forKey: .outputEnabled)
    }
}

public enum TimerRunState: String, Codable, Sendable, Equatable {
    case stopped
    case running
    case paused
}

public struct TimerRuntimeSnapshot: Codable, Sendable, Equatable {
    public let configuredState: SimpleTimerState?
    public let runState: TimerRunState
    public let remainingSeconds: Int
    public let outputEnabled: Bool
    public let senderReady: Bool
    public let senderConnectionCount: Int
    public let displayText: String
    public let lastTickAt: Date?
    public let lastRenderedAt: Date?

    public init(
        configuredState: SimpleTimerState? = nil,
        runState: TimerRunState = .stopped,
        remainingSeconds: Int = 0,
        outputEnabled: Bool = false,
        senderReady: Bool = false,
        senderConnectionCount: Int = 0,
        displayText: String = "00:00",
        lastTickAt: Date? = nil,
        lastRenderedAt: Date? = nil
    ) {
        self.configuredState = configuredState
        self.runState = runState
        self.remainingSeconds = remainingSeconds
        self.outputEnabled = outputEnabled
        self.senderReady = senderReady
        self.senderConnectionCount = senderConnectionCount
        self.displayText = displayText
        self.lastTickAt = lastTickAt
        self.lastRenderedAt = lastRenderedAt
    }
}
