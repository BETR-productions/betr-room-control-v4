@testable import RoutingDomain
import XCTest

final class RoomControlCoreAgentBootstrapperTests: XCTestCase {
    func testEnsureStartedConsumesRestartIntentOnlyOnce() async throws {
        let userDefaultsSuite = "RoomControlCoreAgentBootstrapperTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let launchctl = LaunchctlRecorder()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = try makeInstalledAppBundle(at: temporaryDirectory)
        let mainExecutableURL = appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control", isDirectory: false)

        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: [:],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: mainExecutableURL,
            mainBundleVersion: "0.9.8.84",
            userDefaults: userDefaults,
            networkHelperBootstrapper: TestBootstrapNetworkHelperBootstrapper(),
            runCommand: { executable, arguments, currentDirectoryURL in
                try launchctl.run(executable, arguments, currentDirectoryURL)
            }
        )

        await bootstrapper.markManagedAgentRestartRequired(
            reason: .hostApply,
            expectedConfigFingerprint: "fingerprint-1"
        )

        let first = try await bootstrapper.ensureStarted()
        let second = try await bootstrapper.ensureStarted()

        XCTAssertEqual(first.consumedRestartIntent?.reason, .hostApply)
        XCTAssertEqual(first.consumedRestartIntent?.expectedConfigFingerprint, "fingerprint-1")
        XCTAssertNil(second.consumedRestartIntent)
        let pendingIntent = await bootstrapper.currentManagedAgentRestartIntent()
        XCTAssertNil(pendingIntent)
        XCTAssertEqual(launchctl.bootoutCount, 1)
        XCTAssertEqual(launchctl.bootstrapCount, 1)
    }

    private func makeInstalledAppBundle(at homeDirectoryURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let appBundleURL = homeDirectoryURL
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BETR Room Control.app", isDirectory: true)
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/BETRCoreAgent", isDirectory: false)
        let mainExecutableURL = appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control", isDirectory: false)
        let plistURL = appBundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/com.betr.core-agent.plist",
            isDirectory: false
        )

        try fileManager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mainExecutableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: helperURL.path, contents: Data())
        fileManager.createFile(atPath: mainExecutableURL.path, contents: Data())
        fileManager.createFile(atPath: plistURL.path, contents: Data("<plist/>".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainExecutableURL.path)

        return appBundleURL
    }
}

private struct TestBootstrapNetworkHelperBootstrapper: RoomControlPrivilegedNetworkHelperBootstrapControlling {
    func ensureInstalledIfNeeded(
        skipInstallation: Bool
    ) throws -> RoomControlPrivilegedNetworkHelperBootstrapStatus {
        RoomControlPrivilegedNetworkHelperBootstrapStatus(
            installed: true,
            promptedForInstall: false,
            executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
            plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
            note: "noop"
        )
    }
}

private final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var isLoaded = false
    private(set) var bootoutCount = 0
    private(set) var bootstrapCount = 0

    func run(_ executableURL: URL, _ arguments: [String], _ currentDirectoryURL: URL?) throws -> String {
        XCTAssertEqual(executableURL.path, "/bin/launchctl")
        guard let command = arguments.first else {
            return ""
        }

        lock.lock()
        defer { lock.unlock() }

        switch command {
        case "print":
            if isLoaded {
                return "service = com.betr.core-agent"
            }
            throw RoomControlCoreAgentBootstrapError.commandFailed("service not loaded")
        case "bootstrap":
            bootstrapCount += 1
            isLoaded = true
            return ""
        case "bootout":
            bootoutCount += 1
            isLoaded = false
            return ""
        default:
            return ""
        }
    }
}
