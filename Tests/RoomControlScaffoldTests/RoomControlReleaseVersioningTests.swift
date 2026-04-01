import RoutingDomain
import XCTest

final class RoomControlReleaseVersioningTests: XCTestCase {
    func testCanonicalVersionPrefixesDateInputWithZero() {
        XCTAssertEqual(RoomControlReleaseVersioning.canonicalVersion(".3.23.2"), "0.3.23.2")
    }

    func testInferReleaseTrackTreatsBridgeVersionAsBridge() {
        XCTAssertEqual(
            RoomControlReleaseVersioning.inferredTrack(
                versionArgument: nil,
                canonicalVersion: "0.9.8.57",
                explicitTrack: nil
            ),
            .bridge
        )
    }

    func testInferReleaseTrackTreatsDotVersionAsDate() {
        XCTAssertEqual(
            RoomControlReleaseVersioning.inferredTrack(
                versionArgument: ".3.23.2",
                canonicalVersion: "0.3.23.2",
                explicitTrack: nil
            ),
            .date
        )
    }

    func testUpdateSequenceAllowsDateVersionAfterBridge() {
        XCTAssertTrue(
            RoomControlReleaseVersioning.isCandidateNewer(
                candidateVersion: "0.3.23.2",
                candidateUpdateSequence: 2026032303,
                installedVersion: "0.9.8.57",
                installedUpdateSequence: 2026032302
            )
        )
    }

    func testLegacyFallbackUsesNumericCompareWithoutSequences() {
        XCTAssertTrue(
            RoomControlReleaseVersioning.isCandidateNewer(
                candidateVersion: "0.9.8.57",
                candidateUpdateSequence: nil,
                installedVersion: "0.9.5.2",
                installedUpdateSequence: nil
            )
        )
        XCTAssertFalse(
            RoomControlReleaseVersioning.isCandidateNewer(
                candidateVersion: "0.3.23.2",
                candidateUpdateSequence: nil,
                installedVersion: "0.9.8.57",
                installedUpdateSequence: nil
            )
        )
    }
}
