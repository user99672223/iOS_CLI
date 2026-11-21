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
    @Published var jitPreparing = false
    private var pendingStart: Bool?
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
        get { UserDefaults.standard.object(forKey: "jitPoolMB2") as? Int ?? 512 }
        set { UserDefaults.standard.set(newValue, forKey: "jitPoolMB2") }
    }

    private init() {
        live.runningCommands = { [weak self] in
            guard let self else { return [] }
            return self.engine.chat.runningCommandIDs.map { id in
                (id: id, command: self.commandText(id))
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
        if screen == .chat { startEngine(resumeLatest: true) } else { watchForDebugger() }
    }

    /// The debugger (LiveContainer "Launch with JIT" + StikDebug) can attach
    /// after the app started: make the pool as soon as it does, then go on.
    private var watching = false
    func watchForDebugger() {
        guard !watching, jitInfo.pool_ready == 0, jit != .simulator else { return }
        watching = true
        Task { @MainActor in
            defer { watching = false }
            for _ in 0..<240 {   // two minutes
                try? await Task.sleep(nanoseconds: 500_000_000)
                refreshJIT()
                if jitInfo.pool_ready != 0 { break }
            }
        }
    }

    func refreshJIT() {
        jit = JITEnabler.state
        cli_jit_query(&jitInfo)
        if jit == .ready, jitInfo.pool_ready == 0 { makePool() }
    }

    /// Asks the debugger for the JIT memory on a background thread: the debugger
    /// prepares it page by page, which takes a while, and the UI must stay live.
    func makePool() {
        guard !jitPreparing, jitInfo.pool_ready == 0 else { return }
        jitPreparing = true
        let mb = Self.poolMB
        Thread.detachNewThread { [weak self] in
            var info = cli_jit_info()
            let rc = cli_jit_setup(size_t(mb), &info)
            let result = info
            Task { @MainActor in self?.poolDone(rc: rc, info: result) }
        }
    }

    private func poolDone(rc: Int32, info: cli_jit_info) {
        jitPreparing = false
        jitInfo = info
        jitError = rc == 0 ? nil : JITStatus.error(info)
        jit = JITEnabler.state
        poolChanged()
    }

    private func poolChanged() {
        guard jitInfo.pool_ready != 0 else {
            pendingStart = nil
            if screen == .chat { screen = .setup }
            return
        }
        if let resume = pendingStart {
            pendingStart = nil
            startEngine(resumeLatest: resume)
        } else if screen == .setup {
            finishSetupIfReady()
        }
    }

    func enableJIT() async {
        jitError = nil
        if jit == .ready || jitInfo.pool_ready != 0 { makePool(); return }
        guard await JITEnabler.requestFromStikDebug() else {
            jitError = "StikDebug is not installed or did not open. Use LiveContainer's “Launch with JIT” with the Harbor JIT script instead."
            return
        }
        if await JITEnabler.waitUntilReady(timeout: 600) { makePool() } else {
            refreshJIT()
            jitError = "StikDebug did not attach. Check its VPN and pairing file, then tap the button again."
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
        guard jitInfo.pool_ready != 0 else {
            // Wine needs the JIT memory first; start once it exists.
            if jit == .ready || jit == .simulator { pendingStart = resumeLatest; makePool() }
            return
        }
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
        if engine.isRunning {
            engine.stop()
            Task { @MainActor in
                await engine.waitUntilStopped()
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
            await engine.waitUntilStopped()
            // Wine keeps the prefix open while the app runs: clear it, keeping the downloaded tools.
            let fm = FileManager.default
            let keep = AppPaths.appSupport.appendingPathComponent("tools-keep")
            try? fm.removeItem(at: keep)
            try? fm.moveItem(at: AppPaths.toolsDir, to: keep)
            for name in ["drive_c/workspace", "drive_c/users/user"] {
                try? fm.removeItem(at: AppPaths.prefix.appendingPathComponent(name))
            }
            try? fm.moveItem(at: keep, to: AppPaths.toolsDir)
            try? ToolInstaller.writeConfiguration()
            refreshSessions()
            toolsInstalled = ToolInstaller.isInstalled
            startEngine(resumeLatest: false)
        }
    }
}
