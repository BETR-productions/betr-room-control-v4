import CoreNDIHost
import CryptoKit
import Foundation

public struct RoomControlPrivilegedNetworkHelperBootstrapStatus: Sendable, Equatable {
    public let installed: Bool
    public let promptedForInstall: Bool
    public let executablePath: String
    public let plistPath: String
    public let note: String

    public init(
        installed: Bool,
        promptedForInstall: Bool,
        executablePath: String,
        plistPath: String,
        note: String
    ) {
        self.installed = installed
        self.promptedForInstall = promptedForInstall
        self.executablePath = executablePath
        self.plistPath = plistPath
        self.note = note
    }
}

public enum RoomControlPrivilegedNetworkHelperBootstrapError: LocalizedError, Equatable {
    case bundledHelperMissing
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundledHelperMissing:
            return "This app bundle is missing the embedded BETR privileged network helper."
        case .installFailed(let message):
            return message
        }
    }
}

public protocol RoomControlPrivilegedNetworkHelperBootstrapControlling: Sendable {
    func ensureInstalledIfNeeded(
        skipInstallation: Bool
    ) throws -> RoomControlPrivilegedNetworkHelperBootstrapStatus
}

// Safe as @unchecked Sendable because these dependencies are all immutable after init.
// If future changes add mutable state here, that state must be reviewed for thread safety.
public final class RoomControlPrivilegedNetworkHelperBootstrapper: RoomControlPrivilegedNetworkHelperBootstrapControlling, @unchecked Sendable {
    private let fileManager: FileManager
    private let mainBundleURL: URL
    private let runCommand: @Sendable (_ executableURL: URL, _ arguments: [String], _ currentDirectoryURL: URL?) throws -> String

    public init(
        fileManager: FileManager = .default,
        mainBundleURL: URL = Bundle.main.bundleURL,
        runCommand: @escaping @Sendable (_ executableURL: URL, _ arguments: [String], _ currentDirectoryURL: URL?) throws -> String
    ) {
        self.fileManager = fileManager
        self.mainBundleURL = mainBundleURL
        self.runCommand = runCommand
    }

    public func ensureInstalledIfNeeded(
        skipInstallation: Bool
    ) throws -> RoomControlPrivilegedNetworkHelperBootstrapStatus {
        guard let bundledHelperURL = bundledHelperURL() else {
            throw RoomControlPrivilegedNetworkHelperBootstrapError.bundledHelperMissing
        }

        let installedExecutableURL = URL(fileURLWithPath: BETRPrivilegedNetworkHelperConstants.installedExecutablePath)
        let installedPlistURL = URL(fileURLWithPath: BETRPrivilegedNetworkHelperConstants.installedLaunchDaemonPlistPath)

        if installationIsCurrent(
            bundledHelperURL: bundledHelperURL,
            installedExecutableURL: installedExecutableURL,
            installedPlistURL: installedPlistURL
        ) {
            return RoomControlPrivilegedNetworkHelperBootstrapStatus(
                installed: true,
                promptedForInstall: false,
                executablePath: installedExecutableURL.path,
                plistPath: installedPlistURL.path,
                note: "The BETR privileged network helper is already installed and up to date."
            )
        }

        if skipInstallation {
            return RoomControlPrivilegedNetworkHelperBootstrapStatus(
                installed: false,
                promptedForInstall: false,
                executablePath: installedExecutableURL.path,
                plistPath: installedPlistURL.path,
                note: "Skipped privileged helper installation during packaged bootstrap validation."
            )
        }

        let stagedPlistURL = fileManager.temporaryDirectory
            .appendingPathComponent("com.betr.network-helper.\(UUID().uuidString).plist", isDirectory: false)
        let stagedPlistContents = launchDaemonPlistContents()
        try stagedPlistContents.write(to: stagedPlistURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: stagedPlistURL) }

        let installScript = installScriptContents(
            bundledHelperURL: bundledHelperURL,
            stagedPlistURL: stagedPlistURL
        )
        let appleScript = """
        do shell script "\(appleScriptQuoted(installScript))" with administrator privileges
        """

        do {
            _ = try runCommand(
                URL(fileURLWithPath: "/usr/bin/osascript"),
                ["-e", appleScript],
                nil
            )
        } catch {
            throw RoomControlPrivilegedNetworkHelperBootstrapError.installFailed(
                "BETR could not install the privileged network helper. Approve the one-time administrator prompt so multicast pinning can stay silent on future restarts. \(error.localizedDescription)"
            )
        }

        guard installationIsCurrent(
            bundledHelperURL: bundledHelperURL,
            installedExecutableURL: installedExecutableURL,
            installedPlistURL: installedPlistURL
        ) else {
            throw RoomControlPrivilegedNetworkHelperBootstrapError.installFailed(
                "BETR installed the privileged network helper, but the installed files did not match the bundled version afterward."
            )
        }

        return RoomControlPrivilegedNetworkHelperBootstrapStatus(
            installed: true,
            promptedForInstall: true,
            executablePath: installedExecutableURL.path,
            plistPath: installedPlistURL.path,
            note: "Installed or updated the BETR privileged network helper. Future restarts should no longer ask for a password unless the helper itself changes."
        )
    }

    private func bundledHelperURL() -> URL? {
        let helperURL = mainBundleURL.appendingPathComponent("Contents/Helpers/\(BETRPrivilegedNetworkHelperConstants.executableName)")
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            return nil
        }
        return helperURL
    }

    private func installationIsCurrent(
        bundledHelperURL: URL,
        installedExecutableURL: URL,
        installedPlistURL: URL
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: installedExecutableURL.path),
              fileManager.fileExists(atPath: installedPlistURL.path),
              fileHash(at: bundledHelperURL) == fileHash(at: installedExecutableURL),
              let installedPlistContents = try? String(contentsOf: installedPlistURL, encoding: .utf8) else {
            return false
        }

        return installedPlistContents == launchDaemonPlistContents()
    }

    private func fileHash(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func launchDaemonPlistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(BETRPrivilegedNetworkHelperConstants.launchDaemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(BETRPrivilegedNetworkHelperConstants.installedExecutablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>MachServices</key>
            <dict>
                <key>\(BETRPrivilegedNetworkHelperConstants.machServiceName)</key>
                <true/>
            </dict>
            <key>StandardOutPath</key>
            <string>\(BETRPrivilegedNetworkHelperConstants.logFilePath)</string>
            <key>StandardErrorPath</key>
            <string>\(BETRPrivilegedNetworkHelperConstants.logFilePath)</string>
        </dict>
        </plist>
        """
    }

    private func installScriptContents(
        bundledHelperURL: URL,
        stagedPlistURL: URL
    ) -> String {
        [
            "set -e",
            "/bin/mkdir -p \(shellQuoted("/Library/PrivilegedHelperTools"))",
            "/bin/mkdir -p \(shellQuoted("/Library/LaunchDaemons"))",
            "/bin/mkdir -p \(shellQuoted(BETRPrivilegedNetworkHelperConstants.logDirectoryPath))",
            "/bin/launchctl bootout \(shellQuoted("system/\(BETRPrivilegedNetworkHelperConstants.launchDaemonLabel)")) >/dev/null 2>&1 || true",
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuoted(bundledHelperURL.path)) \(shellQuoted(BETRPrivilegedNetworkHelperConstants.installedExecutablePath))",
            "/usr/bin/install -o root -g wheel -m 644 \(shellQuoted(stagedPlistURL.path)) \(shellQuoted(BETRPrivilegedNetworkHelperConstants.installedLaunchDaemonPlistPath))",
            "/bin/launchctl bootstrap system \(shellQuoted(BETRPrivilegedNetworkHelperConstants.installedLaunchDaemonPlistPath))",
            "/bin/launchctl kickstart -k \(shellQuoted("system/\(BETRPrivilegedNetworkHelperConstants.launchDaemonLabel)")) >/dev/null 2>&1 || true",
        ].joined(separator: " && ")
    }

    private func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
