import AppKit
import Foundation
import RoutingDomain
import os.log

struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
    let browserDownloadURL: String?
    let apiURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case apiURL = "url"
    }
}

struct GitHubReleaseRecord: Decodable, Equatable, Sendable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
        case body
    }

    var normalizedVersion: String {
        let raw = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        return RoomControlReleaseVersioning.canonicalVersion(raw)
    }

    var releaseTrack: RoomControlReleaseTrack? {
        RoomControlReleaseVersioning.parseTrack(from: body)
    }

    var updateSequence: Int? {
        RoomControlReleaseVersioning.parseUpdateSequence(from: body)
    }
}

struct GitHubReleaseSelection: Equatable, Sendable {
    let tagName: String
    let version: String
    let dmgDownloadURL: String?
    let zipAPIURL: String?
    let releaseTrack: RoomControlReleaseTrack?
    let updateSequence: Int?
}

enum GitHubReleaseResolver {
    static func selectLatestStableRelease(
        from releases: [GitHubReleaseRecord],
        currentTrack: RoomControlReleaseTrack
    ) -> GitHubReleaseSelection? {
        let stableReleases = releases.filter { !$0.draft && !$0.prerelease && !$0.normalizedVersion.isEmpty }
        let candidates: [GitHubReleaseRecord]
        switch currentTrack {
        case .bridge, .date:
            let dateTrackReleases = stableReleases.filter { $0.releaseTrack == .date && $0.updateSequence != nil }
            candidates = dateTrackReleases.isEmpty ? stableReleases : dateTrackReleases
        case .legacy:
            candidates = stableReleases
        }

        let bestRelease = candidates.max { lhs, rhs in
            let comparison: ComparisonResult
            switch currentTrack {
            case .bridge, .date:
                comparison = compareReleases(lhs, rhs)
            case .legacy:
                comparison = compareVersions(lhs.normalizedVersion, rhs.normalizedVersion)
            }
            return comparison == .orderedAscending
        }

        return bestRelease
            .map { release in
                GitHubReleaseSelection(
                    tagName: release.tagName,
                    version: release.normalizedVersion,
                    dmgDownloadURL: release.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadURL,
                    zipAPIURL: release.assets.first(where: { $0.name.hasSuffix(".zip") })?.apiURL,
                    releaseTrack: release.releaseTrack,
                    updateSequence: release.updateSequence
                )
            }
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        RoomControlReleaseVersioning.compareNumericVersions(lhs, rhs)
    }

    private static func compareReleases(_ lhs: GitHubReleaseRecord, _ rhs: GitHubReleaseRecord) -> ComparisonResult {
        switch (lhs.updateSequence, rhs.updateSequence) {
        case let (.some(lhsSequence), .some(rhsSequence)):
            if lhsSequence < rhsSequence {
                return .orderedAscending
            }
            if lhsSequence > rhsSequence {
                return .orderedDescending
            }
            return compareVersions(lhs.normalizedVersion, rhs.normalizedVersion)
        case (.some, .none):
            return .orderedDescending
        case (.none, .some):
            return .orderedAscending
        case (.none, .none):
            return compareVersions(lhs.normalizedVersion, rhs.normalizedVersion)
        }
    }
}

enum UpdateDownloadPhase: String {
    case idle
    case contactingGitHub = "contacting_github"
    case startingDownload = "starting_download"
    case downloading
    case unzipping
    case verifyingSignature = "verifying_signature"
    case readyToInstall = "ready_to_install"
    case failed

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .contactingGitHub: return "Contacting GitHub"
        case .startingDownload: return "Starting download"
        case .downloading: return "Downloading update"
        case .unzipping: return "Preparing update"
        case .verifyingSignature: return "Verifying signature"
        case .readyToInstall: return "Ready to install"
        case .failed: return "Update failed"
        }
    }
}

enum UpdateError: LocalizedError {
    case downloadFailed(String)
    case unzipFailed
    case noAppBundleFound
    case signatureInvalid(String)
    case teamIDMismatch
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message): return "Download failed: \(message)"
        case .unzipFailed: return "Failed to unzip update"
        case .noAppBundleFound: return "No app bundle found in update"
        case .signatureInvalid(let message): return "Code signature invalid: \(message)"
        case .teamIDMismatch: return "Update was not signed by BETR"
        case .installFailed(let message): return "Install failed: \(message)"
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var currentVersion = "0.0.0"
    @Published var buildVersion = "0.0.0"
    @Published var latestVersion: String?
    @Published var latestDownloadURL: String?
    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var lastCheckTime: Date?
    @Published var checkError: String?
    @Published var isDownloading = false
    @Published var downloadProgress = 0.0
    @Published var downloadError: String?
    @Published var readyToInstall = false
    @Published var isInstalling = false
    @Published var downloadPhase: UpdateDownloadPhase = .idle
    @Published var bytesDownloaded: Int64 = 0
    @Published var expectedBytes: Int64 = 0
    @Published var downloadRateBytesPerSecond: Double = 0
    @Published var timeToFirstByteMs: Int?
    @Published var readyToInstallLatencyMs: Int?
    @Published var justUpdatedFrom: String?

    let executableModDate: Date?

    private static let repo = RoomControlPublicRelease.releaseRepository
    private static let expectedTeamID = RoomControlPublicRelease.teamIdentifier
    private static let preUpdateVersionKey = "BETRPreUpdateVersion"
    private let logger = Logger(subsystem: RoomControlPublicRelease.bundleIdentifier, category: "Update")
    private let currentReleaseTrack: RoomControlReleaseTrack
    private let currentUpdateSequence: Int?
    private var latestZipAPIURL: String?
    private var pendingUpdateAppURL: URL?
    private var pendingTempDir: URL?
    private var downloadTask: Task<Void, Never>?

    init() {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            currentVersion = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            buildVersion = build
        }
        currentReleaseTrack = RoomControlReleaseVersioning.parseTrack(fromInfoDictionary: Bundle.main.infoDictionary)
        currentUpdateSequence = RoomControlReleaseVersioning.parseUpdateSequence(fromInfoDictionary: Bundle.main.infoDictionary)
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            executableModDate = modDate
        } else {
            executableModDate = nil
        }
        if let previousVersion = UserDefaults.standard.string(forKey: Self.preUpdateVersionKey),
           previousVersion != currentVersion {
            justUpdatedFrom = previousVersion
            logger.info("Post-update detected: \(previousVersion) -> \(self.currentVersion)")
        }
        cleanupLegacyInstalledBackupIfPresent()
    }

    deinit {
        downloadTask?.cancel()
    }

    func dismissUpdateConfirmation() {
        justUpdatedFrom = nil
        UserDefaults.standard.removeObject(forKey: Self.preUpdateVersionKey)
    }

    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        latestVersion = nil
        latestDownloadURL = nil
        latestZipAPIURL = nil
        updateAvailable = false

        Task {
            defer { isChecking = false }

            guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=20") else {
                checkError = "Invalid GitHub release feed URL."
                return
            }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            if let token = Self.loadGitHubToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    checkError = "Could not reach the BETR release feed."
                    return
                }
                let releases = try JSONDecoder().decode([GitHubReleaseRecord].self, from: data)
                guard let release = GitHubReleaseResolver.selectLatestStableRelease(from: releases, currentTrack: currentReleaseTrack) else {
                    checkError = "No stable release is published yet."
                    return
                }

                latestVersion = release.version
                lastCheckTime = Date()
                latestDownloadURL = release.dmgDownloadURL
                latestZipAPIURL = release.zipAPIURL
                updateAvailable = isNewer(release)
            } catch {
                latestVersion = nil
                latestDownloadURL = nil
                latestZipAPIURL = nil
                updateAvailable = false
                checkError = "Network error: \(error.localizedDescription)"
            }
        }
    }

    func openDownloadPage() {
        let urlString = latestDownloadURL ?? "https://github.com/\(Self.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadUpdate() {
        guard let zipAPIURL = latestZipAPIURL, !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        readyToInstall = false
        bytesDownloaded = 0
        expectedBytes = 0
        downloadRateBytesPerSecond = 0
        timeToFirstByteMs = nil
        readyToInstallLatencyMs = nil
        setDownloadPhase(.contactingGitHub)

        if let old = pendingTempDir {
            try? FileManager.default.removeItem(at: old)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("betr-update-\(UUID().uuidString)", isDirectory: true)
        pendingTempDir = tempDir
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        downloadTask = Task {
            do {
                let start = Date()
                guard let requestURL = URL(string: zipAPIURL) else {
                    throw UpdateError.downloadFailed("The release ZIP URL is invalid.")
                }
                var request = URLRequest(url: requestURL)
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                if let token = Self.loadGitHubToken() {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                setDownloadPhase(.startingDownload)
                let (tempFileURL, response) = try await URLSession.shared.download(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw UpdateError.downloadFailed("GitHub returned a non-200 response.")
                }

                timeToFirstByteMs = Int(Date().timeIntervalSince(start) * 1000)
                expectedBytes = response.expectedContentLength
                bytesDownloaded = max(bytesDownloaded, expectedBytes)
                downloadProgress = expectedBytes > 0 ? 1.0 : downloadProgress
                setDownloadPhase(.unzipping)

                let zipDestination = tempDir.appendingPathComponent("update.zip", isDirectory: false)
                try FileManager.default.moveItem(at: tempFileURL, to: zipDestination)
                let unzipURL = tempDir.appendingPathComponent("unzipped", isDirectory: true)
                try FileManager.default.createDirectory(at: unzipURL, withIntermediateDirectories: true)
                try Self.unzip(zipURL: zipDestination, destinationURL: unzipURL)

                guard let appURL = Self.findAppBundle(in: unzipURL) else {
                    throw UpdateError.noAppBundleFound
                }

                setDownloadPhase(.verifyingSignature)
                try Self.verifySignature(of: appURL, expectedTeamID: Self.expectedTeamID)

                pendingUpdateAppURL = appURL
                readyToInstall = true
                readyToInstallLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
                setDownloadPhase(.readyToInstall)
            } catch {
                setDownloadPhase(.failed)
                downloadError = error.localizedDescription
            }
            isDownloading = false
        }
    }

    func installUpdate() {
        guard let updateAppURL = pendingUpdateAppURL, !isInstalling else { return }
        isInstalling = true
        do {
            let currentAppURL = Bundle.main.bundleURL
            UserDefaults.standard.set(currentVersion, forKey: Self.preUpdateVersionKey)

            let fileManager = FileManager.default
            let backupDirectory = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: currentAppURL,
                create: true
            )
            let backupURL = backupDirectory.appendingPathComponent("\(currentAppURL.lastPathComponent).old")
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: currentAppURL, to: backupURL)
            try fileManager.copyItem(at: updateAppURL, to: currentAppURL)

            try ApplicationRelauncher.relaunchAfterCurrentProcessExits(appURL: currentAppURL)
            ApplicationRelauncher.requestApplicationTerminationForRelaunch()
        } catch {
            downloadError = UpdateError.installFailed(error.localizedDescription).localizedDescription
            isInstalling = false
        }
    }

    var downloadPhaseText: String { downloadPhase.title }

    var downloadDetailText: String? {
        switch downloadPhase {
        case .downloading:
            if expectedBytes > 0 {
                let percent = Int(downloadProgress * 100)
                return "\(Self.formatBytes(bytesDownloaded)) of \(Self.formatBytes(expectedBytes)) • \(percent)%"
            }
            if bytesDownloaded > 0 {
                return "\(Self.formatBytes(bytesDownloaded)) downloaded"
            }
            return nil
        case .readyToInstall:
            guard let readyToInstallLatencyMs else { return nil }
            return "Ready in \(Self.formatDuration(milliseconds: readyToInstallLatencyMs))"
        case .failed:
            return downloadError
        default:
            return nil
        }
    }

    private func setDownloadPhase(_ phase: UpdateDownloadPhase) {
        downloadPhase = phase
    }

    private func isNewer(_ release: GitHubReleaseSelection) -> Bool {
        RoomControlReleaseVersioning.isCandidateNewer(
            candidateVersion: release.version,
            candidateUpdateSequence: release.updateSequence,
            installedVersion: currentVersion,
            installedUpdateSequence: currentUpdateSequence
        )
    }

    private func cleanupLegacyInstalledBackupIfPresent() {
        let currentAppURL = Bundle.main.bundleURL
        let legacyBackupURL = currentAppURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(currentAppURL.lastPathComponent).old")
        guard FileManager.default.fileExists(atPath: legacyBackupURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacyBackupURL)
            logger.info("Removed legacy updater backup bundle at \(legacyBackupURL.path, privacy: .public)")
        } catch {
            logger.error("Failed to remove legacy updater backup bundle: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadGitHubToken() -> String? {
        if let dataHex = Bundle.main.infoDictionary?["BETRUpdateTokenData"] as? String,
           let keyHex = Bundle.main.infoDictionary?["BETRUpdateTokenKey"] as? String,
           !dataHex.isEmpty,
           dataHex.count == keyHex.count,
           dataHex.count.isMultiple(of: 2) {
            let dataChars = Array(dataHex)
            let keyChars = Array(keyHex)
            var result = [UInt8]()
            result.reserveCapacity(dataHex.count / 2)
            var index = 0
            while index < dataChars.count {
                guard index + 1 < dataChars.count,
                      let dataByte = UInt8(String(dataChars[index...index + 1]), radix: 16),
                      let keyByte = UInt8(String(keyChars[index...index + 1]), radix: 16) else {
                    return nil
                }
                result.append(dataByte ^ keyByte)
                index += 2
            }
            if let token = String(bytes: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return token
            }
        }

        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            return token
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let tokenFile = appSupport?.appendingPathComponent("BETR/RoomControl/github_token") else {
            return nil
        }
        guard let raw = try? String(contentsOf: tokenFile, encoding: .utf8) else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func unzip(zipURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }
    }

    private static func findAppBundle(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        while let entry = enumerator?.nextObject() as? URL {
            if entry.pathExtension == "app" {
                return entry
            }
        }
        return nil
    }

    private static func verifySignature(of appURL: URL, expectedTeamID: String) throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", appURL.path]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        var outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        outputData.append(stderr.fileHandleForReading.readDataToEndOfFile())
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw UpdateError.signatureInvalid("Unable to read codesign output")
        }
        guard process.terminationStatus == 0 else {
            throw UpdateError.signatureInvalid(output)
        }
        guard output.contains("TeamIdentifier=\(expectedTeamID)") else {
            throw UpdateError.teamIDMismatch
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formatDuration(milliseconds: Int) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds) ms"
        }
        return String(format: "%.1f s", Double(milliseconds) / 1000.0)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
