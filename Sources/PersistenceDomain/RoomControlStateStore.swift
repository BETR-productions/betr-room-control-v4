import Foundation

public actor RoomControlStateStore {
    private let rootDirectory: String
    private let fileManager: FileManager

    public init(
        rootDirectory: String,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    public func load() -> RoomControlPersistedState {
        let stateURL = URL(fileURLWithPath: statePath)
        guard let data = try? Data(contentsOf: stateURL) else {
            return RoomControlPersistedState()
        }
        return (try? JSONDecoder.iso8601.decode(RoomControlPersistedState.self, from: data))
            ?? RoomControlPersistedState()
    }

    @discardableResult
    public func save(_ state: RoomControlPersistedState) throws -> String {
        try fileManager.createDirectory(
            atPath: rootDirectory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.prettyPrinted.encode(state)
        try data.write(to: URL(fileURLWithPath: statePath), options: [.atomic])
        return statePath
    }

    public var statePath: String {
        URL(fileURLWithPath: rootDirectory)
            .appendingPathComponent("room-control-state.json", isDirectory: false)
            .path
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
