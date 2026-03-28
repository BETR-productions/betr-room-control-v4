@testable import FeatureUI
import Foundation
import XCTest

final class ApplicationRelauncherTests: XCTestCase {
    func testRelaunchShellCommandWaitsForParentExitBeforeLaunchingNewInstance() {
        let appURL = URL(fileURLWithPath: "/Applications/BETR Room Control.app")

        let command = ApplicationRelauncher.relaunchShellCommand(
            for: appURL,
            parentProcessID: 4242
        )

        XCTAssertTrue(command.contains("kill -0 4242"))
        XCTAssertTrue(command.contains("[ \"$i\" -lt 10 ]"))
        XCTAssertTrue(command.contains("/bin/kill -TERM 4242"))
        XCTAssertTrue(command.contains("[ \"$i\" -lt 25 ]"))
        XCTAssertTrue(command.contains("/bin/kill -KILL 4242"))
        XCTAssertTrue(command.contains("/usr/bin/open '/Applications/BETR Room Control.app'"))
        XCTAssertFalse(command.contains("openApplication"))
        XCTAssertFalse(command.contains("open -n"))
    }

    func testShellQuoteEscapesSingleQuotes() {
        let quoted = ApplicationRelauncher.shellQuote("/Applications/BETR's Room Control.app")

        XCTAssertEqual(quoted, "'/Applications/BETR'\"'\"'s Room Control.app'")
    }

    func testShellQuotePreservesDollarSignsInsideSingleQuotes() {
        let quoted = ApplicationRelauncher.shellQuote("/Applications/$HOME.app")

        XCTAssertEqual(quoted, "'/Applications/$HOME.app'")
    }

    func testShellQuotePreservesCommandSubstitutionMarkersInsideSingleQuotes() {
        let quoted = ApplicationRelauncher.shellQuote("/Applications/$(echo hi).app")

        XCTAssertEqual(quoted, "'/Applications/$(echo hi).app'")
    }

    func testShellQuotePreservesNewlinesInsideSingleQuotes() {
        let quoted = ApplicationRelauncher.shellQuote("/Applications/BETR\nRoom Control.app")

        XCTAssertEqual(quoted, "'/Applications/BETR\nRoom Control.app'")
    }

    func testRequestApplicationTerminationForRelaunchInvokesTerminator() async {
        let terminatorCalled = expectation(description: "application terminator called")

        await MainActor.run {
            ApplicationRelauncher.requestApplicationTerminationForRelaunch {
                terminatorCalled.fulfill()
            }
        }

        await fulfillment(of: [terminatorCalled], timeout: 0.2)
    }
}
