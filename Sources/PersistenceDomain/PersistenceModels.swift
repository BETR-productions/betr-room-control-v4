import ClipPlayerDomain
import Foundation
import RoomControlUIContracts

public struct MigrationReport: Sendable, Equatable {
    public var summary: String

    public init(summary: String = "Migration not run yet.") {
        self.summary = summary
    }
}

public struct RoomControlPersistedState: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case uiState
        case hostDraft
        case presentationDraft
        case clipPlayerDraft
        case timerDraft
    }

    public var uiState: RoomControlOperatorShellUIState
    public var hostDraft: HostWizardDraft
    public var presentationDraft: PresentationWorkspaceDraft
    public var clipPlayerDraft: ClipPlayerDraft
    public var timerDraft: TimerWorkspaceDraft

    public init(
        uiState: RoomControlOperatorShellUIState = RoomControlOperatorShellUIState(),
        hostDraft: HostWizardDraft = HostWizardDraft(),
        presentationDraft: PresentationWorkspaceDraft = PresentationWorkspaceDraft(),
        clipPlayerDraft: ClipPlayerDraft = .empty,
        timerDraft: TimerWorkspaceDraft = TimerWorkspaceDraft()
    ) {
        self.uiState = uiState
        self.hostDraft = hostDraft
        self.presentationDraft = presentationDraft
        self.clipPlayerDraft = clipPlayerDraft
        self.timerDraft = timerDraft
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uiState = try container.decodeIfPresent(RoomControlOperatorShellUIState.self, forKey: .uiState)
            ?? RoomControlOperatorShellUIState()
        hostDraft = try container.decodeIfPresent(HostWizardDraft.self, forKey: .hostDraft)
            ?? HostWizardDraft()
        presentationDraft = try container.decodeIfPresent(PresentationWorkspaceDraft.self, forKey: .presentationDraft)
            ?? PresentationWorkspaceDraft()
        clipPlayerDraft = try container.decodeIfPresent(ClipPlayerDraft.self, forKey: .clipPlayerDraft)
            ?? .empty
        timerDraft = try container.decodeIfPresent(TimerWorkspaceDraft.self, forKey: .timerDraft)
            ?? TimerWorkspaceDraft()
    }
}
