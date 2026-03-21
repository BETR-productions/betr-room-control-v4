// NDIWizardTypes — validation enums and snapshot types for the NDI wizard.
// Preserved from v3 NDIWizardValidation.swift, made self-contained for v4.

import Foundation
import SwiftUI

// MARK: - Check State

public enum NDIWizardCheckState: String, Equatable, Sendable {
    case passed
    case warning
    case blocked
}

// MARK: - Wizard Step

public enum NDIWizardStep: String, CaseIterable, Equatable, Sendable {
    case baseline
    case interface
    case discovery
    case identity
    case apply
    case validate

    var title: String {
        switch self {
        case .baseline:  return "Room Defaults"
        case .interface: return "Interface"
        case .discovery: return "Discovery + Multicast"
        case .identity:  return "Naming + Advanced"
        case .apply:     return "Apply + Restart"
        case .validate:  return "Validate"
        }
    }

    var subtitle: String {
        switch self {
        case .baseline:  return "Load or reset the BETR room baseline."
        case .interface: return "Lock BETR onto the actual show NIC."
        case .discovery: return "Configure Discovery Server and multicast."
        case .identity:  return "Set names, groups, and uncommon controls."
        case .apply:     return "Write the config and relaunch cleanly."
        case .validate:  return "Prove runtime truth on the host."
        }
    }

    var description: String {
        switch self {
        case .baseline:
            return "Choose BETR room defaults, reload the saved profile, or hard-reset BETR-owned NDI state before doing anything else."
        case .interface:
            return "Pick the actual room NIC BETR should own. This is what discovery, multicast, and receive will use."
        case .discovery:
            return "Set Discovery Server and multicast together so the same committed profile can both find sources and receive the traffic."
        case .identity:
            return "Review names operators will see and any advanced filters or takeover controls that could narrow or alter visibility."
        case .apply:
            return "Commit the config, run the network plan, and relaunch BETR from that exact committed state."
        case .validate:
            return "Validate the remote host's actual runtime truth: NIC, route owner, discovery state, source visibility, and isolated proof."
        }
    }
}

// MARK: - Discovery State

public enum NDIWizardDiscoveryState: String, Equatable, Sendable {
    case noDiscoveryConfigured
    case tcpUnreachable
    case listenerCreateFailed
    case listenerAttachedNotConnected
    case finderVisibleListenerDegraded
    case connectedNoSendersVisible
    case connectedAndSendersVisible

    public var checkState: NDIWizardCheckState {
        switch self {
        case .connectedAndSendersVisible: return .passed
        case .noDiscoveryConfigured: return .warning
        case .tcpUnreachable, .listenerCreateFailed: return .blocked
        case .listenerAttachedNotConnected, .finderVisibleListenerDegraded, .connectedNoSendersVisible: return .warning
        }
    }

    public var summary: String {
        switch self {
        case .noDiscoveryConfigured:
            return "No Discovery Server is configured for the current runtime path."
        case .tcpUnreachable:
            return "BETR could not reach the configured Discovery Server over TCP."
        case .listenerCreateFailed:
            return "BETR reached the Discovery Server, but native sender or receiver listener creation did not stick."
        case .listenerAttachedNotConnected:
            return "BETR attached listeners, but they have not connected to the server yet."
        case .finderVisibleListenerDegraded:
            return "BETR can see sources, but listener telemetry has not reached a fully connected state."
        case .connectedNoSendersVisible:
            return "BETR connected both listeners, but no visible senders were reported yet."
        case .connectedAndSendersVisible:
            return "BETR connected both listeners and visible senders are being reported."
        }
    }

    public var badgeLabel: String {
        switch self {
        case .connectedAndSendersVisible: return "DISCOVERY LIVE"
        case .finderVisibleListenerDegraded: return "DISCOVERY WARN"
        case .connectedNoSendersVisible: return "DISCOVERY EMPTY"
        case .listenerAttachedNotConnected: return "LISTENERS WAITING"
        case .listenerCreateFailed: return "LISTENER FAILED"
        case .tcpUnreachable: return "DISCOVERY TCP"
        case .noDiscoveryConfigured: return "DISCOVERY SETUP"
        }
    }
}

// MARK: - Discovery Mode

public enum NDIDiscoveryMode: String, Sendable {
    case discoveryServerFirst
    case discoveryServerOnly
    case mdnsOnly
}

// MARK: - Ownership Mode

public enum NDIHostOwnershipMode: String, Sendable {
    case betrOnly
    case globalTakeover
}

// MARK: - Multicast Route State

public enum NDIMulticastRouteCheckState: Equatable, Sendable {
    case passed
    case warning
    case blocked

    public var wizardState: NDIWizardCheckState {
        switch self {
        case .passed: return .passed
        case .warning: return .warning
        case .blocked: return .blocked
        }
    }
}

// MARK: - Network Interface

public struct NDINetworkInterface: Identifiable, Equatable, Sendable {
    public let id: String
    public let bsdName: String
    public let hardwarePortLabel: String
    public let serviceName: String
    public let livePrimaryIPv4CIDR: String?
    public let matchesShowNetwork: Bool
    public let isRecommended: Bool
    public let supportsMulticast: Bool

    public var stableDropdownLabel: String {
        "\(hardwarePortLabel) (\(bsdName)) — \(livePrimaryIPv4CIDR ?? "no IP")"
    }

    public init(
        id: String,
        bsdName: String,
        hardwarePortLabel: String,
        serviceName: String = "",
        livePrimaryIPv4CIDR: String? = nil,
        matchesShowNetwork: Bool = false,
        isRecommended: Bool = false,
        supportsMulticast: Bool = true
    ) {
        self.id = id
        self.bsdName = bsdName
        self.hardwarePortLabel = hardwarePortLabel
        self.serviceName = serviceName
        self.livePrimaryIPv4CIDR = livePrimaryIPv4CIDR
        self.matchesShowNetwork = matchesShowNetwork
        self.isRecommended = isRecommended
        self.supportsMulticast = supportsMulticast
    }
}

// MARK: - Validation Snapshot

public struct NDIWizardValidationSnapshot: Equatable, Sendable {
    public var discoveryState: NDIWizardDiscoveryState = .noDiscoveryConfigured
    public var multicastRouteState: NDIMulticastRouteCheckState = .blocked
    public var multicastRouteOwner: String?
    public var configMatches: Bool = false
    public var runtimeFingerprint: String?
    public var expectedFingerprint: String?
    public var sdkVersion: String?
    public var finderSourceCount: Int = 0
    public var senderListenerConnected: Bool = false
    public var receiverListenerConnected: Bool = false
    public var overallReady: Bool = false

    public var configState: NDIWizardCheckState {
        configMatches ? .passed : .blocked
    }
}

// MARK: - Host Draft

public struct NDIHostDraft: Equatable, Sendable {
    public var showLocationName: String = ""
    public var showNetworkCIDR: String = "192.168.55.0/24"
    public var selectedInterfaceID: String = ""
    public var ownershipMode: NDIHostOwnershipMode = .betrOnly
    public var discoveryMode: NDIDiscoveryMode = .discoveryServerFirst
    public var discoveryServersText: String = ""
    public var mdnsEnabled: Bool = true
    public var multicastEnabled: Bool = true
    public var multicastReceiveEnabled: Bool = true
    public var multicastTransmitEnabled: Bool = true
    public var multicastPrefix: String = "239.255.0.0"
    public var multicastNetmask: String = "255.255.0.0"
    public var multicastTTL: Int = 4
    public var receiveSubnetsText: String = ""
    public var nodeLabel: String = "BETR"
    public var senderPrefix: String = "BETR"
    public var outputPrefix: String = "Output"
    public var groupsText: String = ""
    public var sourceFilter: String = ""
    public var extraIPsText: String = ""
    public var disableWiFiInProofMode: Bool = false
    public var disableBridgeServicesInProofMode: Bool = false

    public init() {}
}
