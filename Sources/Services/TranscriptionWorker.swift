import Foundation
import FluidAudio

/// Owns the Parakeet model and turns finished WAV files into text.
///
/// Jobs go through an explicit first-in-first-out queue drained by a single
/// long-lived task. An actor alone would not be enough: actor methods are
/// reentrant across `await`, so a second dictation could interleave with the
/// first and deliver out of order.
///
/// The file on disk is always the input — for live dictation, recovery and
/// retries alike. One code path, and the file doubles as the write-ahead log.
final class TranscriptionWorker {

    enum ModelState: Equatable {
        case notReady
        case downloading(fraction: Double, detail: String)
        /// Checking the downloaded weights against this build's pinned hashes.
        case verifying
        case loading
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    struct Job {
        var id: UUID
        var url: URL
        var source: RecordingJob.Source
    }

    struct Output {
        var text: String
        var confidence: Double
        var audioDuration: Double
        var processingTime: Double
        var realtimeFactor: Double
    }

    /// Called on an arbitrary thread whenever the model state changes.
    var onStateChange: (@Sendable (ModelState) -> Void)?
    /// Called when a job starts being transcribed.
    var onJobStarted: (@Sendable (Job) -> Void)?
    /// Called with each job's outcome, in the order the jobs were enqueued.
    var onResult: (@Sendable (Job, Result<Output, Error>) -> Void)?

    private let stateLock = NSLock()
    private var _state: ModelState = .notReady

    private var manager: AsrManager?
    private var decoderLayers = 2
    private var consumer: Task<Void, Never>?
    private var continuation: AsyncStream<Job>.Continuation?

    private(set) var lastRealtimeFactor: Double = 0

    var state: ModelState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    init() {
        let (stream, continuation) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        consumer = Task.detached(priority: .userInitiated) { [weak self] in
            for await job in stream {
                await self?.process(job)
            }
        }
    }

    deinit {
        continuation?.finish()
        consumer?.cancel()
    }

    // MARK: - Model lifecycle

    /// True when the model is already on disk, so we can skip the network.
    static var modelsAreCached: Bool {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        return AsrModels.modelsExist(at: dir, version: .v3)
    }

    static var modelCacheDirectory: URL { AsrModels.defaultCacheDirectory(for: .v3) }

    /// Downloads (first run only) and loads the model, then warms it up so the
    /// first real dictation is not the one that pays for compilation.
    func prepare() async {
        if case .ready = state { return }

        let cached = Self.modelsAreCached
        setState(cached ? .loading : .downloading(fraction: 0, detail: "Contacting Hugging Face"))

        do {
            // Download and load are deliberately separate so the weights can
            // be checked against the hashes this build was tested with,
            // BEFORE Core ML is asked to run them.
            let directory = try await AsrModels.download(
                version: .v3,
                progressHandler: { [weak self] progress in
                    self?.report(progress)
                })

            setState(.verifying)
            let verdict = ModelIntegrity.verify(modelDirectory: directory)
            switch verdict {
            case .verified:
                Log.info("Speech model verified against \(ModelIntegrity.expected.count) pinned hashes")
            case .mismatch(let files), .missing(let files):
                Log.error(
                    "Model integrity check failed: \(files.prefix(3).joined(separator: ", "))"
                        + (files.count > 3 ? " and \(files.count - 3) more" : ""))
                if Prefs.allowUnverifiedModel {
                    Log.error("Loading anyway — allowUnverifiedModel is set")
                } else {
                    setState(.failed(
                        verdict.explanation
                            + " Update Blurt, or delete "
                            + "~/Library/Application Support/FluidAudio to download it again."))
                    return
                }
            }

            let models = try await AsrModels.load(from: directory, version: .v3)

            setState(.loading)

            // `melChunkContext: false` is what FluidAudio recommends for v3
            // multilingual long-form audio; leaving it on lets the decoder drift
            // back to an English prior at chunk boundaries.
            let manager = AsrManager(config: ASRConfig(melChunkContext: false))
            try await manager.loadModels(models)
            self.decoderLayers = await manager.decoderLayerCount
            self.manager = manager

            await warmUp(manager)
            setState(.ready)
            Log.info("Parakeet v3 ready (decoder layers: \(decoderLayers))")
        } catch {
            let message = error.localizedDescription
            Log.error("Model preparation failed: \(message)")
            setState(.failed(message))
        }
    }

    private func warmUp(_ manager: AsrManager) async {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let silence = [Float](repeating: 0, count: 16000)
        _ = try? await manager.transcribe(silence, decoderState: &state)
    }

    private func report(_ progress: DownloadProgress) {
        let detail: String
        switch progress.phase {
        case .listing:
            detail = "Listing model files"
        case .downloading(let done, let total):
            detail = total > 0 ? "Downloading file \(done + 1) of \(total)" : "Downloading"
        case .compiling(let name):
            detail = "Compiling \(name)"
        }
        setState(.downloading(fraction: progress.fractionCompleted, detail: detail))
    }

    private func setState(_ new: ModelState) {
        stateLock.lock()
        let changed = _state != new
        _state = new
        stateLock.unlock()
        if changed { onStateChange?(new) }
    }

    // MARK: - Queue

    func enqueue(_ job: Job) {
        continuation?.yield(job)
    }

    /// One-shot transcription used by the command-line tool.
    func transcribeNow(url: URL) async throws -> Output {
        guard let manager else { throw Failure.notReady }
        return try await run(manager: manager, url: url)
    }

    private func process(_ job: Job) async {
        onJobStarted?(job)
        guard let manager else {
            onResult?(job, .failure(Failure.notReady))
            return
        }
        do {
            let output = try await run(manager: manager, url: job.url)
            lastRealtimeFactor = output.realtimeFactor
            onResult?(job, .success(output))
        } catch {
            onResult?(job, .failure(error))
        }
    }

    /// The user's pinned language, if any, in FluidAudio's terms.
    private var languageHint: Language? {
        guard let code = Prefs.languageHint else { return nil }
        return Language(rawValue: code)
    }

    /// The languages the model supports, for the dashboard picker.
    static var supportedLanguages: [(code: String, name: String)] {
        Language.allCases
            .map { lang -> (String, String) in
                let name = Locale.current.localizedString(forIdentifier: lang.rawValue)
                    ?? lang.rawValue
                return (lang.rawValue, name.capitalized)
            }
            .sorted { $0.1 < $1.1 }
    }

    /// A quick, throwaway transcription of in-memory audio for the live HUD
    /// preview. Same model, fresh decoder, never touches the job queue.
    func previewTranscribe(_ samples: [Float]) async -> String? {
        guard let manager, state.isReady else { return nil }
        // Half a second — comfortably above the model's 0.3 s minimum.
        guard samples.count >= 8000 else { return nil }
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try? await manager.transcribe(
            samples, decoderState: &decoderState, language: languageHint)
        return result?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(manager: AsrManager, url: URL) async throws -> Output {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.missingAudio(url.lastPathComponent)
        }
        // Each dictation is its own utterance — start from a clean decoder.
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let startedAt = Date()
        let result = try await manager.transcribe(
            url, decoderState: &decoderState, language: languageHint)
        let wallClock = Date().timeIntervalSince(startedAt)

        // The library's own duration is not filled in on every path (the
        // disk-backed one reports zero), so measure it here rather than showing
        // the user a nonsense speed.
        let audioDuration = result.duration > 0 ? result.duration : audioLength(of: url)
        let processingTime = result.processingTime > 0 ? result.processingTime : wallClock

        return Output(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: Double(result.confidence),
            audioDuration: audioDuration,
            processingTime: processingTime,
            realtimeFactor: processingTime > 0 ? audioDuration / processingTime : 0)
    }

    private func audioLength(of url: URL) -> Double {
        if case .usable(let probe) = WavRecovery.probe(url) { return probe.duration }
        return 0
    }

    enum Failure: LocalizedError {
        case notReady
        case missingAudio(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "The speech model is not loaded yet."
            case .missingAudio(let name):
                return "The recording \(name) is no longer on disk."
            }
        }
    }
}
