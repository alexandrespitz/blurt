import SwiftUI

struct HistoryTab: View {

    @ObservedObject var coordinator: AppCoordinator
    @State private var query = ""
    @State private var confirmingClear = false
    @State private var editing: HistoryEntry?
    @State private var editText = ""

    private var entries: [HistoryEntry] {
        let all = coordinator.history
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            attentionBanner

            if coordinator.history.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .listStyle(.inset)
                .searchable(text: $query, placement: .toolbar, prompt: "Search transcripts")
            }

            footer
        }
    }

    // MARK: - Recordings that need a look

    @ViewBuilder
    private var attentionBanner: some View {
        if !coordinator.pending.isEmpty || !coordinator.quarantined.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(coordinator.pending, id: \.id) { job in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pendingTitle(job))
                                .font(.system(size: 12, weight: .medium))
                            if let error = job.lastError {
                                Text(error).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Transcribe") { coordinator.retry(job: job) }
                        Button("Delete") { coordinator.discard(job: job) }
                    }
                }

                ForEach(coordinator.quarantined, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("A recording could not be read")
                                .font(.system(size: 12, weight: .medium))
                            Text(url.lastPathComponent)
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Try Anyway") { coordinator.transcribeQuarantined(url) }
                        Button("Play") { NSWorkspace.shared.open(url) }
                        Button("Delete") { coordinator.deleteQuarantined(url) }
                    }
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08))
        }
    }

    private func pendingTitle(_ job: RecordingJob) -> String {
        let when = job.startedAt.formatted(date: .abbreviated, time: .shortened)
        if let duration = job.durationSeconds {
            return String(format: "A %.0f second recording from %@ is waiting", duration, when)
        }
        return "A recording from \(when) is waiting"
    }

    // MARK: - Rows

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.text)
                .font(.system(size: 12.5))
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(String(format: "%.0fs", entry.duration))
                Text("·")
                Text("\(entry.wordCount) words")
                if entry.recovered {
                    Text("Recovered")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.15)))
                        .foregroundStyle(.blue)
                }
                Spacer()
                Button {
                    coordinator.copyToClipboard(entry.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")

                Button {
                    editText = entry.text
                    editing = entry
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit — fixing the same word twice teaches Blurt a rule")

                Button {
                    coordinator.deleteHistory(id: entry.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { coordinator.copyToClipboard(entry.text) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.alignleft")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Nothing dictated yet")
                .font(.system(size: 13, weight: .medium))
            Text("Tap \(coordinator.hotkey.displayName) anywhere and start talking.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(coordinator.history.count) of \(HistoryStore.maxEntries) kept")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export…") { coordinator.exportHistory() }
                .disabled(coordinator.history.isEmpty)
            Button("Clear History…") { confirmingClear = true }
                .disabled(coordinator.history.isEmpty)
        }
        .padding(12)
        .confirmationDialog(
            "Delete every saved transcript?",
            isPresented: $confirmingClear
        ) {
            Button("Delete All", role: .destructive) { coordinator.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Deletes every saved transcript, including the copies kept "
                + "with retained recordings. Kept audio, learned vocabulary, "
                + "exported files and the clipboard are not affected. This "
                + "cannot be undone.")
        }
        .sheet(item: $editing) { entry in
            editSheet(entry)
        }
    }

    /// Editing a transcript is also how Blurt learns: the diff between what
    /// it wrote and what you meant feeds the correction rules.
    private func editSheet(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit transcript")
                .font(.system(size: 14, weight: .semibold))
            Text("Fix the same word in two different transcripts and Blurt starts fixing it for you.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextEditor(text: $editText)
                .font(.system(size: 13))
                .frame(minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1))

            if let raw = entry.rawText, raw != entry.text {
                VStack(alignment: .leading, spacing: 3) {
                    Text("The model originally heard:")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Text(raw)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button("Save") {
                    coordinator.editHistory(id: entry.id, newText: editText)
                    editing = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
