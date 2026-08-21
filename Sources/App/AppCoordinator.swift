import AppKit
import Combine
import Foundation
import SwiftUI

/// Wires the pieces together and mirrors their state for the UI.
///
/// Deliberately a *projection*: the keyboard tap, the recorder and the
/// transcription queue all run without it. If the main thread hangs, the UI
/// goes stale — the dictation still lands on disk and still gets transcribed.
@MainActor
final class AppCoordinator: ObservableObject {

    /// One app, one coordinator. The menu bar scene and the hand-managed
    /// dashboard window both need to reach the same instance.
    static let shared = AppCoordinator()

    @Published private(set) var phase: RecordingController.Phase = .idle
    @Published private(set) var modelState: TranscriptionWorker.ModelState = .notReady
    @Published private(set) var permissions: PermissionsService.Snapshot
    @Published private(set) var tapStatus: EventTapService.Status = .stopped
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var pending: [RecordingJob] = []
    @Published private(set) var quarantined: [URL] = []
    @Published private(set) var level: Float = 0
    @Published private(set) var lastRecoveryNote: String?
    @Published private(set) var elapsed: TimeInterval = 0

    @Published var hotkey: HotkeySpec {
        didSet {
            guard hotkey != oldValue else { return }
            Prefs.hotkey = hotkey
            tap.updateSpec(hotkey)
        }
    }

    @Published var autoPaste: Bool { didSet { Prefs.autoPaste = autoPaste } }
    @Published var saveHistory: Bool { didSet { Prefs.saveHistory = saveHistory } }
    @Published var retention: AudioRetention {
        didSet {
            Prefs.retention = retention
            controller.collectGarbage()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LaunchAtLoginService.isEnabled else { return }
            LaunchAtLoginService.set(launchAtLogin)
        }
    }
    @Published var didCompleteOnboarding: Bool {
        didSet { Prefs.didCompleteOnboarding = didCompleteOnboarding }
    }

    @Published var livePreview: Bool { didSet { Prefs.livePreview = livePreview } }
    @Published var playSounds: Bool { didSet { Prefs.playSounds = playSounds } }
    @Published var tidyEnabled: Bool { didSet { Prefs.tidyEnabled = tidyEnabled } }
    @Published var gazeMode: Bool {
        didSet {
            Prefs.gazeMode = gazeMode
            guard gazeMode != oldValue else { return }
            if gazeMode { startGazeSession() } else { stopGazeSession() }
        }
    }
    /// Whether the continuous gaze session is currently hearing you.
    @Published private(set) var gazeListening = false
    @Published private(set) var gazeTargetName: String?

    /// nil = system default microphone.
    @Published var inputDeviceUID: String? {
        didSet { Prefs.inputDeviceUID = inputDeviceUID }
    }
    @Published private(set) var inputDevices: [AudioInputDevices.Device] = []

    /// nil = automatic language detection.
    @Published var languageHint: String? {
        didSet { Prefs.languageHint = languageHint }
    }

    @Published private(set) var vocabTerms: [VocabTerm] = []
    @Published private(set) var correctionRules: [CorrectionRule] = []
    @Published private(set) var justLearned: String?

    let permissionsService = PermissionsService()
    private let historyStore = HistoryStore()
    private let vocabularyStore = VocabularyStore()
    private let worker = TranscriptionWorker()
    private let tap = EventTapService()
    private let controller: RecordingController
    private let recovery: RecoveryManager
    private let hud = HUDPanelController()
    private let preview: PreviewEngine
    private let gazeFollow = GazeFollowService()
    private let highlight = HighlightPanelController()

    private var recordingStartedAt: Date?
    private var elapsedTimer: Timer?
    private var gcTimer: Timer?
    private var hudDelayTask: Task<Void, Never>?

    init() {
        Prefs.registerDefaults()
        AppPaths.ensure()

        hotkey = Prefs.hotkey
        autoPaste = Prefs.autoPaste
        saveHistory = Prefs.saveHistory
        retention = Prefs.retention
        didCompleteOnboarding = Prefs.didCompleteOnboarding
        launchAtLogin = LaunchAtLoginService.isEnabled
        livePreview = Prefs.livePreview
        playSounds = Prefs.playSounds
        tidyEnabled = Prefs.tidyEnabled
        gazeMode = Prefs.gazeMode
        inputDeviceUID = Prefs.inputDeviceUID
        languageHint = Prefs.languageHint
        permissions = permissionsService.snapshot()

        controller = RecordingController(
            worker: worker, history: historyStore, vocabulary: vocabularyStore)
        recovery = RecoveryManager(worker: worker, controller: controller)
        preview = PreviewEngine(worker: worker)

        history = historyStore.all
        vocabTerms = vocabularyStore.terms
        correctionRules = vocabularyStore.rules
        wireCallbacks()
    }

    // MARK: - Startup

    func start() {
        tap.start(spec: hotkey)
        permissionsService.startPolling()
        controller.collectGarbage()
        refreshPending()

        gcTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller.collectGarbage() }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.worker.prepare()
            await MainActor.run { self.runRecovery() }
        }

        // One-shot verification hook: `defaults write com.alexspitz.blurt
        // debugGazeProbe -bool true`, relaunch, park the pointer somewhere,
        // and the result of a real gaze acquisition lands in the log. Exists
        // because a terminal-launched process cannot hold the Accessibility
        // grant this app has.
        if UserDefaults.standard.bool(forKey: "debugGazeProbe") {
            UserDefaults.standard.set(false, forKey: "debugGazeProbe")
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if let target = GazeTargetService.acquireUnderPointer() {
                    let frame = target.inputFrame.map {
                        String(format: "%.0f,%.0f %.0f×%.0f", $0.origin.x, $0.origin.y, $0.width, $0.height)
                    } ?? "none"
                    // Judge the raise from inside: frontmost right after,
                    // before anything else can steal focus back.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let front = NSWorkspace.shared.frontmostApplication
                    let raised = front?.processIdentifier == target.pid
                    Log.info(
                        "GazeProbe: app=\(target.appName ?? "?") pid=\(target.pid) "
                            + "input=\(target.foundInput) frame=\(frame) "
                            + "raise=\(raised ? "CONFIRMED" : "failed, front=\(front?.localizedName ?? "?")")")
                } else {
                    Log.info("GazeProbe: nothing acquired under the pointer")
                }
            }
        }
    }

    func shutdown() {
        if gazeMode { stopGazeSession() }
        controller.finalizeForShutdown()
        tap.stop()
        permissionsService.stopPolling()
        elapsedTimer?.invalidate()
        gcTimer?.invalidate()
    }

    private func runRecovery() {
        let report = recovery.scan()
        refreshPending()
        guard !report.isEmpty else { return }

        var parts: [String] = []
        if report.total == 1 {
            parts.append("Recovered a dictation from before the last quit")
        } else if report.total > 1 {
            parts.append("Recovered \(report.total) dictations from before the last quit")
        }
        if !report.quarantined.isEmpty {
            parts.append("\(report.quarantined.count) recording(s) need attention")
        }
        let note = parts.joined(separator: " · ")
        lastRecoveryNote = note
        hud.show(.message(note), autoHideAfter: 6)
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        historyStore.onChange = { [weak self] entries in
            Task { @MainActor in self?.history = entries }
        }

        worker.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.modelState = state
                // Gaze Mode may have been switched on before the model was
                // ready — bring the session up now.
                if state.isReady && self.gazeMode && !self.controller.gazeListening {
                    self.startGazeSession()
                }
            }
        }

        tap.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.tapStatus = status }
        }

        tap.onCommand = { [weak self] command in
            Task { @MainActor in self?.handle(command) }
        }

        permissionsService.onChange = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                let wasBlocked = !self.permissions.accessibility.isGranted
                self.permissions = snapshot
                // The tap could not be created before the grant — try again now.
                if wasBlocked && snapshot.accessibility.isGranted && self.tapStatus != .running {
                    self.tap.start(spec: self.hotkey)
                }
            }
        }

        controller.onPhase = { [weak self] phase in
            Task { @MainActor in self?.apply(phase) }
        }

        controller.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }

        controller.onSamples = { [weak self] samples in
            self?.preview.consume(samples)
        }

        preview.onPartial = { [weak self] text in
            guard let self else { return }
            // In Gaze Mode the partial streams into the box itself when the
            // app allows it; the pill only carries it otherwise.
            self.controller.updateGazePartial(text)
            Task { @MainActor in
                if !self.controller.inBoxActive {
                    self.hud.updatePartial(text)
                }
            }
        }

        controller.onPendingChanged = { [weak self] in
            Task { @MainActor in self?.refreshPending() }
        }

        controller.onGazeEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .listeningStarted:
                    self.gazeListening = true
                case .listeningStopped(let reason):
                    self.gazeListening = false
                    if let reason {
                        self.hud.show(.message(reason), autoHideAfter: 4)
                    }
                case .utteranceBegan:
                    self.playSound(start: true)
                    if self.livePreview { self.preview.start() }
                    self.recordingStartedAt = Date()
                    self.startElapsedTimer()
                    self.hud.show(.recording)
                case .utteranceEnded:
                    self.playSound(start: false)
                    self.preview.stop()
                    self.stopElapsedTimer()
                }
            }
        }

        vocabularyStore.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.vocabTerms = self.vocabularyStore.terms
                self.correctionRules = self.vocabularyStore.rules
            }
        }
    }

    private func handle(_ command: HotkeyStateMachine.Command) {
        // Double-tap anywhere flips Gaze Mode itself — no mousing to the menu.
        if command == .doubleTap {
            gazeMode.toggle()
            hud.show(
                .message(gazeMode ? "Gaze Mode on — look, talk, done" : "Gaze Mode off"),
                autoHideAfter: 2)
            return
        }

        // In Gaze Mode the key has one job: pause and resume the always-on
        // listening. Utterances are cut by your pauses, not by key presses.
        if gazeMode {
            switch command {
            case .startRecording, .stopAndTranscribe:
                toggleGazeListening()
            default:
                break
            }
            return
        }

        switch command {
        case .startRecording:
            guard modelState.isReady else {
                hud.show(.message(modelStatusMessage), autoHideAfter: 2.5)
                return
            }
            guard permissions.microphone.isGranted else {
                hud.show(.message("Blurt needs microphone access"), autoHideAfter: 3)
                return
            }
            controller.startRecording()
        case .stopAndTranscribe:
            controller.stopRecording()
        case .cancelRecording:
            controller.cancelRecording()
        case .doubleTap, .enteredHoldMode, .enteredToggleMode, .armHoldTimer, .cancelHoldTimer:
            break  // doubleTap is intercepted above; the rest are hints
        }
    }

    private func apply(_ phase: RecordingController.Phase) {
        self.phase = phase
        switch phase {
        case .recording:
            recordingStartedAt = Date()
            startElapsedTimer()
            if livePreview { preview.start() }
            playSound(start: true)
            // Short grace period so a keyboard shortcut that merely brushed the
            // hotkey never flashes UI.
            hudDelayTask?.cancel()
            hudDelayTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.controller.isRecording else { return }
                self.hud.show(.recording)
            }
        case .transcribing:
            stopElapsedTimer()
            preview.stop()
            playSound(start: false)
            hudDelayTask?.cancel()
            hud.show(.transcribing)
        case .delivered(_, let pasted, let note):
            stopElapsedTimer()
            hudDelayTask?.cancel()
            if let note {
                hud.show(.message(note), autoHideAfter: 3)
            } else {
                hud.show(.done(pasted: pasted), autoHideAfter: 1.2)
            }
        case .discarded(let reason):
            stopElapsedTimer()
            preview.stop()
            hudDelayTask?.cancel()
            if reason == "too short" {
                hud.hide()
            } else {
                hud.show(.message(reason.prefix(1).uppercased() + reason.dropFirst()), autoHideAfter: 2)
            }
        case .failed(let message):
            stopElapsedTimer()
            preview.stop()
            hudDelayTask?.cancel()
            hud.show(.message(message), autoHideAfter: 4)
        case .idle:
            stopElapsedTimer()
            preview.stop()
            hudDelayTask?.cancel()
            hud.hide()
        }
    }

    /// Two quiet clicks so you know the mic state without looking. Subtle on
    /// purpose — this fires dozens of times a day.
    private func playSound(start: Bool) {
        guard playSounds else { return }
        let sound = NSSound(named: start ? "Pop" : "Bottle")
        sound?.volume = 0.28
        sound?.play()
    }

    // MARK: - Gaze Mode session

    /// Look around → focus follows → talk → text lands where you were looking.
    /// The follow service watches the pointer (your eye tracker's output), the
    /// controller listens continuously and cuts utterances at your pauses.
    private func startGazeSession() {
        guard modelState.isReady, permissions.microphone.isGranted,
              permissions.accessibility.isGranted
        else {
            // Not ready yet — start() retries when the model comes up.
            return
        }

        controller.gazeDeliveryProvider = { [weak self] in
            self?.gazeFollow.currentTarget
        }
        gazeFollow.onTarget = { [weak self] target in
            Task { @MainActor in
                guard let self else { return }
                self.gazeTargetName = target.appName
                let anchor = target.inputFrame
                self.hud.setAnchor(anchor, inside: true)
                if let anchor {
                    self.highlight.show(around: anchor)
                } else {
                    self.highlight.hide()
                }
            }
        }
        gazeFollow.start()

        do {
            try controller.startGazeListening()
        } catch {
            hud.show(.message("Gaze Mode: \(error.localizedDescription)"), autoHideAfter: 4)
            gazeFollow.stop()
        }
    }

    private func stopGazeSession() {
        gazeFollow.stop()
        controller.stopGazeListening()
        highlight.hide()
        hud.setAnchor(nil, inside: false)
        gazeTargetName = nil
    }

    private func toggleGazeListening() {
        if controller.gazeListening {
            controller.stopGazeListening()
            hud.show(.message("Gaze Mode paused"), autoHideAfter: 1.5)
        } else {
            do {
                try controller.startGazeListening()
                hud.show(.message("Gaze Mode listening"), autoHideAfter: 1.5)
            } catch {
                hud.show(.message(error.localizedDescription), autoHideAfter: 3)
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsed = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.recordingStartedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                self.hud.update(elapsed: self.elapsed, level: self.level)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
        level = 0
    }

    // MARK: - Actions from the UI

    func toggleDictation() {
        if gazeMode {
            toggleGazeListening()
            return
        }
        if controller.isRecording {
            controller.stopRecording()
        } else if modelState.isReady {
            controller.startRecording()
        }
    }

    func retryModel() {
        Task { [weak self] in
            guard let self else { return }
            await self.worker.prepare()
            await MainActor.run { self.runRecovery() }
        }
    }

    func retry(job: RecordingJob) {
        controller.retry(jobID: job.id)
        refreshPending()
    }

    func discard(job: RecordingJob) {
        JobStore.remove(job, in: AppPaths.inflight)
        refreshPending()
    }

    func transcribeQuarantined(_ url: URL) {
        WavRecovery.repair(url)
        let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
        worker.enqueue(.init(id: id, url: url, source: .recovered))
    }

    func deleteQuarantined(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let manifest = url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: manifest)
        refreshPending()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func deleteHistory(id: UUID) { historyStore.delete(id: id) }
    func clearHistory() { historyStore.clear() }
    func revealDataFolder() { AppPaths.revealInFinder() }

    /// A hand edit in the History tab — the learning loop's food. The stored
    /// entry is updated, and the diff feeds the vocabulary store; the same fix
    /// made twice becomes a rule.
    func editHistory(id: UUID, newText: String) {
        guard let entry = history.first(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.text else { return }

        var updated = entry
        updated.rawText = updated.rawText ?? entry.text
        updated.text = trimmed
        historyStore.upsert(updated)

        let promoted = vocabularyStore.learn(from: entry.text, to: trimmed)
        if !promoted.isEmpty {
            let described = promoted
                .map { "“\($0.heard)” → “\($0.replacement)”" }
                .joined(separator: ", ")
            justLearned = "Learned \(described) — future dictations get this automatically."
        }
    }

    func dismissJustLearned() { justLearned = nil }

    func addVocabTerm(_ text: String) { vocabularyStore.addTerm(text) }
    func removeVocabTerm(id: UUID) { vocabularyStore.removeTerm(id: id) }
    func addRule(heard: String, replacement: String) {
        vocabularyStore.addRule(heard: heard, replacement: replacement, source: .manual)
    }
    func setRule(id: UUID, enabled: Bool) { vocabularyStore.setRule(id: id, enabled: enabled) }
    func removeRule(id: UUID) { vocabularyStore.removeRule(id: id) }

    func refreshInputDevices() {
        inputDevices = AudioInputDevices.all()
    }

    var languageOptions: [(code: String, name: String)] {
        TranscriptionWorker.supportedLanguages
    }

    var tidyAvailable: Bool { TidyService.isAvailable }
    var tidyUnavailableReason: String? { TidyService.unavailableReason }

    /// Writes the whole history to a Markdown file of the user's choosing.
    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "parakeet-transcripts.md"
        panel.title = "Export Transcripts"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines = ["# Blurt transcripts", ""]
        for entry in history.sorted(by: { $0.date < $1.date }) {
            lines.append("## \(formatter.string(from: entry.date))")
            if entry.recovered { lines.append("*(recovered after a crash)*") }
            lines.append("")
            lines.append(entry.text)
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func requestMicrophone() {
        permissionsService.requestMicrophone { [weak self] _ in
            Task { @MainActor in self?.permissions = self?.permissionsService.snapshot() ?? .init(
                microphone: .denied, accessibility: .denied, inputMonitoring: .denied) }
        }
    }

    func requestAccessibility() { permissionsService.requestAccessibility() }
    func openSettings(_ pane: PermissionsService.Pane) { permissionsService.openSettings(pane) }

    func refreshPending() {
        pending = recovery.pendingJobs()
        quarantined = recovery.quarantinedFiles()
    }

    func dismissRecoveryNote() { lastRecoveryNote = nil }

    // MARK: - Derived UI state

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isTranscribing: Bool { phase == .transcribing }

    var menuBarSymbol: String {
        if isRecording { return "mic.fill" }
        if isTranscribing { return "waveform" }
        if gazeMode && modelState.isReady {
            return gazeListening ? "eye" : "eye.slash"
        }
        switch modelState {
        case .downloading, .loading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        case .notReady: return "mic.slash"
        case .ready: return permissions.readyToDictate ? "mic" : "mic.slash"
        }
    }

    var statusLine: String {
        if isRecording { return "Recording…" }
        if isTranscribing { return "Transcribing…" }
        if !permissions.microphone.isGranted { return "Needs microphone access" }
        if !permissions.accessibility.isGranted { return "Needs Accessibility access" }
        return modelStatusMessage
    }

    var modelStatusMessage: String {
        switch modelState {
        case .notReady: return "Starting up…"
        case .downloading(let fraction, let detail):
            return "Downloading model — \(Int(fraction * 100))% (\(detail))"
        case .loading: return "Loading model…"
        case .ready: return "Ready — tap \(hotkey.displayName) to dictate"
        case .failed(let why): return "Model problem: \(why)"
        }
    }

    var lastRealtimeFactor: Double { worker.lastRealtimeFactor }
}
