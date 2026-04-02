@testable import RoutingDomain
import XCTest

final class RoomControlCoreAgentBootstrapperTests: XCTestCase {
    func testEnsureStartedRequiresEmbeddedSMAppServiceDuringBootstrapCheck() async throws {
        let userDefaultsSuite = "RoomControlCoreAgentBootstrapperTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let launchctl = LaunchctlRecorder()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let appBundleURL = try makeInstalledAppBundle(at: temporaryDirectory)
        let mainExecutableURL = appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control", isDirectory: false)

        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: ["BETR_ROOM_CONTROL_BOOTSTRAP_CHECK": "1"],
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

        do {
            _ = try await bootstrapper.ensureStarted()
            XCTFail("Expected bundled startup to fail when bootstrap-check mode falls back from SMAppService.")
        } catch let error as RoomControlCoreAgentBootstrapError {
            if case let .commandFailed(message) = error {
                XCTAssertTrue(message.contains("embeddedSMAppService"))
            } else {
                XCTFail("Expected commandFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnsureStartedConsumesRestartIntentOnlyOnce() async throws {
        let userDefaultsSuite = "RoomControlCoreAgentBootstrapperTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let launchctl = LaunchctlRecorder()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
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

    func testEnsureStartedRetriesBundledRegistrationWhenWiringMismatchDetected() async throws {
        let userDefaultsSuite = "RoomControlCoreAgentBootstrapperTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let launchctl = LaunchctlRecorder(wiringMode: .mismatchThenMatch)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
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

        let status = try await bootstrapper.ensureStarted()

        XCTAssertTrue(status.loaded)
        XCTAssertEqual(launchctl.bootstrapCount, 2)
        XCTAssertEqual(launchctl.bootoutCount, 1)
    }

    func testEnsureStartedFailsWhenBundledWiringMismatchPersists() async throws {
        let userDefaultsSuite = "RoomControlCoreAgentBootstrapperTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let launchctl = LaunchctlRecorder(wiringMode: .mismatchAlways)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
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

        do {
            _ = try await bootstrapper.ensureStarted()
            XCTFail("Expected startup to fail after persistent wiring mismatch.")
        } catch let error as RoomControlCoreAgentBootstrapError {
            if case let .commandFailed(message) = error {
                XCTAssertTrue(message.contains("launchd wiring mismatch"))
            } else {
                XCTFail("Expected commandFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(launchctl.bootstrapCount, 2)
        XCTAssertEqual(launchctl.bootoutCount, 1)
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
    enum WiringMode {
        case matchBundled
        case mismatchThenMatch
        case mismatchAlways
    }

    private let lock = NSLock()
    private let wiringMode: WiringMode
    private var isLoaded = false
    private var loadedPlistPath: String?
    private var loadedExecutablePath: String?
    private var mismatchIssued = false
    private var loadedPrintsForCurrentBootstrap = 0
    private(set) var bootoutCount = 0
    private(set) var bootstrapCount = 0

    init(wiringMode: WiringMode = .matchBundled) {
        self.wiringMode = wiringMode
    }

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
                let plistPath: String
                let executablePath: String
                switch wiringMode {
                case .matchBundled:
                    plistPath = loadedPlistPath ?? "unknown"
                    executablePath = loadedExecutablePath ?? "unknown"
                case .mismatchThenMatch:
                    loadedPrintsForCurrentBootstrap += 1
                    if mismatchIssued == false, loadedPrintsForCurrentBootstrap >= 2 {
                        mismatchIssued = true
                        plistPath = "/tmp/stale/com.betr.core-agent.plist"
                        executablePath = "/tmp/stale/BETRCoreAgent"
                    } else {
                        plistPath = loadedPlistPath ?? "unknown"
                        executablePath = loadedExecutablePath ?? "unknown"
                    }
                case .mismatchAlways:
                    loadedPrintsForCurrentBootstrap += 1
                    if loadedPrintsForCurrentBootstrap >= 2 {
                        plistPath = "/tmp/stale/com.betr.core-agent.plist"
                        executablePath = "/tmp/stale/BETRCoreAgent"
                    } else {
                        plistPath = loadedPlistPath ?? "unknown"
                        executablePath = loadedExecutablePath ?? "unknown"
                    }
                }
                return """
                service = com.betr.core-agent
                path = \(plistPath)
                program = \(executablePath)
                """
            }
            throw RoomControlCoreAgentBootstrapError.commandFailed("service not loaded")
        case "bootstrap":
            bootstrapCount += 1
            isLoaded = true
            loadedPrintsForCurrentBootstrap = 0
            if let plistPath = arguments.last {
                loadedPlistPath = plistPath
                loadedExecutablePath = Self.programArgumentPath(from: plistPath)
                if let bundledPlistPath = Self.bundledPlistPath(from: loadedExecutablePath) {
                    loadedPlistPath = bundledPlistPath
                }
            }
            return ""
        case "bootout":
            bootoutCount += 1
            isLoaded = false
            loadedPrintsForCurrentBootstrap = 0
            loadedPlistPath = nil
            loadedExecutablePath = nil
            return ""
        default:
            return ""
        }
    }

    private static func programArgumentPath(from plistPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: plistPath, encoding: .utf8),
              let programArgumentsRange = contents.range(of: "<key>ProgramArguments</key>") else {
            return nil
        }
        let tail = contents[programArgumentsRange.upperBound...]
        guard let openStringRange = tail.range(of: "<string>"),
              let closeStringRange = tail.range(of: "</string>", range: openStringRange.upperBound..<tail.endIndex) else {
            return nil
        }
        return String(tail[openStringRange.upperBound..<closeStringRange.lowerBound])
    }

    private static func bundledPlistPath(from executablePath: String?) -> String? {
        guard let executablePath else { return nil }
        var directory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        while directory.path != "/" {
            if directory.lastPathComponent == "Contents" {
                return directory
                    .appendingPathComponent("Library/LaunchAgents/com.betr.core-agent.plist")
                    .path
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }
        return nil
    }
}
