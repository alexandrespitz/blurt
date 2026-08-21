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

    @discardableResult
    func upsert(_ entry: HistoryEntry) -> [HistoryEntry] {
        lock.lock()
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.insert(entry, at: 0)
            if entries.count > Self.maxEntries {
                entries.removeLast(entries.count - Self.maxEntries)
            }
        }
        entries.sort { $0.date > $1.date }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
        onChange?(snapshot)
        return snapshot
    }

    func delete(id: UUID) {
        lock.lock()
        entries.removeAll { $0.id == id }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
        onChange?(snapshot)
    }

    func clear() {
        lock.lock()
        entries = []
        lock.unlock()
        persist([])
        onChange?([])
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

    private func persist(_ snapshot: [HistoryEntry]) {
        AppPaths.ensure()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(snapshot)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            AppPaths.protectFile(url)
        } catch {
            Log.error("Could not save history: \(error.localizedDescription)")
        }
    }
}
