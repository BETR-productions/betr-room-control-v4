import CoreNDIHost
@testable import HostWizardDomain
import XCTest

final class HostInterfaceSummaryMapperTests: XCTestCase {
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

    func testMapperMarksRecommendedShowInterface() {
        let summaries = HostInterfaceSummaryMapper.makeSummaries(
            from: [
                BETRCoreHostInterfaceRecord(
                    id: "en7",
                    bsdName: "en7",
                    hardwarePortLabel: "USB Ethernet",
                    serviceName: "Ethernet",
                    serviceOrder: 1,
                    serviceEnabled: true,
                    isUp: true,
                    isRunning: true,
                    supportsMulticast: true,
                    ipv4Addresses: ["192.168.55.150"],
                    ipv4CIDRs: ["192.168.55.150/24"]
                ),
                BETRCoreHostInterfaceRecord(
                    id: "en0",
                    bsdName: "en0",
                    hardwarePortLabel: "Wi-Fi",
                    serviceName: "Wi-Fi",
                    serviceOrder: 2,
                    serviceEnabled: true,
                    isUp: true,
                    isRunning: true,
                    supportsMulticast: true,
                    ipv4Addresses: ["10.10.10.9"],
                    ipv4CIDRs: ["10.10.10.9/24"]
                )
            ],
            showNetworkCIDR: "192.168.55.0/24",
            selectedInterfaceID: nil
        )

        XCTAssertEqual(summaries.first?.id, "en7")
        XCTAssertEqual(summaries.first?.matchesShowNetwork, true)
        XCTAssertEqual(summaries.first?.isRecommended, true)
    }

    func testMapperPrefersSelectedInterfaceEvenWhenNotRecommended() {
        let summaries = HostInterfaceSummaryMapper.makeSummaries(
            from: [
                BETRCoreHostInterfaceRecord(
                    id: "en0",
                    bsdName: "en0",
                    hardwarePortLabel: "Wi-Fi",
                    isUp: true,
                    isRunning: true,
                    supportsMulticast: true,
                    ipv4Addresses: ["10.10.10.9"],
                    ipv4CIDRs: ["10.10.10.9/24"]
                ),
                BETRCoreHostInterfaceRecord(
                    id: "en7",
                    bsdName: "en7",
                    hardwarePortLabel: "USB Ethernet",
                    isUp: true,
                    isRunning: true,
                    supportsMulticast: true,
                    ipv4Addresses: ["192.168.55.150"],
                    ipv4CIDRs: ["192.168.55.150/24"]
                )
            ],
            showNetworkCIDR: "192.168.55.0/24",
            selectedInterfaceID: "en0"
        )

        XCTAssertEqual(summaries.first?.id, "en0")
    }
}
