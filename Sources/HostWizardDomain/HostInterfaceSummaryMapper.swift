import CoreNDIHost
import Darwin
import Foundation

public enum HostInterfaceSummaryMapper {
    public static func makeSummaries(
        from records: [BETRCoreHostInterfaceRecord],
        showNetworkCIDR: String,
        selectedInterfaceID: String?
    ) -> [HostInterfaceSummary] {
        records
            .map { makeSummary(from: $0, showNetworkCIDR: showNetworkCIDR) }
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

    private static func makeSummary(
        from record: BETRCoreHostInterfaceRecord,
        showNetworkCIDR: String
    ) -> HostInterfaceSummary {
        let linkKind = linkKind(for: record.bsdName, hardwarePortLabel: record.hardwarePortLabel)
        let matchesShowNetwork = record.ipv4Addresses.contains { contains($0, within: showNetworkCIDR) }
        let isRecommended = matchesShowNetwork
            && record.isUp
            && record.isRunning
            && record.supportsMulticast
            && linkKind != .loopback
            && linkKind != .virtual

        let hardwarePortLabel = displayName(
            for: record.bsdName,
            hardwarePortLabel: record.hardwarePortLabel,
            linkKind: linkKind
        )

        return HostInterfaceSummary(
            id: record.id,
            serviceName: record.serviceName,
            bsdName: record.bsdName,
            hardwarePortLabel: hardwarePortLabel,
            displayName: hardwarePortLabel,
            linkKind: linkKind,
            isUp: record.isUp,
            isRunning: record.isRunning,
            supportsMulticast: record.supportsMulticast,
            ipv4Addresses: record.ipv4Addresses.sorted(),
            ipv4CIDRs: record.ipv4CIDRs.sorted(),
            primaryIPv4Address: record.ipv4Addresses.sorted().first,
            primaryIPv4CIDR: record.ipv4CIDRs.sorted().first,
            matchesShowNetwork: matchesShowNetwork,
            isRecommended: isRecommended
        )
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

    private static func ipv4UInt32(_ address: String) -> UInt32? {
        var storage = in_addr()
        let result = address.withCString { inet_pton(AF_INET, $0, &storage) }
        guard result == 1 else { return nil }
        return UInt32(bigEndian: storage.s_addr)
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
