import SwiftUI

struct GeneralTab: View {

    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                permissionsCard
                hotkeyCard
                microphoneCard
                learningCard
                settingsCard
                aboutCard
            }
            .padding(20)
        }
        .onAppear { coordinator.refreshInputDevices() }
    }

    // MARK: - Microphone & language

    private var microphoneCard: some View {
        SectionCard(
            title: "Microphone & language",
            subtitle: "Which mic Blurt listens to, and whether to pin one language."
        ) {
            Picker("Microphone", selection: $coordinator.inputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(coordinator.inputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 380)

            Picker("Language", selection: $coordinator.languageHint) {
                Text("Detect automatically").tag(String?.none)
                ForEach(coordinator.languageOptions, id: \.code) { option in
                    Text(option.name).tag(String?.some(option.code))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 380)

            Text(
                "Auto-detect is right for normal use — you can switch languages "
                + "mid-sentence. Pin a language only if very short dictations "
                + "keep coming out in the wrong one."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Learning

    @State private var newTerm = ""
    @State private var newRuleHeard = ""
    @State private var newRuleReplacement = ""

    private var learningCard: some View {
        SectionCard(
            title: "Learning",
            subtitle: "Blurt gets better the more you fix it — all of it on this Mac, none of it uploaded."
        ) {
            if let learned = coordinator.justLearned {
                HStack(spacing: 8) {
                    Image(systemName: "graduationcap.fill").foregroundStyle(.blue)
                    Text(learned).font(.system(size: 12))
                    Spacer()
                    Button("OK") { coordinator.dismissJustLearned() }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.blue.opacity(0.09)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Words and names it should know")
                    .font(.system(size: 12, weight: .medium))
                Text(
                    "Anything the model keeps mishearing — product names, people, jargon. "
                    + "Close-sounding words in a dictation get corrected to these."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                HStack {
                    TextField("Add a word — e.g. Kubernetes", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit { submitTerm() }
                    Button("Add") { submitTerm() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !coordinator.vocabTerms.isEmpty {
                    FlowChips(items: coordinator.vocabTerms.map { ($0.id, $0.text) }) { id in
                        coordinator.removeVocabTerm(id: id)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Corrections")
                    .font(.system(size: 12, weight: .medium))
                Text(
                    "Exact replacements. Add your own, or let Blurt learn them: fix the "
                    + "same word twice while editing a transcript in History and the rule "
                    + "appears here."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                HStack {
                    TextField("When it writes…", text: $newRuleHeard)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("…it should be", text: $newRuleReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        coordinator.addRule(heard: newRuleHeard, replacement: newRuleReplacement)
                        newRuleHeard = ""
                        newRuleReplacement = ""
                    }
                    .disabled(
                        newRuleHeard.trimmingCharacters(in: .whitespaces).isEmpty
                            || newRuleReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(maxWidth: 480)

                ForEach(coordinator.correctionRules) { rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { coordinator.setRule(id: rule.id, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)

                        Text("“\(rule.heard)”").font(.system(size: 12))
                        Image(systemName: "arrow.right").font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("“\(rule.replacement)”").font(.system(size: 12, weight: .medium))

                        if rule.source == .learned {
                            Text("learned")
                                .font(.system(size: 9.5))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                                .foregroundStyle(.blue)
                        }
                        if rule.hits > 0 {
                            Text("used \(rule.hits)×")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            coordinator.removeRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func submitTerm() {
        coordinator.addVocabTerm(newTerm)
        newTerm = ""
    }

    // MARK: - Status

    private var statusCard: some View {
        SectionCard(title: "Status") {
            HStack(spacing: 10) {
                Image(systemName: coordinator.menuBarSymbol)
                    .font(.system(size: 15))
                    .foregroundStyle(coordinator.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.statusLine)
                        .font(.system(size: 13, weight: .medium))

                    if case .downloading(let fraction, _) = coordinator.modelState {
                        ProgressView(value: fraction)
                            .frame(maxWidth: 320)
                    } else if coordinator.lastRealtimeFactor > 0 {
                        Text(String(
                            format: "Last dictation transcribed %.0f× faster than real time.",
                            coordinator.lastRealtimeFactor))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if case .failed = coordinator.modelState {
                    Button("Retry") { coordinator.retryModel() }
                }
            }

            if let note = coordinator.lastRecoveryNote {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.blue)
                    Text(note)
                        .font(.system(size: 12))
                    Spacer()
                    Button("Dismiss") { coordinator.dismissRecoveryNote() }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(Color.blue.opacity(0.09)))
            }
        }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        SectionCard(
            title: "Permissions",
            subtitle: "Blurt needs both to work. Grants take effect immediately — no restart."
        ) {
            permissionRow(
                name: "Microphone",
                detail: "To hear what you dictate.",
                access: coordinator.permissions.microphone,
                grant: { coordinator.requestMicrophone() },
                pane: .microphone)

            Divider()

            permissionRow(
                name: "Accessibility",
                detail: "To notice your dictation key and to paste for you.",
                access: coordinator.permissions.accessibility,
                grant: { coordinator.requestAccessibility() },
                pane: .accessibility)

            if coordinator.tapStatus == .notPermitted
                && coordinator.permissions.accessibility.isGranted
            {
                Divider()
                permissionRow(
                    name: "Input Monitoring",
                    detail: "This Mac also wants this one before it will let Blurt watch for the key.",
                    access: coordinator.permissions.inputMonitoring,
                    grant: { coordinator.permissionsService.requestInputMonitoring() },
                    pane: .inputMonitoring)
            }
        }
    }

    private func permissionRow(
        name: String,
        detail: String,
        access: PermissionsService.Access,
        grant: @escaping () -> Void,
        pane: PermissionsService.Pane
    ) -> some View {
        HStack(spacing: 10) {
            StatusDot(ok: access.isGranted)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if access.isGranted {
                Text("Granted").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if access == .notDetermined {
                Button("Grant", action: grant)
            } else {
                Button("Open Settings") { coordinator.openSettings(pane) }
            }
        }
    }

    // MARK: - Hotkey

    private var hotkeyCard: some View {
        SectionCard(
            title: "Dictation key",
            subtitle: "Tap it to start, tap again to stop. Hold it to dictate only while held."
        ) {
            Picker("Key", selection: $coordinator.hotkey) {
                ForEach(HotkeySpec.all, id: \.id) { spec in
                    Text("\(spec.symbol)  \(spec.displayName)").tag(spec)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)

            if let note = coordinator.hotkey.note {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if coordinator.tapStatus != .running {
                Text(
                    coordinator.tapStatus == .notPermitted
                        ? "Blurt cannot watch the keyboard yet — grant Accessibility above."
                        : "Keyboard watching is starting up…"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Settings

    private var settingsCard: some View {
        SectionCard(title: "Behaviour") {
            Toggle(isOn: $coordinator.autoPaste) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paste automatically after dictating")
                    Text("The text is always copied. With this on, Blurt also types ⌘V for you.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $coordinator.livePreview) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show live text while recording")
                    Text("The floating pill shows what the model is hearing, as you speak.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $coordinator.gazeMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gaze Mode — look, talk, done")
                    Text(
                        "Hands-free: Blurt listens continuously and your pauses cut the "
                        + "sentences. Look at a text box — even a specific one, like a search "
                        + "bar versus a message bar — and it becomes the outlined target. "
                        + "Nothing is clicked and no windows move; what you say simply lands "
                        + "in the outlined box, even if you are already looking at the next "
                        + "one. The live text appears inside the box when the app allows it, "
                        + "otherwise on a small overlay docked to it. Double-tap your "
                        + "dictation key to turn this mode on or off anywhere; a single tap "
                        + "pauses listening. Works with any eye tracker that moves the "
                        + "pointer where you look; without one it follows the pointer. The "
                        + "microphone stays open while this is on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $coordinator.playSounds) {
                Text("Play a quiet sound when recording starts and stops")
            }

            if coordinator.tidyAvailable {
                Toggle(isOn: $coordinator.tidyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tidy up dictations with Apple Intelligence")
                        Text(
                            "Removes “um”s and false starts, fixes punctuation — using the "
                            + "on-device model, so it still never leaves this Mac. Adds a few "
                            + "seconds per dictation (the first one after launch is slowest).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let reason = coordinator.tidyUnavailableReason {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("Tidy-up with Apple Intelligence is off: \(reason)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Toggle(isOn: $coordinator.saveHistory) {
                Text("Keep a history of transcripts")
            }

            Toggle(isOn: $coordinator.launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Blurt when I log in")
                    Text("Works best once Blurt lives in your Applications folder.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Picker(selection: $coordinator.retention) {
                ForEach(AudioRetention.allCases) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the audio")
                    Text("Recordings are only kept so a crash cannot lose them. They are never uploaded.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("Show Data Folder") { coordinator.revealDataFolder() }
                Spacer()
            }
        }
    }

    private var aboutCard: some View {
        SectionCard(title: "Privacy") {
            Text(
                "Speech is transcribed on this Mac by NVIDIA's Parakeet v3 model, running on the "
                + "Neural Engine. Blurt never uploads your audio or your text. The only time it "
                + "uses the network is the one-off model download."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "One thing worth knowing: transcripts go to the normal macOS clipboard, which "
                + "syncs to your other Apple devices through Universal Clipboard and is readable "
                + "by clipboard manager apps."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Version \(appVersion) · 25 European languages, detected automatically")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        return short
    }
}
