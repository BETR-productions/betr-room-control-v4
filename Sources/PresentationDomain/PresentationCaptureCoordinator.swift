// PresentationCaptureCoordinator — NSWorkspace event-driven capture lifecycle.
// Wires PresentationController + SlideShowProducer + PresenterViewProducer.
// Pure event-driven — no polling. Capture starts only after verified slideshow.
// Task 65: didActivateApplicationNotification triggers capture start.

import AppKit
import Foundation

/// Coordinates presentation capture lifecycle across PresentationController,
/// SlideShowProducer, and PresenterViewProducer. Event-driven via NSWorkspace.
public actor PresentationCaptureCoordinator {
    private let controller: PresentationController
    private let slideshowProducer: SlideShowProducer
    private let presenterProducer: PresenterViewProducer
    private var isCapturing = false

    public init(
        controller: PresentationController,
        slideshowProducer: SlideShowProducer,
        presenterProducer: PresenterViewProducer
    ) {
        self.controller = controller
        self.slideshowProducer = slideshowProducer
        self.presenterProducer = presenterProducer
    }

    /// Wire all callbacks and start workspace monitoring.
    /// Call once at app startup.
    public func start() async {
        // Wire controller phase changes → capture start/stop
        await controller.setOnSessionPhaseChanged { [weak self] phase, state in
            Task { await self?.handlePhaseChange(phase, state: state) }
        }

        // Wire controller app state changes → producer start/stop
        await controller.setOnAppStateChanged { [weak self] kind, isActive in
            Task { await self?.handleAppStateChange(kind, isActive: isActive) }
        }

        // Wire slideshow producer window ID → presenter producer exclusion
        await slideshowProducer.setOnAvailabilityChanged { [weak self] available in
            Task {
                guard let self = self else { return }
                if available {
                    let windowID = await self.slideshowProducer.currentWindowID()
                    await self.presenterProducer.setSlideshowWindowID(windowID)
                } else {
                    await self.presenterProducer.setSlideshowWindowID(nil)
                }
            }
        }

        // Start workspace monitoring (Task 65: event-driven)
        await controller.startMonitoring()
    }

    /// Tear down all monitoring and capture.
    public func stop() async {
        await controller.stopMonitoring()
        await slideshowProducer.stopMonitoring()
        await presenterProducer.stopMonitoring()
        isCapturing = false
    }

    // MARK: - Event Handlers

    /// Handle session phase transitions from PresentationController.
    private func handlePhaseChange(_ phase: PresentationSessionPhase, state: PresentationState) async {
        switch phase {
        case .publishState:
            // Slideshow verified — start capture
            guard let kind = state.appKind else { return }
            await startCapture(for: kind)

        case .metadataReady:
            // Editing mode or slideshow stopped — stop capture
            await stopCapture()

        case .closed:
            // Session ended — stop capture
            await stopCapture()

        case .openOrLocate, .startOrNavigate, .verifyMode:
            // Intermediate states — no capture action
            break
        }
    }

    /// Handle app activation/termination from NSWorkspace.
    /// Task 65: didActivateApplicationNotification triggers capture detection.
    private func handleAppStateChange(_ kind: PresentationAppKind, isActive: Bool) async {
        if isActive {
            // App activated — check if slideshow is already running
            await detectAndStartCapture(for: kind)
        } else {
            // App terminated — stop capture
            await stopCapture()
        }
    }

    /// Detect if a slideshow is already running and start capture if so.
    /// Called on app activation to handle the case where a slideshow was started
    /// before Room Control launched or after Room Control was backgrounded.
    private func detectAndStartCapture(for kind: PresentationAppKind) async {
        let state = await controller.getState()
        if state.mode == .slideshow {
            await startCapture(for: kind)
        }
    }

    // MARK: - Capture Lifecycle

    private func startCapture(for kind: PresentationAppKind) async {
        guard !isCapturing else { return }
        isCapturing = true
        await slideshowProducer.startMonitoring(for: kind)
        await presenterProducer.startMonitoring(for: kind)
    }

    private func stopCapture() async {
        guard isCapturing else { return }
        isCapturing = false
        await slideshowProducer.stopMonitoring()
        await presenterProducer.stopMonitoring()
    }
}
