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
        // Live command output (build/ntdll-unix/cli_capture.c).
        env["CLI_CAPTURE_DIR"] = LiveOutputWatcher.directory.path
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
    private var process: HostProcess?
    private var generation = 0
    private var lines = LineBuffer()
    private var requestSeq = 0
    private var pendingOutput: [ClaudeProtocol.Event] = []
    private var flushScheduled = false
    private var interrupting = false
    private var stderrTail = ""
    /// Raw protocol lines, for the self-test and diagnostics (no user content is logged elsewhere).
    var onRawLine: ((String) -> Void)?

    var isRunning: Bool { phase == .ready || phase == .starting }
    var workspaceWindowsPath: String { AppPaths.windowsPath(AppPaths.workspace) }

    func start(resume sessionID: String?, history: ChatState? = nil) {
        if let old = process { old.closeStdin(); old.kill() }
        process = nil
        generation += 1
        let gen = generation
        chat = history ?? ChatState()
        lines = LineBuffer()
        stderrTail = ""
        pendingOutput.removeAll()
        phase = .starting
        try? FileManager.default.createDirectory(at: AppPaths.workspace, withIntermediateDirectories: true)
        let args = ClaudeProtocol.arguments(resume: sessionID, model: model.isEmpty ? nil : model)
        var o = WineHost.Options(exe: AppPaths.windowsPath(AppPaths.claudeExe))
        o.args = WinQuote.line(args)
        o.workdir = workspaceWindowsPath
        o.env = ClaudeEnvironment.make(token: Credentials.token)
        Task { @MainActor in
            do {
                let p = try await WineHost.shared.spawn(o)
                guard gen == self.generation else { p.kill(); return }
                self.process = p
                p.onOutput { [weak self] data, isErr in
                    Task { @MainActor in
                        guard let self, gen == self.generation else { return }
                        if isErr { self.stderr(data) } else { self.receive(data) }
                    }
                }
                p.onExit { [weak self] code in
                    Task { @MainActor in
                        guard let self, gen == self.generation else { return }
                        self.exited(code: code)
                    }
                }
                self.send(raw: ClaudeProtocol.initialize(id: self.nextRequestID()))
                self.phase = .ready
            } catch {
                self.phase = .failed("\(error)")
            }
        }
    }

    /// UI demo / screenshots: show a conversation without running anything.
    func loadDemo(_ state: ChatState) {
        chat = state
        phase = .ready
    }

    /// Ends claude.exe: EOF on its stdin (it exits after the current turn), then terminate.
    func stop() {
        guard let p = process else { return }
        p.closeStdin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.kill() } }
    }

    /// Resolves once the current claude.exe has exited (or after `timeout`).
    func waitUntilStopped(timeout: TimeInterval = 10) async {
        let end = Date().addingTimeInterval(timeout)
        while let p = process, p.isRunning, Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
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
        process?.write(Data((line + "\n").utf8))
    }

    private func stderr(_ data: Data) {
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.count > 4000 { stderrTail = String(stderrTail.suffix(3000)) }
    }

    /// The end of claude.exe's stderr (diagnostics, error messages), token-redacted.
    var errorOutput: String { TerminalText.redact(stderrTail) }

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

    private func exited(code: UInt32) {
        if let rest = lines.flush(), let e = ClaudeProtocol.parse(line: rest) { pendingOutput.append(e) }
        for e in pendingOutput { chat.apply(e) }
        pendingOutput.removeAll()
        chat.endTurn(interrupted: interrupting)
        process = nil
        let tail = errorOutput.split(separator: "\n").suffix(3).joined(separator: " ")
        if code >= 0xC000_0000 && code != 0xFFFF_FFFF {
            phase = .failed(String(format: "Claude Code stopped unexpectedly (0x%08X). See Diagnostics for the log.", code))
        } else if code == 0xFFFF_FFFF {
            phase = .failed("Claude Code could not be started. \(tail)")
        } else if code != 0 {
            phase = .failed("Claude Code exited with code \(code). \(tail)")
        } else {
            phase = .stopped
        }
    }
}
