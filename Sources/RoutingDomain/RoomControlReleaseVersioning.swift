import Foundation

public enum RoomControlReleaseTrack: String, Codable, Sendable {
    case legacy
    case bridge
    case date
}

public enum RoomControlReleaseVersioning {
    public static let releaseTrackInfoKey = "BETRReleaseTrack"
    public static let updateSequenceInfoKey = "BETRUpdateSequence"
    public static let bridgeVersion = "0.9.8.57"
    public static let firstDateVersion = "0.3.23.2"
    public static let releaseTrackMarkerPrefix = "BETR-Release-Track:"
    public static let updateSequenceMarkerPrefix = "BETR-Update-Sequence:"

    public static func canonicalVersion(_ raw: String) -> String {
        if raw.hasPrefix(".") {
            return "0\(raw)"
        }
        return raw
    }

    public static func compareNumericVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = normalizedVersionParts(lhs)
        let rhsParts = normalizedVersionParts(rhs)

        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    public static func inferredTrack(
        versionArgument: String?,
        canonicalVersion: String,
        explicitTrack: RoomControlReleaseTrack?
    ) -> RoomControlReleaseTrack {
        if let explicitTrack {
            return explicitTrack
        }
        if canonicalVersion == bridgeVersion {
            return .bridge
        }
        if versionArgument?.hasPrefix(".") == true {
            return .date
        }
        return .legacy
    }

    public static func defaultUpdateSequence(
        canonicalVersion: String,
        track: RoomControlReleaseTrack,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        switch track {
        case .bridge:
            return sequenceString(year: calendar.component(.year, from: now), month: calendar.component(.month, from: now), day: calendar.component(.day, from: now), build: 1)
        case .date:
            let parts = normalizedVersionParts(canonicalVersion)
            let month = parts.count > 1 ? parts[1] : calendar.component(.month, from: now)
            let day = parts.count > 2 ? parts[2] : calendar.component(.day, from: now)
            let build = parts.count > 3 ? parts[3] : 1
            return sequenceString(year: calendar.component(.year, from: now), month: month, day: day, build: build)
        case .legacy:
            return "0"
        }
    }

    public static func parseTrack(from body: String?) -> RoomControlReleaseTrack? {
        guard let body else { return nil }
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(releaseTrackMarkerPrefix) else { continue }
            let rawValue = trimmed.dropFirst(releaseTrackMarkerPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return RoomControlReleaseTrack(rawValue: rawValue)
        }
        return nil
    }

    public static func parseUpdateSequence(from body: String?) -> Int? {
        guard let body else { return nil }
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(updateSequenceMarkerPrefix) else { continue }
            let rawValue = trimmed.dropFirst(updateSequenceMarkerPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(rawValue)
        }
        return nil
    }

    public static func parseUpdateSequence(fromInfoDictionary infoDictionary: [String: Any]?) -> Int? {
        guard let rawValue = infoDictionary?[updateSequenceInfoKey] as? String else {
            return nil
        }
        return Int(rawValue)
    }

    public static func parseTrack(fromInfoDictionary infoDictionary: [String: Any]?) -> RoomControlReleaseTrack {
        guard let rawValue = infoDictionary?[releaseTrackInfoKey] as? String,
              let track = RoomControlReleaseTrack(rawValue: rawValue) else {
            return .legacy
        }
        return track
    }

    public static func isCandidateNewer(
        candidateVersion: String,
        candidateUpdateSequence: Int?,
        installedVersion: String,
        installedUpdateSequence: Int?
    ) -> Bool {
        if let candidateUpdateSequence, let installedUpdateSequence {
            return candidateUpdateSequence > installedUpdateSequence
        }
        return compareNumericVersions(candidateVersion, installedVersion) == .orderedDescending
    }

    private static func normalizedVersionParts(_ raw: String) -> [Int] {
        canonicalVersion(raw).split(separator: ".").compactMap { Int($0) }
    }

    private static func sequenceString(year: Int, month: Int, day: Int, build: Int) -> String {
        String(format: "%04d%02d%02d%02d", year, month, day, build)
    }
}
