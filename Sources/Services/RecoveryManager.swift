import Foundation

/// Picks up whatever the last run left behind.
///
/// Because a running instance holds the single-instance lock for its whole
/// life, anything still sitting in `inflight/` when we get that lock belongs to
/// a session that died. There is no guessing involved.
///
/// Nothing here deletes audio it cannot read. Files that fail to parse are
/// moved to `quarantine/` and surfaced in the dashboard — for an app whose one
/// promise is "you will not lose what you said", silent deletion is the wrong
/// failure mode. Only genuinely empty files are dropped.
final class RecoveryManager {

    struct Report {
        var requeued: [UUID] = []
        var recommitted: [UUID] = []
        var quarantined: [String] = []
        var removedEmpty: Int = 0

        var total: Int { requeued.count + recommitted.count }
        var isEmpty: Bool { total == 0 && quarantined.isEmpty }
    }

    private let worker: TranscriptionWorker
    private let controller: RecordingController

    init(worker: TranscriptionWorker, controller: RecordingController) {
        self.worker = worker
        self.controller = controller
    }

    /// Scans `inflight/` and returns what it did. Safe to run repeatedly.
    @discardableResult
    func scan() -> Report {
        AppPaths.ensure()
        var report = Report()

        // A manifest that fails to decode must not make its WAV invisible —
        // neither a job nor an orphan. Park the broken sidecar in quarantine;
        // the WAV it was hiding becomes an orphan and is adopted below.
        let audit = JobStore.audit(in: AppPaths.inflight)
        for corrupt in audit.corruptManifests {
            let parked = AppPaths.quarantine
                .appendingPathComponent(corrupt.lastPathComponent + ".corrupt")
            try? FileManager.default.removeItem(at: parked)
            do {
                try FileManager.default.moveItem(at: corrupt, to: parked)
                Log.error("Quarantined an unreadable manifest: \(corrupt.lastPathComponent)")
                report.quarantined.append(corrupt.lastPathComponent)
            } catch {
                Log.error("Could not quarantine \(corrupt.lastPathComponent): \(error.localizedDescription)")
            }
        }

        adoptOrphanedWavs()

        for job in JobStore.loadAll(in: AppPaths.inflight) {
            let wav = JobStore.wavURL(for: job, in: AppPaths.inflight)

            guard FileManager.default.fileExists(atPath: wav.path) else {
                // Manifest with no audio: nothing to recover.
                try? FileManager.default.removeItem(
                    at: JobStore.manifestURL(for: job, in: AppPaths.inflight))
                continue
            }

            // Already transcribed last time — finish the job, do not redo it.
            if job.state == .transcribed, let text = job.text, !text.isEmpty {
                controller.recommitRecovered(job, in: AppPaths.inflight)
                report.recommitted.append(job.id)
                continue
            }

            switch WavRecovery.probe(wav) {
            case .usable(let probe):
                if probe.needsRepair { WavRecovery.repair(wav) }
                var recovered = job
                recovered.source = .recovered
                recovered.state = .finalized
                recovered.durationSeconds = probe.duration
                JobStore.save(recovered, in: AppPaths.inflight)
                controller.enqueueTranscription(id: recovered.id, url: wav, source: .recovered)
                report.requeued.append(recovered.id)
                Log.info(
                    "Recovering \(String(format: "%.1f", probe.duration))s of audio from a previous session")

            case .tooShort(let probe):
                if probe.frames == 0 {
                    JobStore.remove(job, in: AppPaths.inflight)
                    report.removedEmpty += 1
                } else {
                    quarantine(job, reason: "only \(String(format: "%.2f", probe.duration))s of audio")
                    report.quarantined.append(wav.lastPathComponent)
                }

            case .invalid(let reason):
                quarantine(job, reason: reason)
                report.quarantined.append(wav.lastPathComponent)
            }
        }

        if !report.isEmpty {
            Log.info(
                "Recovery: \(report.requeued.count) to transcribe, "
                    + "\(report.recommitted.count) already transcribed, "
                    + "\(report.quarantined.count) quarantined")
        }
        return report
    }

    /// Anything in `quarantine/` that the user might still want.
    func quarantinedFiles() -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: AppPaths.quarantine.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".wav") }
            .map { AppPaths.quarantine.appendingPathComponent($0) }
    }

    /// Recordings still waiting for a successful transcription.
    func pendingJobs() -> [RecordingJob] {
        JobStore.loadAll(in: AppPaths.inflight).filter { $0.state != .committed }
    }

    // MARK: - Internals

    /// A crash between opening the WAV and writing the manifest leaves audio
    /// with no sidecar. It is still a real dictation, so give it one.
    private func adoptOrphanedWavs() {
        for url in JobStore.orphanedWavs(in: AppPaths.inflight) {
            let name = url.deletingPathExtension().lastPathComponent
            let id = UUID(uuidString: name) ?? UUID()
            var job = RecordingJob(id: id, source: .recovered)
            job.state = .finalized

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let created = attrs?[.creationDate] as? Date { job.startedAt = created }

            if id.uuidString != name {
                // Unexpected filename — move it alongside its new identity.
                let dest = JobStore.wavURL(for: job, in: AppPaths.inflight)
                try? FileManager.default.moveItem(at: url, to: dest)
            }
            JobStore.save(job, in: AppPaths.inflight)
            Log.info("Adopted an orphaned recording: \(url.lastPathComponent)")
        }
    }

    private func quarantine(_ job: RecordingJob, reason: String) {
        var job = job
        job.lastError = reason
        JobStore.save(job, in: AppPaths.inflight)
        JobStore.move(job, from: AppPaths.inflight, to: AppPaths.quarantine)
        Log.error("Quarantined \(job.wavFilename): \(reason)")
    }
}
