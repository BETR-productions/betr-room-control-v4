// RoomControlXPCContracts — re-exports BETRCoreXPC + app-specific extensions.

@_exported import BETRCoreXPC
import Foundation

/// App-specific XPC service identifiers for Room Control v4.
public enum RoomControlXPC {
    public static let serviceName = BETRCoreXPCIdentifiers.agentServiceName
}
