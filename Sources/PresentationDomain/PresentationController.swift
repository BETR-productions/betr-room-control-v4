// PresentationController — async Swift actor wrapping PresentationBridgeController.
// Lifecycle: open_or_locate → metadata_ready → start_or_navigate → verify_mode → publish_state.
// Spec: PRESENTATION_AUTOMATION.md — all invariants enforced here.

import AppKit
import BETRCoreObjC
import Foundation

// MARK: - Models

/// Presentation application kind.
public enum PresentationAppKind: String, Codable, Sendable, Equatable, CaseIterable {
    case keynote
    case powerPoint = "powerpoint"

    public var displayName: String {
        switch self {
        case .keynote: return "Keynote"
        case .powerPoint: return "PowerPoint"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .keynote: return ["com.apple.iWork.Keynote", "com.apple.Keynote"]
        case .powerPoint: return ["com.microsoft.PowerPoint", "com.microsoft.Powerpoint"]
        }
    }
}

/// Current presentation mode.
public enum SlideshowMode: String, Codable, Sendable, Equatable {
    case closed
    case editing
    case slideshow
}

/// Snapshot of presentation state.
public struct PresentationState: Sendable, Equatable {
    public let appKind: PresentationAppKind?
    public let mode: SlideshowMode
    public let filePath: String
    public let currentSlide: Int
    public let totalSlides: Int
    public let hasPresenterView: Bool
    public let slideShowBounds: CGRect
    public let sessionPhase: PresentationSessionPhase
    public let probeReasonCode: String?

    public static let closed = PresentationState(
        appKind: nil, mode: .closed, filePath: "",
        currentSlide: 0, totalSlides: 0,
        hasPresenterView: false, slideShowBounds: .zero,
        sessionPhase: .closed, probeReasonCode: nil
    )
}

// MARK: - Constants

private enum PresentationConstants {
    /// Grace period for app launch before first Scripting Bridge query.
    static let appLaunchGraceMs: UInt64 = 800
    /// Budget for metadata readiness (totalSlides > 0).
    static let metadataBudgetMs: UInt64 = 1200
    /// Poll interval during metadata wait.
    static let metadataPollMs: UInt64 = 100
    /// Budget for slideshow verification after start.
    static let verifyBudgetMs: UInt64 = 2000
    /// Poll interval during slideshow verification.
    static let verifyPollMs: UInt64 = 150
}

// MARK: - PresentationController

/// Async Swift API for controlling PowerPoint and Keynote via Scripting Bridge.
/// All bridge calls are dispatched off the main thread.
///
/// Enforces the documented presentation automation invariants:
/// - Open or locate deck by exact full path
/// - Wait for presentation metadata before slideshow start
/// - Use slide show settings + run slide show (PowerPoint)
/// - Do not require slideshow window lookup in same call that starts slideshow
/// - Verify slideshow mode after start, then signal capture readiness
/// - Start capture only after slideshow mode is verified
public actor PresentationController {
    private let bridge = PresentationBridgeController()
    private var activeAppKind: PresentationAppKind?
    private var activeFilePath: String = ""
    private var sessionPhase: PresentationSessionPhase = .closed
    private var lastProbeReasonCode: String?

    private var terminationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    /// Callback when a presentation app activates or terminates.
    /// Parameters: (appKind, isActive).
    private var onAppStateChanged: (@Sendable (PresentationAppKind, Bool) -> Void)?

    /// Callback when session phase changes. Used to coordinate capture start/stop.
    private var onSessionPhaseChanged: (@Sendable (PresentationSessionPhase, PresentationState) -> Void)?

    public init() {}

    /// Set the app state change callback (actor-safe setter).
    public func setOnAppStateChanged(_ handler: (@Sendable (PresentationAppKind, Bool) -> Void)?) {
        onAppStateChanged = handler
    }

    /// Set the session phase change callback (actor-safe setter).
    public func setOnSessionPhaseChanged(_ handler: (@Sendable (PresentationSessionPhase, PresentationState) -> Void)?) {
        onSessionPhaseChanged = handler
    }

    deinit {
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle (Task 65)

    /// Start observing workspace app activation/termination events.
    /// Pure event-driven — no polling.
    public func startMonitoring() {
        guard terminationObserver == nil else { return }
        let appCallback = onAppStateChanged
        let nc = NSWorkspace.shared.notificationCenter

        // Termination: clear session when tracked app quits
        terminationObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            let matchedKind = PresentationAppKind.allCases.first { $0.bundleIdentifiers.contains(bundleID) }
            if let kind = matchedKind {
                appCallback?(kind, false)
                Task { await self?.handleAppTerminated(kind) }
            }
        }

        // Activation: trigger capture start for PowerPoint/Keynote (Task 65)
        activationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            let matchedKind = PresentationAppKind.allCases.first { $0.bundleIdentifiers.contains(bundleID) }
            if let kind = matchedKind {
                appCallback?(kind, true)
                Task { await self?.handleAppActivated(kind) }
            }
        }
    }

    /// Stop observing workspace events.
    public func stopMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        if let observer = terminationObserver {
            nc.removeObserver(observer)
            terminationObserver = nil
        }
        if let observer = activationObserver {
            nc.removeObserver(observer)
            activationObserver = nil
        }
    }

    // MARK: - Open (Task 62)

    /// Open a presentation file. Detects app kind from file extension.
    /// Includes 800ms grace period for app launch and waits for metadata readiness.
    public func openPresentation(filePath: String, appKind: PresentationAppKind? = nil) async -> Bool {
        let canonicalPath = (filePath as NSString).standardizingPath
        let resolvedKind = appKind ?? detectAppKind(for: canonicalPath)
        guard let kind = resolvedKind else {
            lastProbeReasonCode = "unsupported_file_type"
            return false
        }

        sessionPhase = .openOrLocate
        let phaseCallback = onSessionPhaseChanged

        // Check if app is running; if not, grace period for launch
        let wasRunning = await isAppRunning(kind)

        let success: Bool = await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.openPowerPointFile(canonicalPath)
            case .keynote: return self.bridge.openKeynoteFile(canonicalPath)
            }
        }

        guard success else {
            lastProbeReasonCode = "open_failed"
            sessionPhase = .closed
            return false
        }

        activeAppKind = kind
        activeFilePath = canonicalPath

        if !wasRunning {
            try? await Task.sleep(nanoseconds: PresentationConstants.appLaunchGraceMs * 1_000_000) // DOCUMENTED EXCEPTION: 800ms grace period for app launch
        }

        // Wait for metadata readiness (totalSlides > 0)
        let metadataReady = await waitForMetadata(kind: kind)
        if metadataReady {
            sessionPhase = .metadataReady
            let state = await getState()
            phaseCallback?(.metadataReady, state)
        } else {
            lastProbeReasonCode = "metadata_timeout"
            // Still mark as open — editing mode without confirmed metadata
            sessionPhase = .metadataReady
        }

        return true
    }

    // MARK: - Slideshow Control (Task 62)

    /// Start slideshow from a given slide.
    /// Uses slide show settings + run slide show (PowerPoint invariant).
    /// Verifies slideshow mode after start before signaling capture readiness.
    public func startSlideshow(fromSlide: Int = 1, withPresenter: Bool = true) async -> Bool {
        guard let kind = activeAppKind else { return false }

        sessionPhase = .startOrNavigate
        let phaseCallback = onSessionPhaseChanged

        let started: Bool = await withBridge {
            switch kind {
            case .powerPoint:
                return self.bridge.showPowerPointSlideShow(fromSlide: Int(fromSlide), withPresenter: withPresenter)
            case .keynote:
                return self.bridge.showKeynoteSlideShow(fromSlide: Int(fromSlide))
            }
        }

        guard started else {
            lastProbeReasonCode = "slideshow_start_failed"
            sessionPhase = .metadataReady
            return false
        }

        // INVARIANT: Do NOT require slideshow window lookup in same call that starts slideshow.
        // Verify slideshow mode via separate state query.
        sessionPhase = .verifyMode

        let verified = await waitForVerifiedSlideshow(kind: kind)
        if verified {
            sessionPhase = .publishState
            lastProbeReasonCode = nil
            let state = await getState()
            phaseCallback?(.publishState, state)
        } else {
            lastProbeReasonCode = "slideshow_verify_timeout"
            // Stay in verifyMode — capture should NOT start
            sessionPhase = .verifyMode
        }

        return verified
    }

    /// Stop the running slideshow.
    public func stopSlideshow() async -> Bool {
        guard let kind = activeAppKind else { return false }
        let success: Bool = await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.exitPowerPointSlideShow()
            case .keynote: return self.bridge.stopKeynoteSlideShow()
            }
        }
        if success {
            sessionPhase = .metadataReady
            lastProbeReasonCode = nil
            let phaseCallback = onSessionPhaseChanged
            let state = await getState()
            phaseCallback?(.metadataReady, state)
        }
        return success
    }

    /// Close the presentation and optionally quit the app.
    public func closePresentation(save: Bool = false) async -> Bool {
        guard let kind = activeAppKind else { return true }
        let success: Bool = await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.closePowerPoint(save)
            case .keynote: return self.bridge.closeKeynote(save)
            }
        }
        if success {
            clearSession()
        }
        return success
    }

    // MARK: - Navigation

    /// Go to a specific slide number.
    public func goToSlide(_ number: Int) async -> Bool {
        guard number > 0, let kind = activeAppKind else { return false }
        return await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.gotoPowerPointSlide(Int(number))
            case .keynote: return self.bridge.gotoKeynoteSlide(Int(number))
            }
        }
    }

    /// Advance to next slide.
    public func nextSlide() async -> Bool {
        guard let kind = activeAppKind else { return false }
        return await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.gotoPowerPointNextSlide()
            case .keynote: return self.bridge.gotoKeynoteNextSlide()
            }
        }
    }

    /// Go to previous slide.
    public func previousSlide() async -> Bool {
        guard let kind = activeAppKind else { return false }
        return await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.gotoPowerPointPreviousSlide()
            case .keynote: return self.bridge.gotoKeynotePreviousSlide()
            }
        }
    }

    // MARK: - State

    /// Get current presentation state snapshot.
    public func getState() async -> PresentationState {
        guard let kind = activeAppKind else { return .closed }
        let cachedFilePath = activeFilePath
        let phase = sessionPhase
        let reasonCode = lastProbeReasonCode

        return await withBridge {
            let running: Bool
            let slideshowActive: Bool
            let currentSlide: Int
            let totalSlides: Int
            let filePath: String
            let hasPresenter: Bool
            let bounds: CGRect

            switch kind {
            case .powerPoint:
                running = self.bridge.isPowerPointRunning()
                slideshowActive = self.bridge.isPowerPointSlideShowActive()
                currentSlide = Int(self.bridge.powerPointCurrentSlide())
                totalSlides = Int(self.bridge.powerPointSlideCount())
                filePath = self.bridge.activePowerPointPresentationPath() ?? cachedFilePath
                hasPresenter = self.bridge.hasPowerPointPresenterView()
                let rect = self.bridge.powerPointSlideShowWindowBounds()
                bounds = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
            case .keynote:
                running = self.bridge.isKeynoteRunning()
                slideshowActive = self.bridge.isKeynoteSlideShowActive()
                currentSlide = Int(self.bridge.keynoteCurrentSlide())
                totalSlides = Int(self.bridge.keynoteSlideCount())
                filePath = self.bridge.activeKeynotePresentationPath() ?? cachedFilePath
                hasPresenter = false
                bounds = .zero
            }

            guard running else {
                return PresentationState(
                    appKind: kind, mode: .closed, filePath: cachedFilePath,
                    currentSlide: 0, totalSlides: 0,
                    hasPresenterView: false, slideShowBounds: .zero,
                    sessionPhase: phase, probeReasonCode: "tracked_presentation_missing"
                )
            }

            let mode: SlideshowMode = slideshowActive ? .slideshow : (totalSlides > 0 ? .editing : .closed)

            return PresentationState(
                appKind: kind,
                mode: mode,
                filePath: filePath,
                currentSlide: currentSlide,
                totalSlides: totalSlides,
                hasPresenterView: hasPresenter,
                slideShowBounds: bounds,
                sessionPhase: phase,
                probeReasonCode: reasonCode
            )
        }
    }

    /// Get slide notes for a specific slide (deck-scoped).
    public func getSlideNotes(slideNumber: Int) async -> String? {
        guard slideNumber > 0, let kind = activeAppKind else { return nil }
        return await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.powerPointSlideNotes(Int(slideNumber))
            case .keynote: return self.bridge.keynoteSlideNotes(Int(slideNumber))
            }
        }
    }

    /// Check if a presentation app is running.
    public func isAppRunning(_ kind: PresentationAppKind) async -> Bool {
        await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.isPowerPointRunning()
            case .keynote: return self.bridge.isKeynoteRunning()
            }
        }
    }

    /// Current session phase (read-only accessor).
    public func currentPhase() -> PresentationSessionPhase {
        sessionPhase
    }

    /// Active app kind (read-only accessor).
    public func currentAppKind() -> PresentationAppKind? {
        activeAppKind
    }

    // MARK: - Private: File Detection

    private func detectAppKind(for filePath: String) -> PresentationAppKind? {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "key":
            return .keynote
        case "ppt", "pptx", "pps", "pptm", "ppsm":
            return .powerPoint
        default:
            return nil
        }
    }

    // MARK: - Private: Session Management

    private func clearSession() {
        activeAppKind = nil
        activeFilePath = ""
        sessionPhase = .closed
        lastProbeReasonCode = nil
        let phaseCallback = onSessionPhaseChanged
        phaseCallback?(.closed, .closed)
    }

    private func handleAppTerminated(_ kind: PresentationAppKind) {
        if activeAppKind == kind {
            clearSession()
        }
    }

    /// Handle app activation — used by Task 65 NSWorkspace auto-start.
    private func handleAppActivated(_ kind: PresentationAppKind) {
        // If no active session, record the activated app kind so producers can detect windows.
        // The actual capture start is coordinated via onAppStateChanged callback.
        if activeAppKind == nil {
            activeAppKind = kind
        }
    }

    // MARK: - Private: Metadata Wait

    /// Wait for metadata readiness (totalSlides > 0) within budget.
    private func waitForMetadata(kind: PresentationAppKind) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + PresentationConstants.metadataBudgetMs * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let count: Int = await withBridge {
                switch kind {
                case .powerPoint: return Int(self.bridge.powerPointSlideCount())
                case .keynote: return Int(self.bridge.keynoteSlideCount())
                }
            }
            if count > 0 { return true }
            try? await Task.sleep(nanoseconds: PresentationConstants.metadataPollMs * 1_000_000) // DOCUMENTED EXCEPTION: metadata wait budget, not media path
        }
        return false
    }

    // MARK: - Private: Slideshow Verification

    /// Wait for slideshow mode to be confirmed after start command.
    /// INVARIANT: Separate verification pass — do not require window lookup in same call.
    private func waitForVerifiedSlideshow(kind: PresentationAppKind) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + PresentationConstants.verifyBudgetMs * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let active: Bool = await withBridge {
                switch kind {
                case .powerPoint: return self.bridge.isPowerPointSlideShowActive()
                case .keynote: return self.bridge.isKeynoteSlideShowActive()
                }
            }
            if active { return true }
            try? await Task.sleep(nanoseconds: PresentationConstants.verifyPollMs * 1_000_000) // DOCUMENTED EXCEPTION: slideshow verification poll, not media path
        }
        return false
    }

    // MARK: - Private: Bridge Dispatch

    /// Execute a bridge call off the main actor to avoid blocking.
    private func withBridge<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = body()
                continuation.resume(returning: result)
            }
        }
    }
}
