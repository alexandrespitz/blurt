import Foundation

/// Streams 16-bit mono PCM to disk while recording, so a crash, force-quit or
/// freeze can never cost more than the samples that have not been handed to the
/// kernel yet.
///
/// The RIFF/data size fields stay zero until `finalize()`. Recovery therefore
/// never trusts the header — it derives the length from the file size (see
/// `WavRecovery`). That is what makes a half-written file readable.
final class WavWriter {

    enum WriteError: LocalizedError {
        case openFailed(String, Int32)
        case writeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .openFailed(let path, let code):
                return "Could not create \(path): \(String(cString: strerror(code)))"
            case .writeFailed(let code):
                return "Could not write audio: \(String(cString: strerror(code)))"
            }
        }
    }

    static let headerBytes = 44

    let url: URL
    let sampleRate: Int
    let channels: Int

    private var fd: Int32 = -1
    private(set) var framesWritten: Int = 0
    private(set) var isOpen = false

    var durationSeconds: Double { Double(framesWritten) / Double(sampleRate) }

    init(url: URL, sampleRate: Int = 16000, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        // O_EXCL: a UUID collision must fail loudly rather than corrupt a recording.
        fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw WriteError.openFailed(url.path, errno) }
        isOpen = true

        try writeAll(Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0))

        // Make the directory entry itself durable, otherwise a power cut can
        // leave the data blocks with no file pointing at them.
        syncParentDirectory()
        AppPaths.excludeFromBackup(url)
    }

    /// Appends samples. Returns only once the bytes are in the kernel's hands,
    /// which is what survives a process crash.
    func append(_ samples: [Int16]) throws {
        guard isOpen, !samples.isEmpty else { return }
        try samples.withUnsafeBufferPointer { buf in
            let data = Data(buffer: buf)
            try writeAll(data)
        }
        framesWritten += samples.count / channels
    }

    /// Durability barrier for power loss / kernel panic. Called on a slow
    /// cadence by the recorder; `append` deliberately does not wait on it.
    func sync() {
        guard isOpen else { return }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    /// Patches the two size fields and closes. After this the file is a
    /// completely ordinary WAV.
    func finalize() {
        guard isOpen else { return }
        let dataBytes = framesWritten * channels * 2
        patch(UInt32(36 + dataBytes), at: 4)
        patch(UInt32(dataBytes), at: 40)
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
        fd = -1
        isOpen = false
        AppPaths.protectFile(url)
    }

    /// Closes without patching the header (used when we are about to delete the
    /// file, or when tearing down after an error).
    func abort() {
        guard isOpen else { return }
        close(fd)
        fd = -1
        isOpen = false
    }

    deinit { if isOpen { close(fd) } }

    // MARK: - Internals

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n > 0 {
                    remaining -= n
                    ptr = ptr.advanced(by: n)
                } else if n < 0 && errno == EINTR {
                    continue  // interrupted by a signal, not a failure
                } else {
                    throw WriteError.writeFailed(errno)
                }
            }
        }
    }

    private func patch(_ value: UInt32, at offset: off_t) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < 4 {
                let n = pwrite(fd, base.advanced(by: written), 4 - written, offset + off_t(written))
                if n > 0 { written += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
    }

    private func syncParentDirectory() {
        let dir = url.deletingLastPathComponent().path
        let dfd = open(dir, O_RDONLY)
        guard dfd >= 0 else { return }
        _ = fcntl(dfd, F_FULLFSYNC)
        close(dfd)
    }

    /// A canonical 44-byte PCM WAV header.
    static func header(sampleRate: Int, channels: Int, dataBytes: Int) -> Data {
        var d = Data(capacity: headerBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2

        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                      // PCM fmt chunk size
        u16(1)                       // format = PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(16)                      // bits per sample
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        return d
    }
}
