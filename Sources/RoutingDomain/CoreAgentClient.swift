// CoreAgentClient — XPC connection wrapper for BETRCoreAgent.
// Sends commands via BETRCoreXPCCommands, receives events via BETRCoreXPCEvents.
// Publishes typed events via AsyncStream for consumption by ShellViewState.

import Foundation
import RoomControlXPCContracts
import os

// MARK: - Typed Events

/// Events received from BETRCoreAgent, decoded and ready for UI consumption.
public enum CoreAgentEvent: Sendable {
    case sourcesChanged([SourceDescriptor])
    case warmStateChanged(sourceID: String, state: SourceWarmState)
    case switchCompleted(fromSourceID: String?, toSourceID: String)
    case switchAborted(toSourceID: String, reason: String)
    case metersUpdated([MeterSnapshot])
    case healthUpdated(AgentHealthSnapshot)
    case capacityLevelChanged(level: CapacityLevel, activeCount: Int, maxCount: Int)
    case connectionReady
    case connectionInterrupted
    case connectionInvalidated
}

// MARK: - Core Agent Client

/// Actor-isolated XPC client for communicating with BETRCoreAgent.
/// Thread-safe: all XPC proxy calls are dispatched from the actor's executor.
public actor CoreAgentClient {
    private static let log = Logger(subsystem: "com.betr.room-control", category: "CoreAgentClient")

    private var connection: NSXPCConnection?
    private let serviceName: String
    private let eventContinuation: AsyncStream<CoreAgentEvent>.Continuation
    public nonisolated let events: AsyncStream<CoreAgentEvent>
    private let eventHandler: CoreAgentEventHandler

    public init(serviceName: String = RoomControlXPC.serviceName) {
        self.serviceName = serviceName
        let (stream, continuation) = AsyncStream<CoreAgentEvent>.makeStream()
        self.events = stream
        self.eventContinuation = continuation
        self.eventHandler = CoreAgentEventHandler(continuation: continuation)
    }

    deinit {
        connection?.invalidate()
        eventContinuation.finish()
    }

    // MARK: - Connection Lifecycle

    /// Establish the XPC connection to BETRCoreAgent.
    public func connect() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(machServiceName: serviceName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: BETRCoreXPCCommands.self)
        conn.exportedInterface = NSXPCInterface(with: BETRCoreXPCEvents.self)
        conn.exportedObject = eventHandler

        conn.interruptionHandler = { [weak self] in
            Self.log.warning("XPC connection interrupted")
            Task { await self?.handleInterruption() }
        }
        conn.invalidationHandler = { [weak self] in
            Self.log.error("XPC connection invalidated")
            Task { await self?.handleInvalidation() }
        }

        conn.resume()
        connection = conn
        eventContinuation.yield(.connectionReady)
        Self.log.info("XPC connection established to \(self.serviceName)")
    }

    /// Disconnect and invalidate the XPC connection.
    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    private func handleInterruption() {
        eventContinuation.yield(.connectionInterrupted)
    }

    private func handleInvalidation() {
        connection = nil
        eventContinuation.yield(.connectionInvalidated)
    }

    // MARK: - Command Proxy

    private var proxy: BETRCoreXPCCommands? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            Self.log.error("XPC proxy error: \(error.localizedDescription)")
        } as? BETRCoreXPCCommands
    }

    // MARK: - Routing Commands

    /// Set a source as Program output with the given transition.
    public func setProgram(sourceID: String, transition: TransitionConfig) async -> Bool {
        guard let proxy else {
            Self.log.error("setProgram failed: no XPC proxy")
            return false
        }
        guard let transitionData = try? JSONEncoder().encode(transition) else {
            Self.log.error("setProgram failed: could not encode transition")
            return false
        }
        return await withCheckedContinuation { continuation in
            proxy.setProgram(sourceID: sourceID, transitionData: transitionData) { success, errorMessage in
                if let errorMessage, !success {
                    Self.log.error("setProgram failed: \(errorMessage)")
                }
                continuation.resume(returning: success)
            }
        }
    }

    /// Set a source as Preview.
    public func setPreview(sourceID: String) async -> Bool {
        guard let proxy else {
            Self.log.error("setPreview failed: no XPC proxy")
            return false
        }
        return await withCheckedContinuation { continuation in
            proxy.setPreview(sourceID: sourceID) { success in
                continuation.resume(returning: success)
            }
        }
    }

    /// Warm a source (create receiver, start capture).
    public func warmSource(descriptor: SourceDescriptor, tier: SourceTier = .remote) async -> Bool {
        guard let proxy else {
            Self.log.error("warmSource failed: no XPC proxy")
            return false
        }
        guard let descriptorData = try? JSONEncoder().encode(descriptor) else {
            Self.log.error("warmSource failed: could not encode descriptor")
            return false
        }
        return await withCheckedContinuation { continuation in
            proxy.warmSource(descriptorData: descriptorData, tier: tier.rawValue) { success, errorMessage in
                if let errorMessage, !success {
                    Self.log.error("warmSource failed: \(errorMessage)")
                }
                continuation.resume(returning: success)
            }
        }
    }

    /// Cool a source (tear down receiver).
    public func coolSource(sourceID: String) async -> Bool {
        guard let proxy else {
            Self.log.error("coolSource failed: no XPC proxy")
            return false
        }
        return await withCheckedContinuation { continuation in
            proxy.coolSource(sourceID: sourceID) { success in
                continuation.resume(returning: success)
            }
        }
    }

    /// Request the current source catalog.
    public func refreshSourceCatalog() async -> [SourceDescriptor]? {
        guard let proxy else { return nil }
        return await withCheckedContinuation { continuation in
            proxy.refreshSourceCatalog { data in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                let sources = try? JSONDecoder().decode([SourceDescriptor].self, from: data)
                continuation.resume(returning: sources)
            }
        }
    }

    /// Request the current agent health snapshot.
    public func requestHealthSnapshot() async -> AgentHealthSnapshot? {
        guard let proxy else { return nil }
        return await withCheckedContinuation { continuation in
            proxy.requestHealthSnapshot { data in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                let snapshot = try? JSONDecoder().decode(AgentHealthSnapshot.self, from: data)
                continuation.resume(returning: snapshot)
            }
        }
    }

    /// Ping the agent (keepalive).
    public func ping() async -> Bool {
        guard let proxy else { return false }
        return await withCheckedContinuation { continuation in
            proxy.ping { alive in
                continuation.resume(returning: alive)
            }
        }
    }
}

// MARK: - Event Handler (NSObject for XPC)

/// NSObject subclass that implements BETRCoreXPCEvents for receiving agent events.
/// Forwards decoded events to the AsyncStream continuation.
private final class CoreAgentEventHandler: NSObject, BETRCoreXPCEvents, Sendable {
    private static let log = Logger(subsystem: "com.betr.room-control", category: "CoreAgentEvents")
    private let continuation: AsyncStream<CoreAgentEvent>.Continuation

    init(continuation: AsyncStream<CoreAgentEvent>.Continuation) {
        self.continuation = continuation
    }

    func sourcesChanged(catalogData: Data) {
        guard let sources = try? JSONDecoder().decode([SourceDescriptor].self, from: catalogData) else {
            Self.log.error("sourcesChanged: failed to decode catalog data")
            return
        }
        continuation.yield(.sourcesChanged(sources))
    }

    func metersUpdated(snapshotData: Data) {
        guard let snapshots = try? JSONDecoder().decode([MeterSnapshot].self, from: snapshotData) else {
            Self.log.error("metersUpdated: failed to decode snapshot data")
            return
        }
        continuation.yield(.metersUpdated(snapshots))
    }

    func healthUpdated(snapshotData: Data) {
        guard let snapshot = try? JSONDecoder().decode(AgentHealthSnapshot.self, from: snapshotData) else {
            Self.log.error("healthUpdated: failed to decode snapshot data")
            return
        }
        continuation.yield(.healthUpdated(snapshot))
    }

    func warmStateChanged(sourceID: String, stateRawValue: String) {
        guard let state = SourceWarmState(rawValue: stateRawValue) else {
            Self.log.error("warmStateChanged: unknown state '\(stateRawValue)' for source \(sourceID)")
            return
        }
        continuation.yield(.warmStateChanged(sourceID: sourceID, state: state))
    }

    func switchCompleted(fromSourceID: String?, toSourceID: String) {
        continuation.yield(.switchCompleted(fromSourceID: fromSourceID, toSourceID: toSourceID))
    }

    func switchAborted(toSourceID: String, reason: String) {
        Self.log.warning("Switch aborted to \(toSourceID): \(reason)")
        continuation.yield(.switchAborted(toSourceID: toSourceID, reason: reason))
    }

    func capacityLevelChanged(levelRawValue: String, activeCount: Int32, maxCount: Int32) {
        guard let level = CapacityLevel(rawValue: levelRawValue) else {
            Self.log.error("capacityLevelChanged: unknown level '\(levelRawValue)'")
            return
        }
        continuation.yield(.capacityLevelChanged(level: level, activeCount: Int(activeCount), maxCount: Int(maxCount)))
    }
}
