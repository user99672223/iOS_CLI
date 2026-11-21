import Foundation
import HarborKit
import os

/// Windows command-line quoting (the inverse of CommandLineToArgvW).
enum WinQuote {
    static func arg(_ s: String) -> String {
        if !s.isEmpty && !s.contains(where: { " \t\n\"".contains($0) }) { return s }
        var out = "\""
        var backslashes = 0
        for c in s {
            if c == "\\" { backslashes += 1; continue }
            if c == "\"" { out += String(repeating: "\\", count: backslashes * 2 + 1) + "\"" }
            else { out += String(repeating: "\\", count: backslashes) + String(c) }
            backslashes = 0
        }
        out += String(repeating: "\\", count: backslashes * 2) + "\""
        return out
    }
    static func line(_ args: [String]) -> String { args.map(arg).joined(separator: " ") }
}

/// Environment every Claude Code launch gets.
enum ClaudeEnvironment {
    static func make(token: String?) -> [String: String] {
        let git = AppPaths.windowsPath(AppPaths.gitDir)
        var env: [String: String] = [
            // Shell for Claude's Bash tool: MinGit-busybox's native ARM64 sh.
            "CLAUDE_CODE_GIT_BASH_PATH": git + "\\clangarm64\\bin\\bash.exe",
            "PATH": "\(git)\\cmd;\(git)\\clangarm64\\bin;\(git)\\usr\\bin;C:\\windows\\system32;C:\\windows",
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "sdk-harbor",
            "FORCE_COLOR": "0",
            "NO_COLOR": "1",
            "TERM": "dumb",
            "LANG": "en_US.UTF-8",
        ]
        if let token, !token.isEmpty { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        return env
    }
}

/// Runs `claude.exe` headless with the stream-json protocol and keeps the chat state.
@MainActor
final class ClaudeEngine: ObservableObject {
    enum Phase: Equatable { case stopped, starting, ready, failed(String) }

    @Published private(set) var chat = ChatState()
    @Published private(set) var phase: Phase = .stopped
    @Published var model: String = UserDefaults.standard.string(forKey: "model") ?? ""

    private let log = Logger(subsystem: "cli.app", category: "engine")
    private var session: WineSession?
    private var lines = LineBuffer()
    private var requestSeq = 0
    private var pendingOutput: [ClaudeProtocol.Event] = []
    private var flushScheduled = false
    private var interrupting = false
    /// Raw protocol lines, for the self-test and diagnostics (no user content is logged elsewhere).
    var onRawLine: ((String) -> Void)?

    var isRunning: Bool { phase == .ready || phase == .starting }
    var workspaceWindowsPath: String { AppPaths.windowsPath(AppPaths.workspace) }

    func start(resume sessionID: String?, history: ChatState? = nil) {
        guard !WineSession.isRunning else {
            phase = .failed("Another Windows program is still running")
            return
        }
        chat = history ?? ChatState()
        lines = LineBuffer()
        phase = .starting
        try? FileManager.default.createDirectory(at: AppPaths.workspace, withIntermediateDirectories: true)
        let args = ClaudeProtocol.arguments(resume: sessionID, model: model.isEmpty ? nil : model)
        var o = WineSession.Options(exe: AppPaths.windowsPath(AppPaths.claudeExe))
        o.args = WinQuote.line(args)
        o.workdir = workspaceWindowsPath
        o.env = ClaudeEnvironment.make(token: Credentials.token)
        o.stdinPipe = true
        o.stdoutPipe = true
        let s = WineSession()
        s.onOutput = { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
        s.onExit = { [weak self] code, crash in
            Task { @MainActor in self?.exited(code: code, crash: crash) }
        }
        do {
            try s.start(o)
        } catch {
            phase = .failed("\(error)")
            return
        }
        session = s
        send(raw: ClaudeProtocol.initialize(id: nextRequestID()))
        phase = .ready
    }

    /// UI demo / screenshots: show a conversation without running anything.
    func loadDemo(_ state: ChatState) {
        chat = state
        phase = .ready
    }

    func stop() {
        session?.closeStdin()
        cli_session_shutdown()
    }

    func send(text: String, images: [ClaudeProtocol.ImageAttachment] = []) {
        guard phase == .ready else { return }
        chat.addUserMessage(text, imageCount: images.count)
        send(raw: ClaudeProtocol.userMessage(text: text, images: images, sessionID: chat.sessionID ?? ""))
    }

    func interrupt() {
        guard chat.isTurnRunning else { return }
        interrupting = true
        send(raw: ClaudeProtocol.interrupt(id: nextRequestID()))
    }

    func setModel(_ m: String) {
        model = m
        UserDefaults.standard.set(m, forKey: "model")
        if phase == .ready { send(raw: ClaudeProtocol.setModel(id: nextRequestID(), model: m.isEmpty ? nil : m)) }
    }

    private func nextRequestID() -> String { requestSeq += 1; return "req_\(requestSeq)_\(UUID().uuidString.prefix(8))" }

    private func send(raw line: String) {
        guard let session else { return }
        let ok = session.write(Data((line + "\n").utf8))
        if !ok { log.error("stdin write failed") }
    }

    private func receive(_ data: Data) {
        for line in lines.append(data) {
            onRawLine?(line)
            guard let e = ClaudeProtocol.parse(line: line) else { continue }
            switch e {
            case .controlRequest(let id, let req):
                // bypassPermissions should prevent these; allow anything that still asks.
                if req["subtype"]?.string == "can_use_tool" {
                    send(raw: ClaudeProtocol.controlResponse(id: id, response: ["behavior": "allow", "updatedInput": req["input"] ?? .object([:])]))
                } else {
                    send(raw: ClaudeProtocol.controlResponse(id: id, response: .object([:])))
                }
            case .unparsable(let text):
                log.debug("non-protocol output: \(text.prefix(200), privacy: .private)")
            default:
                pendingOutput.append(e)
            }
        }
        scheduleFlush()
    }

    /// Batch UI updates (stream deltas arrive in bursts) at ~20 Hz.
    private func scheduleFlush() {
        guard !flushScheduled, !pendingOutput.isEmpty else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.flushScheduled = false
            var c = self.chat
            for e in self.pendingOutput {
                if case .result = e { self.interrupting = false }
                c.apply(e)
            }
            self.pendingOutput.removeAll()
            self.chat = c
        }
    }

    func appendLiveOutput(toolID: String, _ text: String) {
        chat.appendLiveOutput(toolID: toolID, text)
    }

    private func exited(code: Int32, crash: UInt32) {
        if let rest = lines.flush(), let e = ClaudeProtocol.parse(line: rest) { pendingOutput.append(e) }
        for e in pendingOutput { chat.apply(e) }
        pendingOutput.removeAll()
        chat.endTurn(interrupted: interrupting)
        session = nil
        if crash != 0 {
            phase = .failed(String(format: "Claude Code stopped unexpectedly (0x%08X). See Diagnostics for the log.", crash))
        } else if code != 0 {
            phase = .failed("Claude Code exited with code \(code)")
        } else {
            phase = .stopped
        }
    }
}
