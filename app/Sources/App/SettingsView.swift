import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var model_ = ""
    @State private var minutes = BackgroundKeeper.minutes
    @State private var confirmReset = false
    @State private var confirmSignOut = false
    @State private var updating = false
    @State private var updateMessage: String?

    static let models: [(String, String)] = [
        ("", "Default"),
        ("opus", "Opus"),
        ("sonnet", "Sonnet"),
        ("haiku", "Haiku"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Model", selection: $model_) {
                        ForEach(Self.models, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: model_) { _, m in model.engine.setModel(m) }
                    TextField("Custom model ID", text: $model_)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced())
                }

                Section("Sessions") {
                    Button { model.newSession(); dismiss() } label: { Label("New session", systemImage: "square.and.pencil") }
                    NavigationLink { SessionsList(onSelect: { _ in dismiss() }).navigationTitle("Sessions") } label: {
                        Label("All sessions", systemImage: "list.bullet")
                    }
                }

                Section("Account") {
                    LabeledContent("Claude subscription", value: model.signedIn ? "Signed in" : "Signed out")
                    LabeledContent("Token stored in", value: Credentials.storage == "keychain" ? "Keychain" :
                                    Credentials.storage == "file" ? "Protected file" : "—")
                    if model.signedIn {
                        Button("Sign out", role: .destructive) { confirmSignOut = true }
                    } else {
                        Button("Sign in") { model.showSignIn = true }
                    }
                }

                Section {
                    Stepper(value: $minutes, in: 0...60, step: 5) {
                        LabeledContent("Keep working in the background", value: minutes == 0 ? "Off" : "\(Int(minutes)) min")
                    }
                    .onChange(of: minutes) { _, m in BackgroundKeeper.minutes = m }
                } footer: {
                    Text("While Claude is working, Harbor keeps running for this long after you leave the app.")
                }

                Section("Tools") {
                    LabeledContent("Claude Code", value: ToolInstaller.installedClaudeVersion ?? "not installed")
                    LabeledContent("Git for Windows (ARM64)", value: ToolInstaller.installedGitVersion ?? "not installed")
                    Button(updating ? "Checking…" : "Update Claude Code") { update() }.disabled(updating)
                    if let m = updateMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Button("Reset Windows prefix", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Deletes the Wine prefix, including saved sessions, the workspace and the downloaded tools. The sign-in is kept.")
                }

                Section("About") {
                    LabeledContent("Harbor", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Wine", value: "11.4 (Madeira iOS port)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { model_ = model.engine.model }
            .confirmationDialog("Reset the Windows prefix?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { model.resetPrefix(); dismiss() }
            }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { model.signOut(); dismiss() }
            }
            .sheet(isPresented: $model.showSignIn) { SignInView() }
        }
    }

    private func update() {
        updating = true
        updateMessage = nil
        Task {
            let before = ToolInstaller.installedClaudeVersion
            do {
                let r = try await ToolInstaller.fetchRelease()
                if r.version == before {
                    updateMessage = "Claude Code \(r.version) is the latest version."
                } else {
                    model.engine.stop()
                    for _ in 0..<100 where WineSession.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
                    try await ToolInstaller.shared.installClaude()
                    updateMessage = "Updated to \(r.version). It was tested with \(SelfTestInfo.testedClaudeVersion)."
                    model.startEngine(resumeLatest: true)
                }
            } catch {
                updateMessage = error.localizedDescription
            }
            updating = false
        }
    }
}

enum SelfTestInfo {
    /// The Claude Code version the CI self-test last passed with (set at build time).
    static var testedClaudeVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "HarborTestedClaudeVersion") as? String ?? "unknown"
    }
}
