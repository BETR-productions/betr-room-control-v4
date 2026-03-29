import Foundation

public struct DiscoveryServerDraftEntry: Sendable, Equatable, Hashable, Identifiable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host.lowercased()
        self.port = port
    }

    public var id: String { normalizedEndpoint }

    public var normalizedEndpoint: String {
        "\(host):\(port)"
    }
}

public enum DiscoveryServerDraftError: LocalizedError, Sendable, Equatable {
    case invalidEntry(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEntry:
            return "Enter a valid Discovery Server like 192.168.55.11 or 192.168.55.11:5959."
        }
    }
}

public enum DiscoveryServerVisualState: String, Sendable, Equatable {
    case draftOnly
    case connected
    case warning
    case error
}

public struct DiscoveryServerPresentationEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let visualState: DiscoveryServerVisualState
    public let statusWord: String
    public let detailText: String?
    public let validatedAddress: String?

    public init(
        id: String,
        label: String,
        visualState: DiscoveryServerVisualState,
        statusWord: String,
        detailText: String? = nil,
        validatedAddress: String? = nil
    ) {
        self.id = id
        self.label = label
        self.visualState = visualState
        self.statusWord = statusWord
        self.detailText = detailText
        self.validatedAddress = validatedAddress
    }
}

public struct DiscoveryAggregateStatus: Sendable, Equatable {
    public let usesMDNSOnly: Bool
    public let healthyCount: Int
    public let totalCount: Int

    public init(
        usesMDNSOnly: Bool = false,
        healthyCount: Int = 0,
        totalCount: Int = 0
    ) {
        self.usesMDNSOnly = usesMDNSOnly
        self.healthyCount = healthyCount
        self.totalCount = totalCount
    }

    public var visualState: DiscoveryServerVisualState {
        if usesMDNSOnly {
            return .draftOnly
        }
        if healthyCount == totalCount, totalCount > 0 {
            return .connected
        }
        if healthyCount > 0 {
            return .warning
        }
        return .error
    }

    public var label: String {
        if usesMDNSOnly {
            return "mDNS"
        }
        return "DISCOVERY \(healthyCount)/\(totalCount)"
    }
}

public enum DiscoveryServerDraftCodec {
    public static func strictEntries(from rawInput: String) throws -> [DiscoveryServerDraftEntry] {
        let tokens = tokenize(rawInput)
        guard tokens.isEmpty == false else { return [] }

        var entries: [DiscoveryServerDraftEntry] = []
        for token in tokens {
            entries.append(try parse(token))
        }
        return dedupe(entries)
    }

    public static func normalizedEntries(from text: String) -> [DiscoveryServerDraftEntry] {
        let tokens = tokenize(text)
        return dedupe(tokens.compactMap { try? parse($0) })
    }

    public static func normalizedText(from text: String) -> String {
        normalizedText(from: normalizedEntries(from: text))
    }

    public static func normalizedText(from entries: [DiscoveryServerDraftEntry]) -> String {
        dedupe(entries).map(\.normalizedEndpoint).joined(separator: "\n")
    }

    public static func merge(rawInput: String, into existingText: String) throws -> String {
        let incoming = try strictEntries(from: rawInput)
        let existing = normalizedEntries(from: existingText)
        return normalizedText(from: existing + incoming)
    }

    public static func remove(normalizedEndpoint: String, from existingText: String) -> String {
        normalizedText(from: normalizedEntries(from: existingText).filter { $0.normalizedEndpoint != normalizedEndpoint })
    }

    public static func canSafelyNormalize(_ text: String) -> Bool {
        let tokens = tokenize(text)
        guard tokens.isEmpty == false else { return true }
        return tokens.count == normalizedEntries(from: text).count
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func parse(_ rawValue: String) throws -> DiscoveryServerDraftEntry {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw DiscoveryServerDraftError.invalidEntry(rawValue)
        }

        let candidate = trimmed.contains("://") ? trimmed : "ndi://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil
        else {
            throw DiscoveryServerDraftError.invalidEntry(rawValue)
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || path == "/" else {
            throw DiscoveryServerDraftError.invalidEntry(rawValue)
        }

        let port = components.port ?? 5959
        guard (1...65_535).contains(port) else {
            throw DiscoveryServerDraftError.invalidEntry(rawValue)
        }

        return DiscoveryServerDraftEntry(host: host, port: port)
    }

    private static func dedupe(_ entries: [DiscoveryServerDraftEntry]) -> [DiscoveryServerDraftEntry] {
        var seen: Set<String> = []
        var result: [DiscoveryServerDraftEntry] = []
        for entry in entries {
            if seen.insert(entry.normalizedEndpoint).inserted {
                result.append(entry)
            }
        }
        return result
    }
}

public enum DiscoveryServerPresentationBuilder {
    public static func entries(
        configuredText: String,
        runtimeRows: [NDIWizardDiscoveryServerRow]
    ) -> [DiscoveryServerPresentationEntry] {
        let configuredEntries = DiscoveryServerDraftCodec.normalizedEntries(from: configuredText)
        let runtimeByEndpoint = Dictionary(runtimeRows.map { ($0.normalizedEndpoint, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        return configuredEntries.map { entry in
            makeEntry(for: entry, runtimeRow: runtimeByEndpoint[entry.normalizedEndpoint])
        }
    }

    public static func aggregate(
        configuredText: String,
        runtimeRows: [NDIWizardDiscoveryServerRow],
        mdnsEnabled: Bool
    ) -> DiscoveryAggregateStatus {
        let entries = entries(configuredText: configuredText, runtimeRows: runtimeRows)
        if entries.isEmpty {
            return DiscoveryAggregateStatus(usesMDNSOnly: mdnsEnabled, healthyCount: 0, totalCount: 0)
        }

        let healthyCount = entries.filter { $0.visualState == .connected }.count
        return DiscoveryAggregateStatus(
            usesMDNSOnly: false,
            healthyCount: healthyCount,
            totalCount: entries.count
        )
    }

    public static func sortedForPopover(_ entries: [DiscoveryServerPresentationEntry]) -> [DiscoveryServerPresentationEntry] {
        entries.sorted { lhs, rhs in
            let lhsRank = rank(for: lhs.visualState)
            let rhsRank = rank(for: rhs.visualState)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private static func makeEntry(
        for entry: DiscoveryServerDraftEntry,
        runtimeRow: NDIWizardDiscoveryServerRow?
    ) -> DiscoveryServerPresentationEntry {
        guard let runtimeRow else {
            return DiscoveryServerPresentationEntry(
                id: entry.normalizedEndpoint,
                label: entry.normalizedEndpoint,
                visualState: .draftOnly,
                statusWord: "DRAFT",
                detailText: "Apply this server to bring up live listener status."
            )
        }

        return DiscoveryServerPresentationEntry(
            id: runtimeRow.normalizedEndpoint,
            label: runtimeRow.normalizedEndpoint,
            visualState: runtimeRow.discoveryVisualState,
            statusWord: runtimeRow.discoveryStatusWord,
            detailText: runtimeRow.discoveryDetailText,
            validatedAddress: runtimeRow.validatedAddress
        )
    }

    private static func rank(for visualState: DiscoveryServerVisualState) -> Int {
        switch visualState {
        case .error:
            return 0
        case .warning:
            return 1
        case .draftOnly:
            return 2
        case .connected:
            return 3
        }
    }
}

public extension NDIWizardDiscoveryServerRow {
    private var hasListenerBringUpEvidence: Bool {
        senderListenerConnected
            || receiverListenerConnected
            || senderListenerAttached
            || receiverListenerAttached
            || validatedAddress != nil
            || listenerLifecycleState == "attaching"
            || listenerLifecycleState == "attached_waiting"
    }

    var discoveryVisualState: DiscoveryServerVisualState {
        if senderListenerConnected && receiverListenerConnected {
            return .connected
        }
        if listenerLifecycleState == "attached_waiting" || listenerLifecycleState == "attaching" {
            return .warning
        }
        if listenerLifecycleState == "degraded" {
            return hasListenerBringUpEvidence ? .warning : .error
        }
        if hasListenerBringUpEvidence {
            return .warning
        }
        if senderAttachFailureReason != nil || receiverAttachFailureReason != nil {
            return .error
        }
        return .warning
    }

    var discoveryStatusWord: String {
        switch discoveryVisualState {
        case .draftOnly:
            return "DRAFT"
        case .connected:
            return "CONNECTED"
        case .warning:
            if listenerLifecycleState == "attaching" || listenerLifecycleState == "attached_waiting" {
                return "WAITING"
            }
            return "CHECK"
        case .error:
            return "ERROR"
        }
    }

    var discoveryLifecycleLabel: String {
        Self.prettyLabel(from: listenerLifecycleState)
    }

    var discoveryDetailText: String {
        if discoveryVisualState == .connected {
            return validatedAddress.map { "Validated on \($0)." } ?? "Both listeners are connected."
        }
        if let degradedReason, degradedReason.isEmpty == false {
            return "\(Self.prettyLabel(from: degradedReason))."
        }
        if let failure = senderAttachFailureReason?.nilIfEmpty ?? receiverAttachFailureReason?.nilIfEmpty {
            return "\(Self.prettyLabel(from: failure))."
        }
        if senderListenerConnected != receiverListenerConnected {
            return "Only one listener is fully connected."
        }
        if listenerLifecycleState == "attaching" || listenerLifecycleState == "attached_waiting" {
            return "Listener is attached and waiting for a full connection."
        }
        if senderListenerAttached || receiverListenerAttached {
            return "Listener is attached but not fully connected yet."
        }
        if validatedAddress == nil {
            return "No listener instance is live yet."
        }
        return "\(discoveryLifecycleLabel)."
    }

    private static func prettyLabel(from rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { fragment in
                let word = String(fragment)
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

public extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
