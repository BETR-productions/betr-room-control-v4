@testable import HostWizardDomain
import XCTest

final class HostInterfaceInspectorTests: XCTestCase {
    func testParseHardwarePortsMapsWiFiHardwarePort() {
        let output = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: aa:bb:cc:dd:ee:ff

        Hardware Port: USB 10/100/1000 LAN
        Device: en7
        Ethernet Address: 11:22:33:44:55:66
        """

        let mapping = HostInterfaceInspector.parseHardwarePorts(output)

        XCTAssertEqual(mapping["en0"]?.hardwarePortLabel, "Wi-Fi")
        XCTAssertEqual(mapping["en7"]?.hardwarePortLabel, "USB 10/100/1000 LAN")
    }

    func testDropdownLabelIncludesHardwarePortBsdAndIPv4() {
        let summary = HostInterfaceSummary(
            id: "en0",
            serviceName: "Wi-Fi",
            bsdName: "en0",
            hardwarePortLabel: "Wi-Fi",
            displayName: "Wi-Fi",
            linkKind: .wifi,
            isUp: true,
            isRunning: true,
            supportsMulticast: true,
            ipv4Addresses: ["192.168.55.150"],
            ipv4CIDRs: ["192.168.55.150/24"],
            primaryIPv4Address: "192.168.55.150",
            primaryIPv4CIDR: "192.168.55.150/24",
            matchesShowNetwork: true,
            isRecommended: true
        )

        XCTAssertEqual(summary.stableDropdownLabel, "Wi-Fi • en0 • 192.168.55.150/24 • SHOW")
    }

    func testParseNetworkServiceOrderMapsServiceToDevice() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Ethernet
        (Hardware Port: Ethernet, Device: en0)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en1)

        (*) Bluetooth PAN
        (Hardware Port: Bluetooth PAN, Device: en7)
        """

        let mapping = HostInterfaceInspector.parseNetworkServiceOrder(output)

        XCTAssertEqual(mapping["en0"]?.serviceName, "Ethernet")
        XCTAssertEqual(mapping["en0"]?.order, 1)
        XCTAssertEqual(mapping["en0"]?.enabled, true)
        XCTAssertEqual(mapping["en7"]?.serviceName, "Bluetooth PAN")
        XCTAssertEqual(mapping["en7"]?.enabled, false)
    }
}
