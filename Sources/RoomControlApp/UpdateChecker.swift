import Foundation
import SwiftUI
import FeatureUI

/// Checks for updates from the BËTR Room Control v4 GitHub releases feed.
/// Non-blocking. Displays a dismissable banner in the UI when a newer version is available.
/// GitHub PAT is XOR-obfuscated into the binary at build time via BETRUpdateTokenData/Key
/// plist keys — never stored as plaintext.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var updateAvailable: UpdateInfo? = nil

    private let releaseRepo = "BETR-productions/betr-room-control-v4"
    private let apiBase = "https://api.github.com"
    private var checkTask: Task<Void, Never>?

    struct UpdateInfo: Identifiable {
        let id = UUID()
        let tag: String
        let downloadURL: URL
        let sha256: String?
        let releaseNotes: String
    }

    private init() {}

    /// Begin a periodic update check. Call once on app launch.
    func startChecking() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.checkForUpdate()
            // Re-check every 4 hours
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4 * 60 * 60 * 1_000_000_000) // DOCUMENTED EXCEPTION: update check interval, 4hr, not media path
                guard !Task.isCancelled else { break }
                await self?.checkForUpdate()
            }
        }
    }

    func dismiss() {
        updateAvailable = nil
    }

    // MARK: - Private

    private func checkForUpdate() async {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return
        }

        do {
            let latest = try await fetchLatestRelease()
            let latestVersion = latest.tag.hasPrefix("v") ? String(latest.tag.dropFirst()) : latest.tag
            guard isNewer(remote: latestVersion, than: currentVersion) else { return }
            updateAvailable = latest
        } catch {
            // Silent failure — update checks are best-effort
        }
    }

    private func fetchLatestRelease() async throws -> UpdateInfo {
        let url = URL(string: "\(apiBase)/repos/\(releaseRepo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let pat = deobfuscatedPAT() {
            request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // Find the ZIP asset
        guard let zipAsset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noZipAsset
        }

        // SHA-256 is optionally embedded in a .sha256 sidecar asset
        let sha256Asset = release.assets.first(where: { $0.name == zipAsset.name + ".sha256" })
        var sha256: String? = nil
        if let sha256URL = sha256Asset.flatMap({ URL(string: $0.browserDownloadURL) }) {
            var shaRequest = URLRequest(url: sha256URL)
            if let pat = deobfuscatedPAT() {
                shaRequest.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
            }
            if let (shaData, _) = try? await URLSession.shared.data(for: shaRequest) {
                sha256 = String(data: shaData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return UpdateInfo(
            tag: release.tagName,
            downloadURL: URL(string: zipAsset.browserDownloadURL)!,
            sha256: sha256,
            releaseNotes: release.body ?? ""
        )
    }

    /// Download, verify, extract and relaunch the update.
    func downloadAndInstall(_ info: UpdateInfo) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Download ZIP
        var request = URLRequest(url: info.downloadURL)
        if let pat = deobfuscatedPAT() {
            request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        }
        let (zipData, _) = try await URLSession.shared.data(for: request)

        // Verify SHA-256 if provided
        if let expected = info.sha256 {
            let actual = sha256Hex(of: zipData)
            guard actual.lowercased() == expected.lowercased() else {
                throw UpdateError.sha256Mismatch(expected: expected, actual: actual)
            }
        }

        // Write and extract ZIP
        let zipPath = tempDir.appendingPathComponent("update.zip")
        try zipData.write(to: zipPath)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipPath.path, extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.extractionFailed }

        // Find the .app inside extracted
        let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInZip
        }

        // Replace current app
        let currentApp = URL(fileURLWithPath: Bundle.main.bundlePath)
        let appParent = currentApp.deletingLastPathComponent()
        let dest = appParent.appendingPathComponent(newApp.lastPathComponent)

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: newApp, to: dest)

        // Relaunch
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = [dest.path]
        try launcher.run()

        NSApp.terminate(nil)
    }

    // MARK: - PAT deobfuscation

    private func deobfuscatedPAT() -> String? {
        guard
            let tokenData = Bundle.main.infoDictionary?["BETRUpdateTokenData"] as? String,
            let tokenKey = Bundle.main.infoDictionary?["BETRUpdateTokenKey"] as? String,
            !tokenData.isEmpty, !tokenKey.isEmpty
        else { return nil }

        var result = ""
        let dataPairs = stride(from: 0, to: tokenData.count, by: 2).map { i -> String in
            let start = tokenData.index(tokenData.startIndex, offsetBy: i)
            let end = tokenData.index(start, offsetBy: 2, limitedBy: tokenData.endIndex) ?? tokenData.endIndex
            return String(tokenData[start..<end])
        }
        let keyPairs = stride(from: 0, to: tokenKey.count, by: 2).map { i -> String in
            let start = tokenKey.index(tokenKey.startIndex, offsetBy: i)
            let end = tokenKey.index(start, offsetBy: 2, limitedBy: tokenKey.endIndex) ?? tokenKey.endIndex
            return String(tokenKey[start..<end])
        }
        guard dataPairs.count == keyPairs.count else { return nil }
        for (d, k) in zip(dataPairs, keyPairs) {
            guard let db = UInt8(d, radix: 16), let kb = UInt8(k, radix: 16) else { return nil }
            let byte = db ^ kb
            let scalar = Unicode.Scalar(byte)
            result.append(Character(scalar))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Version comparison

    private func isNewer(remote: String, than current: String) -> Bool {
        let remoteNorm = normalizeVersion(remote)
        let currentNorm = normalizeVersion(current)
        return remoteNorm.lexicographicallyPrecedes(currentNorm) == false && remoteNorm != currentNorm
    }

    private func normalizeVersion(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    // MARK: - SHA-256

    private func sha256Hex(of data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Errors

    enum UpdateError: Error, LocalizedError {
        case httpError(Int)
        case noZipAsset
        case sha256Mismatch(expected: String, actual: String)
        case extractionFailed
        case noAppInZip

        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "GitHub API returned HTTP \(code)"
            case .noZipAsset: return "No ZIP asset found in the latest release"
            case .sha256Mismatch(let e, let a): return "SHA-256 mismatch: expected \(e), got \(a)"
            case .extractionFailed: return "Failed to extract update ZIP"
            case .noAppInZip: return "No .app bundle found in update ZIP"
            }
        }
    }

    // MARK: - GitHub API types

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

// MARK: - Update Banner View

struct UpdateBannerView: View {
    @ObservedObject private var checker = UpdateChecker.shared
    @State private var isInstalling = false
    @State private var installError: String? = nil

    var body: some View {
        if let info = checker.updateAvailable {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(BrandTokens.gold)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available: \(info.tag)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(BrandTokens.offWhite)
                    if let err = installError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(BrandTokens.red)
                    }
                }

                Spacer()

                Button("Install & Relaunch") {
                    isInstalling = true
                    installError = nil
                    Task { @MainActor in
                        do {
                            try await checker.downloadAndInstall(info)
                        } catch {
                            installError = error.localizedDescription
                            isInstalling = false
                        }
                    }
                }
                .disabled(isInstalling)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(BrandTokens.dark)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(BrandTokens.gold)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: { checker.dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(BrandTokens.warmGrey)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(BrandTokens.toolbarDark)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(BrandTokens.charcoal)
            }
        }
    }
}

// MARK: - CommonCrypto import shim

import CommonCrypto
