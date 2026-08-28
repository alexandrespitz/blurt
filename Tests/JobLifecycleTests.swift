import XCTest

/// The invariant these guard: whatever moment you kill the app at, relaunching
/// converges on exactly one history entry or one visible, retryable recording —
/// never a duplicate, never a silent deletion.
final class JobLifecycleTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-jobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep the suite out of the real data folder and log.
        AppPaths.rootOverride = directory
    }

    override func tearDownWithError() throws {
        AppPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testManifestSurvivesARoundTrip() {
        var job = RecordingJob()
        job.state = .transcribed
        job.text = "bonjour, ceci est un test"
        job.durationSeconds = 3.5
        job.confidence = 0.92
        job.frontAppBundleID = "com.apple.TextEdit"

        JobStore.save(job, in: directory)
        let loaded = JobStore.load(JobStore.manifestURL(for: job, in: directory))

        XCTAssertEqual(loaded, job)
        XCTAssertEqual(loaded?.text, "bonjour, ceci est un test")
        XCTAssertEqual(loaded?.state, .transcribed)
    }

    func testLoadAllIsOldestFirst() {
        var older = RecordingJob(startedAt: Date(timeIntervalSince1970: 1000))
        var newer = RecordingJob(startedAt: Date(timeIntervalSince1970: 2000))
        older.state = .finalized
        newer.state = .finalized
        JobStore.save(newer, in: directory)
        JobStore.save(older, in: directory)

        let all = JobStore.loadAll(in: directory)
        XCTAssertEqual(all.map(\.id), [older.id, newer.id])
    }

    func testOrphanedWavIsSpotted() throws {
        // A crash between opening the file and writing the sidecar.
        let job = RecordingJob()
        let wav = JobStore.wavURL(for: job, in: directory)
        try Data(repeating: 0, count: 100).write(to: wav)

        XCTAssertEqual(JobStore.orphanedWavs(in: directory).map(\.lastPathComponent),
                       [job.wavFilename])

        JobStore.save(job, in: directory)
        XCTAssertTrue(JobStore.orphanedWavs(in: directory).isEmpty,
                      "once it has a manifest it is no longer an orphan")
    }

    func testMoveTakesBothFiles() throws {
        let destination = directory.appendingPathComponent("done")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let job = RecordingJob()
        try Data(repeating: 1, count: 64).write(to: JobStore.wavURL(for: job, in: directory))
        JobStore.save(job, in: directory)

        JobStore.move(job, from: directory, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: JobStore.wavURL(for: job, in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: JobStore.wavURL(for: job, in: destination).path))
        XCTAssertEqual(JobStore.loadAll(in: destination).count, 1)
    }

    // MARK: - Corrupt manifests must never hide audio

    func testAuditReportsCorruptManifestsInsteadOfHidingThem() throws {
        var good = RecordingJob()
        good.state = .finalized
        JobStore.save(good, in: directory)

        // A WAV beside an unreadable sidecar: the old enumeration dropped the
        // JSON silently AND refused to call the WAV an orphan — invisible.
        let hidden = RecordingJob()
        try Data(repeating: 7, count: 128).write(
            to: JobStore.wavURL(for: hidden, in: directory))
        try Data("{ definitely not json".utf8).write(
            to: JobStore.manifestURL(for: hidden, in: directory))

        let audit = JobStore.audit(in: directory)
        XCTAssertEqual(audit.jobs.map(\.id), [good.id])
        XCTAssertEqual(
            audit.corruptManifests.map(\.lastPathComponent),
            [hidden.manifestFilename],
            "an undecodable sidecar must be reported, never skipped")
        XCTAssertTrue(
            JobStore.orphanedWavs(in: directory).isEmpty,
            "documented trap: the WAV is not an orphan while the bad JSON "
                + "exists — recovery must quarantine the JSON to free it")
    }

    // MARK: - Redaction: Clear History's reach into retained recordings

    func testRedactTranscriptStripsTextKeepsEverythingElse() throws {
        var job = RecordingJob()
        job.state = .committed
        job.text = "a transcript that should not outlive Clear History"
        job.confidence = 0.9
        job.durationSeconds = 4.2
        job.retainedAt = Date(timeIntervalSince1970: 5000)
        JobStore.save(job, in: directory)

        JobStore.redactTranscript(job, in: directory)

        let reloaded = JobStore.load(JobStore.manifestURL(for: job, in: directory))
        XCTAssertNotNil(reloaded)
        XCTAssertNil(reloaded?.text, "the transcript must be gone")
        XCTAssertNil(reloaded?.confidence)
        XCTAssertEqual(reloaded?.id, job.id)
        XCTAssertEqual(reloaded?.state, .committed)
        XCTAssertEqual(reloaded?.durationSeconds, 4.2)
        XCTAssertEqual(
            reloaded?.retainedAt, Date(timeIntervalSince1970: 5000),
            "retention metadata survives so GC still works")
    }

    // MARK: - Retention clock

    func testRetentionClockStartsAtKeepTimeNotRecordingTime() {
        var recovered = RecordingJob(startedAt: Date(timeIntervalSinceNow: -3 * 24 * 3600))
        XCTAssertEqual(
            recovered.retentionReference, recovered.startedAt,
            "without a keep timestamp the start time is all there is")

        recovered.retainedAt = Date()
        let window: TimeInterval = 24 * 3600
        let cutoff = Date().addingTimeInterval(-window)
        XCTAssertFalse(
            recovered.retentionReference < cutoff,
            "a recording recovered from a 3-day-old crash gets its full "
                + "keep window, not deletion at the next sweep")
    }

    // MARK: - Manifest schema compatibility

    func testOldManifestsWithoutNewFieldsStillDecode() throws {
        let json = """
            {"id":"\(UUID().uuidString)","state":"committed",
            "startedAt":"2026-08-11T18:00:00Z","source":"live",
            "attemptCount":0,"truncated":false}
            """
        let url = directory.appendingPathComponent("legacy.json")
        try Data(json.utf8).write(to: url)
        let job = JobStore.load(url)
        XCTAssertNotNil(job, "pre-1.3.1 manifests must keep decoding")
        XCTAssertNil(job?.deliveryMode)
        XCTAssertNil(job?.retainedAt)
    }

    // MARK: - Durable history writes

    func testUpsertDurablyThrowsAndRollsBackWhenDiskRefuses() throws {
        let sealed = directory.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        let store = HistoryStore(url: sealed.appendingPathComponent("history.json"))
        // Read-only directory: the write must fail...
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sealed.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: sealed.path)
        }

        let entry = HistoryEntry(
            id: UUID(), date: Date(), text: "must not pretend to be saved",
            duration: 1, recovered: false, confidence: nil)
        XCTAssertThrowsError(try store.upsertDurably(entry))
        // ...and memory must roll back, so the UI never shows history that
        // would vanish at the next launch.
        XCTAssertFalse(store.contains(id: entry.id))
    }

    // MARK: - History idempotency

    func testHistoryUpsertNeverDuplicates() throws {
        let file = directory.appendingPathComponent("history.json")
        let store = HistoryStore(url: file)
        let id = UUID()
        let entry = HistoryEntry(
            id: id, date: Date(), text: "the same dictation", duration: 2,
            recovered: false, confidence: 0.9)

        store.upsert(entry)
        // Recovery re-committing the same job must not add a second row.
        store.upsert(entry)
        var revised = entry
        revised.recovered = true
        store.upsert(revised)

        XCTAssertEqual(store.all.count, 1)
        XCTAssertTrue(store.all[0].recovered, "the newer version wins")
        XCTAssertTrue(store.contains(id: id))

        // And it must still be one row after a reload from disk.
        let reloaded = HistoryStore(url: file)
        XCTAssertEqual(reloaded.all.count, 1)
    }

    func testHistoryIsCappedAndNewestFirst() {
        let store = HistoryStore(url: directory.appendingPathComponent("capped.json"))
        for index in 0..<(HistoryStore.maxEntries + 25) {
            store.upsert(
                HistoryEntry(
                    id: UUID(),
                    date: Date(timeIntervalSince1970: Double(index)),
                    text: "entry \(index)", duration: 1, recovered: false, confidence: nil))
        }
        XCTAssertEqual(store.all.count, HistoryStore.maxEntries)
        XCTAssertEqual(store.all.first?.text, "entry \(HistoryStore.maxEntries + 24)")
    }

    func testCorruptHistoryIsParkedNotLost() throws {
        let file = directory.appendingPathComponent("bad.json")
        try Data("{ not json at all".utf8).write(to: file)

        let store = HistoryStore(url: file)
        XCTAssertTrue(store.all.isEmpty, "a broken file starts empty rather than crashing")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            siblings.contains { $0.contains("corrupt") },
            "the unreadable file is kept for inspection")
    }

    func testSearchMatchesCaseInsensitively() {
        let store = HistoryStore(url: directory.appendingPathComponent("search.json"))
        store.upsert(HistoryEntry(
            id: UUID(), date: Date(), text: "Bonjour tout le monde", duration: 1,
            recovered: false, confidence: nil))
        store.upsert(HistoryEntry(
            id: UUID(), date: Date(), text: "the quick brown fox", duration: 1,
            recovered: false, confidence: nil))

        XCTAssertEqual(store.search("BONJOUR").count, 1)
        XCTAssertEqual(store.search("fox").count, 1)
        XCTAssertEqual(store.search("").count, 2)
        XCTAssertEqual(store.search("nothing here").count, 0)
    }
}
