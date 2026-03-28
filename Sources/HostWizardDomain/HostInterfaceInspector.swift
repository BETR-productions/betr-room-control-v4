import Darwin
import Foundation

public enum HostInterfaceInspector {
    public struct HardwarePortInfo: Sendable, Equatable {
        public let hardwarePortLabel: String
        public let ethernetAddress: String?

        public init(hardwarePortLabel: String, ethernetAddress: String?) {
            self.hardwarePortLabel = hardwarePortLabel
            self.ethernetAddress = ethernetAddress
        }
    }

    public struct NetworkServiceInfo: Sendable, Equatable {
        public let serviceName: String
        public let order: Int?
        public let enabled: Bool

        public init(serviceName: String, order: Int?, enabled: Bool) {
            self.serviceName = serviceName
            self.order = order
            self.enabled = enabled
        }
    }

    public static func scan(
        showNetworkCIDR: String,
        selectedInterfaceID: String?,
        hardwarePortOutput: String? = nil,
        serviceOrderOutput: String? = nil
    ) -> [HostInterfaceSummary] {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddress = ifaddrPointer else {
            return []
        }
        defer { freeifaddrs(ifaddrPointer) }

        let hardwarePorts = hardwarePortOutput.map(parseHardwarePorts) ?? readHardwarePortMap()
        let services = serviceOrderOutput.map(parseNetworkServiceOrder) ?? readNetworkServiceMap()
        var builders: [String: InterfaceBuilder] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = pointer {
            let interface = current.pointee
            let bsdName = String(cString: interface.ifa_name)
            var builder = builders[bsdName] ?? InterfaceBuilder(
                bsdName: bsdName,
                hardwarePort: hardwarePorts[bsdName],
                networkService: services[bsdName]
            )
            builder.consume(flags: Int32(interface.ifa_flags))

            if let addressPointer = interface.ifa_addr {
                switch Int32(addressPointer.pointee.sa_family) {
                case AF_INET:
                    if let address = ipv4String(from: addressPointer),
                       let netmask = ipv4String(from: interface.ifa_netmask),
                       let cidr = cidrString(address: address, netmask: netmask) {
                        builder.ipv4CIDRs.insert(cidr)
                        builder.ipv4Addresses.insert(address)
                    }
                default:
                    break
                }
            }

            builders[bsdName] = builder
            pointer = interface.ifa_next
        }

        return builders.values
            .map { $0.summary(showNetworkCIDR: showNetworkCIDR) }
            .sorted { lhs, rhs in
                if lhs.id == selectedInterfaceID { return true }
                if rhs.id == selectedInterfaceID { return false }
                if lhs.isRecommended != rhs.isRecommended {
                    return lhs.isRecommended && !rhs.isRecommended
                }
                if lhs.matchesShowNetwork != rhs.matchesShowNetwork {
                    return lhs.matchesShowNetwork && !rhs.matchesShowNetwork
                }
                if lhs.isUp != rhs.isUp {
                    return lhs.isUp && !rhs.isUp
                }
                if lhs.linkKind != rhs.linkKind {
                    let preferredOrder: [HostInterfaceSummary.LinkKind] = [.ethernet, .wifi, .other, .virtual, .loopback]
                    guard let lhsIndex = preferredOrder.firstIndex(of: lhs.linkKind),
                          let rhsIndex = preferredOrder.firstIndex(of: rhs.linkKind) else {
                        return lhs.bsdName.localizedCaseInsensitiveCompare(rhs.bsdName) == .orderedAscending
                    }
                    return lhsIndex < rhsIndex
                }
                return lhs.bsdName.localizedCaseInsensitiveCompare(rhs.bsdName) == .orderedAscending
            }
    }

    public static func matches(_ ipAddress: String, within cidr: String) -> Bool {
        contains(ipAddress, within: cidr)
    }

    public static func parseHardwarePorts(_ output: String) -> [String: HardwarePortInfo] {
        var mapping: [String: HardwarePortInfo] = [:]
        var currentPort: String?
        var currentDevice: String?
        var currentAddress: String?

        func commitCurrent() {
            guard let currentPort, let currentDevice else { return }
            mapping[currentDevice] = HardwarePortInfo(
                hardwarePortLabel: currentPort,
                ethernetAddress: currentAddress
            )
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                commitCurrent()
                currentPort = nil
                currentDevice = nil
                currentAddress = nil
                continue
            }

            if line.hasPrefix("Hardware Port:") {
                currentPort = line.replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("Device:") {
                currentDevice = line.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("Ethernet Address:") {
                currentAddress = line.replacingOccurrences(of: "Ethernet Address:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        commitCurrent()
        return mapping
    }

    public static func parseNetworkServiceOrder(_ output: String) -> [String: NetworkServiceInfo] {
        var mapping: [String: NetworkServiceInfo] = [:]
        var pendingServiceName: String?
        var pendingOrder: Int?
        var pendingEnabled = true

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }

            if let service = parseServiceHeader(line) {
                pendingServiceName = service.name
                pendingOrder = service.order
                pendingEnabled = service.enabled
                continue
            }

            guard let pendingServiceName,
                  line.contains("Device:"),
                  let device = parseDeviceName(fromServiceLine: line) else {
                continue
            }

            mapping[device] = NetworkServiceInfo(
                serviceName: pendingServiceName,
                order: pendingOrder,
                enabled: pendingEnabled
            )
        }

        return mapping
    }

    private static func readHardwarePortMap() -> [String: HardwarePortInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return parseHardwarePorts(output)
        } catch {
            return [:]
        }
    }

    private static func readNetworkServiceMap() -> [String: NetworkServiceInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listnetworkserviceorder"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return parseNetworkServiceOrder(output)
        } catch {
            return [:]
        }
    }

    private static func parseServiceHeader(_ line: String) -> (name: String, order: Int?, enabled: Bool)? {
        guard line.hasPrefix("("), let closing = line.firstIndex(of: ")") else {
            return nil
        }

        let marker = String(line[line.index(after: line.startIndex)..<closing])
        let name = line[line.index(after: closing)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return nil }

        if marker == "*" {
            return (name, nil, false)
        }

        guard let order = Int(marker) else { return nil }
        return (name, order, true)
    }

    private static func parseDeviceName(fromServiceLine line: String) -> String? {
        guard let deviceRange = line.range(of: "Device:") else {
            return nil
        }
        let suffix = line[deviceRange.upperBound...]
        let device = suffix
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " )"))
        guard let device, device.isEmpty == false else { return nil }
        return device
    }

    private static func ipv4String(from pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let pointer else { return nil }
        var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { rebound in
            rebound.pointee
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        guard result != nil else { return nil }
        return String(cString: buffer)
    }

    private static func cidrString(address: String, netmask: String) -> String? {
        guard let prefixLength = prefixLength(from: netmask) else { return nil }
        return "\(address)/\(prefixLength)"
    }

    private static func prefixLength(from netmask: String) -> Int? {
        guard let value = ipv4UInt32(netmask) else { return nil }
        return value.nonzeroBitCount
    }

    private static func ipv4UInt32(_ address: String) -> UInt32? {
        var storage = in_addr()
        let result = address.withCString { inet_pton(AF_INET, $0, &storage) }
        guard result == 1 else { return nil }
        return UInt32(bigEndian: storage.s_addr)
    }

    private static func contains(_ ipAddress: String, within cidr: String) -> Bool {
        let components = cidr.split(separator: "/")
        guard components.count == 2,
              let prefixLength = Int(components[1]),
              prefixLength >= 0,
              prefixLength <= 32,
              let network = ipv4UInt32(String(components[0])),
              let address = ipv4UInt32(ipAddress) else {
            return false
        }

        let mask: UInt32
        if prefixLength == 0 {
            mask = 0
        } else {
            mask = UInt32.max << (32 - prefixLength)
        }
        return (network & mask) == (address & mask)
    }

    private struct InterfaceBuilder {
        let bsdName: String
        let hardwarePort: HardwarePortInfo?
        let networkService: NetworkServiceInfo?
        var flags: Int32 = 0
        var ipv4Addresses: Set<String> = []
        var ipv4CIDRs: Set<String> = []

        mutating func consume(flags: Int32) {
            self.flags |= flags
        }

        func summary(showNetworkCIDR: String) -> HostInterfaceSummary {
            let addresses = Array(ipv4Addresses).sorted()
            let cidrs = Array(ipv4CIDRs).sorted()
            let linkKind = Self.linkKind(for: bsdName, hardwarePortLabel: hardwarePort?.hardwarePortLabel)
            let matchesShowNetwork = addresses.contains { HostInterfaceInspector.contains($0, within: showNetworkCIDR) }
            let recommended = matchesShowNetwork
                && isUp
                && isRunning
                && supportsMulticast
                && linkKind != .loopback
                && linkKind != .virtual

            let hardwarePortLabel = Self.displayName(
                for: bsdName,
                hardwarePortLabel: hardwarePort?.hardwarePortLabel,
                linkKind: linkKind
            )

            return HostInterfaceSummary(
                id: bsdName,
                serviceName: networkService?.serviceName,
                bsdName: bsdName,
                hardwarePortLabel: hardwarePortLabel,
                displayName: hardwarePortLabel,
                linkKind: linkKind,
                isUp: isUp,
                isRunning: isRunning,
                supportsMulticast: supportsMulticast,
                ipv4Addresses: addresses,
                ipv4CIDRs: cidrs,
                primaryIPv4Address: addresses.first,
                primaryIPv4CIDR: cidrs.first,
                matchesShowNetwork: matchesShowNetwork,
                isRecommended: recommended
            )
        }

        private var isUp: Bool {
            (flags & Int32(IFF_UP)) != 0
        }

        private var isRunning: Bool {
            (flags & Int32(IFF_RUNNING)) != 0
        }

        private var supportsMulticast: Bool {
            (flags & Int32(IFF_MULTICAST)) != 0
        }

        private static func linkKind(
            for bsdName: String,
            hardwarePortLabel: String?
        ) -> HostInterfaceSummary.LinkKind {
            let hardwarePort = hardwarePortLabel?.lowercased() ?? ""
            if bsdName == "lo0" {
                return .loopback
            }
            if hardwarePort.contains("wi-fi") || hardwarePort.contains("wifi") || bsdName.hasPrefix("awdl") || bsdName.hasPrefix("llw") {
                return .wifi
            }
            if hardwarePort.contains("ethernet") || hardwarePort.contains("thunderbolt") {
                return .ethernet
            }
            if bsdName.hasPrefix("bridge") || bsdName.hasPrefix("utun") || bsdName.hasPrefix("tap") || bsdName.hasPrefix("vmnet") || bsdName.hasPrefix("vmenet") {
                return .virtual
            }
            if bsdName.hasPrefix("en") {
                return .other
            }
            return .other
        }

        private static func displayName(
            for bsdName: String,
            hardwarePortLabel: String?,
            linkKind: HostInterfaceSummary.LinkKind
        ) -> String {
            if let hardwarePortLabel, hardwarePortLabel.isEmpty == false {
                return hardwarePortLabel
            }

            switch linkKind {
            case .ethernet:
                return "Ethernet"
            case .wifi:
                return "Wi-Fi"
            case .loopback:
                return "Loopback"
            case .virtual:
                return "Virtual"
            case .other:
                return bsdName.uppercased()
            }
        }
    }
}
