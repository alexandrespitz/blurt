import Foundation

/// Turns a continuous microphone stream into utterances.
///
/// Gaze Mode listens all the time; this decides where one thing you said ends
/// and the next begins. Energy-based on purpose — no extra model, no network,
/// and with a close microphone the difference between speech and silence is
/// unambiguous. Pure logic with injectable thresholds, so the boundary cases
/// live in tests instead of in your dictations.
struct Segmenter {

    struct Config {
        /// RMS above this counts as speech…
        var startThreshold: Float = 0.015
        /// …and it has to stay below this to count as silence (hysteresis).
        var endThreshold: Float = 0.009
        /// Consecutive speech chunks before an utterance begins (~0.25 s).
        var chunksToStart = 3
        /// Consecutive silent chunks before it ends (~0.8 s of pause).
        var chunksToEnd = 9
        /// Hard cap per utterance, in chunks (~85 ms each): ~2 minutes.
        var maxChunksPerUtterance = 1400

        static let `default` = Config()
    }

    enum Verdict: Equatable {
        /// Nothing happening.
        case quiet
        /// Speech just started — the caller should open a segment and include
        /// its pre-roll buffer so the first syllable is not clipped.
        case begin
        /// Mid-utterance — keep appending.
        case speaking
        /// The utterance just ended (a pause, or the length cap).
        case end
    }

    private enum State {
        case quiet(loudRun: Int)
        case speaking(quietRun: Int, length: Int)
    }

    let config: Config
    private var state: State = .quiet(loudRun: 0)

    init(config: Config = .default) {
        self.config = config
    }

    var isSpeaking: Bool {
        if case .speaking = state { return true }
        return false
    }

    mutating func feed(rms: Float) -> Verdict {
        switch state {
        case .quiet(let loudRun):
            if rms >= config.startThreshold {
                let run = loudRun + 1
                if run >= config.chunksToStart {
                    state = .speaking(quietRun: 0, length: run)
                    return .begin
                }
                state = .quiet(loudRun: run)
            } else {
                state = .quiet(loudRun: 0)
            }
            return .quiet

        case .speaking(let quietRun, let length):
            let newLength = length + 1
            if newLength >= config.maxChunksPerUtterance {
                state = .quiet(loudRun: 0)
                return .end
            }
            if rms < config.endThreshold {
                let run = quietRun + 1
                if run >= config.chunksToEnd {
                    state = .quiet(loudRun: 0)
                    return .end
                }
                state = .speaking(quietRun: run, length: newLength)
            } else {
                state = .speaking(quietRun: 0, length: newLength)
            }
            return .speaking
        }
    }

    mutating func reset() {
        state = .quiet(loudRun: 0)
    }

    /// Root-mean-square energy of a chunk, the segmenter's only input.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
