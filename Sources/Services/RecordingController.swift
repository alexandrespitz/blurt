import AppKit
import Foundation

/// The spine of a dictation: press → audio on disk → text → clipboard → history.
///
/// Lives on its own serial queue so the capture path never waits on the UI.
/// Every state change is mirrored to whoever is listening, which is how the
/// menu bar and HUD stay in step without being in the way.
final class RecordingController {

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case delivered(text: String, pasted: Bool, note: String?)
        case discarded(reason: String)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.alexspitz.blurt.pipeline", qos: .userInitiated)
    private let recorder = RecorderEngine()
    private let worker: TranscriptionWorker
    private let history: HistoryStore
    private let vocabulary: VocabularyStore

    private var activeJob: RecordingJob?
    /// Jobs we started in this process — only these may paste.
    private var liveJobIDs = Set<UUID>()
    /// In Gaze Mode, the app chosen by looking — it overrides "whatever was
    /// frontmost when recording stopped" as the delivery destination.
    private var gazeTarget: DeliveryService.Target?

    // MARK: Gaze Mode continuous listening

    private(set) var gazeListening = false
    private var gazeSegmenter = Segmenter()
    private var gazePreRoll: [[Float]] = []
    private let gazePreRollChunks = 6  // ~0.5 s so the first syllable survives
    private var gazeJob: RecordingJob?
    private var gazeWriter: WavWriter?
    private var gazeLastSync: CFAbsoluteTime = 0
    /// The exact input element each in-flight gaze utterance was aimed at, so
    /// the transcript can be inserted there even after the gaze moved on.
    /// In-memory only: after a crash, recovery delivers to history, never to
    /// whatever box happens to exist later.
    private var gazeInserts: [UUID: AXUIElement] = [:]
    /// Live in-box preview session for the utterance being spoken right now,
    /// then parked under the job id until its final transcript arrives.
    private var activeInBox: InBoxPreview?
    private var pendingInBox: [UUID: InBoxPreview] = [:]

    /// Read at each utterance's end: where was the user looking?
    var gazeDeliveryProvider: (@Sendable () -> GazeTargetService.Target?)?

    enum GazeEvent {
        case listeningStarted
        case listeningStopped(String?)
        case utteranceBegan
        case utteranceEnded
    }
    var onGazeEvent: (@Sendable (GazeEvent) -> Void)?
    /// Serializes post-processing so overlapping dictations still deliver in order.
    private var postChain: Task<Void, Never>?

    var onPhase: (@Sendable (Phase) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    /// Each converted audio chunk while recording, for the live preview.
    var onSamples: (@Sendable ([Float]) -> Void)?
    /// Fired whenever the set of recordings awaiting attention changes.
    var onPendingChanged: (@Sendable () -> Void)?

    init(worker: TranscriptionWorker, history: HistoryStore, vocabulary: VocabularyStore) {
        self.worker = worker
        self.history = history
        self.vocabulary = vocabulary

        recorder.onLevel = { [weak self] level in self?.onLevel?(level) }
        recorder.onSamples = { [weak self] samples in
            self?.onSamples?(samples)
            self?.queue.async { self?.gazeConsume(samples) }
        }
        recorder.onFailure = { [weak self] message in
            self?.queue.async { self?.handleRecorderFailure(message) }
        }
        worker.onResult = { [weak self] job, result in
            self?.queue.async { self?.handleResult(job: job, result: result) }
        }
        worker.onJobStarted = { [weak self] _ in
            self?.emit(.transcribing)
        }
    }

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Commands from the hotkey

    func startRecording() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stopRecording() {
        queue.async { [weak self] in self?.stopLocked(discard: false) }
    }

    func cancelRecording() {
        queue.async { [weak self] in self?.stopLocked(discard: true) }
    }

    /// Called by Gaze Mode once it has raised and focused the looked-at app.
    func setGazeTarget(bundleID: String?, pid: pid_t?, name: String?) {
        queue.async { [weak self] in
            guard let self, self.activeJob != nil else { return }
            self.gazeTarget = DeliveryService.Target(bundleID: bundleID, pid: pid, name: name)
        }
    }

    // MARK: - Gaze Mode: continuous listening

    /// Opens the microphone with no end in sight. Utterances are cut out of
    /// the stream by the segmenter; each becomes an ordinary crash-safe job.
    func startGazeListening() throws {
        var thrown: Error?
        queue.sync {
            guard !gazeListening else { return }
            // A hotkey recording in flight keeps priority; gaze waits.
            guard activeJob == nil else { return }
            do {
                try recorder.startMonitoring()
                gazeListening = true
                gazeSegmenter.reset()
                gazePreRoll = []
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        onGazeEvent?(.listeningStarted)
    }

    func stopGazeListening(reason: String? = nil) {
        var wasListening = false
        queue.sync {
            guard gazeListening else { return }
            wasListening = true
            gazeListening = false
            finishGazeUtterance()
            recorder.stop()
        }
        if wasListening { onGazeEvent?(.listeningStopped(reason)) }
    }

    private func gazeConsume(_ chunk: [Float]) {
        guard gazeListening else { return }

        switch gazeSegmenter.feed(rms: Segmenter.rms(chunk)) {
        case .quiet:
            gazePreRoll.append(chunk)
            if gazePreRoll.count > gazePreRollChunks {
                gazePreRoll.removeFirst(gazePreRoll.count - gazePreRollChunks)
            }
        case .begin:
            beginGazeUtterance(firstChunk: chunk)
        case .speaking:
            appendGaze(chunk)
        case .end:
            appendGaze(chunk)
            finishGazeUtterance()
        }
    }

    private func beginGazeUtterance(firstChunk: [Float]) {
        AppPaths.ensure()
        var job = RecordingJob()
        let url = JobStore.wavURL(for: job, in: AppPaths.inflight)
        do {
            gazeWriter = try WavWriter(url: url)
        } catch {
            Log.error("Gaze utterance could not open its file: \(error.localizedDescription)")
            return
        }
        job.state = .recording
        JobStore.save(job, in: AppPaths.inflight)
        gazeJob = job
        gazeLastSync = CFAbsoluteTimeGetCurrent()

        // If the armed box can host the live preview, the words appear right
        // in it as they are heard; otherwise the pill overlay carries them.
        if let input = gazeDeliveryProvider?()?.input {
            activeInBox = InBoxPreview.begin(in: input)
        }

        for chunk in gazePreRoll { appendGaze(chunk) }
        gazePreRoll = []
        appendGaze(firstChunk)
        onGazeEvent?(.utteranceBegan)
    }

    /// Routed from the preview engine: the latest partial for the utterance
    /// being spoken. Only meaningful while an in-box session is running.
    func updateGazePartial(_ text: String) {
        queue.async { [weak self] in
            self?.activeInBox?.update(text)
        }
    }

    /// Whether the current utterance's preview is showing inside the box —
    /// the pill can stay out of the way then.
    var inBoxActive: Bool {
        queue.sync { activeInBox != nil }
    }

    private func appendGaze(_ chunk: [Float]) {
        guard let writer = gazeWriter else { return }
        var samples = [Int16](repeating: 0, count: chunk.count)
        for i in 0..<chunk.count {
            samples[i] = Int16(max(-1.0, min(1.0, chunk[i])) * 32767.0)
        }
        do {
            try writer.append(samples)
        } catch {
            Log.error("Gaze utterance write failed: \(error.localizedDescription)")
            finishGazeUtterance()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - gazeLastSync > 2.0 {
            gazeLastSync = now
            writer.sync()
        }
    }

    private func finishGazeUtterance() {
        guard var job = gazeJob, let writer = gazeWriter else { return }
        gazeJob = nil
        gazeWriter = nil
        let inBox = activeInBox
        activeInBox = nil

        let duration = writer.durationSeconds
        writer.finalize()

        guard duration >= WavRecovery.minimumUsableSeconds else {
            JobStore.remove(job, in: AppPaths.inflight)
            // Clear any preview blip that made it into the box.
            inBox?.finish("")
            onGazeEvent?(.utteranceEnded)
            emit(.discarded(reason: "too short"))
            return
        }

        let looked = gazeDeliveryProvider?()
        job.state = .finalized
        job.durationSeconds = duration
        job.frontAppBundleID = looked?.bundleID
        job.frontAppPID = looked?.pid
        JobStore.save(job, in: AppPaths.inflight)

        liveJobIDs.insert(job.id)
        if let inBox {
            pendingInBox[job.id] = inBox
        }
        if let input = looked?.input {
            gazeInserts[job.id] = input
        }
        onGazeEvent?(.utteranceEnded)
        worker.enqueue(
            .init(id: job.id, url: JobStore.wavURL(for: job, in: AppPaths.inflight), source: .live))
    }

    /// Used when quitting: finalize whatever is open so it can be recovered.
    func finalizeForShutdown() {
        queue.sync {
            guard activeJob != nil else { return }
            stopLocked(discard: false, enqueue: false)
        }
    }

    // MARK: - Pipeline

    private func startLocked() {
        guard activeJob == nil else { return }
        // The continuous gaze session owns the engine; the hotkey pauses and
        // resumes that session instead (handled upstream). Belt and braces.
        guard !gazeListening else { return }
        AppPaths.ensure()

        var job = RecordingJob()
        let url = JobStore.wavURL(for: job, in: AppPaths.inflight)

        do {
            try recorder.start(writingTo: url)
        } catch {
            Log.error("Could not start recording: \(error.localizedDescription)")
            emit(.failed(error.localizedDescription))
            return
        }

        JobStore.save(job, in: AppPaths.inflight)
        job.state = .recording
        activeJob = job
        liveJobIDs.insert(job.id)
        emit(.recording)
    }

    private func stopLocked(discard: Bool, enqueue: Bool = true) {
        guard var job = activeJob else { return }
        activeJob = nil

        let outcome = recorder.stop()
        let url = JobStore.wavURL(for: job, in: AppPaths.inflight)

        if discard {
            JobStore.remove(job, in: AppPaths.inflight)
            emit(.idle)
            return
        }

        // A stray brush of the key is not a dictation.
        if outcome.duration < WavRecovery.minimumUsableSeconds {
            JobStore.remove(job, in: AppPaths.inflight)
            emit(.discarded(reason: "too short"))
            return
        }

        job.state = .finalized
        job.durationSeconds = outcome.duration
        job.truncated = outcome.truncated
        if let error = outcome.error { job.lastError = error }

        // Remembered on the job itself, not on the controller: two dictations
        // can be in flight at once, and each has to be delivered back to the
        // app *it* was spoken into. In Gaze Mode the looked-at app wins over
        // whatever happens to be frontmost.
        let target = gazeTarget ?? DeliveryService.Target.current()
        gazeTarget = nil
        job.frontAppBundleID = target.bundleID
        job.frontAppPID = target.pid

        JobStore.save(job, in: AppPaths.inflight)

        guard enqueue else { return }
        emit(.transcribing)
        worker.enqueue(.init(id: job.id, url: url, source: .live))
    }

    private func handleRecorderFailure(_ message: String) {
        if gazeListening {
            // Keep whatever the current utterance captured, stop listening,
            // and say why — silently dead ears would be worse.
            gazeListening = false
            finishGazeUtterance()
            recorder.stop()
            emit(.failed(message))
            onGazeEvent?(.listeningStopped(message))
            return
        }
        guard activeJob != nil else { return }
        // Keep whatever was captured; it is still a real dictation.
        stopLocked(discard: false)
        emit(.failed(message))
    }

    private func handleResult(
        job workerJob: TranscriptionWorker.Job,
        result: Result<TranscriptionWorker.Output, Error>
    ) {
        let directory = workerJob.url.deletingLastPathComponent()
        let manifestURL = directory.appendingPathComponent("\(workerJob.id.uuidString).json")
        var job = JobStore.load(manifestURL) ?? {
            var placeholder = RecordingJob(id: workerJob.id, source: workerJob.source)
            placeholder.state = .finalized
            return placeholder
        }()

        switch result {
        case .failure(let error):
            job.attemptCount += 1
            job.lastError = error.localizedDescription
            JobStore.save(job, in: directory)
            // A retry happens minutes later from the dashboard, by which point
            // "the app you were dictating into" is meaningless. Drop the claim
            // to paste; the transcript will be copied instead. Any in-box
            // partial stays visible — better an approximation than deletion.
            liveJobIDs.remove(job.id)
            gazeInserts.removeValue(forKey: job.id)
            pendingInBox.removeValue(forKey: job.id)
            Log.error("Transcription failed for \(job.id): \(error.localizedDescription)")
            emit(.failed(error.localizedDescription))
            onPendingChanged?()

        case .success(let output):
            job.text = output.text
            job.confidence = output.confidence
            job.durationSeconds = output.audioDuration
            job.state = .transcribed
            job.lastError = nil
            // Durable before anything is delivered, so a crash here cannot
            // cost the transcript.
            JobStore.save(job, in: directory)

            guard !output.text.isEmpty else {
                commit(job, in: directory, output: output, finalText: "")
                return
            }

            // Corrections are instant; tidying can take a second or two of
            // on-device model time. The chain keeps overlapping dictations
            // delivering in the order they were spoken.
            let previous = postChain
            let jobSnapshot = job
            postChain = Task(priority: .userInitiated) { [weak self] in
                await previous?.value
                guard let self else { return }
                let final = await self.polish(output.text)
                self.queue.async {
                    self.commit(jobSnapshot, in: directory, output: output, finalText: final)
                }
            }
        }
    }

    /// Everything that happens to the raw transcript before delivery — the
    /// learned corrections, then (optionally) the on-device tidy pass. All of
    /// it local; failure at any step keeps the more literal text.
    private func polish(_ raw: String) async -> String {
        let corrected = TextCorrector.apply(
            raw, rules: vocabulary.enabledRules, terms: vocabulary.terms)
        if !corrected.appliedRules.isEmpty {
            vocabulary.recordHits(corrected.appliedRules)
        }

        var text = corrected.text
        if Prefs.tidyEnabled, TidyService.isAvailable,
           let tidied = await TidyService.tidy(text)
        {
            text = tidied
        }
        return text
    }

    private func commit(
        _ job: RecordingJob, in directory: URL,
        output: TranscriptionWorker.Output, finalText: String
    ) {
        var job = job

        guard !finalText.isEmpty else {
            job.state = .committed
            JobStore.save(job, in: directory)
            applyRetention(to: job, in: directory)
            emit(.discarded(reason: "no speech detected"))
            onPendingChanged?()
            return
        }

        if Prefs.saveHistory {
            history.upsert(
                HistoryEntry(
                    id: job.id,
                    date: job.startedAt,
                    text: finalText,
                    duration: output.audioDuration,
                    recovered: job.source == .recovered,
                    confidence: output.confidence,
                    rawText: finalText == output.text ? nil : output.text))
        }

        // Only a dictation this process actually recorded may type itself into
        // an app. Recovered work never replays a paste.
        let isLive = liveJobIDs.contains(job.id)
        var pasted = false
        var note: String?

        if isLive {
            // In-box preview first: the words are already sitting in the box —
            // finishing swaps them for the final transcript in place.
            if let inBox = pendingInBox.removeValue(forKey: job.id),
               inBox.finish(finalText)
            {
                gazeInserts.removeValue(forKey: job.id)
                DeliveryService.copyOnly(text: finalText)
                pasted = true
            }
            // Otherwise a gaze utterance goes into the exact box it was aimed
            // at — via accessibility, which works even if your eyes (and
            // focus) have moved on. Fall back to the normal paste path.
            else if let input = gazeInserts.removeValue(forKey: job.id),
               GazeTargetService.insert(text: finalText, into: input)
            {
                // Clipboard still gets the text, as everywhere else.
                DeliveryService.copyOnly(text: finalText)
                pasted = true
            } else {
                let intended = DeliveryService.Target(
                    bundleID: job.frontAppBundleID, pid: job.frontAppPID, name: nil)
                let result = DeliveryService.deliver(
                    text: finalText,
                    intendedTarget: intended,
                    allowPaste: Prefs.autoPaste)
                switch result {
                case .pasted:
                    pasted = true
                case .copiedOnly(let reason):
                    note = "Copied — \(reason)"
                }
            }
        } else {
            note = "Recovered — copied to history"
        }

        job.state = .committed
        JobStore.save(job, in: directory)
        applyRetention(to: job, in: directory)
        liveJobIDs.remove(job.id)

        Log.info(
            "Delivered \(finalText.count) chars in \(String(format: "%.2f", output.processingTime))s "
                + "(\(String(format: "%.0f", output.realtimeFactor))× realtime)")
        emit(.delivered(text: finalText, pasted: pasted, note: note))
        onPendingChanged?()
    }

    // MARK: - Retention

    private func applyRetention(to job: RecordingJob, in directory: URL) {
        switch Prefs.retention {
        case .immediate:
            JobStore.remove(job, in: directory)
        case .oneDay, .sevenDays:
            if directory != AppPaths.done {
                JobStore.move(job, from: directory, to: AppPaths.done)
            }
        }
    }

    /// Deletes kept audio once it is past its retention window.
    func collectGarbage() {
        queue.async {
            let fm = FileManager.default
            guard let window = Prefs.retention.seconds else {
                for job in JobStore.loadAll(in: AppPaths.done) {
                    JobStore.remove(job, in: AppPaths.done)
                }
                return
            }
            let cutoff = Date().addingTimeInterval(-window)
            var removed = 0
            for job in JobStore.loadAll(in: AppPaths.done) where job.startedAt < cutoff {
                JobStore.remove(job, in: AppPaths.done)
                removed += 1
            }
            // Sweep stray WAVs with no manifest too.
            for url in JobStore.orphanedWavs(in: AppPaths.done) {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let created = (attrs?[.creationDate] as? Date) ?? .distantPast
                if created < cutoff {
                    try? fm.removeItem(at: url)
                    removed += 1
                }
            }
            if removed > 0 { Log.info("Retention removed \(removed) old recording(s)") }
        }
    }

    // MARK: - Recovery

    /// Finishes a job whose transcript survived in its manifest. No paste — the
    /// moment for that passed with the previous session.
    func recommitRecovered(_ job: RecordingJob, in directory: URL) {
        queue.async { [weak self] in
            guard let self, let text = job.text, !text.isEmpty else { return }
            let output = TranscriptionWorker.Output(
                text: text,
                confidence: job.confidence ?? 0,
                audioDuration: job.durationSeconds ?? 0,
                processingTime: 0,
                realtimeFactor: 0)
            // Corrections still apply; the async tidy pass does not — recovery
            // favors predictability over polish.
            let corrected = TextCorrector.apply(
                text, rules: self.vocabulary.enabledRules, terms: self.vocabulary.terms)
            self.commit(job, in: directory, output: output, finalText: corrected.text)
        }
    }

    // MARK: - Retry from the dashboard

    func retry(jobID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let url = AppPaths.inflight.appendingPathComponent("\(jobID.uuidString).wav")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            self.worker.enqueue(.init(id: jobID, url: url, source: .recovered))
        }
    }

    private func emit(_ phase: Phase) {
        onPhase?(phase)
    }
}
