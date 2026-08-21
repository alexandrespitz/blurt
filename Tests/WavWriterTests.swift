import AVFoundation
import XCTest

/// These are the tests that back the promise on the tin: a recording that was
/// never finalized must still be readable, and must contain the audio.
final class WavWriterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep the suite out of the real data folder and log.
        AppPaths.rootOverride = directory
    }

    override func tearDownWithError() throws {
        AppPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func tone(frames: Int) -> [Int16] {
        (0..<frames).map { index in
            Int16(sin(Double(index) * 0.05) * 8000)
        }
    }

    func testFinalizedFileIsSampleExact() throws {
        let url = directory.appendingPathComponent("tone.wav")
        let samples = tone(frames: 16000)

        let writer = try WavWriter(url: url)
        try writer.append(Array(samples[0..<8000]))
        try writer.append(Array(samples[8000...]))
        writer.finalize()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)

        guard case .usable(let probe) = WavRecovery.probe(url) else {
            return XCTFail("a finalized file must probe as usable")
        }
        XCTAssertEqual(probe.frames, 16000)
        XCTAssertFalse(probe.needsRepair)
    }

    func testUnfinalizedFileIsRecoveredWithAllItsAudio() throws {
        let url = directory.appendingPathComponent("crash.wav")
        let samples = tone(frames: 24000)  // 1.5 seconds

        // Write, sync, and walk away — exactly what a force-quit leaves behind.
        let writer = try WavWriter(url: url)
        try writer.append(samples)
        writer.sync()
        writer.abort()

        guard case .usable(let probe) = WavRecovery.probe(url) else {
            return XCTFail("an abandoned recording must still be usable")
        }
        XCTAssertTrue(probe.needsRepair, "the header should still say zero")
        XCTAssertEqual(probe.declaredDataBytes, 0)
        XCTAssertEqual(probe.frames, 24000, "length must come from the file size")

        XCTAssertTrue(WavRecovery.repair(url))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 24000, "every sample written must survive")

        // And the audio itself must be intact, not just the length.
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let read = buffer.floatChannelData![0]
        XCTAssertEqual(Double(read[100]), Double(samples[100]) / 32767.0, accuracy: 0.001)
        XCTAssertEqual(Double(read[23999]), Double(samples[23999]) / 32767.0, accuracy: 0.001)
    }

    func testTornFinalSampleIsTrimmedRatherThanRejected() throws {
        let url = directory.appendingPathComponent("torn.wav")
        let writer = try WavWriter(url: url)
        try writer.append(tone(frames: 16000))
        writer.abort()

        // Chop a single byte off, as a power cut mid-write would.
        let handle = try FileHandle(forWritingTo: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 1)
        try handle.close()

        guard case .usable(let probe) = WavRecovery.probe(url) else {
            return XCTFail("a torn file must still be usable")
        }
        XCTAssertEqual(probe.frames, 15999, "the half sample is dropped, the rest is kept")
        XCTAssertTrue(WavRecovery.repair(url))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 15999)
    }

    func testTooShortAndGarbageAreClassifiedNotDeleted() throws {
        let brief = directory.appendingPathComponent("brief.wav")
        let writer = try WavWriter(url: brief)
        try writer.append(tone(frames: 1000))  // 62 ms
        writer.finalize()
        guard case .tooShort = WavRecovery.probe(brief) else {
            return XCTFail("62 ms is a key brush, not a dictation")
        }

        let garbage = directory.appendingPathComponent("garbage.wav")
        try Data(repeating: 0x41, count: 500).write(to: garbage)
        guard case .invalid = WavRecovery.probe(garbage) else {
            return XCTFail("random bytes are not a WAV")
        }

        let stub = directory.appendingPathComponent("stub.wav")
        try Data(repeating: 0, count: 10).write(to: stub)
        guard case .invalid = WavRecovery.probe(stub) else {
            return XCTFail("a file smaller than a header is invalid")
        }
    }

    func testExclusiveCreateRefusesToClobber() throws {
        let url = directory.appendingPathComponent("once.wav")
        let first = try WavWriter(url: url)
        first.finalize()
        XCTAssertThrowsError(try WavWriter(url: url), "a collision must fail loudly")
    }

    func testDurationTracksFramesWritten() throws {
        let url = directory.appendingPathComponent("length.wav")
        let writer = try WavWriter(url: url)
        try writer.append(tone(frames: 8000))
        XCTAssertEqual(writer.durationSeconds, 0.5, accuracy: 0.0001)
        writer.finalize()
    }
}
