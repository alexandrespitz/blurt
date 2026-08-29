import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Headless companion to the app. Everything the dictation pipeline does can be
/// exercised here — including crashing on purpose — so the crash-safety claims
/// are tested rather than asserted.
///
///   blurt-cli selftest              transcribe the generated fixtures
///   blurt-cli transcribe <file>     one file, prints the transcript
///   blurt-cli models                where the model lives, whether it is cached
///   blurt-cli simulate-crash <wav>  write audio, then die before finalizing
///   blurt-cli recover [dir]         repair + transcribe abandoned recordings
///   blurt-cli tap-probe             can we create a keyboard tap right now?

Log.echoToStdout = true

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Tiny lock-guarded box for values shared with @Sendable callbacks.
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func mutate(_ change: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}

func fixturesDirectory() -> URL {
    // Scripts/make_fixtures.sh writes next to the repo root.
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return cwd.appendingPathComponent("Fixtures")
}

/// Loads the model once for whatever the command needs.
func makeWorker() async -> TranscriptionWorker {
    let worker = TranscriptionWorker()
    worker.onStateChange = { state in
        switch state {
        case .downloading(let fraction, let detail):
            let percent = Int(fraction * 100)
            print("  downloading \(percent)% — \(detail)")
        case .verifying:
            print("  verifying model against pinned hashes…")
        case .loading:
            print("  loading model…")
        case .ready:
            print("  model ready")
        case .failed(let why):
            print("  model failed: \(why)")
        case .notReady:
            break
        }
    }
    let started = Date()
    await worker.prepare()
    print(String(format: "  startup took %.1fs", Date().timeIntervalSince(started)))
    guard worker.state.isReady else { fail("model did not load") }
    return worker
}

func transcribe(_ worker: TranscriptionWorker, _ url: URL) async -> TranscriptionWorker.Output? {
    do {
        return try await worker.transcribeNow(url: url)
    } catch {
        print("  transcription failed: \(error.localizedDescription)")
        return nil
    }
}

switch command {

case "models":
    let dir = TranscriptionWorker.modelCacheDirectory
    print("Model directory: \(dir.path)")
    print("Cached: \(TranscriptionWorker.modelsAreCached ? "yes" : "no")")
    if let size = try? FileManager.default.subpathsOfDirectory(atPath: dir.path)
        .compactMap({ try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent($0).path)[.size] as? NSNumber })
        .reduce(0, { $0 + $1.int64Value })
    {
        print(String(format: "Size on disk: %.2f GB", Double(size) / 1_073_741_824))
    }

case "tap-probe":
    // Does an active tap work with the permissions we have right now?
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
    let permissions = PermissionsService()
    let snapshot = permissions.snapshot()
    print("Accessibility:    \(snapshot.accessibility)")
    print("Input Monitoring: \(snapshot.inputMonitoring)")
    print("Microphone:       \(snapshot.microphone)")
    print("Active tap creation: \(tap != nil ? "SUCCEEDED" : "FAILED")")
    exit(tap != nil ? 0 : 1)

case "transcribe":
    guard args.count > 1 else { fail("usage: blurt-cli transcribe <file.wav>") }
    let url = URL(fileURLWithPath: args[1])
    let worker = await makeWorker()
    guard let output = await transcribe(worker, url) else { fail("no transcript") }
    print("")
    print(output.text)
    print("")
    print(String(
        format: "  %.1fs audio in %.2fs (%.0f× realtime), confidence %.2f",
        output.audioDuration, output.processingTime, output.realtimeFactor, output.confidence))

case "selftest":
    let dir = fixturesDirectory()
    struct Case { let file: String; let mustContain: [String]; let label: String }
    let cases = [
        Case(file: "en_short.wav", mustContain: ["quick brown fox"], label: "English"),
        Case(file: "fr_short.wav", mustContain: ["bonjour"], label: "French"),
        Case(file: "en_long.wav", mustContain: ["quick brown fox"], label: "English, long"),
        Case(file: "silence.wav", mustContain: [], label: "Silence"),
    ]

    print("Blurt selftest")
    print("Fixtures: \(dir.path)")
    let worker = await makeWorker()

    var failures = 0
    for testCase in cases {
        let url = dir.appendingPathComponent(testCase.file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("  SKIP  \(testCase.label): \(testCase.file) not generated")
            continue
        }
        guard let output = await transcribe(worker, url) else {
            print("  FAIL  \(testCase.label): no result")
            failures += 1
            continue
        }
        let lowered = output.text.lowercased()
        let missing = testCase.mustContain.filter { !lowered.contains($0.lowercased()) }

        if testCase.mustContain.isEmpty {
            // Silence must not hallucinate words.
            let words = output.text.split(separator: " ").count
            if words > 2 {
                print("  FAIL  \(testCase.label): expected near-silence, got \(words) words")
                failures += 1
            } else {
                print("  ok    \(testCase.label): produced \(words) word(s)")
            }
        } else if missing.isEmpty {
            print(String(
                format: "  ok    %@ — %.0f× realtime, %d chars",
                testCase.label, output.realtimeFactor, output.text.count))
            print("        “\(output.text.prefix(90))\(output.text.count > 90 ? "…" : "")”")
        } else {
            print("  FAIL  \(testCase.label): missing \(missing)")
            print("        got: \(output.text)")
            failures += 1
        }
    }

    print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)

case "simulate-crash":
    // Streams a fixture through the real WavWriter and dies before finalizing,
    // exactly like a force-quit mid-sentence.
    guard args.count > 1 else { fail("usage: blurt-cli simulate-crash <source.wav> [dir]") }
    let source = URL(fileURLWithPath: args[1])
    let dir = args.count > 2
        ? URL(fileURLWithPath: args[2])
        : AppPaths.inflight
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    guard let data = try? Data(contentsOf: source), data.count > WavWriter.headerBytes else {
        fail("cannot read \(source.path)")
    }
    var job = RecordingJob()
    job.state = .recording
    let destination = JobStore.wavURL(for: job, in: dir)
    JobStore.save(job, in: dir)

    do {
        let writer = try WavWriter(url: destination)
        let payload = data.dropFirst(WavWriter.headerBytes)
        let samples = payload.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        // Write in realistic chunks, syncing as the recorder would.
        var index = 0
        let chunk = 1600
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            try writer.append(Array(samples[index..<end]))
            index = end
            if index % (chunk * 20) == 0 { writer.sync() }
        }
        writer.sync()
        print("Wrote \(samples.count) frames to \(destination.lastPathComponent) — crashing now")
    } catch {
        fail(error.localizedDescription)
    }
    fflush(stdout)
    // No finalize(), no clean exit: the header stays zeroed, like a real crash.
    exit(9)

case "record":
    // Exercises the real capture path — engine, converter, incremental writer —
    // against whatever the default input device is.
    let seconds = Double(args.count > 1 ? args[1] : "3") ?? 3
    let dir = AppPaths.inflight
    AppPaths.ensure()

    var job = RecordingJob()
    let destination = JobStore.wavURL(for: job, in: dir)
    let recorder = RecorderEngine()
    recorder.onFailure = { print("  recorder problem: \($0)") }

    do {
        try recorder.start(writingTo: destination)
    } catch {
        fail(error.localizedDescription)
    }
    print("Recording \(seconds)s from the default input…")
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    let outcome = recorder.stop()
    print(String(
        format: "  wrote %d frames (%.2fs)%@",
        outcome.frames, outcome.duration, outcome.truncated ? " [truncated]" : ""))

    guard case .usable(let probe) = WavRecovery.probe(destination) else {
        fail("the recording did not come out as a readable WAV")
    }
    print(String(
        format: "  %@: %.2fs, %dHz mono, header %@",
        destination.lastPathComponent, probe.duration, probe.sampleRate,
        probe.needsRepair ? "UNFINALIZED" : "finalized"))

    job.state = .finalized
    job.durationSeconds = probe.duration
    JobStore.save(job, in: dir)

    let worker = await makeWorker()
    if let output = await transcribe(worker, destination) {
        print("\nHeard: \(output.text.isEmpty ? "(nothing — silence or room noise)" : output.text)")
    }
    JobStore.remove(job, in: dir)

case "preview":
    // Headless check of the live-preview loop: streams a fixture into the
    // PreviewEngine at real-time pace and prints each partial as it lands.
    guard args.count > 1 else { fail("usage: blurt-cli preview <file.wav>") }
    let url = URL(fileURLWithPath: args[1])

    let worker = await makeWorker()
    let engine = PreviewEngine(worker: worker)
    let partials = Atomic<[String]>([])
    engine.onPartial = { text in
        partials.mutate { $0.append(text) }
        print("  partial: \(text)")
    }

    guard let file = try? AVAudioFile(forReading: url),
          file.processingFormat.sampleRate == 16000,
          let pcm = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: pcm)) != nil,
          let channel = pcm.floatChannelData?[0]
    else { fail("cannot read \(url.lastPathComponent) as 16 kHz audio") }

    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
    let duration = Double(samples.count) / 16000.0

    print("Streaming \(String(format: "%.1f", duration))s at real-time pace…")
    engine.start()
    let chunk = 1600  // 100 ms
    var index = 0
    while index < samples.count {
        let end = min(index + chunk, samples.count)
        engine.consume(Array(samples[index..<end]))
        index = end
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    try? await Task.sleep(nanoseconds: 1_600_000_000)
    engine.stop()

    let count = partials.value.count
    print(count > 0 ? "\nPASS — \(count) live partial(s) while streaming" : "\nFAIL — no partials arrived")
    exit(count > 0 ? 0 : 1)

case "tidy":
    // Checks the on-device Apple Intelligence cleanup path.
    print("Tidy available: \(TidyService.isAvailable)")
    if let reason = TidyService.unavailableReason {
        print("Reason: \(reason)")
        exit(1)
    }
    let sample = args.count > 1
        ? args[1]
        : "um so basically the thing is uh we should we should ship the blurt app tomorrow I think"
    print("Input:  \(sample)")
    let started = Date()
    if let cleaned = await TidyService.tidy(sample) {
        print("Output: \(cleaned)")
        print(String(format: "Took %.1fs", Date().timeIntervalSince(started)))
    } else {
        print("Tidy declined (kept the original) — this is the safe fallback path.")
    }

case "gaze-probe":
    // Verifies Gaze Mode's aiming: warps the pointer to the given screen
    // point (or uses its current position), then acquires, raises and
    // focuses whatever is there — exactly what recording start does.
    if args.count > 2, let x = Double(args[1]), let y = Double(args[2]) {
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        usleep(150_000)
    }
    let pointer = CGEvent(source: nil)?.location ?? .zero
    print("Pointer at (\(Int(pointer.x)), \(Int(pointer.y))) — acquiring…")

    guard let target = GazeTargetService.acquireUnderPointer() else {
        print("Nothing acquirable there (desktop, our own UI, or AX refused).")
        exit(1)
    }
    print("App:        \(target.appName ?? "?") (\(target.bundleID ?? "?"), pid \(target.pid))")
    print("Text input: \(target.foundInput ? "found and focused" : "none found — window raised only")")
    if let frame = target.inputFrame {
        print(String(
            format: "Input box:  x=%.0f y=%.0f  %.0f×%.0f (Cocoa coords)",
            frame.origin.x, frame.origin.y, frame.width, frame.height))
    }
    usleep(400_000)
    let front = NSWorkspace.shared.frontmostApplication
    let raised = front?.processIdentifier == target.pid
    print("Frontmost:  \(front?.localizedName ?? "?") — \(raised ? "raise CONFIRMED" : "raise did not take")")
    exit(raised ? 0 : 1)

case "devices":
    let devices = AudioInputDevices.all()
    let defaultDevice = AudioInputDevices.defaultInput()
    print("Input devices:")
    for device in devices {
        let marker = device.id == defaultDevice?.id ? "  (system default)" : ""
        print("  \(device.name)\(marker)")
        print("      uid: \(device.uid)")
    }

case "recover":
    let dir = args.count > 1 ? URL(fileURLWithPath: args[1]) : AppPaths.inflight
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let wavs = files.filter { $0.hasSuffix(".wav") }.map { dir.appendingPathComponent($0) }
    guard !wavs.isEmpty else {
        print("Nothing to recover in \(dir.path)")
        exit(0)
    }
    print("Recovering \(wavs.count) file(s) from \(dir.path)")

    var usable: [URL] = []
    for wav in wavs {
        switch WavRecovery.probe(wav) {
        case .usable(let probe):
            if probe.needsRepair {
                WavRecovery.repair(wav)
                print(String(
                    format: "  repaired %@ (%.1fs, header said %d bytes)",
                    wav.lastPathComponent, probe.duration, probe.declaredDataBytes))
            } else {
                print(String(format: "  intact   %@ (%.1fs)", wav.lastPathComponent, probe.duration))
            }
            usable.append(wav)
        case .tooShort(let probe):
            print(String(format: "  too short %@ (%.2fs)", wav.lastPathComponent, probe.duration))
        case .invalid(let reason):
            print("  invalid  \(wav.lastPathComponent): \(reason)")
        }
    }

    guard !usable.isEmpty else { exit(1) }
    let worker = await makeWorker()
    for wav in usable {
        if let output = await transcribe(worker, wav) {
            print("\n\(wav.lastPathComponent):")
            print(output.text)
        }
    }

default:
    print("""
        blurt-cli — headless side of Blurt

          selftest                 transcribe the fixtures and check the text
          transcribe <file.wav>    transcribe one file
          models                   model cache location and size
          simulate-crash <wav>     write a recording, then die before finalizing
          recover [dir]            repair and transcribe abandoned recordings
          tap-probe                report permissions and whether a tap can be made
        """)
}
