import XCTest

final class SegmenterTests: XCTestCase {

    private let loud: Float = 0.05
    private let silent: Float = 0.0004

    private func run(_ levels: [Float], config: Segmenter.Config = .default) -> [Segmenter.Verdict] {
        var segmenter = Segmenter(config: config)
        return levels.map { segmenter.feed(rms: $0) }
    }

    func testSpeechThenSilenceMakesOneUtterance() {
        let levels = [Float](repeating: silent, count: 10)
            + [Float](repeating: loud, count: 20)
            + [Float](repeating: silent, count: 15)
        let verdicts = run(levels)

        XCTAssertEqual(verdicts.filter { $0 == .begin }.count, 1)
        XCTAssertEqual(verdicts.filter { $0 == .end }.count, 1)
        // Begins on the third loud chunk (default chunksToStart)…
        XCTAssertEqual(verdicts.firstIndex(of: .begin), 12)
        // …ends after nine silent chunks.
        XCTAssertEqual(verdicts.firstIndex(of: .end), 30 + 8)
    }

    func testTwoUtterancesSeparatedByAPause() {
        let levels = [Float](repeating: loud, count: 12)
            + [Float](repeating: silent, count: 12)
            + [Float](repeating: loud, count: 12)
            + [Float](repeating: silent, count: 12)
        let verdicts = run(levels)
        XCTAssertEqual(verdicts.filter { $0 == .begin }.count, 2)
        XCTAssertEqual(verdicts.filter { $0 == .end }.count, 2)
    }

    func testAShortBlipDoesNotStartAnUtterance() {
        // Two loud chunks (a cough, a key clack) is below chunksToStart.
        let levels = [Float](repeating: silent, count: 5)
            + [Float](repeating: loud, count: 2)
            + [Float](repeating: silent, count: 10)
        XCTAssertFalse(run(levels).contains(.begin))
    }

    func testMidSentencePausesDoNotSplit() {
        // Short gaps (below chunksToEnd) inside speech must not end it.
        let levels = [Float](repeating: loud, count: 6)
            + [Float](repeating: silent, count: 4)
            + [Float](repeating: loud, count: 6)
            + [Float](repeating: silent, count: 4)
            + [Float](repeating: loud, count: 6)
            + [Float](repeating: silent, count: 12)
        let verdicts = run(levels)
        XCTAssertEqual(verdicts.filter { $0 == .begin }.count, 1)
        XCTAssertEqual(verdicts.filter { $0 == .end }.count, 1)
    }

    func testHysteresisIgnoresQuietTrailingAudio() {
        // Levels between endThreshold and startThreshold: not silence.
        let between: Float = 0.012
        let levels = [Float](repeating: loud, count: 6)
            + [Float](repeating: between, count: 20)
        let verdicts = run(levels)
        XCTAssertEqual(verdicts.filter { $0 == .begin }.count, 1)
        XCTAssertTrue(verdicts.filter { $0 == .end }.isEmpty, "soft audio must not end the utterance")
    }

    func testRunawayUtteranceIsCappedAndSplits() {
        var config = Segmenter.Config()
        config.maxChunksPerUtterance = 30
        let levels = [Float](repeating: loud, count: 60)
        let verdicts = run(levels, config: config)

        // The cap cuts the utterance…
        let firstEnd = verdicts.firstIndex(of: .end)
        XCTAssertNotNil(firstEnd)
        XCTAssertLessThan(firstEnd!, 32, "the cap must fire near the limit")
        // …and uninterrupted speech simply starts a fresh one — nothing is
        // ever silently dropped.
        let laterBegin = verdicts[(firstEnd! + 1)...].firstIndex(of: .begin)
        XCTAssertNotNil(laterBegin, "speech continuing past the cap begins a new utterance")
    }

    func testRMSMathIsSane() {
        XCTAssertEqual(Segmenter.rms([]), 0)
        XCTAssertEqual(Segmenter.rms([0, 0, 0]), 0)
        XCTAssertEqual(Segmenter.rms([0.5, -0.5]), 0.5, accuracy: 0.0001)
        // A fixture-loudness sine wave sits comfortably above startThreshold.
        let sine = (0..<1600).map { Float(sin(Double($0) * 0.1)) * 0.1 }
        XCTAssertGreaterThan(Segmenter.rms(sine), Segmenter.Config.default.startThreshold)
    }
}
