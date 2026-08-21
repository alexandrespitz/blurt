import Foundation

/// Reads WAV files that may have been abandoned mid-write.
///
/// The rule everywhere here: believe the file size, never the header. A file
/// that was still being written has zeroed size fields, and a file killed by a
/// power cut may have a torn final sample.
enum WavRecovery {

    struct Probe {
        var frames: Int
        var sampleRate: Int
        var channels: Int
        var declaredDataBytes: Int
        var needsRepair: Bool
        var duration: Double { sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0 }
    }

    enum Verdict {
        /// Usable. `repair` is a no-op when `needsRepair` is false.
        case usable(Probe)
        /// Header is intact but there is (almost) no audio in it.
        case tooShort(Probe)
        /// Not a WAV we wrote, or unreadable. Never auto-deleted — quarantined.
        case invalid(String)
    }

    /// Anything shorter than this is an accidental key tap, not a dictation.
    static let minimumUsableSeconds = 0.4

    static func probe(_ url: URL) -> Verdict {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .invalid("cannot open file")
        }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: WavWriter.headerBytes),
              header.count == WavWriter.headerBytes
        else {
            return .invalid("shorter than a WAV header")
        }

        let bytes = [UInt8](header)
        func tag(_ at: Int) -> String { String(bytes: bytes[at..<(at + 4)], encoding: .ascii) ?? "" }
        func u32(_ at: Int) -> Int {
            let b0 = Int(bytes[at])
            let b1 = Int(bytes[at + 1]) << 8
            let b2 = Int(bytes[at + 2]) << 16
            let b3 = Int(bytes[at + 3]) << 24
            return b0 | b1 | b2 | b3
        }
        func u16(_ at: Int) -> Int {
            let b0 = Int(bytes[at])
            let b1 = Int(bytes[at + 1]) << 8
            return b0 | b1
        }

        guard tag(0) == "RIFF", tag(8) == "WAVE", tag(12) == "fmt ", tag(36) == "data" else {
            return .invalid("not a Blurt WAV layout")
        }
        guard u16(20) == 1 else { return .invalid("not PCM") }

        let channels = u16(22)
        let sampleRate = u32(24)
        let bitsPerSample = u16(34)
        guard channels == 1, bitsPerSample == 16, sampleRate > 0 else {
            return .invalid("unexpected format (\(channels)ch \(bitsPerSample)bit \(sampleRate)Hz)")
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let total = (attrs?[.size] as? NSNumber)?.intValue, total >= WavWriter.headerBytes
        else {
            return .invalid("cannot size file")
        }

        // Round down to a whole sample: a torn write can leave a stray byte.
        let actualDataBytes = (total - WavWriter.headerBytes) & ~1
        let declared = u32(40)
        let frames = actualDataBytes / (channels * 2)

        let probe = Probe(
            frames: frames,
            sampleRate: sampleRate,
            channels: channels,
            declaredDataBytes: declared,
            needsRepair: declared != actualDataBytes)

        if probe.duration < minimumUsableSeconds { return .tooShort(probe) }
        return .usable(probe)
    }

    /// Rewrites the size fields from the real file size. Idempotent.
    @discardableResult
    static func repair(_ url: URL) -> Bool {
        guard case .usable(let probe) = probe(url) else { return false }
        guard probe.needsRepair else { return true }

        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let dataBytes = probe.frames * probe.channels * 2
        func patch(_ value: UInt32, at offset: off_t) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { raw in
                guard let base = raw.baseAddress else { return }
                _ = pwrite(fd, base, 4, offset)
            }
        }
        patch(UInt32(36 + dataBytes), at: 4)
        patch(UInt32(dataBytes), at: 40)

        // A repaired file that a later crash un-repairs helps nobody.
        _ = fcntl(fd, F_FULLFSYNC)
        Log.info("Repaired WAV header for \(url.lastPathComponent) (\(String(format: "%.1f", probe.duration))s)")
        return true
    }
}
