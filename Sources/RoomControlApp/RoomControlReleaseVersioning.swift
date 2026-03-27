import Foundation

enum RoomControlReleaseTrack: String, Codable, Sendable {
    case legacy
    case bridge
    case date
}

enum RoomControlReleaseVersioning {
    static let releaseTrackInfoKey = "BETRReleaseTrack"
    static let updateSequenceInfoKey = "BETRUpdateSequence"
    static let bridgeVersion = "0.9.8.51"
    static let firstDateVersion = "0.3.23.2"
    static let releaseTrackMarkerPrefix = "BETR-Release-Track:"
    static let updateSequenceMarkerPrefix = "BETR-Update-Sequence:"

    static func canonicalVersion(_ raw: String) -> String {
        if raw.hasPrefix(".") {
            return "0\(raw)"
        }
        return raw
    }

    static func compareNumericVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
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

    static func parseTrack(from body: String?) -> RoomControlReleaseTrack? {
        guard let body else { return nil }
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(releaseTrackMarkerPrefix) else { continue }
            let rawValue = trimmed.dropFirst(releaseTrackMarkerPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return RoomControlReleaseTrack(rawValue: rawValue)
        }
        return nil
    }

    static func parseUpdateSequence(from body: String?) -> Int? {
        guard let body else { return nil }
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(updateSequenceMarkerPrefix) else { continue }
            let rawValue = trimmed.dropFirst(updateSequenceMarkerPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(rawValue)
        }
        return nil
    }

    static func parseUpdateSequence(fromInfoDictionary infoDictionary: [String: Any]?) -> Int? {
        guard let rawValue = infoDictionary?[updateSequenceInfoKey] as? String else {
            return nil
        }
        return Int(rawValue)
    }

    static func parseTrack(fromInfoDictionary infoDictionary: [String: Any]?) -> RoomControlReleaseTrack {
        guard let rawValue = infoDictionary?[releaseTrackInfoKey] as? String,
              let track = RoomControlReleaseTrack(rawValue: rawValue) else {
            return .legacy
        }
        return track
    }

    static func isCandidateNewer(
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
}
