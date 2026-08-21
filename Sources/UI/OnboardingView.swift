import SwiftUI

/// First run. Asks for the two permissions, lets you pick your key, downloads
/// the model, and then makes you try it once — because a dictation app you have
/// not yet dictated into is just a menu bar icon.
struct OnboardingView: View {

    @ObservedObject var coordinator: AppCoordinator
    @State private var step = 0

    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)

            Divider()

            HStack {
                ForEach(0...lastStep, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == lastStep ? "Done" : "Continue") {
                    if step == lastStep {
                        coordinator.didCompleteOnboarding = true
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)

                if step < lastStep {
                    Button("Skip Setup") { coordinator.didCompleteOnboarding = true }
                        .buttonStyle(.borderless)
                }
            }
            .padding(16)
        }
    }

    private var canContinue: Bool {
        switch step {
        case 3: return coordinator.modelState.isReady
        default: return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: microphone
        case 2: accessibilityAndKey
        case 3: model
        default: tryIt
        }
    }

    private func header(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            header(
                "mic.circle",
                "Welcome to Blurt",
                "Hold a key, talk, let go. The text appears where your cursor is.")

            VStack(alignment: .leading, spacing: 12) {
                bullet("bolt.fill", "Fast", "A minute of speech becomes text in about a second, on the Neural Engine.")
                bullet("globe", "Multilingual", "25 European languages, recognised automatically — no switching.")
                bullet("lock.fill", "Private", "Nothing is uploaded. The only network use is the one-off model download.")
                bullet(
                    "arrow.uturn.backward", "Crash-proof",
                    "Your voice is written to disk as you speak. If anything freezes or dies, "
                        + "Blurt transcribes the recording next time it opens.")
            }
            .frame(maxWidth: 460)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var microphone: some View {
        VStack(spacing: 22) {
            header("mic", "Let Blurt hear you", "It only listens while you hold or toggle your key.")

            if coordinator.permissions.microphone.isGranted {
                granted("Microphone access granted")
            } else {
                Button("Allow Microphone Access") { coordinator.requestMicrophone() }
                    .controlSize(.large)
                if coordinator.permissions.microphone == .denied {
                    Text("Previously declined — you can change it in System Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { coordinator.openSettings(.microphone) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var accessibilityAndKey: some View {
        VStack(spacing: 20) {
            header(
                "keyboard",
                "Choose your dictation key",
                "Tap it to start and stop. Hold it to record only while you hold.")

            Picker("Key", selection: $coordinator.hotkey) {
                ForEach(HotkeySpec.all, id: \.id) { spec in
                    Text("\(spec.symbol)  \(spec.displayName)").tag(spec)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 300)

            if let note = coordinator.hotkey.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().frame(maxWidth: 380)

            if coordinator.permissions.accessibility.isGranted {
                granted("Accessibility access granted")
            } else {
                VStack(spacing: 8) {
                    Text("Blurt needs Accessibility access to notice that key, and to paste for you.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("Grant Accessibility Access") { coordinator.requestAccessibility() }
                        .controlSize(.large)
                    Text("Turn Blurt on in the list, then come back here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var model: some View {
        VStack(spacing: 22) {
            header(
                "arrow.down.circle",
                "Getting the speech model",
                "About a gigabyte, once. After this Blurt works offline.")

            switch coordinator.modelState {
            case .ready:
                granted("Model ready")
            case .downloading(let fraction, let detail):
                VStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 320)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .loading:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading onto the Neural Engine…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .failed(let why):
                VStack(spacing: 8) {
                    Text(why).font(.system(size: 12)).foregroundStyle(.red)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Try Again") { coordinator.retryModel() }
                }
            case .notReady:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var tryIt: some View {
        VStack(spacing: 20) {
            header(
                "checkmark.circle",
                "Give it a go",
                "Hold \(coordinator.hotkey.displayName), say something, then let go.")

            if let latest = coordinator.history.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You said:")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(latest.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(maxWidth: 460)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: coordinator.isRecording ? "waveform" : "mic")
                        .font(.system(size: 22))
                        .foregroundStyle(coordinator.isRecording ? Color.red : .secondary)
                    Text(coordinator.isRecording ? "Listening…" : "Waiting for you")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 70)
            }

            Text("From now on Blurt lives in the menu bar. It works in any app.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func granted(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.system(size: 12.5, weight: .medium))
        }
    }
}
