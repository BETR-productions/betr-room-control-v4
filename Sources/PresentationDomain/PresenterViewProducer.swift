// PresenterViewProducer — SCStream capture for the presenter view window.
// Static slot: "BËTR Presenter View". 1920×1080, 29.97fps, BGRA.
// Window detection via bundleIdentifier + title patterns.
// Requires slideshow window ID from SlideShowProducer to exclude.

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import RoomControlXPCContracts
import ScreenCaptureKit

// MARK: - Window Title Patterns

private enum PresenterViewPatterns {
    /// PowerPoint presenter view window title patterns.
    /// PowerPoint uses "Presenter View" in the window title.
    static let powerPointTitlePatterns = [
        "Presenter View",
        "presenter view",
        "Referentenansicht",  // German
        "Mode Présentateur",  // French
    ]

    /// Keynote presenter view: any non-fullscreen window during slideshow.
    /// Keynote doesn't have a distinct title pattern — identified by exclusion.
}

/// Captures the presenter view window (separate from the slideshow window) via ScreenCaptureKit.
public actor PresenterViewProducer {
    public static let slotName = "BËTR Presenter View"

    private let outputWidth = 1920
    private let outputHeight = 1080
    private let frameRateNumerator = 1001
    private let frameRateDenominator = 30000

    private var stream: SCStream?
    private var streamDelegate: PresenterStreamDelegate?
    private var trackedWindowID: CGWindowID?
    private var slideshowWindowID: CGWindowID?
    private var pollTask: Task<Void, Never>?
    private var appKind: PresentationAppKind?
    private var capturing = false

    /// Called when the presenter view capture becomes available or unavailable.
    public var onAvailabilityChanged: (@Sendable (Bool) -> Void)?

    /// Called with each captured video frame (BGRA pixel buffer + timestamp).
    public var onFrame: (@Sendable (CVPixelBuffer, Int64) -> Void)?

    /// Called when capture starts to signal warm-pool auto-warm.
    public var onWarmRequested: (@Sendable () -> Void)?

    /// Called when capture stops to signal warm-pool auto-cool.
    public var onCoolRequested: (@Sendable () -> Void)?

    public init() {}

    // MARK: - Monitoring

    /// Start monitoring for presenter view windows from the given presentation app.
    public func startMonitoring(for kind: PresentationAppKind) {
        stopMonitoring()
        appKind = kind
        pollTask = Task { [weak self] in
            while let self = self, !Task.isCancelled {
                await self.pollForWindow()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // DOCUMENTED EXCEPTION: window detection retry, not media path
            }
        }
    }

    /// Update the tracked slideshow window ID so presenter detection can exclude it.
    public func setSlideshowWindowID(_ windowID: CGWindowID?) {
        slideshowWindowID = windowID
    }

    /// Update the tracked app kind. Restarts monitoring if changed.
    public func updateApp(_ kind: PresentationAppKind?) {
        guard appKind != kind else { return }
        if let kind {
            startMonitoring(for: kind)
        } else {
            stopMonitoring()
        }
    }

    /// Stop monitoring and tear down any active stream.
    public func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        tearDownStream()
        appKind = nil
        trackedWindowID = nil
        slideshowWindowID = nil
    }

    /// Whether capture is actively running.
    public func isCapturing() -> Bool {
        capturing
    }

    /// Producer descriptor for registration with the agent.
    public var descriptor: LocalProducerDescriptor {
        LocalProducerDescriptor(
            name: Self.slotName,
            producerProtocol: .ioSurface,
            hasVideo: true,
            hasAudio: false
        )
    }

    // MARK: - Private: Window Detection

    private func pollForWindow() async {
        guard let appKind else { return }

        do {
            let content = try await SCShareableContent.current
            let bundleIDs = appKind.bundleIdentifiers

            // Filter to windows belonging to the tracked presentation app
            let appWindows = content.windows.filter { window in
                guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
                return bundleIDs.contains(bundleID)
                    && window.frame.width > 100 && window.frame.height > 100
            }

            guard appWindows.count > 1 else {
                // Need at least 2 windows (slideshow + presenter view)
                if trackedWindowID != nil {
                    tearDownStream()
                    trackedWindowID = nil
                }
                return
            }

            // Identify the slideshow window to exclude
            let displayFrames = content.displays.map {
                CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
            }
            let fullscreenWindow = appWindows.first { window in
                let windowSize = CGSize(width: window.frame.width, height: window.frame.height)
                return displayFrames.contains { displaySize in
                    let wTol = max(displaySize.width * 0.01, 4)
                    let hTol = max(displaySize.height * 0.01, 4)
                    return abs(windowSize.width - displaySize.width) < wTol
                        && abs(windowSize.height - displaySize.height) < hTol
                }
            }

            let sortedByArea = appWindows.sorted { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) > (rhs.frame.width * rhs.frame.height)
            }
            let slideshowWindow = fullscreenWindow ?? sortedByArea.first
            let ssWindowID = slideshowWindowID ?? slideshowWindow?.windowID

            // Find presenter view window using title patterns + exclusion
            let presenterWindow = findPresenterWindow(
                appWindows: appWindows,
                excludeWindowID: ssWindowID,
                appKind: appKind
            )

            if let presenterWindow {
                if presenterWindow.windowID != trackedWindowID {
                    await tearDownStreamAsync()
                    trackedWindowID = presenterWindow.windowID
                    await startStream(for: presenterWindow)
                }
            } else if trackedWindowID != nil {
                tearDownStream()
                trackedWindowID = nil
            }
        } catch {
            // SCShareableContent query failed — silently retry next poll
        }
    }

    /// Find the presenter view window using title pattern matching + size exclusion.
    private func findPresenterWindow(
        appWindows: [SCWindow],
        excludeWindowID: CGWindowID?,
        appKind: PresentationAppKind
    ) -> SCWindow? {
        let candidates = appWindows.filter { $0.windowID != excludeWindowID }
        guard !candidates.isEmpty else { return nil }

        switch appKind {
        case .powerPoint:
            // PowerPoint: match by title pattern first
            let titleMatch = candidates.first { window in
                guard let title = window.title else { return false }
                return PresenterViewPatterns.powerPointTitlePatterns.contains { pattern in
                    title.localizedCaseInsensitiveContains(pattern)
                }
            }
            // Fall back to largest non-slideshow window
            return titleMatch ?? candidates.sorted { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) > (rhs.frame.width * rhs.frame.height)
            }.first

        case .keynote:
            // Keynote: no distinct title pattern — largest non-slideshow window
            return candidates.sorted { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) > (rhs.frame.width * rhs.frame.height)
            }.first
        }
    }

    // MARK: - Private: Stream Lifecycle

    private func startStream(for window: SCWindow) async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = outputWidth
        config.height = outputHeight
        config.minimumFrameInterval = CMTime(
            value: CMTimeValue(frameRateNumerator),
            timescale: CMTimeScale(frameRateDenominator)
        )
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.showsCursor = false
        config.capturesAudio = false

        let delegate = PresenterStreamDelegate()
        let onFrameCallback = onFrame
        delegate.onSampleBuffer = { pixelBuffer, timestampNs in
            onFrameCallback?(pixelBuffer, timestampNs)
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try newStream.addStreamOutput(
                delegate, type: .screen,
                sampleHandlerQueue: .global(qos: .userInitiated)
            )
            try await newStream.startCapture()
            stream = newStream
            streamDelegate = delegate
            capturing = true
            onAvailabilityChanged?(true)
            onWarmRequested?()
        } catch {
            capturing = false
            onAvailabilityChanged?(false)
        }
    }

    private func tearDownStreamAsync() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        let wasCapturing = capturing
        stream = nil
        streamDelegate = nil
        capturing = false
        if wasCapturing {
            onAvailabilityChanged?(false)
            onCoolRequested?()
        }
    }

    private func tearDownStream() {
        if let s = stream {
            Task { try? await s.stopCapture() }
        }
        let wasCapturing = capturing
        stream = nil
        streamDelegate = nil
        capturing = false
        if wasCapturing {
            onAvailabilityChanged?(false)
            onCoolRequested?()
        }
    }
}

// MARK: - Stream Output Delegate

private final class PresenterStreamDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    var onSampleBuffer: ((_ pixelBuffer: CVPixelBuffer, _ timestampNs: Int64) -> Void)?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let timestampNs = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        onSampleBuffer?(pixelBuffer, timestampNs)
    }
}
