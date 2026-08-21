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
