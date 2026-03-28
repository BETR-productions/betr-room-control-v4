@testable import FeatureUI
import XCTest

final class UpdateCheckerReleaseResolverTests: XCTestCase {
    func testBridgeTrackPrefersDateLineReleaseUsingUpdateSequence() {
        let releases = [
            GitHubReleaseRecord(
                tagName: "v0.9.8.51",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: bridge
                BETR-Update-Sequence: 2026032302
                """
            ),
            GitHubReleaseRecord(
                tagName: "v0.3.23.2",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: date
                BETR-Update-Sequence: 2026032303
                """
            ),
        ]

        let selection = GitHubReleaseResolver.selectLatestStableRelease(
            from: releases,
            currentTrack: .bridge
        )

        XCTAssertEqual(selection?.version, "0.3.23.2")
        XCTAssertEqual(selection?.releaseTrack, .date)
        XCTAssertEqual(selection?.updateSequence, 2026032303)
    }

    func testLegacyTrackStillPrefersBridgeVersionByNumericOrdering() {
        let releases = [
            GitHubReleaseRecord(
                tagName: "v0.9.8.51",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: bridge
                BETR-Update-Sequence: 2026032302
                """
            ),
            GitHubReleaseRecord(
                tagName: "v0.3.23.2",
                draft: false,
                prerelease: false,
                assets: [],
                body: """
                BETR-Release-Track: date
                BETR-Update-Sequence: 2026032303
                """
            ),
        ]

        let selection = GitHubReleaseResolver.selectLatestStableRelease(
            from: releases,
            currentTrack: .legacy
        )

        XCTAssertEqual(selection?.version, "0.9.8.51")
        XCTAssertEqual(selection?.releaseTrack, .bridge)
        XCTAssertEqual(selection?.updateSequence, 2026032302)
    }
}
