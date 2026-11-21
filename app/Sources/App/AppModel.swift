import SwiftUI
import HarborKit
import os

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Screen: Equatable { case setup, chat }

    @Published var screen: Screen = .setup
    @Published var jit: JITEnabler.State = JITEnabler.state
    @Published var jitInfo = cli_jit_info()
    @Published var jitError: String?
    @Published var sessions: [SessionSummary] = []
    @Published var signedIn = Credentials.isSignedIn
    @Published var toolsInstalled = ToolInstaller.isInstalled
    @Published var showSettings = false
    @Published var showDiagnostics = false
    @Published var showSessions = false
    @Published var showSignIn = false
    @Published var currentSessionID: String?

    let engine = ClaudeEngine()
    let installer = ToolInstaller.shared
    private let live = LiveOutputWatcher()
    private let log = Logger(subsystem: "cli.app", category: "app")

    static var poolMB: Int {
        get { UserDefaults.standard.object(forKey: "jitPoolMB") as? Int ?? 1024 }
        set { UserDefaults.standard.set(newValue, forKey: "jitPoolMB") }
    }

    private init() {
        live.runningCommands = { [weak self] in
            guard let self else { return [] }
            return self.engine.chat.runningCommandIDs.map { id in
                (id, self.commandText(id))
            }
        }
        live.deliver = { [weak self] id, text in self?.engine.appendLiveOutput(toolID: id, text) }
        BackgroundKeeper.shared.isBusy = { [weak self] in self?.engine.chat.isTurnRunning ?? false }
    }

    private func commandText(_ id: String) -> String {
        for item in engine.chat.items {
            if item.id == id, case .tool(let t) = item.kind { return t.command ?? "" }
        }
        return ""
    }

    var setupComplete: Bool { toolsInstalled && signedIn && jitUsable }
    var jitUsable: Bool { jit == .simulator || jit == .ready || jitInfo.pool_ready != 0 }

    func launch() {
        if UIDemo.apply(to: self) { return }
        BackgroundKeeper.shared.install()
        refreshJIT()
        // Make the JIT pool as soon as a debugger is attached: the script
        // detaches right after, which keeps Wine's signals off the debugger.
        if jit == .ready || jit == .simulator { makePool() }
        sessions = SessionStore.list()
        screen = setupComplete ? .chat : .setup
        if screen == .chat { startEngine(resumeLatest: true) }
    }

    func refreshJIT() {
        jit = JITEnabler.state
        cli_jit_query(&jitInfo)
    }

    func makePool() {
        var info = cli_jit_info()
        let rc = cli_jit_setup(Self.poolMB, &info)
        jitInfo = info
        jitError = rc == 0 ? nil : JITStatus.error(info)
        refreshJIT()
    }

    func enableJIT() async {
        jitError = nil
        if jit == .ready { makePool(); return }
        guard await JITEnabler.requestFromStikDebug() else {
            jitError = "StikDebug is not installed or did not open. Use LiveContainer's “Launch with JIT” with the Harbor JIT script instead."
            return
        }
        if await JITEnabler.waitUntilReady(timeout: 90) { makePool() } else {
            refreshJIT()
            jitError = "No debugger attached within 90 seconds."
        }
    }

    func finishSetupIfReady() {
        toolsInstalled = ToolInstaller.isInstalled
        signedIn = Credentials.isSignedIn
        refreshJIT()
        if setupComplete {
            try? ToolInstaller.writeConfiguration()
            screen = .chat
            startEngine(resumeLatest: true)
        }
    }

    // MARK: sessions

    func startEngine(resumeLatest: Bool) {
        guard jitInfo.pool_ready != 0 || jit == .simulator else { return }
        if jitInfo.pool_ready == 0 { makePool() }
        try? ToolInstaller.writeConfiguration()
        sessions = SessionStore.list()
        if resumeLatest, let last = sessions.first {
            open(last)
        } else {
            currentSessionID = nil
            engine.start(resume: nil)
            live.start()
        }
    }

    func open(_ s: SessionSummary) {
        restart {
            self.currentSessionID = s.id
            self.engine.start(resume: s.id, history: SessionStore.load(s))
            self.live.start()
        }
    }

    func newSession() {
        restart {
            self.currentSessionID = nil
            self.engine.start(resume: nil)
            self.live.start()
        }
    }

    /// Stop the running claude.exe (if any), wait for it to exit, then run `next`.
    private func restart(_ next: @escaping @MainActor () -> Void) {
        if engine.isRunning || WineSession.isRunning {
            engine.stop()
            Task { @MainActor in
                for _ in 0..<100 where WineSession.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
                next()
            }
        } else {
            next()
        }
    }

    func refreshSessions() { sessions = SessionStore.list() }

    func signOut() {
        Credentials.clear()
        signedIn = false
        engine.stop()
        screen = .setup
    }

    func resetPrefix() {
        engine.stop()
        Task { @MainActor in
            for _ in 0..<100 where WineSession.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? FileManager.default.removeItem(at: AppPaths.prefix)
            toolsInstalled = false
            screen = .setup
        }
    }
}
