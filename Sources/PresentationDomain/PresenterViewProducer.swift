// PresenterViewProducer — SCStream capture for the presenter view window.
// Static slot: "BËTR Presenter View". Auto-warm/cool based on window visibility.

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import RoomControlXPCContracts
import ScreenCaptureKit

/// Captures the presenter view window (separate from the slideshow window) via ScreenCaptureKit.
public actor PresenterViewProducer {
    public static let slotName = "BËTR Presenter View"

    private let outputWidth = 1920
    private let outputHeight = 1080
    private let frameRateNumerator = 1001
    private let frameRateDenominator = 30000

    private var stream: SCStream?
    private var streamDelegate: PresenterStreamOutputDelegate?
    private var trackedWindowID: CGWindowID?
    private var slideshowWindowID: CGWindowID?
    private var pollTask: Task<Void, Never>?
    private var appKind: PresentationAppKind?

    /// Called when the presenter view capture becomes available or unavailable.
    public var onAvailabilityChanged: (@Sendable (Bool) -> Void)?

    /// Called with each captured video frame (BGRA pixel buffer).
    public var onFrame: (@Sendable (CVPixelBuffer, Int64) -> Void)?

    public init() {}

    // MARK: - Monitoring

    /// Start monitoring for presenter view windows from the given presentation app.
    public func startMonitoring(for kind: PresentationAppKind) {
        stopMonitoring()
        appKind = kind
        pollTask = Task { [weak self] in
            while let self = self, !Task.isCancelled {
                await self.pollForWindow()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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

    /// Producer descriptor for registration with the agent.
    public var descriptor: LocalProducerDescriptor {
        LocalProducerDescriptor(
            name: Self.slotName,
            producerProtocol: .ioSurface,
            hasVideo: true,
            hasAudio: false
        )
    }

    // MARK: - Private

    private func pollForWindow() async {
        guard let appKind else { return }

        do {
            let content = try await SCShareableContent.current
            let bundleIDs = appKind.bundleIdentifiers

            let appWindows = content.windows.filter { window in
                guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
                return bundleIDs.contains(bundleID)
            }

            guard appWindows.count > 1 else {
                // Need at least 2 windows (slideshow + presenter view)
                if trackedWindowID != nil {
                    tearDownStream()
                    trackedWindowID = nil
                }
                return
            }

            // Sort by area descending — largest is likely the slideshow
            let sortedByArea = appWindows.sorted { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) > (rhs.frame.width * rhs.frame.height)
            }

            // Find the fullscreen window (slideshow)
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

            let slideshowWindow = fullscreenWindow ?? sortedByArea.first
            let ssWindowID = slideshowWindowID ?? slideshowWindow?.windowID

            // Presenter view is the first non-slideshow window
            let presenterWindow = sortedByArea.first { window in
                window.windowID != ssWindowID
            }

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

    private func startStream(for window: SCWindow) async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = outputWidth
        config.height = outputHeight
        config.minimumFrameInterval = CMTime(value: CMTimeValue(frameRateNumerator), timescale: CMTimeScale(frameRateDenominator))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.showsCursor = false

        let delegate = PresenterStreamOutputDelegate()
        let onFrameCallback = onFrame
        delegate.onSampleBuffer = { pixelBuffer, timestampNs in
            onFrameCallback?(pixelBuffer, timestampNs)
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try newStream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            stream = newStream
            streamDelegate = delegate
            onAvailabilityChanged?(true)
        } catch {
            onAvailabilityChanged?(false)
        }
    }

    private func tearDownStreamAsync() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        streamDelegate = nil
        onAvailabilityChanged?(false)
    }

    private func tearDownStream() {
        if let s = stream {
            Task { try? await s.stopCapture() }
        }
        stream = nil
        streamDelegate = nil
        onAvailabilityChanged?(false)
    }
}

// MARK: - Stream Output Delegate

private final class PresenterStreamOutputDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    var onSampleBuffer: ((_ pixelBuffer: CVPixelBuffer, _ timestampNs: Int64) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let timestampNs = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        onSampleBuffer?(pixelBuffer, timestampNs)
    }
}
