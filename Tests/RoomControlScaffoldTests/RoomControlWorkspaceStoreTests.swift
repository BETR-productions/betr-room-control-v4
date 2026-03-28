@testable import FeatureUI
import HostWizardDomain
import XCTest

@MainActor
final class RoomControlWorkspaceStoreTests: XCTestCase {
    func testRefreshHostInterfacesIgnoresStaleScanResults() async {
        let rootDirectory = NSTemporaryDirectory() + UUID().uuidString
        let firstScanStarted = expectation(description: "first scan started")
        let firstScanGate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var invocationCount = 0

        let firstSummaries = [
            makeSummary(id: "en0", hardwarePortLabel: "Wi-Fi", ipv4CIDR: "192.168.55.150/24")
        ]
        let secondSummaries = [
            makeSummary(id: "en7", hardwarePortLabel: "USB Ethernet", ipv4CIDR: "10.10.10.12/24")
        ]

        let store = RoomControlWorkspaceStore(
            rootDirectory: rootDirectory,
            hostInterfaceScanner: { _, _ in
                lock.lock()
                invocationCount += 1
                let callNumber = invocationCount
                lock.unlock()

                if callNumber == 1 {
                    firstScanStarted.fulfill()
                    _ = firstScanGate.wait(timeout: .now() + 2)
                    return firstSummaries
                }

                return secondSummaries
            },
            refreshHostInterfacesOnInit: false
        )

        store.hostDraft.showNetworkCIDR = "192.168.55.0/24"
        store.refreshHostInterfaces()
        await fulfillment(of: [firstScanStarted], timeout: 1.0)

        store.hostDraft.showNetworkCIDR = "10.10.10.0/24"
        store.refreshHostInterfaces()
        await waitForSelection("en7", in: store)

        firstScanGate.signal()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.hostInterfaceSummaries.map(\.id), ["en7"])
        XCTAssertEqual(store.hostDraft.selectedInterfaceID, "en7")

        store.shutdown()
    }

    private func waitForSelection(_ interfaceID: String, in store: RoomControlWorkspaceStore) async {
        for _ in 0..<50 {
            if store.hostDraft.selectedInterfaceID == interfaceID {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTFail("Timed out waiting for selected interface \(interfaceID)")
    }

    private func makeSummary(id: String, hardwarePortLabel: String, ipv4CIDR: String) -> HostInterfaceSummary {
        HostInterfaceSummary(
            id: id,
            serviceName: hardwarePortLabel,
            bsdName: id,
            hardwarePortLabel: hardwarePortLabel,
            displayName: hardwarePortLabel,
            linkKind: .ethernet,
            isUp: true,
            isRunning: true,
            supportsMulticast: true,
            ipv4Addresses: [String(ipv4CIDR.split(separator: "/").first ?? "")],
            ipv4CIDRs: [ipv4CIDR],
            primaryIPv4Address: String(ipv4CIDR.split(separator: "/").first ?? ""),
            primaryIPv4CIDR: ipv4CIDR,
            matchesShowNetwork: true,
            isRecommended: true
        )
    }
}
