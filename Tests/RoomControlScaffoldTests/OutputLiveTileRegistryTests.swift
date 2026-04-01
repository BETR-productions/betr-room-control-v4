import CoreNDIGPU
import CoreNDIOutput
import IOSurface
import RoutingDomain
import XCTest

final class OutputLiveTileRegistryTests: XCTestCase {
    func testAttachmentNoticeAndAdvanceBindSurface() async throws {
        let registry = OutputLiveTileRegistry()
        let attachment = try makeAttachment(outputID: "OUT-1", attachmentID: 11, width: 320, height: 180)
        registry.setAttachmentFetcher { _, _ in attachment }

        let feed = registry.renderFeed(for: "OUT-1")
        registry.applyAttachmentNotice(
            OutputPreviewAttachmentNotice(
                outputID: "OUT-1",
                attachmentID: 11,
                width: 320,
                height: 180,
                lineStride: 320 * 4,
                pixelFormat: .bgra,
                slotCount: 1
            )
        )
        registry.applyAdvance(
            OutputPreviewAdvance(
                snapshot: OutputLiveTileSnapshot(
                    outputID: "OUT-1",
                    sequence: 5,
                    sourceID: "ndi-presenter",
                    previewState: .live,
                    audioPresenceState: .live
                ),
                attachmentID: 11,
                slotIndex: 0
            )
        )

        try await waitUntilSurfaceBound(feed, expectedSequence: 5)

        let snapshot = feed.snapshot()
        XCTAssertNotNil(snapshot.surface)
        XCTAssertEqual(snapshot.sequence, 5)
    }

    func testStaleAdvanceIsIgnored() async throws {
        let registry = OutputLiveTileRegistry()
        let attachment = try makeAttachment(outputID: "OUT-1", attachmentID: 12, width: 320, height: 180)
        registry.setAttachmentFetcher { _, _ in attachment }

        let feed = registry.renderFeed(for: "OUT-1")
        let liveAdvance = OutputPreviewAdvance(
            snapshot: OutputLiveTileSnapshot(
                outputID: "OUT-1",
                sequence: 7,
                sourceID: "ndi-presenter",
                previewState: .live,
                audioPresenceState: .live
            ),
            attachmentID: 12,
            slotIndex: 0
        )
        registry.applyAttachmentNotice(
            OutputPreviewAttachmentNotice(
                outputID: "OUT-1",
                attachmentID: 12,
                width: 320,
                height: 180,
                lineStride: 320 * 4,
                pixelFormat: .bgra,
                slotCount: 1
            )
        )
        registry.applyAdvance(liveAdvance)
        try await waitUntilSurfaceBound(feed, expectedSequence: 7)

        registry.applyAdvance(
            OutputPreviewAdvance(
                snapshot: OutputLiveTileSnapshot(
                    outputID: "OUT-1",
                    sequence: 6,
                    sourceID: "ndi-presenter",
                    previewState: .live,
                    audioPresenceState: .live
                ),
                attachmentID: 12,
                slotIndex: 0
            )
        )

        let snapshot = feed.snapshot()
        XCTAssertEqual(snapshot.sequence, 7)
        XCTAssertNotNil(snapshot.surface)
    }

    func testDetachClearsTile() async throws {
        let registry = OutputLiveTileRegistry()
        let attachment = try makeAttachment(outputID: "OUT-1", attachmentID: 13, width: 320, height: 180)
        registry.setAttachmentFetcher { _, _ in attachment }

        let feed = registry.renderFeed(for: "OUT-1")
        registry.applyAttachmentNotice(
            OutputPreviewAttachmentNotice(
                outputID: "OUT-1",
                attachmentID: 13,
                width: 320,
                height: 180,
                lineStride: 320 * 4,
                pixelFormat: .bgra,
                slotCount: 1
            )
        )
        registry.applyAdvance(
            OutputPreviewAdvance(
                snapshot: OutputLiveTileSnapshot(
                    outputID: "OUT-1",
                    sequence: 8,
                    sourceID: "ndi-presenter",
                    previewState: .live,
                    audioPresenceState: .live
                ),
                attachmentID: 13,
                slotIndex: 0
            )
        )
        try await waitUntilSurfaceBound(feed, expectedSequence: 8)

        registry.applyDetach(outputID: "OUT-1")

        let snapshot = feed.snapshot()
        XCTAssertNil(snapshot.surface)
        XCTAssertEqual(snapshot.sequence, 0)
    }

    func testSameSequenceRecoveryRebindsSurface() async throws {
        let registry = OutputLiveTileRegistry()
        let attachment = try makeAttachment(outputID: "OUT-1", attachmentID: 14, width: 320, height: 180)
        registry.setAttachmentFetcher { _, _ in attachment }

        let feed = registry.renderFeed(for: "OUT-1")
        let notice = OutputPreviewAttachmentNotice(
            outputID: "OUT-1",
            attachmentID: 14,
            width: 320,
            height: 180,
            lineStride: 320 * 4,
            pixelFormat: .bgra,
            slotCount: 1
        )
        let advance = OutputPreviewAdvance(
            snapshot: OutputLiveTileSnapshot(
                outputID: "OUT-1",
                sequence: 9,
                sourceID: "ndi-presenter",
                previewState: .live,
                audioPresenceState: .live
            ),
            attachmentID: 14,
            slotIndex: 0
        )
        registry.applyAttachmentNotice(notice)
        registry.applyAdvance(advance)
        try await waitUntilSurfaceBound(feed, expectedSequence: 9)

        _ = feed.clear()
        XCTAssertNil(feed.snapshot().surface)

        registry.applyAdvance(advance)

        try await waitUntilSurfaceBound(feed, expectedSequence: 9)
        XCTAssertNotNil(feed.snapshot().surface)
    }

    private func waitUntilSurfaceBound(
        _ feed: OutputTileRenderFeed,
        expectedSequence: UInt64,
        timeoutNanoseconds: UInt64 = 500_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let snapshot = feed.snapshot()
            if snapshot.surface != nil, snapshot.sequence == expectedSequence {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for render surface to bind.")
    }

    private func makeAttachment(
        outputID: String,
        attachmentID: UInt64,
        width: Int,
        height: Int
    ) throws -> OutputPreviewAttachment {
        let surface = try XCTUnwrap(makeSurface(width: width, height: height))
        return OutputPreviewAttachment(
            outputID: outputID,
            attachmentID: attachmentID,
            width: width,
            height: height,
            lineStride: width * 4,
            pixelFormat: .bgra,
            slotCount: 1,
            surfaces: [surface]
        )
    }

    private func makeSurface(width: Int, height: Int) -> IOSurface? {
        let bytesPerElement = 4
        let bytesPerRow = width * bytesPerElement
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfacePixelFormat: SharedVideoSurfacePixelFormat.bgra.rawValue,
            kIOSurfaceAllocSize: bytesPerRow * height,
        ]
        return IOSurfaceCreate(properties as CFDictionary)
    }
}
