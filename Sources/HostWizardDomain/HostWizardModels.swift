import Foundation
import RoomControlUIContracts

public struct HostWizardSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let profileSummary: String
    public let statusSummary: String

    public init(
        generatedAt: Date = Date(),
        profileSummary: String = "BETR-only",
        statusSummary: String = "Pending agent validation"
    ) {
        self.generatedAt = generatedAt
        self.profileSummary = profileSummary
        self.statusSummary = statusSummary
    }
}

public struct HostInterfaceSummary: Sendable, Equatable, Identifiable {
    public enum LinkKind: String, Sendable, Equatable {
        case ethernet
        case wifi
        case loopback
        case virtual
        case other

        public var label: String {
            switch self {
            case .ethernet:
                return "Ethernet"
            case .wifi:
                return "Wi-Fi"
            case .loopback:
                return "Loopback"
            case .virtual:
                return "Virtual"
            case .other:
                return "Other"
            }
        }
    }

    public let id: String
    public let serviceName: String?
    public let bsdName: String
    public let hardwarePortLabel: String
    public let displayName: String
    public let linkKind: LinkKind
    public let isUp: Bool
    public let isRunning: Bool
    public let supportsMulticast: Bool
    public let ipv4Addresses: [String]
    public let ipv4CIDRs: [String]
    public let primaryIPv4Address: String?
    public let primaryIPv4CIDR: String?
    public let matchesShowNetwork: Bool
    public let isRecommended: Bool

    public init(
        id: String,
        serviceName: String? = nil,
        bsdName: String,
        hardwarePortLabel: String,
        displayName: String,
        linkKind: LinkKind,
        isUp: Bool,
        isRunning: Bool,
        supportsMulticast: Bool,
        ipv4Addresses: [String],
        ipv4CIDRs: [String],
        primaryIPv4Address: String? = nil,
        primaryIPv4CIDR: String? = nil,
        matchesShowNetwork: Bool,
        isRecommended: Bool = false
    ) {
        self.id = id
        self.serviceName = serviceName
        self.bsdName = bsdName
        self.hardwarePortLabel = hardwarePortLabel
        self.displayName = displayName
        self.linkKind = linkKind
        self.isUp = isUp
        self.isRunning = isRunning
        self.supportsMulticast = supportsMulticast
        self.ipv4Addresses = ipv4Addresses
        self.ipv4CIDRs = ipv4CIDRs
        self.primaryIPv4Address = primaryIPv4Address
        self.primaryIPv4CIDR = primaryIPv4CIDR
        self.matchesShowNetwork = matchesShowNetwork
        self.isRecommended = isRecommended
    }

    public var livePrimaryIPv4CIDR: String? {
        primaryIPv4CIDR
    }

    public var stableDropdownLabel: String {
        var components = [hardwarePortLabel, bsdName]
        components.append(primaryIPv4CIDR ?? "no IPv4")
        if matchesShowNetwork {
            components.append("SHOW")
        }
        return components.joined(separator: " • ")
    }

    public var statusLine: String {
        stableDropdownLabel
    }

    public var serviceSummary: String {
        serviceName ?? linkKind.label
    }
}
