import Foundation

public struct PresentationXPCState: Sendable, Equatable {
    public var app: String
    public var filePath: String
    public var isConnected: Bool

    public init(app: String = "PowerPoint", filePath: String = "", isConnected: Bool = false) {
        self.app = app
        self.filePath = filePath
        self.isConnected = isConnected
    }
}

public enum PresentationSessionPhase: String, Sendable, Equatable {
    case closed
    case opening
    case live
    case failed
}

public struct PresentationControlHealthSnapshot: Sendable, Equatable {
    public var state: PresentationXPCState
    public var sessionPhase: PresentationSessionPhase

    public init(
        state: PresentationXPCState = PresentationXPCState(),
        sessionPhase: PresentationSessionPhase = .closed
    ) {
        self.state = state
        self.sessionPhase = sessionPhase
    }
}
