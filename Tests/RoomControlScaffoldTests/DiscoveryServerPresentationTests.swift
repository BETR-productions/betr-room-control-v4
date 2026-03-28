import RoomControlUIContracts
import XCTest

final class DiscoveryServerPresentationTests: XCTestCase {
    func testDraftCodecNormalizesAndDedupesEntries() throws {
        let entries = try DiscoveryServerDraftCodec.strictEntries(
            from: "192.168.55.11\nndi://192.168.55.11:5959,192.168.55.12"
        )

        XCTAssertEqual(entries.map(\.normalizedEndpoint), ["192.168.55.11:5959", "192.168.55.12:5959"])
        XCTAssertEqual(
            DiscoveryServerDraftCodec.normalizedText(from: entries),
            "192.168.55.11:5959\n192.168.55.12:5959"
        )
    }

    func testDraftCodecRejectsInvalidEntries() {
        XCTAssertThrowsError(try DiscoveryServerDraftCodec.strictEntries(from: "ndi://192.168.55.11/bad/path")) { error in
            XCTAssertEqual(error as? DiscoveryServerDraftError, .invalidEntry("ndi://192.168.55.11/bad/path"))
        }
    }

    func testAggregateStatusShowsMixedHealthWhenOneServerIsStrongAndOneIsDegraded() {
        let runtimeRows = [
            NDIWizardDiscoveryServerRow(
                id: "192.168.55.11:5959",
                configuredURL: "192.168.55.11",
                normalizedEndpoint: "192.168.55.11:5959",
                host: "192.168.55.11",
                port: 5959,
                tcpReachable: true,
                validatedAddress: "192.168.55.11:5959",
                listenerLifecycleState: "connected_visible",
                senderListenerAttached: true,
                senderListenerConnected: true,
                receiverListenerAttached: true,
                receiverListenerConnected: true
            ),
            NDIWizardDiscoveryServerRow(
                id: "192.168.55.12:5959",
                configuredURL: "192.168.55.12",
                normalizedEndpoint: "192.168.55.12:5959",
                host: "192.168.55.12",
                port: 5959,
                tcpReachable: true,
                listenerLifecycleState: "attached_waiting",
                senderListenerAttached: true,
                senderListenerConnected: false,
                receiverListenerAttached: true,
                receiverListenerConnected: false
            )
        ]

        let entries = DiscoveryServerPresentationBuilder.entries(
            configuredText: "192.168.55.11:5959\n192.168.55.12:5959",
            runtimeRows: runtimeRows
        )
        let aggregate = DiscoveryServerPresentationBuilder.aggregate(
            configuredText: "192.168.55.11:5959\n192.168.55.12:5959",
            runtimeRows: runtimeRows,
            mdnsEnabled: false
        )

        XCTAssertEqual(aggregate.label, "DISCOVERY 1/2")
        XCTAssertEqual(aggregate.visualState, .warning)
        XCTAssertEqual(entries.first(where: { $0.id == "192.168.55.11:5959" })?.statusWord, "CONNECTED")
        XCTAssertEqual(entries.first(where: { $0.id == "192.168.55.12:5959" })?.statusWord, "WAITING")
    }

    func testAggregateStatusFallsBackToMDNSOnlyWhenNoServerIsConfigured() {
        let aggregate = DiscoveryServerPresentationBuilder.aggregate(
            configuredText: "",
            runtimeRows: [],
            mdnsEnabled: true
        )

        XCTAssertTrue(aggregate.usesMDNSOnly)
        XCTAssertEqual(aggregate.label, "mDNS")
        XCTAssertEqual(aggregate.visualState, .draftOnly)
    }

    func testEntriesIgnoreRuntimeOnlyRowsNotPresentInDraft() {
        let runtimeRows = [
            NDIWizardDiscoveryServerRow(
                id: "192.168.55.11:5959",
                configuredURL: "192.168.55.11",
                normalizedEndpoint: "192.168.55.11:5959",
                host: "192.168.55.11",
                port: 5959,
                tcpReachable: true,
                validatedAddress: "192.168.55.11:5959",
                listenerLifecycleState: "connected_visible",
                senderListenerAttached: true,
                senderListenerConnected: true,
                receiverListenerAttached: true,
                receiverListenerConnected: true
            )
        ]

        let entries = DiscoveryServerPresentationBuilder.entries(
            configuredText: "",
            runtimeRows: runtimeRows
        )
        let aggregate = DiscoveryServerPresentationBuilder.aggregate(
            configuredText: "",
            runtimeRows: runtimeRows,
            mdnsEnabled: false
        )

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(aggregate.healthyCount, 0)
        XCTAssertEqual(aggregate.totalCount, 0)
    }

    func testSortedPopoverEntriesPutFailingServersFirst() {
        let entries = [
            DiscoveryServerPresentationEntry(
                id: "192.168.55.11:5959",
                label: "192.168.55.11:5959",
                visualState: .connected,
                statusWord: "CONNECTED"
            ),
            DiscoveryServerPresentationEntry(
                id: "192.168.55.12:5959",
                label: "192.168.55.12:5959",
                visualState: .error,
                statusWord: "ERROR"
            ),
            DiscoveryServerPresentationEntry(
                id: "192.168.55.13:5959",
                label: "192.168.55.13:5959",
                visualState: .warning,
                statusWord: "CHECK"
            )
        ]

        XCTAssertEqual(
            DiscoveryServerPresentationBuilder.sortedForPopover(entries).map(\.id),
            ["192.168.55.12:5959", "192.168.55.13:5959", "192.168.55.11:5959"]
        )
    }
}
