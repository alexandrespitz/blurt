import Foundation

/// One dictation, from key press to delivered text.
///
/// The sidecar JSON next to each WAV is what makes recovery idempotent: it
/// records how far the job got, so a relaunch knows whether to transcribe again
/// or merely finish committing a transcript it already has.
///
///     recording → finalized → transcribed → committed
///
/// Guarantees this buys us: at-least-once transcription, exactly-once history
/// entry (history is keyed by job id and upserted), and an auto-paste that is
/// never replayed — pasting only ever happens in the live session that produced
/// the audio.
struct RecordingJob: Codable, Equatable {

    enum State: String, Codable {
        case recording    // WAV open, audio still arriving
        case finalized    // WAV header patched, audio durable
        case transcribed  // text captured in this sidecar, not yet delivered
        case committed    // history written, delivery attempted, retention pending
    }

    enum Source: String, Codable {
        case live
        case recovered
    }

    var id: UUID
    var state: State
    var startedAt: Date
    var source: Source
    var durationSeconds: Double?
    var text: String?
    var confidence: Double?
    /// Where the text was meant to go, captured when recording stopped.
    var frontAppBundleID: String?
    var frontAppPID: Int32?
    var attemptCount: Int
    var lastError: String?
    /// Set when the writer had to stop early (disk full, buffer overflow).
    /// The audio up to that point is still good.
    var truncated: Bool
    /// How this job's transcript may be delivered. nil = the normal path
    /// (paste with guards). "copy" = clipboard/history only — used for gaze
    /// utterances that never acquired a target, so they can never fall through
    /// to pasting into whatever happens to be frontmost.
    var deliveryMode: String?
    /// When the recording entered its retention window (the move to `done/`).
    /// Recovery can finish days after `startedAt`; the retention clock must
    /// start here, or a just-recovered recording would be collected minutes
    /// later. Optional so older manifests still decode.
    var retainedAt: Date?

    init(id: UUID = UUID(), source: Source = .live, startedAt: Date = Date()) {
        self.id = id
        self.state = .recording
        // Whole seconds, so the value that comes back out of the manifest is
        // the value that went in. ISO-8601 has no room for the fraction, and a
        // job that changes identity across a reload is a job that can be
        // committed twice.
        self.startedAt = Date(timeIntervalSince1970: startedAt.timeIntervalSince1970.rounded())
        self.source = source
        self.attemptCount = 0
        self.truncated = false
    }

    /// The moment the retention window starts counting from: the move into
    /// the keep folder when known, else the recording's start. Recovery can
    /// finish days after `startedAt` — a just-recovered recording gets its
    /// full window.
    var retentionReference: Date { retainedAt ?? startedAt }

    var wavFilename: String { "\(id.uuidString).wav" }
    var manifestFilename: String { "\(id.uuidString).json" }
}

/// Reads and writes job sidecars. Every write is atomic and fsynced, because a
/// half-written manifest is worse than no manifest.
enum JobStore {

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func wavURL(for job: RecordingJob, in directory: URL) -> URL {
        directory.appendingPathComponent(job.wavFilename)
    }

    static func manifestURL(for job: RecordingJob, in directory: URL) -> URL {
        directory.appendingPathComponent(job.manifestFilename)
    }

    static func save(_ job: RecordingJob, in directory: URL) {
        let url = manifestURL(for: job, in: directory)
        do {
            let data = try encoder.encode(job)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: [.atomic])
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            AppPaths.protectFile(url)
        } catch {
            Log.error("Could not save manifest for \(job.id): \(error.localizedDescription)")
        }
    }

    static func load(_ url: URL) -> RecordingJob? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(RecordingJob.self, from: data)
    }

    /// Every job sidecar in a directory, oldest first.
    static func loadAll(in directory: URL) -> [RecordingJob] {
        audit(in: directory).jobs
    }

    struct Audit {
        var jobs: [RecordingJob] = []
        /// Manifests that exist but do not decode. These must never be
        /// silently skipped: a corrupt sidecar would otherwise make its WAV
        /// invisible — not a job, yet not an orphan either.
        var corruptManifests: [URL] = []
    }

    /// The honest enumeration: decodable jobs oldest-first, plus every
    /// manifest that failed to decode so the caller can quarantine it and
    /// rescue the audio beside it.
    static func audit(in directory: URL) -> Audit {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return Audit()
        }
        var result = Audit()
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            if let job = load(url) {
                result.jobs.append(job)
            } else {
                result.corruptManifests.append(url)
            }
        }
        result.jobs.sort { $0.startedAt < $1.startedAt }
        return result
    }

    /// Removes the transcript from a committed manifest, keeping identity,
    /// lifecycle state and retention metadata intact — Clear History's reach
    /// into retained recordings without deleting the audio the user asked to
    /// keep.
    static func redactTranscript(_ job: RecordingJob, in directory: URL) {
        guard job.text != nil || job.confidence != nil else { return }
        var redacted = job
        redacted.text = nil
        redacted.confidence = nil
        save(redacted, in: directory)
    }

    /// WAV files with no sidecar at all — from a crash so early the manifest
    /// never landed, or an older build. They are still real audio.
    static func orphanedWavs(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let manifestIDs = Set(names.filter { $0.hasSuffix(".json") }.map {
            $0.replacingOccurrences(of: ".json", with: "")
        })
        return names
            .filter { $0.hasSuffix(".wav") }
            .filter { !manifestIDs.contains($0.replacingOccurrences(of: ".wav", with: "")) }
            .map { directory.appendingPathComponent($0) }
    }

    static func remove(_ job: RecordingJob, in directory: URL) {
        try? FileManager.default.removeItem(at: manifestURL(for: job, in: directory))
        try? FileManager.default.removeItem(at: wavURL(for: job, in: directory))
    }

    /// Moves a job's files to another directory (retention or quarantine),
    /// re-applying the backup exclusion that the move would otherwise drop.
    static func move(_ job: RecordingJob, from: URL, to: URL) {
        let fm = FileManager.default
        for url in [wavURL(for: job, in: from), manifestURL(for: job, in: from)] {
            let dest = to.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: url, to: dest)
                AppPaths.protectFile(dest)
            } catch {
                // A missing manifest is normal for orphaned WAVs.
                if fm.fileExists(atPath: url.path) {
                    Log.error("Could not move \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
}
