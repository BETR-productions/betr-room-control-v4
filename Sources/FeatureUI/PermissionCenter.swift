// PermissionCenter — checks screen recording, accessibility, and automation permissions.
// Task 142: Permission banners appear at top of shell when permissions are missing.
// Ported from v3 PermissionCenter.swift.

import AppKit
import ApplicationServices
import Foundation
import PresentationDomain

// MARK: - Automation Authorization

enum AutomationAuthorizationState: Equatable {
    case notRequired
    case granted
    case denied
}

struct AutomationPermissionSnapshot: Equatable {
    var statuses: [PresentationAppKind: AutomationAuthorizationState] = [:]

    func missingAppKinds(for requiredAppKinds: [PresentationAppKind]) -> [PresentationAppKind] {
        var seen = Set<PresentationAppKind>()
        return requiredAppKinds.filter { appKind in
            guard seen.insert(appKind).inserted else { return false }
            return statuses[appKind] == .denied
        }
    }

    func isGranted(for requiredAppKinds: [PresentationAppKind]) -> Bool {
        missingAppKinds(for: requiredAppKinds).isEmpty
    }
}

enum AutomationPermissionEvaluator {
    static func snapshot(
        installedBundleIDs: Set<String>,
        authorizationStatuses: [String: OSStatus]
    ) -> AutomationPermissionSnapshot {
        let statuses = Dictionary(uniqueKeysWithValues: PresentationAppKind.allCases.map { appKind in
            (appKind, authorizationState(for: appKind, installedBundleIDs: installedBundleIDs, authorizationStatuses: authorizationStatuses))
        })
        return AutomationPermissionSnapshot(statuses: statuses)
    }

    private static func authorizationState(
        for appKind: PresentationAppKind,
        installedBundleIDs: Set<String>,
        authorizationStatuses: [String: OSStatus]
    ) -> AutomationAuthorizationState {
        let installedAliases = appKind.bundleIdentifiers.filter { installedBundleIDs.contains($0) }
        guard !installedAliases.isEmpty else { return .notRequired }
        if installedAliases.contains(where: { authorizationStatuses[$0] == noErr }) {
            return .granted
        }
        return .denied
    }
}

// MARK: - Permission Center

@MainActor
public final class PermissionCenter: ObservableObject {
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var automationSnapshot = AutomationPermissionSnapshot()

    public init() {}

    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
        let installedBundleIDs = Set(
            PresentationAppKind.allCases
                .flatMap(\.bundleIdentifiers)
                .filter(isInstalledOrRunning(bundleId:))
        )
        let authorizationStatuses = Dictionary(uniqueKeysWithValues: installedBundleIDs.map { bundleID in
            (bundleID, automationStatus(bundleId: bundleID))
        })
        automationSnapshot = AutomationPermissionEvaluator.snapshot(
            installedBundleIDs: installedBundleIDs,
            authorizationStatuses: authorizationStatuses
        )
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    func missingAutomationAppKinds(for requiredAppKinds: [PresentationAppKind]) -> [PresentationAppKind] {
        automationSnapshot.missingAppKinds(for: requiredAppKinds)
    }

    private func automationStatus(bundleId: String) -> OSStatus {
        var addressDesc = AEDesc()
        defer { AEDisposeDesc(&addressDesc) }

        guard let data = bundleId.data(using: .utf8) else { return OSStatus(errAECoercionFail) }
        let createStatus = data.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &addressDesc)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        return AEDeterminePermissionToAutomateTarget(&addressDesc, typeWildCard, typeWildCard, false)
    }

    private func isInstalledOrRunning(bundleId: String) -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            return true
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
}
