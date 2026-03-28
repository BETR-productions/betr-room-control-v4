import AppKit
import Foundation

enum ApplicationRelauncher {
    static let defaultInitialQuitGracePeriodSeconds: Double = 2
    static let defaultForcedQuitTimeoutSeconds: Double = 5
    static let pollIntervalSeconds: Double = 0.2

    static func relaunchAfterCurrentProcessExits(
        appURL: URL = Bundle.main.bundleURL,
        parentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            relaunchShellCommand(
                for: appURL,
                parentProcessID: parentProcessID,
                initialQuitGracePeriodSeconds: defaultInitialQuitGracePeriodSeconds,
                forcedQuitTimeoutSeconds: defaultForcedQuitTimeoutSeconds
            )
        ]
        try process.run()
    }

    @MainActor
    static func requestApplicationTerminationForRelaunch(
        applicationTerminator: @escaping @MainActor () -> Void = {
            _ = NSRunningApplication.current.terminate()
            NSApp.terminate(nil)
        }
    ) {
        applicationTerminator()
    }

    static func relaunchShellCommand(
        for appURL: URL,
        parentProcessID: Int32,
        initialQuitGracePeriodSeconds: Double = defaultInitialQuitGracePeriodSeconds,
        forcedQuitTimeoutSeconds: Double = defaultForcedQuitTimeoutSeconds
    ) -> String {
        let quotedAppPath = shellQuote(appURL.path)
        let initialQuitIntervals = max(1, Int((initialQuitGracePeriodSeconds / pollIntervalSeconds).rounded(.up)))
        let forcedQuitIntervals = max(1, Int((forcedQuitTimeoutSeconds / pollIntervalSeconds).rounded(.up)))
        return [
            "i=0",
            "while /bin/kill -0 \(parentProcessID) 2>/dev/null && [ \"$i\" -lt \(initialQuitIntervals) ]; do /bin/sleep \(pollIntervalSeconds); i=$((i+1)); done",
            "if /bin/kill -0 \(parentProcessID) 2>/dev/null; then /bin/kill -TERM \(parentProcessID) 2>/dev/null || true; fi",
            "i=0",
            "while /bin/kill -0 \(parentProcessID) 2>/dev/null && [ \"$i\" -lt \(forcedQuitIntervals) ]; do /bin/sleep \(pollIntervalSeconds); i=$((i+1)); done",
            "if /bin/kill -0 \(parentProcessID) 2>/dev/null; then /bin/kill -KILL \(parentProcessID) 2>/dev/null || true; fi",
            "while /bin/kill -0 \(parentProcessID) 2>/dev/null; do /bin/sleep \(pollIntervalSeconds); done",
            "/usr/bin/open \(quotedAppPath) >/dev/null 2>&1",
        ].joined(separator: "; ")
    }

    static func shellQuote(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
