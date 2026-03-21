// PresentationController — async Swift actor wrapping PresentationBridgeController.
// Lifecycle: open → slideshow → navigate → exit.

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

    var bundleIdentifiers: [String] {
        switch self {
        case .keynote: return ["com.apple.iWork.Keynote"]
        case .powerPoint: return ["com.microsoft.PowerPoint", "com.microsoft.Powerpoint"]
        }
    }
}

/// Current presentation mode.
public enum PresentationMode: String, Codable, Sendable, Equatable {
    case closed
    case editing
    case slideshow
}

/// Snapshot of presentation state.
public struct PresentationState: Sendable, Equatable {
    public let appKind: PresentationAppKind?
    public let mode: PresentationMode
    public let filePath: String
    public let currentSlide: Int
    public let totalSlides: Int
    public let hasPresenterView: Bool
    public let slideShowBounds: CGRect

    public static let closed = PresentationState(
        appKind: nil, mode: .closed, filePath: "",
        currentSlide: 0, totalSlides: 0,
        hasPresenterView: false, slideShowBounds: .zero
    )
}

// MARK: - PresentationController

/// Async Swift API for controlling PowerPoint and Keynote via Scripting Bridge.
/// All bridge calls are dispatched off the main thread.
public actor PresentationController {
    private let bridge = PresentationBridgeController()
    private var activeAppKind: PresentationAppKind?
    private var activeFilePath: String = ""
    private var workspaceObserver: NSObjectProtocol?

    /// Callback when a presentation app launches or terminates.
    public var onAppStateChanged: (@Sendable (PresentationAppKind, Bool) -> Void)?

    public init() {}

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Start observing workspace app launch/terminate events.
    public func startMonitoring() {
        guard workspaceObserver == nil else { return }
        let callback = onAppStateChanged
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            let matchedKind = PresentationAppKind.allCases.first { $0.bundleIdentifiers.contains(bundleID) }
            if let kind = matchedKind {
                callback?(kind, false)
                Task { await self?.handleAppTerminated(kind) }
            }
        }
    }

    /// Stop observing workspace events.
    public func stopMonitoring() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }

    // MARK: - Open

    /// Open a presentation file. Detects app kind from file extension.
    public func openPresentation(filePath: String, appKind: PresentationAppKind? = nil) async -> Bool {
        let resolvedKind = appKind ?? detectAppKind(for: filePath)
        guard let kind = resolvedKind else { return false }

        let success: Bool = await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.openPowerPointFile(filePath)
            case .keynote: return self.bridge.openKeynoteFile(filePath)
            }
        }

        if success {
            activeAppKind = kind
            activeFilePath = filePath
        }
        return success
    }

    // MARK: - Slideshow Control

    /// Start slideshow from a given slide.
    public func startSlideshow(fromSlide: Int = 1, withPresenter: Bool = true) async -> Bool {
        guard let kind = activeAppKind else { return false }
        return await withBridge {
            switch kind {
            case .powerPoint:
                return self.bridge.showPowerPointSlideShow(fromSlide: Int(fromSlide), withPresenter: withPresenter)
            case .keynote:
                return self.bridge.showKeynoteSlideShow(fromSlide: Int(fromSlide))
            }
        }
    }

    /// Stop the running slideshow.
    public func stopSlideshow() async -> Bool {
        guard let kind = activeAppKind else { return false }
        return await withBridge {
            switch kind {
            case .powerPoint: return self.bridge.exitPowerPointSlideShow()
            case .keynote: return self.bridge.stopKeynoteSlideShow()
            }
        }
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
                return PresentationState.closed
            }

            let mode: PresentationMode = slideshowActive ? .slideshow : (totalSlides > 0 ? .editing : .closed)

            return PresentationState(
                appKind: kind,
                mode: mode,
                filePath: filePath,
                currentSlide: currentSlide,
                totalSlides: totalSlides,
                hasPresenterView: hasPresenter,
                slideShowBounds: bounds
            )
        }
    }

    /// Get slide notes for a specific slide.
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

    // MARK: - Private

    private func detectAppKind(for filePath: String) -> PresentationAppKind? {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "key": return .keynote
        case "ppt", "pptx": return .powerPoint
        default: return nil
        }
    }

    private func clearSession() {
        activeAppKind = nil
        activeFilePath = ""
    }

    private func handleAppTerminated(_ kind: PresentationAppKind) {
        if activeAppKind == kind {
            clearSession()
        }
    }

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
