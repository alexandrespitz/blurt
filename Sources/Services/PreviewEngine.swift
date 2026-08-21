import Foundation

/// Live text while you speak.
///
/// No second model, no separate streaming stack: every ~1.4 seconds the last
/// stretch of audio is re-transcribed by the same warm model that will do the
/// final pass. At 30×+ realtime that costs well under half a second of Neural
/// Engine time per update — and it speaks all 25 languages, because it *is*
/// the same model.
///
/// The preview is feedback, never the result. The final transcript always
/// comes from the full batch pass over the finished WAV.
final class PreviewEngine {

    /// How much recent audio each preview pass looks at. Long enough to give
    /// the model context, short enough that a pass stays well under the tick.
    private let windowSeconds = 12.0
    /// Cadence of preview passes. Each pass costs ~0.1–0.3 s of Neural Engine
    /// time, so at this rate the words trail your voice by well under a second.
    private let interval = 0.55
    private let sampleRate = 16000

    private let queue = DispatchQueue(label: "com.alexspitz.blurt.preview", qos: .utility)
    private var buffer: [Float] = []
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var generation = 0
    /// Monotonic count of every sample ever consumed this recording. The ring
    /// buffer caps out at the window size, so comparing against `buffer.count`
    /// froze the preview dead after 12 seconds — this counter never caps.
    private var totalConsumed = 0
    private var lastPreviewedTotal = 0
    private var lastPublished = ""

    private weak var worker: TranscriptionWorker?

    /// The latest partial text, off the main thread.
    var onPartial: (@Sendable (String) -> Void)?

    init(worker: TranscriptionWorker) {
        self.worker = worker
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.removeAll(keepingCapacity: true)
            self.totalConsumed = 0
            self.lastPreviewedTotal = 0
            self.lastPublished = ""
            self.generation += 1
            let generation = self.generation

            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.interval, repeating: self.interval)
            t.setEventHandler { [weak self] in self?.tick(generation) }
            self.timer?.cancel()
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.timer?.cancel()
            self.timer = nil
            self.buffer.removeAll(keepingCapacity: false)
            self.totalConsumed = 0
            self.lastPreviewedTotal = 0
        }
    }

    /// Fed from the recorder's io queue with each converted 16 kHz chunk.
    func consume(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.buffer.append(contentsOf: samples)
            self.totalConsumed += samples.count
            let cap = Int(self.windowSeconds * Double(self.sampleRate))
            if self.buffer.count > cap {
                self.buffer.removeFirst(self.buffer.count - cap)
            }
        }
    }

    private func tick(_ generation: Int) {
        guard generation == self.generation, !busy else { return }
        // Half a second of audio is enough to start (the model's own floor is
        // 0.3 s), and a quarter second of new audio is enough to bother again.
        guard buffer.count >= sampleRate / 2,
              totalConsumed - lastPreviewedTotal >= sampleRate / 4
        else { return }

        busy = true
        lastPreviewedTotal = totalConsumed
        let snapshot = buffer
        let worker = self.worker

        Task.detached(priority: .utility) { [weak self] in
            let text = await worker?.previewTranscribe(snapshot)
            guard let self else { return }
            self.queue.async {
                self.busy = false
                guard generation == self.generation else { return }
                if let text, !text.isEmpty, text != self.lastPublished {
                    self.lastPublished = text
                    self.onPartial?(text)
                }
            }
        }
    }
}
