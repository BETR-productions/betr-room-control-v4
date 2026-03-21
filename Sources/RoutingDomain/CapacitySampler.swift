// CapacitySampler — 1Hz host metrics sampler for NIC throughput, CPU%, GPU pressure.
// Uses saturating arithmetic for NIC counters to fix the v3 0.9.8.18 overflow crash.

import Foundation
import os

#if canImport(Darwin)
import Darwin
#endif

// MARK: - NIC Counter Snapshot

public struct NICCounterSnapshot: Sendable {
    public let interfaceName: String
    public let inputBytes: UInt64
    public let outputBytes: UInt64
    public let linkSpeedBitsPerSecond: UInt64?
    public let timestamp: Date

    public init(
        interfaceName: String,
        inputBytes: UInt64,
        outputBytes: UInt64,
        linkSpeedBitsPerSecond: UInt64?,
        timestamp: Date = Date()
    ) {
        self.interfaceName = interfaceName
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.linkSpeedBitsPerSecond = linkSpeedBitsPerSecond
        self.timestamp = timestamp
    }
}

// MARK: - Capacity Sample

/// A single capacity sample, published at ~1Hz.
public struct CapacitySample: Sendable {
    public let activeOutputs: Int
    public let activeSources: Int
    public let nicInboundMbps: Double
    public let nicOutboundMbps: Double
    public let nicUtilizationPercent: Double?
    public let cpuPercent: Double
    public let estimatedGPUPressure: Double?
    public let remainingHeadroom: Int?
    public let timestamp: Date

    public init(
        activeOutputs: Int = 0,
        activeSources: Int = 0,
        nicInboundMbps: Double = 0,
        nicOutboundMbps: Double = 0,
        nicUtilizationPercent: Double? = nil,
        cpuPercent: Double = 0,
        estimatedGPUPressure: Double? = nil,
        remainingHeadroom: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.activeOutputs = activeOutputs
        self.activeSources = activeSources
        self.nicInboundMbps = nicInboundMbps
        self.nicOutboundMbps = nicOutboundMbps
        self.nicUtilizationPercent = nicUtilizationPercent
        self.cpuPercent = cpuPercent
        self.estimatedGPUPressure = estimatedGPUPressure
        self.remainingHeadroom = remainingHeadroom
        self.timestamp = timestamp
    }
}

// MARK: - Capacity Sampler

/// Samples host metrics at 1Hz and publishes CapacitySample via AsyncStream.
public actor CapacitySampler {
    private static let log = Logger(subsystem: "com.betr.room-control", category: "CapacitySampler")

    private let interfaceName: String
    private var previousNICSnapshot: NICCounterSnapshot?
    private var previousCPUInfo: host_cpu_load_info?
    private var samplingTask: Task<Void, Never>?

    private let sampleContinuation: AsyncStream<CapacitySample>.Continuation
    public nonisolated let samples: AsyncStream<CapacitySample>

    public init(interfaceName: String = "en0") {
        self.interfaceName = interfaceName
        let (stream, continuation) = AsyncStream<CapacitySample>.makeStream()
        self.samples = stream
        self.sampleContinuation = continuation
    }

    deinit {
        samplingTask?.cancel()
        sampleContinuation.finish()
    }

    /// Start the 1Hz sampling loop.
    public func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1)) // DOCUMENTED EXCEPTION: capacity sampling, 1Hz, not media path
            }
        }
        Self.log.info("Capacity sampler started on interface \(self.interfaceName)")
    }

    /// Stop the sampling loop.
    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    // MARK: - Sampling

    private func tick() {
        let nicSnapshot = Self.readNICCounters(for: interfaceName)
        let cpuPercent = readCPUPercent()
        let gpuPressure = readEstimatedGPUPressure()

        var inboundMbps: Double = 0
        var outboundMbps: Double = 0
        var utilizationPercent: Double? = nil

        if let current = nicSnapshot, let previous = previousNICSnapshot {
            let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
            guard elapsed > 0 else {
                previousNICSnapshot = current
                return
            }

            // Saturating arithmetic — handles counter rollback/wrap without crashing.
            // This fixes the v3 0.9.8.18 overflow crash.
            let inputDelta = current.inputBytes >= previous.inputBytes
                ? current.inputBytes - previous.inputBytes
                : 0
            let outputDelta = current.outputBytes >= previous.outputBytes
                ? current.outputBytes - previous.outputBytes
                : 0

            // Convert bytes/elapsed to Mbps (megabits per second)
            inboundMbps = Double(inputDelta) * 8.0 / elapsed / 1_000_000.0
            outboundMbps = Double(outputDelta) * 8.0 / elapsed / 1_000_000.0

            // NIC utilization as percentage of link speed
            if let linkSpeed = current.linkSpeedBitsPerSecond, linkSpeed > 0 {
                // Use saturating add for total
                let (totalDelta, overflow) = inputDelta.addingReportingOverflow(outputDelta)
                let safeTotalDelta = overflow ? UInt64.max : totalDelta
                let totalBitsPerSecond = Double(safeTotalDelta) * 8.0 / elapsed
                utilizationPercent = (totalBitsPerSecond / Double(linkSpeed)) * 100.0
            }
        }

        previousNICSnapshot = nicSnapshot

        let headroom = estimateRemainingStreams(
            cpuPercent: cpuPercent,
            gpuPressure: gpuPressure,
            nicUtilization: utilizationPercent
        )

        let sample = CapacitySample(
            nicInboundMbps: inboundMbps,
            nicOutboundMbps: outboundMbps,
            nicUtilizationPercent: utilizationPercent,
            cpuPercent: cpuPercent,
            estimatedGPUPressure: gpuPressure,
            remainingHeadroom: headroom
        )

        sampleContinuation.yield(sample)
    }

    // MARK: - NIC Counter Reading

    /// Read current NIC byte counters via getifaddrs. Returns nil if interface not found.
    private static func readNICCounters(for bsdName: String) -> NICCounterSnapshot? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var addr = firstAddr
        while true {
            let name = String(cString: addr.pointee.ifa_name)
            if name == bsdName && addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let data = addr.pointee.ifa_data.assumingMemoryBound(to: if_data.self).pointee
                return NICCounterSnapshot(
                    interfaceName: bsdName,
                    inputBytes: UInt64(data.ifi_ibytes),
                    outputBytes: UInt64(data.ifi_obytes),
                    linkSpeedBitsPerSecond: data.ifi_baudrate > 0 ? UInt64(data.ifi_baudrate) : nil
                )
            }
            guard let next = addr.pointee.ifa_next else { break }
            addr = next
        }
        return nil
    }

    // MARK: - CPU Reading

    /// Read system-wide CPU usage as a percentage (delta between ticks).
    private func readCPUPercent() -> Double {
        var loadInfo = host_cpu_load_info()
        var loadCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let loadResult = withUnsafeMutablePointer(to: &loadInfo) { loadPtr in
            loadPtr.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) { ptr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, ptr, &loadCount)
            }
        }
        guard loadResult == KERN_SUCCESS else { return 0 }

        if let prev = previousCPUInfo {
            let userDelta = Double(loadInfo.cpu_ticks.0 - prev.cpu_ticks.0)
            let systemDelta = Double(loadInfo.cpu_ticks.1 - prev.cpu_ticks.1)
            let idleDelta = Double(loadInfo.cpu_ticks.2 - prev.cpu_ticks.2)
            let niceDelta = Double(loadInfo.cpu_ticks.3 - prev.cpu_ticks.3)
            let total = userDelta + systemDelta + idleDelta + niceDelta
            previousCPUInfo = loadInfo
            return total > 0 ? ((userDelta + systemDelta) / total) * 100.0 : 0
        }
        previousCPUInfo = loadInfo
        return 0
    }

    // MARK: - GPU Pressure Estimation

    /// Estimate GPU pressure. Returns nil if unavailable.
    /// Uses thermal state as a rough proxy.
    private nonisolated func readEstimatedGPUPressure() -> Double? {
        let thermalState = ProcessInfo.processInfo.thermalState
        switch thermalState {
        case .nominal: return 10.0
        case .fair: return 35.0
        case .serious: return 65.0
        case .critical: return 90.0
        @unknown default: return nil
        }
    }

    // MARK: - Headroom Estimation

    /// Estimate remaining 1080p30 stream capacity.
    /// Per v3 formula: CPU headroom = (78 - cpu%) / 9, GPU = (82 - gpu%) / 11, NIC = (78 - nic%) / 10.
    private nonisolated func estimateRemainingStreams(
        cpuPercent: Double,
        gpuPressure: Double?,
        nicUtilization: Double?
    ) -> Int? {
        let cpuCapacity = max(0, Int((78.0 - cpuPercent) / 9.0))

        guard let gpuPressure else { return cpuCapacity }
        let gpuCapacity = max(0, Int((82.0 - gpuPressure) / 11.0))

        if let nicUtilization {
            let networkCapacity = max(0, Int((78.0 - nicUtilization) / 10.0))
            return min(cpuCapacity, gpuCapacity, networkCapacity)
        }

        return min(cpuCapacity, gpuCapacity)
    }
}
