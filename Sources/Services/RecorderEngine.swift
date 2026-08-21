import AVFoundation
import AudioToolbox
import Foundation

/// Captures the microphone and streams it to disk as it arrives.
///
/// Everything here is confined to its own serial queue and deliberately
/// independent of the main thread — a wedged UI must never be able to stall or
/// silence the capture path.
///
/// The tap callback does the minimum: copy the samples and hand them off. All
/// conversion and file I/O happens on `ioQueue`, so a slow disk can never block
/// CoreAudio's real-time thread.
final class RecorderEngine {

    enum RecorderError: LocalizedError {
        case noInputDevice
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone is available. Check Sound settings and try again."
            case .engineFailed(let why):
                return "The audio engine could not start: \(why)"
            }
        }
    }

    struct Outcome {
        var frames: Int
        var duration: Double
        var truncated: Bool
        var error: String?
    }

    static let sampleRate = 16000

    /// Roughly 30 seconds of backlog. Reaching it means the disk has stopped
    /// keeping up, at which point we stop cleanly rather than drop audio silently.
    private let maxPendingBuffers = 300

    private let engine = AVAudioEngine()
    private let ioQueue = DispatchQueue(label: "com.alexspitz.blurt.recorder.io", qos: .userInitiated)
    private let stateLock = NSLock()

    private var writer: WavWriter?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var tapInstalled = false
    private var running = false
    private var pendingBuffers = 0
    private var overflowed = false
    private var writeError: String?
    private var lastSyncAt: CFAbsoluteTime = 0
    private var observer: NSObjectProtocol?

    /// Fired ~20×/s with a 0…1 loudness value while recording.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Fired if capture has to stop by itself (disk full, backlog, device loss).
    var onFailure: (@Sendable (String) -> Void)?
    /// Each converted 16 kHz chunk, for the live preview. Called on the io queue.
    var onSamples: (@Sendable ([Float]) -> Void)?

    var isRecording: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Never touch the engine inside the notification callback.
            self?.ioQueue.async { self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Lifecycle

    /// Opens `url` and starts capturing. Synchronous so the caller knows the
    /// file exists before the first word is spoken.
    func start(writingTo url: URL) throws {
        var thrown: Error?
        ioQueue.sync {
            do {
                try startLocked(url: url)
            } catch {
                thrown = error
                teardownLocked()
            }
        }
        if let thrown { throw thrown }
    }

    /// Gaze Mode's always-on ear: the same capture chain with no file of its
    /// own. Audio flows out through `onSamples`/`onLevel`; whoever listens
    /// decides what deserves a WAV.
    func startMonitoring() throws {
        var thrown: Error?
        ioQueue.sync {
            do {
                try startLocked(url: nil)
            } catch {
                thrown = error
                teardownLocked()
            }
        }
        if let thrown { throw thrown }
    }

    /// Stops capture and finalizes the file. Returns what actually got written.
    @discardableResult
    func stop() -> Outcome {
        var outcome = Outcome(frames: 0, duration: 0, truncated: false, error: nil)
        ioQueue.sync {
            guard running || writer != nil else { return }
            outcome = teardownLocked()
        }
        return outcome
    }

    // MARK: - Internals (ioQueue only)

    private func startLocked(url: URL?) throws {
        let input = engine.inputNode
        applyPreferredDevice()
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false)
        else {
            throw RecorderError.engineFailed("could not build the 16 kHz output format")
        }

        guard let conv = AVAudioConverter(from: hwFormat, to: outFormat) else {
            throw RecorderError.engineFailed("no converter from \(hwFormat) to 16 kHz mono")
        }

        // Monitoring mode has no file; utterances get their own writers later.
        writer = try url.map { try WavWriter(url: $0, sampleRate: Self.sampleRate, channels: 1) }
        converter = conv
        outputFormat = outFormat
        overflowed = false
        writeError = nil
        pendingBuffers = 0
        lastSyncAt = CFAbsoluteTimeGetCurrent()

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        stateLock.lock(); running = true; stateLock.unlock()
        let destination = url?.lastPathComponent ?? "monitor only"
        Log.info("Capture running (\(destination)) — input \(hwFormat.sampleRate)Hz × \(hwFormat.channelCount)ch")
    }

    @discardableResult
    private func teardownLocked() -> Outcome {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        stateLock.lock(); running = false; stateLock.unlock()

        let frames = writer?.framesWritten ?? 0
        let duration = writer?.durationSeconds ?? 0
        writer?.finalize()
        writer = nil
        converter = nil

        return Outcome(
            frames: frames, duration: duration,
            truncated: overflowed || writeError != nil, error: writeError)
    }

    /// Called on CoreAudio's thread. Keep it short.
    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        stateLock.lock()
        let backlog = pendingBuffers
        pendingBuffers += 1
        stateLock.unlock()

        if backlog > maxPendingBuffers {
            stateLock.lock(); pendingBuffers -= 1; stateLock.unlock()
            ioQueue.async { [weak self] in self?.failOut("the disk stopped keeping up") }
            return
        }

        // The buffer is reused as soon as we return, so copy before hopping.
        guard let copy = Self.copy(buffer) else {
            stateLock.lock(); pendingBuffers -= 1; stateLock.unlock()
            return
        }

        ioQueue.async { [weak self] in
            self?.consume(copy)
            self?.stateLock.lock()
            self?.pendingBuffers -= 1
            self?.stateLock.unlock()
        }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            failOut(error?.localizedDescription ?? "audio conversion failed")
            return
        }
        guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        let count = Int(out.frameLength)
        var samples = [Int16](repeating: 0, count: count)
        var sumSquares: Float = 0
        for i in 0..<count {
            let f = max(-1.0, min(1.0, channel[i]))
            sumSquares += f * f
            samples[i] = Int16(f * 32767.0)
        }

        if let onSamples {
            onSamples(Array(UnsafeBufferPointer(start: channel, count: count)))
        }

        guard let writer else {
            // Monitoring mode: level + samples only, nothing on disk here.
            publishLevel(sumSquares: sumSquares, count: count)
            return
        }

        do {
            try writer.append(samples)
        } catch {
            failOut(error.localizedDescription)
            return
        }

        // Durability barrier on a slow cadence; appends never wait on it.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastSyncAt > 2.0 {
            lastSyncAt = now
            writer.sync()
        }

        publishLevel(sumSquares: sumSquares, count: count)
    }

    private func publishLevel(sumSquares: Float, count: Int) {
        guard let onLevel, count > 0 else { return }
        let rms = sqrt(sumSquares / Float(count))
        // Compress the range so quiet speech still moves the meter.
        let level = min(1.0, max(0.0, (20 * log10(max(rms, 0.000_01)) + 55) / 55))
        onLevel(level)
    }

    private func failOut(_ message: String) {
        guard writeError == nil else { return }
        writeError = message
        overflowed = true
        Log.error("Recording stopped early: \(message)")
        onFailure?(message)
    }

    /// Points the engine's input at the microphone chosen in the dashboard.
    /// Falls back silently to the system default when the device is gone.
    private func applyPreferredDevice() {
        guard let uid = Prefs.inputDeviceUID else { return }
        guard let device = AudioInputDevices.resolve(uid: uid) else {
            Log.info("Chosen microphone is not connected — using the system default")
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            Log.info("Recording from \(device.name)")
        } else {
            Log.error("Could not select \(device.name) (error \(status)) — using the default")
        }
    }

    private func handleConfigurationChange() {
        // macOS stops and uninitializes the engine itself on an I/O format
        // change, so this is a full rebuild, not just a new converter.
        // Applies to both a live recording and Gaze Mode's monitoring.
        stateLock.lock()
        let active = running
        stateLock.unlock()
        guard active else { return }
        Log.info("Audio configuration changed — rebuilding the input chain")

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }

        let input = engine.inputNode
        applyPreferredDevice()
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0,
              let outFormat = outputFormat,
              let conv = AVAudioConverter(from: hwFormat, to: outFormat)
        else {
            failOut("the microphone went away mid-recording")
            return
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            let destination = writer?.url.lastPathComponent ?? "monitor only"
            Log.info("Input chain rebuilt at \(hwFormat.sampleRate)Hz (\(destination))")
        } catch {
            failOut("could not restart after the device changed: \(error.localizedDescription)")
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
        copy.frameLength = buffer.frameLength

        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
            return copy
        }
        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
            return copy
        }
        if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
            return copy
        }
        return nil
    }
}
