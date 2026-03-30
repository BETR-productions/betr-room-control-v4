@testable import FeatureUI
import XCTest

final class RoomControlSettingsRootViewTests: XCTestCase {
    func testConfiguredDiscoveryServerSummaryShowsNoneWhenEmpty() {
        XCTAssertEqual(
            RoomControlSettingsRootView.configuredDiscoveryServerSummary(
                configuredDiscoveryServerText: ""
            ),
            "None"
        )
    }

    func testConfiguredDiscoveryServerSummaryPreservesSingleEntry() {
        XCTAssertEqual(
            RoomControlSettingsRootView.configuredDiscoveryServerSummary(
                configuredDiscoveryServerText: "192.168.55.11:5959"
            ),
            "192.168.55.11:5959"
        )
    }

    func testConfiguredDiscoveryServerSummaryJoinsMultilineEntries() {
        XCTAssertEqual(
            RoomControlSettingsRootView.configuredDiscoveryServerSummary(
                configuredDiscoveryServerText: "192.168.55.11:5959\n\nndi://192.168.55.12:5959\n"
            ),
            "192.168.55.11:5959, ndi://192.168.55.12:5959"
        )
    }

    func testRuntimeDiscoveryServerSummaryShowsMDNSOnlyWhenNoServerIsConfigured() {
        XCTAssertEqual(
            RoomControlSettingsRootView.runtimeDiscoveryServerSummary(
                activeDiscoveryServerURL: nil,
                configuredDiscoveryServerText: "",
                runtimeDiscoveryServersCount: 0
            ),
            "mDNS only"
        )
    }

    func testRuntimeDiscoveryServerSummaryShowsNotConnectedWhenServerIsConfiguredButSDKHasNoConnection() {
        XCTAssertEqual(
            RoomControlSettingsRootView.runtimeDiscoveryServerSummary(
                activeDiscoveryServerURL: nil,
                configuredDiscoveryServerText: "192.168.55.11:5959",
                runtimeDiscoveryServersCount: 0
            ),
            "Not connected"
        )
    }

    func testRuntimeDiscoveryServerSummaryShowsNotConnectedWhenRuntimeServersExistButDraftIsEmpty() {
        XCTAssertEqual(
            RoomControlSettingsRootView.runtimeDiscoveryServerSummary(
                activeDiscoveryServerURL: nil,
                configuredDiscoveryServerText: "",
                runtimeDiscoveryServersCount: 1
            ),
            "Not connected"
        )
    }

    func testRuntimeDiscoveryServerSummaryPrefersActualSDKServerURL() {
        XCTAssertEqual(
            RoomControlSettingsRootView.runtimeDiscoveryServerSummary(
                activeDiscoveryServerURL: "ndi://192.168.55.11:5959",
                configuredDiscoveryServerText: "192.168.55.11:5959",
                runtimeDiscoveryServersCount: 1
            ),
            "ndi://192.168.55.11:5959"
        )
    }
}
