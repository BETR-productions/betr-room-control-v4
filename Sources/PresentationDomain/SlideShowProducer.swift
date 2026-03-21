// SlideShowProducer — SCStream capture for the slideshow window.
// Static slot: "BËTR Slideshow". Auto-warm/cool based on window visibility.

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import RoomControlXPCContracts
import ScreenCaptureKit

/// Captures the running presentation's full-screen slideshow window via ScreenCaptureKit.
public actor SlideShowProducer {
    public static let slotName = "BËTR Slideshow"

    private let outputWidth = 1920
    private let outputHeight = 1080
    private let frameRateNumerator = 1001
    private let frameRateDenominator = 30000

    private var stream: SCStream?
    private var streamDelegate: StreamOutputDelegate?
    private var trackedWindowID: CGWindowID?
    private var pollTask: Task<Void, Never>?
    private var appKind: PresentationAppKind?
    private var registered = false

    /// Called when the slideshow capture becomes available or unavailable.
    public var onAvailabilityChanged: (@Sendable (Bool) -> Void)?

    /// Called with each captured video frame (BGRA pixel buffer).
    public var onFrame: (@Sendable (CVPixelBuffer, Int64) -> Void)?

    public init() {}

    // MARK: - Monitoring

    /// Start monitoring for slideshow windows from the given presentation app.
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

            guard !appWindows.isEmpty else {
                if trackedWindowID != nil {
                    tearDownStream()
                    trackedWindowID = nil
                }
                return
            }

            // Find the fullscreen slideshow window (matches a display size)
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

            // Prefer fullscreen, fall back to largest window
            let sortedByArea = appWindows.sorted { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) > (rhs.frame.width * rhs.frame.height)
            }
            let slideshowWindow = fullscreenWindow ?? sortedByArea.first

            if let window = slideshowWindow {
                if window.windowID != trackedWindowID {
                    await tearDownStreamAsync()
                    trackedWindowID = window.windowID
                    await startStream(for: window)
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

        let delegate = StreamOutputDelegate()
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

private final class StreamOutputDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
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
