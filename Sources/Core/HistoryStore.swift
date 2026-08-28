import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var text: String
    var duration: Double
    var recovered: Bool
    var confidence: Double?
    /// What the model originally produced, kept whenever corrections, tidying
    /// or a hand edit changed `text`. Optional so old history files still load.
    var rawText: String?

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
}

/// The transcript list behind the dashboard's History tab.
///
/// Keyed by the recording's job id and **upserted**, never appended blindly —
/// that is what stops a crash between "wrote history" and "cleaned up the WAV"
/// from producing the same dictation twice after recovery.
final class HistoryStore {

    static let maxEntries = 500

    private let url: URL
    private let lock = NSLock()
    private var entries: [HistoryEntry] = []

    /// Fired on an arbitrary thread after any mutation.
    var onChange: (@Sendable ([HistoryEntry]) -> Void)?

    init(url: URL = AppPaths.historyFile) {
        self.url = url
        load()
    }

    var all: [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func search(_ query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    /// Best-effort upsert for UI edits: a failed write is logged, and memory
    /// keeps the newer value so the user's edit is not visibly swallowed.
    @discardableResult
    func upsert(_ entry: HistoryEntry) -> [HistoryEntry] {
        let snapshot = mutate { entries in
            Self.apply(entry, to: &entries)
        }
        try? persistOrdered(snapshot)
        onChange?(snapshot)
        return snapshot
    }

    /// The commit pipeline's upsert: returns only once the snapshot is on
    /// disk, throws when it is not. The caller must not scrub the transcript's
    /// other copies or advance the job past `.transcribed` on failure —
    /// otherwise the UI would show history that never survived a relaunch.
    func upsertDurably(_ entry: HistoryEntry) throws {
        let snapshot = mutate { entries in
            Self.apply(entry, to: &entries)
        }
        do {
            try persistOrdered(snapshot)
        } catch {
            // Roll memory back so the UI never shows an entry that has no
            // durable backing; the job stays retryable instead.
            let rolledBack = mutate { entries in
                entries.removeAll { $0.id == entry.id }
            }
            onChange?(rolledBack)
            throw error
        }
        onChange?(snapshot)
    }

    func delete(id: UUID) {
        let snapshot = mutate { entries in
            entries.removeAll { $0.id == id }
        }
        try? persistOrdered(snapshot)
        onChange?(snapshot)
    }

    func clear() {
        let snapshot = mutate { entries in entries = [] }
        try? persistOrdered(snapshot)
        onChange?(snapshot)
    }

    private static func apply(_ entry: HistoryEntry, to entries: inout [HistoryEntry]) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast(entries.count - maxEntries)
            }
        }
        entries.sort { $0.date > $1.date }
    }

    private func mutate(_ change: (inout [HistoryEntry]) -> Void) -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        change(&entries)
        return entries
    }

    func contains(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.id == id }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            // Never lose a corrupt file silently — park it and carry on.
            let stamp = Int(Date().timeIntervalSince1970)
            let quarantined = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: quarantined)
            Log.error("History file unreadable, moved to \(quarantined.lastPathComponent)")
            entries = []
        }
    }

    /// Writes go through one serial queue, so concurrent mutations from the
    /// UI and the transcription pipeline can never land on disk out of order —
    /// the last write is always the newest snapshot.
    private let persistQueue = DispatchQueue(label: "com.alexspitz.blurt.history.persist")

    private func persistOrdered(_ snapshot: [HistoryEntry]) throws {
        var failure: Error?
        persistQueue.sync {
            do {
                try write(snapshot)
            } catch {
                failure = error
                Log.error("Could not save history: \(error.localizedDescription)")
            }
        }
        if let failure { throw failure }
    }

    private func write(_ snapshot: [HistoryEntry]) throws {
        AppPaths.ensure()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(snapshot)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        AppPaths.protectFile(url)
    }
}
