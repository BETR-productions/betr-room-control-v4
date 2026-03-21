// OutputTileRenderFeed — thread-safe IOSurface + sequence binding for Metal rendering.
// Provides lock-protected snapshot API so the MTKView draw callback can
// safely read the latest surface without racing with XPC event delivery.

import Foundation
import IOSurface

public final class OutputTileRenderFeed: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let surface: IOSurface?
        public let sequence: UInt64
    }

    private let lock = NSLock()
    private var surface: IOSurface?
    private var sequence: UInt64 = 0

    public init() {}

    /// Thread-safe snapshot of the current surface and sequence.
    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(surface: surface, sequence: sequence)
    }

    /// Bind a new IOSurface and bump sequence. Returns true if this replaced an existing surface.
    @discardableResult
    public func bind(surface: IOSurface, sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasBound = self.surface != nil
        self.surface = surface
        self.sequence = sequence
        return wasBound
    }

    /// Clear the surface binding.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        surface = nil
        sequence = 0
    }
}
