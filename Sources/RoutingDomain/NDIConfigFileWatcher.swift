// NDIConfigFileWatcher — pure FSEvents watcher for NDI config files.
// No polling. Uses DispatchSource.makeFileSystemObjectSource for real-time
// notification when NDI config files change on disk.

import Foundation
import os

/// Watches an NDI config file via FSEvents (DispatchSource).
/// Publishes change events via AsyncStream. Never polls.
public actor NDIConfigFileWatcher {
    private static let log = Logger(subsystem: "com.betr.room-control", category: "NDIConfigFileWatcher")

    private let filePath: String
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let changeContinuation: AsyncStream<Void>.Continuation
    public nonisolated let changes: AsyncStream<Void>

    public init(filePath: String) {
        self.filePath = filePath
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.changes = stream
        self.changeContinuation = continuation
    }

    deinit {
        stopWatching()
        changeContinuation.finish()
    }

    /// Start watching the file. Creates a DispatchSource for file system events.
    public func startWatching() {
        guard source == nil else { return }

        // Ensure parent directory exists
        let directory = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // Touch the file if it doesn't exist so we can get a file descriptor
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil)
        }

        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            Self.log.error("Failed to open \(self.filePath) for FSEvents monitoring (errno=\(errno))")
            return
        }
        fileDescriptor = fd

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )

        dispatchSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleFileChange() }
        }

        dispatchSource.setCancelHandler { [fd] in
            close(fd)
        }

        dispatchSource.resume()
        source = dispatchSource
        Self.log.info("FSEvents watcher started for \(self.filePath)")
    }

    /// Stop watching.
    public func stopWatching() {
        source?.cancel()
        source = nil
        // File descriptor is closed by the cancel handler
        fileDescriptor = -1
    }

    private func handleFileChange() {
        Self.log.info("Config file changed: \(self.filePath)")
        changeContinuation.yield(())

        // If file was deleted/renamed, re-establish watch
        if let source, source.data.contains(.delete) || source.data.contains(.rename) {
            Self.log.info("File deleted/renamed — re-establishing watcher")
            stopWatching()
            Task { await startWatching() }
        }
    }
}
