import Foundation

/// Where Blurt keeps its data, and the permissions/exclusions that apply to it.
///
/// Everything lives under `~/Library/Application Support/Blurt` with 0700 on
/// directories and 0600 on files. Audio is excluded from Time Machine — the
/// exclusion is re-applied on every create and move because macOS drops the
/// resource value during common file operations.
enum AppPaths {

    static let appName = "Blurt"

    /// Overridable so the CLI and tests can run against a scratch directory.
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    static var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }
    static var inflight: URL { recordings.appendingPathComponent("inflight", isDirectory: true) }
    static var done: URL { recordings.appendingPathComponent("done", isDirectory: true) }
    static var quarantine: URL { recordings.appendingPathComponent("quarantine", isDirectory: true) }
    static var historyFile: URL { root.appendingPathComponent("history.json") }
    static var vocabularyFile: URL { root.appendingPathComponent("vocabulary.json") }
    static var lockFile: URL { root.appendingPathComponent("blurt.lock") }
    static var logFile: URL { root.appendingPathComponent("blurt.log") }

    static var allDirectories: [URL] { [root, recordings, inflight, done, quarantine] }

    /// Creates the directory tree if needed. Safe to call repeatedly.
    @discardableResult
    static func ensure() -> Bool {
        let fm = FileManager.default
        migrateFromParakeetIfNeeded(fm)
        do {
            for dir in allDirectories {
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(
                        at: dir, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                } else {
                    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                }
            }
            excludeFromBackup(recordings)
            // Best effort; modern Spotlight largely ignores this, but it costs nothing.
            let marker = recordings.appendingPathComponent(".metadata_never_index")
            if !fm.fileExists(atPath: marker.path) {
                fm.createFile(atPath: marker.path, contents: Data())
            }
            return true
        } catch {
            Log.error("AppPaths.ensure failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The app began life as "Parakeet" before the model lent its name back.
    /// Carry an existing data folder (history, learned rules, recordings)
    /// across the rename, once, before anything is created at the new path.
    private static func migrateFromParakeetIfNeeded(_ fm: FileManager) {
        guard rootOverride == nil else { return }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Parakeet", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: root.path) else { return }
        try? fm.moveItem(at: old, to: root)
    }

    /// Marks a file or directory as excluded from Time Machine backups.
    /// Must be re-applied after every create/move — the flag does not survive them.
    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// Tightens permissions on a freshly created file.
    static func protectFile(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        excludeFromBackup(url)
    }

    static func revealInFinder() {
        ensure()
        NSWorkspaceReveal.reveal(root)
    }
}

/// Tiny indirection so `AppPaths` stays usable from the command-line target,
/// where pulling in AppKit for one call would be silly.
enum NSWorkspaceReveal {
    static func reveal(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.path]
        try? p.run()
    }
}
