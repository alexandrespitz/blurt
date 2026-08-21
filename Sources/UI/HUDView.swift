import SwiftUI

/// The contents of the floating pill.
struct HUDView: View {

    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .recording:
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(0.55 + 0.45 * Double(min(1, model.level * 2 + 0.3)))
                Text(timeString)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                LevelMeter(level: model.level)
                if !model.partial.isEmpty {
                    // The live preview: always the newest words, trimmed by
                    // hand — SwiftUI's head-truncation kept the oldest instead.
                    Text(PreviewTail.trim(model.partial))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 400, alignment: .trailing)
                }

            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium))

            case .done(let pasted):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(pasted ? "Pasted" : "Copied")
                    .font(.system(size: 13, weight: .medium))

            case .message(let text):
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 150)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeString: String {
        let total = Int(model.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Five bars that follow your voice, so you can tell it is actually hearing you.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5.0
                let active = level > threshold
                Capsule()
                    .fill(active ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 3, height: barHeight(index))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: 16)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base: CGFloat = 5
        let extra = CGFloat(index) * 2.4
        return base + extra
    }
}
