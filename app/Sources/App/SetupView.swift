import SwiftUI

/// First run: JIT, the Windows tools, and the Claude sign-in. Each step says
/// what is missing and how to fix it.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var installer = ToolInstaller.shared
    @State private var installing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claude Code on your iPhone").font(.title2.weight(.semibold))
                        Text("Harbor runs the Windows ARM64 build of Claude Code through Wine, right inside this app.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section("1 · JIT") { JITStep() }

                Section("2 · Tools") {
                    StepRow(done: model.toolsInstalled,
                            title: "Claude Code and Git",
                            detail: model.toolsInstalled
                                ? "Claude Code \(ToolInstaller.installedClaudeVersion ?? "") · Git \(ToolInstaller.installedGitVersion ?? "")"
                                : "About 400 MB is downloaded from Anthropic and GitHub and verified.")
                    if let p = installer.progress {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.title).font(.footnote)
                            if let f = p.fraction { ProgressView(value: f) } else { ProgressView() }
                            if !p.detail.isEmpty { Text(p.detail).font(.caption2).foregroundStyle(.secondary) }
                        }
                    } else if !model.toolsInstalled {
                        Button(installing ? "Downloading…" : "Download") { install() }
                            .disabled(installing)
                    }
                    if let e = installer.lastError ?? installError {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("3 · Sign in") {
                    StepRow(done: model.signedIn, title: "Claude subscription",
                            detail: model.signedIn ? "Signed in" : "Sign in once with your Claude account. No API key needed.")
                    if !model.signedIn {
                        Button("Sign in") { model.showSignIn = true }
                            .disabled(!model.toolsInstalled || !model.jitUsable)
                    }
                }

                Section {
                    Button {
                        model.finishSetupIfReady()
                    } label: {
                        Text("Start").frame(maxWidth: .infinity).font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.setupComplete)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Setup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showDiagnostics = true } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                        .accessibilityLabel("Diagnostics")
                }
            }
            .sheet(isPresented: $model.showSignIn, onDismiss: { model.finishSetupIfReady() }) { SignInView() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                model.refreshJIT()
            }
        }
    }

    @State private var installError: String?

    private func install() {
        installing = true
        installError = nil
        Task {
            do {
                try await installer.installClaude()
                try await installer.installGit()
                try ToolInstaller.writeConfiguration()
            } catch {
                installError = "\(error.localizedDescription)"
            }
            installing = false
            model.toolsInstalled = ToolInstaller.isInstalled
        }
    }
}

struct StepRow: View {
    let done: Bool
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct JITStep: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false

    var body: some View {
        switch model.jit {
        case .simulator:
            StepRow(done: true, title: "JIT", detail: "Simulator: no debugger needed.")
        case .ready:
            StepRow(done: model.jitInfo.pool_ready != 0, title: "JIT is on",
                    detail: model.jitInfo.pool_ready != 0 ? "JIT memory is ready (\(model.jitInfo.pool_size >> 20) MB)." : "Debugger attached.")
        case .enabledDetached:
            if model.jitInfo.pool_ready != 0 {
                StepRow(done: true, title: "JIT is on", detail: "JIT memory is ready (\(model.jitInfo.pool_size >> 20) MB).")
            } else {
                StepRow(done: false, title: "JIT is on, but without Harbor's script",
                        detail: "Relaunch with JIT using the Harbor JIT script (see the guide below).")
                guide
            }
        case .off:
            StepRow(done: false, title: "JIT is off",
                    detail: "Windows programs need JIT. Launch Harbor from LiveContainer with “Launch with JIT” and Harbor's JIT script.")
            guide
        }
        if let e = model.jitError { Text(e).font(.footnote).foregroundStyle(.red) }
    }

    @ViewBuilder private var guide: some View {
        DisclosureGroup("How to enable JIT") {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. In LiveContainer, long-press Harbor → Settings → turn on “Launch with JIT”.")
                Text("2. Under “JIT script”, choose harbor-jit.js (export it with the button below).")
                Text("3. Make sure StikDebug and its VPN are set up, then launch Harbor.")
                Text("Or tap “Enable with StikDebug” to attach StikDebug to this running copy.")
            }
            .font(.footnote)
            ShareLink(item: JITScriptFile.url, preview: SharePreview("harbor-jit.js")) {
                Label("Export the JIT script", systemImage: "square.and.arrow.up")
            }
            Button {
                busy = true
                Task { await model.enableJIT(); busy = false }
            } label: {
                Label(busy ? "Waiting for StikDebug…" : "Enable with StikDebug", systemImage: "bolt")
            }
            .disabled(busy)
        }
    }
}

enum JITScriptFile {
    /// The bundled script copied to a shareable file named harbor-jit.js.
    static var url: URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-jit.js")
        if let data = JITEnabler.scriptData { try? data.write(to: dest) }
        return dest
    }
}
