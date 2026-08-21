import SwiftUI

struct DashboardView: View {

    @ObservedObject var coordinator: AppCoordinator
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if coordinator.didCompleteOnboarding {
                TabView(selection: $tab) {
                    GeneralTab(coordinator: coordinator)
                        .tabItem { Label("General", systemImage: "gearshape") }
                        .tag(Tab.general)

                    HistoryTab(coordinator: coordinator)
                        .tabItem { Label("History", systemImage: "text.alignleft") }
                        .tag(Tab.history)
                }
                .padding(.top, 8)
            } else {
                OnboardingView(coordinator: coordinator)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { coordinator.refreshPending() }
    }
}

// MARK: - Shared bits

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
    }
}

/// Deletable chips that wrap onto as many rows as they need.
struct FlowChips: View {
    let items: [(UUID, String)]
    let onDelete: (UUID) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)],
            alignment: .leading, spacing: 6
        ) {
            ForEach(items, id: \.0) { id, label in
                HStack(spacing: 4) {
                    Text(label).font(.system(size: 11.5)).lineLimit(1)
                    Button {
                        onDelete(id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }
}
