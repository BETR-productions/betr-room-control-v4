// TimerDomain — models and types for timer producer.

import Foundation

// MARK: - Timer Mode

/// Timer operating mode per build doc 5.3.
public enum TimerMode: Codable, Sendable, Equatable {
    case duration(seconds: Int)
    case endTime(target: Date)

    private enum CodingKeys: String, CodingKey {
        case type, seconds, target
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .duration(let seconds):
            try container.encode("duration", forKey: .type)
            try container.encode(seconds, forKey: .seconds)
        case .endTime(let target):
            try container.encode("endTime", forKey: .type)
            try container.encode(target, forKey: .target)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "duration":
            let seconds = try container.decode(Int.self, forKey: .seconds)
            self = .duration(seconds: seconds)
        case "endTime":
            let target = try container.decode(Date.self, forKey: .target)
            self = .endTime(target: target)
        default:
            self = .duration(seconds: 600)
        }
    }
}

// MARK: - Timer Run State

public enum TimerRunState: String, Codable, Sendable, Equatable {
    case stopped
    case running
    case paused
}

// MARK: - Timer Snapshot

/// Observable snapshot of timer runtime state.
public struct TimerSnapshot: Codable, Sendable, Equatable {
    public let mode: TimerMode
    public let runState: TimerRunState
    public let remainingSeconds: Int
    public let displayText: String
    public let producerID: String?
    public let capturedAt: Date

    public init(
        mode: TimerMode = .duration(seconds: 600),
        runState: TimerRunState = .stopped,
        remainingSeconds: Int = 600,
        displayText: String = "10:00",
        producerID: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.mode = mode
        self.runState = runState
        self.remainingSeconds = remainingSeconds
        self.displayText = displayText
        self.producerID = producerID
        self.capturedAt = capturedAt
    }
}

// MARK: - Constants

public enum TimerConstants {
    public static let producerName = "BËTR Timer"
    public static let defaultWidth = 1920
    public static let defaultHeight = 1080
    public static let defaultFrameRateNumerator = 30_000
    public static let defaultFrameRateDenominator = 1_001
    public static let defaultDurationSeconds = 600
}
