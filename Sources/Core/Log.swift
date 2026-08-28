import Foundation
import os

/// Console logging plus a small rotating file log, so a freeze that happens
/// while nobody is watching Console.app still leaves a trail.
enum Log {

    private static let logger = Logger(subsystem: "com.alexspitz.blurt", category: "app")
    private static let queue = DispatchQueue(label: "com.alexspitz.blurt.log")
    private static let maxBytes = 512 * 1024

    nonisolated(unsafe) static var echoToStdout = false

    static func info(_ message: String) { emit("INFO", message) }
    static func error(_ message: String) { emit("ERROR", message) }
    static func debug(_ message: String) { emit("DEBUG", message) }

    private static func emit(_ level: String, _ message: String) {
        switch level {
        case "ERROR": logger.error("\(message, privacy: .public)")
        case "DEBUG": logger.debug("\(message, privacy: .public)")
        default: logger.info("\(message, privacy: .public)")
        }
        if echoToStdout {
            print("[\(level)] \(message)")
        }
        queue.async { appendToFile(level: level, message: message) }
    }

    private static func appendToFile(level: String, message: String) {
        let url = AppPaths.logFile
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard AppPaths.ensure() else { return }
            fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            // The log carries app names and timings — never transcript text —
            // but there is no reason for it to ride into backups either.
            AppPaths.excludeFromBackup(url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            if let size = try? handle.offset(), size > maxBytes {
                try? handle.truncate(atOffset: 0)
            }
        }
    }
}
