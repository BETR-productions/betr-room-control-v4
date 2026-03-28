import BETRCoreXPC
import CoreNDIHost
import Foundation
import ServiceManagement

public struct RoomControlCoreAgentBootstrapStatus: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case embeddedSMAppService
        case embeddedLaunchAgent
        case developerLaunchAgent
    }

    public let mode: Mode
    public let executablePath: String
    public let plistPath: String
    public let loaded: Bool
    public let note: String

    public init(
        mode: Mode,
        executablePath: String,
        plistPath: String,
        loaded: Bool,
        note: String
    ) {
        self.mode = mode
        self.executablePath = executablePath
        self.plistPath = plistPath
        self.loaded = loaded
        self.note = note
    }
}

public enum RoomControlCoreAgentBootstrapError: LocalizedError, Equatable {
    case bundledAgentAssetsMissing
    case developerCoreCheckoutNotFound
    case agentExecutableMissing(String)
    case installRequired(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundledAgentAssetsMissing:
            return "This app bundle is missing the embedded BETRCoreAgent helper or its LaunchAgent plist."
        case .developerCoreCheckoutNotFound:
            return "Could not locate a governed betr-core-v3 checkout for BETRCoreAgent."
        case let .agentExecutableMissing(path):
            return "BETRCoreAgent was expected at \(path), but no executable was found there."
        case let .installRequired(bundlePath):
            return "Install BETR Room Control into Applications before launching it. Do not run it directly from the DMG or a translocated path. Current bundle: \(bundlePath)"
        case let .commandFailed(message):
            return message
        }
    }
}

public actor RoomControlCoreAgentBootstrapper {
    private static let launchAgentLabel = BETRCoreAgentMachServiceName
    private static let launchAgentPlistName = "\(BETRCoreAgentMachServiceName).plist"
    private static let supportDirectoryName = "BETRCoreAgentV3"
    private static let logFileName = "BETRCoreAgent.log"
    private static let agentExecutableName = "BETRCoreAgent"
    private static let bundledLaunchAgentRelativePath = "Contents/Library/LaunchAgents/\(launchAgentPlistName)"
    private static let preUpdateVersionDefaultsKey = "BETRPreUpdateVersion"
    private static let postUpdateBootstrapResetVersionDefaultsKey = "BETRCoreAgentPostUpdateResetVersion"
    private static let pendingHostProfileRecycleDefaultsKey = "BETRCoreAgentPendingHostProfileRecycle"
    private static let liveRunCommand: @Sendable (URL, [String], URL?) throws -> String = { executableURL, arguments, currentDirectoryURL in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RoomControlCoreAgentBootstrapError.commandFailed(error.isEmpty ? output : error)
        }
        return output
    }
    private static let compileTimeWorkspaceRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let environment: [String: String]
    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let mainBundleURL: URL
    private let mainExecutableURL: URL?
    private let mainBundleVersion: String?
    private let userDefaults: UserDefaults
    private let networkHelperBootstrapper: any RoomControlPrivilegedNetworkHelperBootstrapControlling
    private let runCommand: @Sendable (_ executableURL: URL, _ arguments: [String], _ currentDirectoryURL: URL?) throws -> String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        mainBundleURL: URL = Bundle.main.bundleURL,
        mainExecutableURL: URL? = Bundle.main.executableURL,
        mainBundleVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        userDefaults: UserDefaults = .standard,
        networkHelperBootstrapper: (any RoomControlPrivilegedNetworkHelperBootstrapControlling)? = nil,
        runCommand: (@Sendable (_ executableURL: URL, _ arguments: [String], _ currentDirectoryURL: URL?) throws -> String)? = nil
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
        self.mainBundleURL = mainBundleURL
        self.mainExecutableURL = mainExecutableURL
        self.mainBundleVersion = mainBundleVersion
        self.userDefaults = userDefaults
        self.runCommand = runCommand ?? Self.liveRunCommand
        self.networkHelperBootstrapper = networkHelperBootstrapper ?? RoomControlPrivilegedNetworkHelperBootstrapper(
            fileManager: fileManager,
            mainBundleURL: mainBundleURL,
            runCommand: runCommand ?? Self.liveRunCommand
        )
    }

    public func ensureStarted(
        skipPrivilegedNetworkHelperInstall: Bool = false
    ) throws -> RoomControlCoreAgentBootstrapStatus {
        if isRealAppBundleRun() {
            try validateStableInstalledBundleContext()
            let networkHelperStatus = try networkHelperBootstrapper.ensureInstalledIfNeeded(
                skipInstallation: skipPrivilegedNetworkHelperInstall
            )
            guard let bundledPlistURL = bundledLaunchAgentPlistURL(),
                  let bundledExecutableURL = bundledAgentExecutableURL() else {
                throw RoomControlCoreAgentBootstrapError.bundledAgentAssetsMissing
            }
            return try ensureBundledAgentStarted(
                plistURL: bundledPlistURL,
                executableURL: bundledExecutableURL,
                networkHelperNote: networkHelperStatus.note
            )
        }

        if let explicitAgentExecutable = explicitAgentExecutableURL() {
            let status = try ensureLaunchAgentStarted(
                plistURL: launchAgentPlistURL(),
                plistContents: launchAgentPlistContents(agentExecutableURL: explicitAgentExecutable),
                executablePath: explicitAgentExecutable.path
            )
            return RoomControlCoreAgentBootstrapStatus(
                mode: .developerLaunchAgent,
                executablePath: status.executablePath,
                plistPath: status.plistPath,
                loaded: status.loaded,
                note: "Started BETRCoreAgent from the explicit developer executable path."
            )
        }

        if let bundledExecutableURL = bundledAgentExecutableURL() {
            let status = try ensureLaunchAgentStarted(
                plistURL: launchAgentPlistURL(),
                plistContents: launchAgentPlistContents(agentExecutableURL: bundledExecutableURL),
                executablePath: bundledExecutableURL.path
            )
            return RoomControlCoreAgentBootstrapStatus(
                mode: .embeddedLaunchAgent,
                executablePath: status.executablePath,
                plistPath: status.plistPath,
                loaded: status.loaded,
                note: "Started BETRCoreAgent from the app bundle helper path."
            )
        }

        guard let coreDirectoryURL = resolveDeveloperCoreDirectoryURL() else {
            throw RoomControlCoreAgentBootstrapError.developerCoreCheckoutNotFound
        }

        let agentExecutableURL = try ensureDeveloperAgentExecutable(coreDirectoryURL: coreDirectoryURL)
        let status = try ensureLaunchAgentStarted(
            plistURL: launchAgentPlistURL(),
            plistContents: launchAgentPlistContents(agentExecutableURL: agentExecutableURL),
            executablePath: agentExecutableURL.path
        )
        return RoomControlCoreAgentBootstrapStatus(
            mode: .developerLaunchAgent,
            executablePath: status.executablePath,
            plistPath: status.plistPath,
            loaded: status.loaded,
            note: "Built and started BETRCoreAgent from \(coreDirectoryURL.path)."
        )
    }

    public func stopManagedAgentForRelaunch() {
        userDefaults.set(true, forKey: Self.pendingHostProfileRecycleDefaultsKey)
        _ = try? launchctl(["bootout", launchDomainLabel()])
    }

    public func markManagedAgentRestartRequired() {
        userDefaults.set(true, forKey: Self.pendingHostProfileRecycleDefaultsKey)
    }

    private func ensureBundledAgentStarted(
        plistURL: URL,
        executableURL: URL,
        networkHelperNote: String
    ) throws -> RoomControlCoreAgentBootstrapStatus {
        try prepareRuntimeDirectories()
        try removeStaleDeveloperLaunchAgentIfNeeded(expectedExecutablePath: executableURL.path)
        let recycledPendingHostProfile = try recyclePendingHostProfileRestartIfNeeded(plistName: plistURL.lastPathComponent)
        let resetExistingService = try recyclePostUpdateBundledAgentIfNeeded()

        if #available(macOS 13.0, *) {
            do {
                let service = SMAppService.agent(plistName: plistURL.lastPathComponent)
                try service.register()
                return RoomControlCoreAgentBootstrapStatus(
                    mode: .embeddedSMAppService,
                    executablePath: executableURL.path,
                    plistPath: plistURL.path,
                    loaded: true,
                    note: decoratedNote(
                        bundledRegistrationNote(
                            recycledPendingHostProfile: recycledPendingHostProfile,
                            resetExistingService: resetExistingService,
                            fallbackUsed: false
                        ),
                        networkHelperNote: networkHelperNote
                    )
                )
            } catch {
                let status = try ensureLaunchAgentStarted(
                    plistURL: launchAgentPlistURL(),
                    plistContents: launchAgentPlistContents(agentExecutableURL: executableURL),
                    executablePath: executableURL.path
                )
                return RoomControlCoreAgentBootstrapStatus(
                    mode: .embeddedLaunchAgent,
                    executablePath: status.executablePath,
                    plistPath: status.plistPath,
                    loaded: status.loaded,
                    note: decoratedNote(
                        bundledRegistrationNote(
                            recycledPendingHostProfile: recycledPendingHostProfile,
                            resetExistingService: resetExistingService,
                            fallbackUsed: true
                        ),
                        networkHelperNote: networkHelperNote
                    )
                )
            }
        }

        let status = try ensureLaunchAgentStarted(
            plistURL: launchAgentPlistURL(),
            plistContents: launchAgentPlistContents(agentExecutableURL: executableURL),
            executablePath: executableURL.path
        )
        return RoomControlCoreAgentBootstrapStatus(
            mode: .embeddedLaunchAgent,
            executablePath: status.executablePath,
            plistPath: status.plistPath,
            loaded: status.loaded,
            note: decoratedNote(
                bundledRegistrationNote(
                    recycledPendingHostProfile: recycledPendingHostProfile,
                    resetExistingService: resetExistingService,
                    fallbackUsed: true
                ),
                networkHelperNote: networkHelperNote
            )
        )
    }

    private func decoratedNote(
        _ coreAgentNote: String,
        networkHelperNote: String
    ) -> String {
        "\(networkHelperNote) \(coreAgentNote)"
    }

    private func explicitAgentExecutableURL() -> URL? {
        guard let rawValue = environment["BETR_CORE_AGENT_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isEmpty == false else {
            return nil
        }

        let url = URL(fileURLWithPath: rawValue)
        guard fileManager.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private func bundledLaunchAgentPlistURL() -> URL? {
        let plistURL = mainBundleURL.appendingPathComponent(Self.bundledLaunchAgentRelativePath)
        return fileManager.fileExists(atPath: plistURL.path) ? plistURL : nil
    }

    private func bundledAgentExecutableURL() -> URL? {
        let candidates = [
            mainBundleURL.appendingPathComponent("Contents/Helpers/\(Self.agentExecutableName)"),
            mainBundleURL.appendingPathComponent("Contents/MacOS/\(Self.agentExecutableName)"),
            mainExecutableURL?.deletingLastPathComponent().appendingPathComponent(Self.agentExecutableName),
        ].compactMap { $0 }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func resolveDeveloperCoreDirectoryURL() -> URL? {
        let envCandidate = environment["BETR_CORE_DIR"].flatMap { candidate -> URL? in
            let url = URL(fileURLWithPath: candidate)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        if let envCandidate {
            return envCandidate
        }

        let workspaceRootURL = Self.compileTimeWorkspaceRootURL
        let worktreesURL = workspaceRootURL.appendingPathComponent("worktrees", isDirectory: true)
        if let worktreeMatch = try? fileManager.contentsOfDirectory(at: worktreesURL, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first(where: {
                $0.lastPathComponent.hasPrefix("betr-core-v3--") &&
                fileManager.fileExists(atPath: $0.path)
            }) {
            return worktreeMatch
        }

        let repoRootCandidate = workspaceRootURL
            .appendingPathComponent("macos-apps", isDirectory: true)
            .appendingPathComponent("betr-core-v3", isDirectory: true)
        guard fileManager.fileExists(atPath: repoRootCandidate.path) else {
            return nil
        }
        return repoRootCandidate
    }

    private func ensureDeveloperAgentExecutable(coreDirectoryURL: URL) throws -> URL {
        let swiftURL = URL(fileURLWithPath: "/usr/bin/swift")
        _ = try runCommand(
            swiftURL,
            ["build", "--package-path", coreDirectoryURL.path, "--product", Self.agentExecutableName],
            coreDirectoryURL
        )
        let binPath = try runCommand(
            swiftURL,
            ["build", "--package-path", coreDirectoryURL.path, "--show-bin-path"],
            coreDirectoryURL
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let executableURL = URL(fileURLWithPath: binPath).appendingPathComponent(Self.agentExecutableName)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw RoomControlCoreAgentBootstrapError.agentExecutableMissing(executableURL.path)
        }
        return executableURL
    }

    private func ensureLaunchAgentStarted(
        plistURL: URL,
        plistContents: String,
        executablePath: String
    ) throws -> BETRCoreLaunchAgentStatus {
        try prepareRuntimeDirectories()
        try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existingContents = try? String(contentsOf: plistURL, encoding: .utf8)
        let wasLoaded = isLaunchAgentLoaded()

        if existingContents != plistContents {
            if wasLoaded {
                _ = try? launchctl(["bootout", launchDomainLabel()])
            }
            try plistContents.write(to: plistURL, atomically: true, encoding: .utf8)
        }

        if wasLoaded == false || existingContents != plistContents {
            _ = try launchctl(["bootstrap", launchDomain(), plistURL.path])
        }

        return BETRCoreLaunchAgentStatus(
            plistPath: plistURL.path,
            executablePath: executablePath,
            loaded: isLaunchAgentLoaded()
        )
    }

    private func prepareRuntimeDirectories() throws {
        try fileManager.createDirectory(at: supportDirectoryURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectoryURL(), withIntermediateDirectories: true)
    }

    private func removeStaleDeveloperLaunchAgentIfNeeded(expectedExecutablePath: String) throws {
        let userPlistURL = launchAgentPlistURL()
        if let existingContents = try? String(contentsOf: userPlistURL, encoding: .utf8),
           existingContents.contains(expectedExecutablePath) == false {
            if isLaunchAgentLoaded() {
                _ = try? launchctl(["bootout", launchDomainLabel()])
            }
            try? fileManager.removeItem(at: userPlistURL)
        }

        if let loadedDescription = try? launchctl(["print", launchDomainLabel()]),
           loadedDescription.contains(Self.agentExecutableName),
           loadedDescription.contains(expectedExecutablePath) == false {
            _ = try? launchctl(["bootout", launchDomainLabel()])
        }
    }

    private func recyclePostUpdateBundledAgentIfNeeded() throws -> Bool {
        guard let currentVersion = currentBundleVersion(),
              let previousVersion = userDefaults.string(forKey: Self.preUpdateVersionDefaultsKey),
              previousVersion != currentVersion,
              userDefaults.string(forKey: Self.postUpdateBootstrapResetVersionDefaultsKey) != currentVersion else {
            return false
        }

        _ = try? launchctl(["bootout", launchDomainLabel()])
        userDefaults.set(currentVersion, forKey: Self.postUpdateBootstrapResetVersionDefaultsKey)
        return true
    }

    private func recyclePendingHostProfileRestartIfNeeded(plistName: String) throws -> Bool {
        guard userDefaults.bool(forKey: Self.pendingHostProfileRecycleDefaultsKey) else {
            return false
        }

        if #available(macOS 13.0, *) {
            let service = SMAppService.agent(plistName: plistName)
            try? service.unregister()
        }
        _ = try? launchctl(["bootout", launchDomainLabel()])
        userDefaults.removeObject(forKey: Self.pendingHostProfileRecycleDefaultsKey)
        return true
    }

    private func bundledRegistrationNote(
        recycledPendingHostProfile: Bool,
        resetExistingService: Bool,
        fallbackUsed: Bool
    ) -> String {
        let base: String
        if fallbackUsed {
            base = "Room Control rewrote the user LaunchAgent manifest to the bundled BETRCoreAgent helper path."
        } else {
            base = "Registered the bundled BETRCoreAgent LaunchAgent with SMAppService."
        }

        if recycledPendingHostProfile && resetExistingService {
            return "\(base.dropLast()). After recycling the helper for the committed host-profile restart and clearing stale helper state from the previous update."
        }
        if recycledPendingHostProfile {
            return "\(base.dropLast()). After recycling the helper so NDI can reinitialize on the committed host profile."
        }
        if resetExistingService {
            return "\(base.dropLast()). After clearing stale helper state from the previous update."
        }
        return base
    }

    private func launchAgentPlistURL() -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.launchAgentPlistName)
    }

    private func supportDirectoryURL() -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Self.supportDirectoryName, isDirectory: true)
    }

    private func logsDirectoryURL() -> URL {
        URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("BETR", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    private func logFileURL() -> URL {
        logsDirectoryURL().appendingPathComponent(Self.logFileName)
    }

    private func launchAgentPlistContents(agentExecutableURL: URL) -> String {
        let logPath = logFileURL().path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(agentExecutableURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>MachServices</key>
            <dict>
                <key>\(BETRCoreAgentMachServiceName)</key>
                <true/>
            </dict>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    private func isRealAppBundleRun() -> Bool {
        mainBundleURL.pathExtension == "app"
    }

    private func validateStableInstalledBundleContext() throws {
        let bundlePath = mainBundleURL.standardizedFileURL.path
        if bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/") {
            throw RoomControlCoreAgentBootstrapError.installRequired(bundlePath)
        }

        let installedRoots = [
            "/Applications",
            homeDirectoryURL.appendingPathComponent("Applications", isDirectory: true).path,
        ]

        let isInstalled = installedRoots.contains { rootPath in
            bundlePath == rootPath || bundlePath.hasPrefix(rootPath + "/")
        }

        guard isInstalled else {
            throw RoomControlCoreAgentBootstrapError.installRequired(bundlePath)
        }
    }

    private func currentBundleVersion() -> String? {
        let version = mainBundleVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version, version.isEmpty == false else {
            return nil
        }
        return version
    }

    private func isLaunchAgentLoaded() -> Bool {
        (try? launchctl(["print", launchDomainLabel()])) != nil
    }

    private func launchDomain() -> String {
        "gui/\(getuid())"
    }

    private func launchDomainLabel() -> String {
        "\(launchDomain())/\(Self.launchAgentLabel)"
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) throws -> String {
        do {
            return try runCommand(URL(fileURLWithPath: "/bin/launchctl"), arguments, nil)
        } catch {
            throw RoomControlCoreAgentBootstrapError.commandFailed(error.localizedDescription)
        }
    }
}

private struct BETRCoreLaunchAgentStatus: Equatable {
    let plistPath: String
    let executablePath: String
    let loaded: Bool
}
