// PresentationDomain — Scripting Bridge automation, ScreenCaptureKit capture.

import Foundation

/// Presentation application type for automation.
public enum PresentationAppType: String, Sendable {
    case powerPoint = "Microsoft PowerPoint"
    case keynote = "Keynote"
}

/// Session lifecycle states per the presentation automation spec.
public enum PresentationSessionPhase: String, Sendable, Equatable {
    case closed
    case openOrLocate
    case metadataReady
    case startOrNavigate
    case verifyMode
    case publishState
}
