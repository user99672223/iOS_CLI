import SwiftUI
import HarborKit

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .setup: SetupView()
            case .chat: MainView()
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(isPresented: $model.showDiagnostics) { NavigationStack { DiagnosticsView() } }
    }
}

/// Phone: chat full screen, sessions/settings/diagnostics as sheets.
/// iPad and wide landscape: sessions | chat | optional inspector.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var inspector = false

    var body: some View {
        if hSize == .regular {
            NavigationSplitView {
                SessionsList(onSelect: { _ in })
                    .navigationTitle("Sessions")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { model.newSession() } label: { Image(systemName: "square.and.pencil") }
                                .accessibilityLabel("New session")
                        }
                    }
            } detail: {
                chat
                    .inspector(isPresented: $inspector) {
                        DiagnosticsView().inspectorColumnWidth(min: 300, ideal: 340, max: 440)
                    }
            }
        } else {
            NavigationStack { chat }
                .sheet(isPresented: $model.showSessions) {
                    NavigationStack {
                        SessionsList(onSelect: { _ in model.showSessions = false })
                            .navigationTitle("Sessions")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("Done") { model.showSessions = false } }
                                ToolbarItem(placement: .primaryAction) {
                                    Button { model.newSession(); model.showSessions = false } label: { Image(systemName: "square.and.pencil") }
                                        .accessibilityLabel("New session")
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
        }
    }

    private var chat: some View {
        ChatView(engine: model.engine)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hSize != .regular {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.refreshSessions(); model.showSessions = true } label: {
                            Image(systemName: "sidebar.leading")
                        }
                        .accessibilityLabel("Sessions")
                        .accessibilityIdentifier("sessions")
                    }
                }
                ToolbarItem(placement: .principal) { StatusTitle(engine: model.engine, title: title) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if hSize == .regular {
                        Button { inspector.toggle() } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                            .accessibilityLabel("Diagnostics")
                    } else {
                        Button { model.showDiagnostics = true } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                            .accessibilityLabel("Diagnostics")
                            .accessibilityIdentifier("diagnostics")
                    }
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings")
                }
            }
    }

    private var title: String {
        if let id = model.currentSessionID, let s = model.sessions.first(where: { $0.id == id }) { return s.title }
        return "New session"
    }
}

struct StatusTitle: View {
    @ObservedObject var engine: ClaudeEngine
    let title: String
    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var status: String {
        switch engine.phase {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .ready: return engine.chat.isTurnRunning ? "Working" : (engine.chat.model ?? "Ready")
        case .failed: return "Stopped with an error"
        }
    }
    private var color: Color {
        switch engine.phase {
        case .ready: return engine.chat.isTurnRunning ? .orange : .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }
}

struct SessionsList: View {
    @EnvironmentObject var model: AppModel
    let onSelect: (SessionSummary) -> Void

    var body: some View {
        List {
            if model.sessions.isEmpty {
                Text("No saved sessions yet.").foregroundStyle(.secondary)
            }
            ForEach(model.sessions) { s in
                Button {
                    model.open(s)
                    onSelect(s)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).lineLimit(2).foregroundStyle(.primary)
                        Text(s.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(s.id == model.currentSessionID ? Color.accentColor.opacity(0.12) : nil)
                .swipeActions {
                    Button(role: .destructive) {
                        SessionStore.delete(s)
                        model.refreshSessions()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .refreshable { model.refreshSessions() }
        .onAppear { model.refreshSessions() }
    }
}
