import Foundation

/// The learning loop's memory. Entirely on disk, entirely local.
///
/// Three layers, from explicit to inferred:
/// - **terms** you typed in ("GitHub", "Supabase") — fuzzy-matched forever;
/// - **rules** — exact replacements, either typed or learned;
/// - **pending pairs** — corrections observed in history edits. The same fix
///   seen `promotionThreshold` times graduates into a rule, and the dashboard
///   shows exactly what was learned so it can be vetoed.
final class VocabularyStore {

    struct PendingPair: Codable, Equatable {
        var heard: String
        var corrected: String
        var count: Int
        var lastSeen: Date
    }

    private struct Payload: Codable {
        var terms: [VocabTerm] = []
        var rules: [CorrectionRule] = []
        var pending: [PendingPair] = []
    }

    static let promotionThreshold = 2

    private let url: URL
    private let lock = NSLock()
    private var payload = Payload()

    var onChange: (@Sendable () -> Void)?

    init(url: URL = AppPaths.vocabularyFile) {
        self.url = url
        load()
    }

    // MARK: - Reading

    var terms: [VocabTerm] {
        lock.lock(); defer { lock.unlock() }
        return payload.terms
    }

    var rules: [CorrectionRule] {
        lock.lock(); defer { lock.unlock() }
        return payload.rules
    }

    var enabledRules: [CorrectionRule] {
        lock.lock(); defer { lock.unlock() }
        return payload.rules.filter(\.enabled)
    }

    // MARK: - Terms

    func addTerm(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        let exists = payload.terms.contains { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }
        if !exists { payload.terms.append(VocabTerm(text: trimmed)) }
        lock.unlock()
        if !exists { persistAndNotify() }
    }

    func removeTerm(id: UUID) {
        lock.lock()
        payload.terms.removeAll { $0.id == id }
        lock.unlock()
        persistAndNotify()
    }

    // MARK: - Rules

    func addRule(heard: String, replacement: String, source: CorrectionRule.Source) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !r.isEmpty, h.caseInsensitiveCompare(r) != .orderedSame else { return }
        lock.lock()
        if let index = payload.rules.firstIndex(where: {
            $0.heard.caseInsensitiveCompare(h) == .orderedSame
        }) {
            payload.rules[index].replacement = r
            payload.rules[index].enabled = true
        } else {
            payload.rules.append(CorrectionRule(heard: h, replacement: r, source: source))
        }
        lock.unlock()
        persistAndNotify()
    }

    func setRule(id: UUID, enabled: Bool) {
        lock.lock()
        if let index = payload.rules.firstIndex(where: { $0.id == id }) {
            payload.rules[index].enabled = enabled
        }
        lock.unlock()
        persistAndNotify()
    }

    func removeRule(id: UUID) {
        lock.lock()
        payload.rules.removeAll { $0.id == id }
        lock.unlock()
        persistAndNotify()
    }

    func recordHits(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        for id in ids {
            if let index = payload.rules.firstIndex(where: { $0.id == id }) {
                payload.rules[index].hits += 1
            }
        }
        lock.unlock()
        persistAndNotify()
    }

    // MARK: - Learning from edits

    /// Feed an edit in; get back any rules that just graduated.
    @discardableResult
    func learn(from old: String, to new: String) -> [CorrectionRule] {
        let changes = WordDiff.changes(from: old, to: new)
        guard !changes.isEmpty else { return [] }

        var promoted: [CorrectionRule] = []
        lock.lock()
        for change in changes {
            let key = change.heard.lowercased()

            // Already covered by a rule? Nothing to learn.
            if payload.rules.contains(where: { $0.heard.lowercased() == key }) { continue }

            if let index = payload.pending.firstIndex(where: {
                $0.heard.lowercased() == key
                    && $0.corrected.caseInsensitiveCompare(change.corrected) == .orderedSame
            }) {
                payload.pending[index].count += 1
                payload.pending[index].lastSeen = Date()
                if payload.pending[index].count >= Self.promotionThreshold {
                    let rule = CorrectionRule(
                        heard: change.heard, replacement: change.corrected, source: .learned)
                    payload.rules.append(rule)
                    promoted.append(rule)
                    payload.pending.remove(at: index)
                }
            } else {
                // A different correction for the same heard-form resets the
                // count — the evidence is contradictory, not accumulating.
                payload.pending.removeAll { $0.heard.lowercased() == key }
                payload.pending.append(
                    PendingPair(
                        heard: change.heard, corrected: change.corrected,
                        count: 1, lastSeen: Date()))
            }
        }
        // Old half-observed pairs eventually stop mattering.
        let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
        payload.pending.removeAll { $0.lastSeen < cutoff }
        lock.unlock()

        persistAndNotify()
        if !promoted.isEmpty {
            // Count only — rule text is the user's vocabulary, and the log
            // promises to carry states and timings, never transcript words.
            Log.info("Learned \(promoted.count) correction rule(s) from edits")
        }
        return promoted
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(
                at: url, to: url.appendingPathExtension("corrupt-\(stamp)"))
            Log.error("Vocabulary file unreadable — starting fresh, original kept")
            payload = Payload()
        }
    }

    /// Everything the store knows, gone — part of "Delete All Blurt Data".
    func clearAll() {
        lock.lock()
        payload = Payload()
        lock.unlock()
        persistAndNotify()
    }

    /// Writes are serialized so concurrent mutations (UI adds, pipeline hit
    /// counting, history-edit learning) can never persist out of order.
    private let persistQueue = DispatchQueue(label: "com.alexspitz.blurt.vocabulary.persist")

    private func persistAndNotify() {
        lock.lock()
        let snapshot = payload
        lock.unlock()

        persistQueue.sync { self.write(snapshot) }
        onChange?()
    }

    private func write(_ snapshot: Payload) {
        AppPaths.ensure()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
            Log.error("Could not save vocabulary: \(error.localizedDescription)")
        }
    }
}
