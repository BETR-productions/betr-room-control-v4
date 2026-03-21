import Foundation
import Testing
@testable import FeatureUI
@testable import RoutingDomain
@testable import ClipPlayerDomain
@testable import TimerDomain
@testable import PersistenceDomain
@testable import RoomControlXPCContracts

@Test func brandTokensExist() async throws {
    // Verify BrandTokens are accessible from test target.
    _ = BrandTokens.gold
    _ = BrandTokens.dark
    _ = BrandTokens.pgnGreen
    _ = BrandTokens.pvwRed
}

@Test func persistedLayoutDefaults() async throws {
    let layout = PersistedLayout()
    #expect(layout.leadingWidth == 340)
    #expect(layout.centerWidth == 340)
}

// MARK: - OutputAudioBufferSizing Tests (Task 58)

@Test func audioBufferSizing_48kHz_29_97fps_alternates800_801() async throws {
    // At 48kHz / 29.97fps (30000/1001): buffers should alternate ~800/801 samples.
    // Over 10 buffers (5 video frames): exactly 8008 samples total.
    var total = 0
    for i in 0..<10 {
        let count = OutputAudioBufferSizing.sampleCount(
            forFrameIndex: UInt64(i),
            sampleRate: 48_000,
            frameRateNumerator: 30_000,
            frameRateDenominator: 1_001
        )
        #expect(count >= 800 && count <= 801, "Buffer \(i) had \(count) samples, expected 800 or 801")
        total += count
    }
    #expect(total == 8008, "10 buffers should sum to 8008 samples, got \(total)")
}

@Test func audioBufferSizing_neverReturns480_or_48000() async throws {
    // Verify no buffer ever returns the old wrong values.
    for i in 0..<100 {
        let count = OutputAudioBufferSizing.sampleCount(
            forFrameIndex: UInt64(i),
            sampleRate: 48_000,
            frameRateNumerator: 30_000,
            frameRateDenominator: 1_001
        )
        #expect(count != 480, "Buffer \(i) returned forbidden 480 samples")
        #expect(count != 48_000, "Buffer \(i) returned forbidden 48000 samples")
    }
}

@Test func audioBufferSizing_samplesPerVideoFrame_alternates1601_1602() async throws {
    // At 48kHz / 29.97fps: video frames should get 1601 or 1602 samples.
    // Over 5 frames: exactly 8008 total.
    var total = 0
    for i in 0..<5 {
        let count = OutputAudioBufferSizing.samplesPerVideoFrame(
            videoFrameIndex: UInt64(i),
            sampleRate: 48_000,
            frameRateNumerator: 30_000,
            frameRateDenominator: 1_001
        )
        #expect(count == 1601 || count == 1602, "Frame \(i) had \(count) samples, expected 1601 or 1602")
        total += count
    }
    #expect(total == 8008, "5 frames should sum to 8008 samples, got \(total)")
}

@Test func audioBufferSizing_longTermAlignment() async throws {
    // Over 30000 audio buffers (15000 video frames = ~500s), total must equal
    // exactly 15000 * 48000 * 1001 / 30000 = 15000 * 1601.6 = 24024000 samples.
    // Actually: accumulated(30000) = 30000 * 48000 * 1001 / 60000 = 24024000
    var total: UInt64 = 0
    for i in 0..<30_000 {
        total += UInt64(OutputAudioBufferSizing.sampleCount(
            forFrameIndex: UInt64(i),
            sampleRate: 48_000,
            frameRateNumerator: 30_000,
            frameRateDenominator: 1_001
        ))
    }
    #expect(total == 24_024_000, "30000 buffers should sum to 24024000, got \(total)")
}

@Test func audioBufferSizing_25fps_exact() async throws {
    // At 48kHz / 25fps (25/1): each half-frame = 48000/(25*2) = 960 samples exactly.
    for i in 0..<10 {
        let count = OutputAudioBufferSizing.sampleCount(
            forFrameIndex: UInt64(i),
            sampleRate: 48_000,
            frameRateNumerator: 25,
            frameRateDenominator: 1
        )
        #expect(count == 960, "25fps buffer \(i) should be 960, got \(count)")
    }
}

// MARK: - ClipPlayerDomain Type Tests

@Test func clipItemType_detectsFromURL() async throws {
    #expect(ClipItemType.type(for: URL(fileURLWithPath: "/test.mp4")) == .video)
    #expect(ClipItemType.type(for: URL(fileURLWithPath: "/test.mov")) == .video)
    #expect(ClipItemType.type(for: URL(fileURLWithPath: "/test.hevc")) == .video)
    #expect(ClipItemType.type(for: URL(fileURLWithPath: "/test.jpg")) == .still)
    #expect(ClipItemType.type(for: URL(fileURLWithPath: "/test.jpeg")) == .still)
    #expect(ClipItemType.type(for: URL(fileURLWithPath: "/test.png")) == .still)
    #expect(ClipItemType.type(for: URL(fileURLWithPath: "/test.txt")) == nil)
}

@Test func clipItem_codableRoundTrip() async throws {
    let item = ClipItem(
        url: URL(fileURLWithPath: "/test/clip.mp4"),
        type: .video,
        transitionKind: .dissolve,
        durationOverride: 3.0
    )
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ClipItem.self, from: data)
    #expect(decoded == item)
    #expect(decoded.displayName == "clip")
}

@Test func clipPlayerSnapshot_defaults() async throws {
    let snapshot = ClipPlayerSnapshot()
    #expect(snapshot.runState == .stopped)
    #expect(snapshot.producerID == nil)
    #expect(snapshot.totalItemCount == 0)
    #expect(snapshot.playbackOrder == .sequential)
}

// MARK: - TimerDomain Type Tests

@Test func timerMode_codableRoundTrip_duration() async throws {
    let mode = TimerMode.duration(seconds: 300)
    let data = try JSONEncoder().encode(mode)
    let decoded = try JSONDecoder().decode(TimerMode.self, from: data)
    #expect(decoded == mode)
}

@Test func timerMode_codableRoundTrip_endTime() async throws {
    let target = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let mode = TimerMode.endTime(target: target)
    let data = try JSONEncoder().encode(mode)
    let decoded = try JSONDecoder().decode(TimerMode.self, from: data)
    #expect(decoded == mode)
}

@Test func timerSnapshot_defaults() async throws {
    let snapshot = TimerSnapshot()
    #expect(snapshot.runState == .stopped)
    #expect(snapshot.remainingSeconds == 600)
    #expect(snapshot.displayText == "10:00")
}

// MARK: - PersistenceDomain Tests (Task 54)

@Test func clipPlaylist_codableRoundTrip() async throws {
    let item = ClipItem(
        url: URL(fileURLWithPath: "/media/intro.mp4"),
        type: .video,
        transitionKind: .cut
    )
    let playlist = PersistedClipPlaylist(items: [item], playbackOrder: .random)
    let data = try JSONEncoder().encode(playlist)
    let decoded = try JSONDecoder().decode(PersistedClipPlaylist.self, from: data)
    #expect(decoded.items.count == 1)
    #expect(decoded.items.first == item)
    #expect(decoded.playbackOrder == .random)
}

@Test func persistenceStore_saveAndLoadPlaylist() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = PersistenceStore(directory: tempDir)

    let item = ClipItem(
        url: URL(fileURLWithPath: "/media/clip.mov"),
        type: .video,
        transitionKind: .dissolve,
        durationOverride: nil
    )
    let playlist = PersistedClipPlaylist(items: [item], playbackOrder: .sequential)
    store.saveClipPlaylist(playlist)

    let loaded = store.loadClipPlaylist()
    #expect(loaded.items.count == 1)
    #expect(loaded.items.first?.url.lastPathComponent == "clip.mov")
    #expect(loaded.playbackOrder == .sequential)

    // Cleanup
    try? FileManager.default.removeItem(at: tempDir)
}

@Test func persistenceStore_emptyPlaylistOnFirstLoad() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = PersistenceStore(directory: tempDir)

    let loaded = store.loadClipPlaylist()
    #expect(loaded.items.isEmpty)
    #expect(loaded.playbackOrder == .sequential)

    try? FileManager.default.removeItem(at: tempDir)
}
