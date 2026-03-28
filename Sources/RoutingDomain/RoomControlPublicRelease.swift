import CoreNDIPlatform
import Foundation

public enum RoomControlPublicRelease {
    public static let identity = BETRReleaseIdentities.roomControl
    public static let appName = identity.appName
    public static let bundleIdentifier = identity.bundleIdentifier
    public static let teamIdentifier = identity.signingTeamIdentifier
    public static let releaseRepository = identity.releaseRepository
    public static let firstRebuiltPublicVersion = identity.firstRebuiltPublicVersion
    public static let bridgeVersion = RoomControlReleaseVersioning.bridgeVersion
    public static let firstDateVersion = RoomControlReleaseVersioning.firstDateVersion
}
