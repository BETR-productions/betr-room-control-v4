@testable import FeatureUI
import XCTest

final class RoomControlSettingsRootViewTests: XCTestCase {
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
