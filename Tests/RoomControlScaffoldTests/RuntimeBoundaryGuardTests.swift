import Foundation
import XCTest

final class RuntimeBoundaryGuardTests: XCTestCase {
    func testAppSourcesDoNotOwnOperationalHostProbes() throws {
        let forbiddenNeedles = [
            "/usr/sbin/networksetup",
            "getifaddrs(",
        ]

        for sourceURL in try appSourceFiles() {
            let contents = try String(contentsOf: sourceURL, encoding: .utf8)
            for needle in forbiddenNeedles where contents.contains(needle) {
                XCTFail("Forbidden operational host probe '\(needle)' found in \(sourceURL.path)")
            }
        }
    }

    func testAppSourcesDoNotConstructRuntimeNDIObjects() throws {
        let forbiddenNeedles = [
            "NDIFinder(",
            "NDIControlPlaneMonitor(",
            "NDIReceiverSession(",
            "NDIOutputRuntime(",
        ]

        for sourceURL in try appSourceFiles() {
            let contents = try String(contentsOf: sourceURL, encoding: .utf8)
            for needle in forbiddenNeedles where contents.contains(needle) {
                XCTFail("Forbidden runtime ownership '\(needle)' found in \(sourceURL.path)")
            }
        }
    }

    private func appSourceFiles() throws -> [URL] {
        let testsDirectoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let packageRootURL = testsDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesURL = packageRootURL.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }
}
