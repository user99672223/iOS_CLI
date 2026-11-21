import Foundation
import HarborKit
import os

/// Drives `claude setup-token` (an interactive terminal program) to get a
/// long-lived OAuth token for the owner's Claude subscription.
///
/// The program runs in a pseudo console (ConPTY, via harbor-host) so its
/// terminal UI works; its VT output is shown in a minimal terminal view with
/// any token redacted. The sign-in URL it prints is offered as a button, the
/// code from the browser is typed back into it, and the token it prints is
/// stored in the Keychain and never displayed or logged.
@MainActor
final class SignInFlow: ObservableObject {
    enum Phase: Equatable { case idle, starting, waitingForBrowser, waitingForToken, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var signInURL: URL?
    @Published private(set) var screen = ""     // redacted terminal text
    private var raw = ""
    private var process: HostProcess?
    private let log = Logger(subsystem: "cli.app", category: "signin")

    func start() {
        guard phase == .idle || isFailed else { return }
        phase = .starting
        raw = ""; screen = ""; signInURL = nil
        var o = WineHost.Options(exe: AppPaths.windowsPath(AppPaths.claudeExe), args: "setup-token")
        o.workdir = AppPaths.windowsPath(AppPaths.workspace)
        var env = ClaudeEnvironment.make(token: nil)
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = "1"
        env["BROWSER"] = "none"
        o.env = env
        o.pseudoConsole = true   // setup-token is a terminal program (ConPTY)
        Task { @MainActor in
            do {
                let p = try await WineHost.shared.spawn(o)
                self.process = p
                p.resize(cols: 400, rows: 40)   // wide: URLs and tokens stay on one line
                p.onOutput { [weak self] d, _ in
                    let text = String(decoding: d, as: UTF8.self)
                    Task { @MainActor in self?.receive(text) }
                }
                p.onExit { [weak self] code in Task { @MainActor in self?.exited(code) } }
            } catch {
                self.phase = .failed("\(error)")
            }
        }
    }

    var isFailed: Bool { if case .failed = phase { return true }; return false }

    /// The code shown by the browser after signing in.
    func submit(code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let process else { return }
        process.write(Data((c + "\r").utf8))
        phase = .waitingForToken
    }

    func cancel() {
        process?.kill()
    }

    private func receive(_ chunk: String) {
        raw += chunk
        if raw.count > 200_000 { raw = String(raw.suffix(100_000)) }
        let plain = Self.stripANSI(raw)
        // Only a complete token: followed by whitespace (it may arrive in pieces).
        if let token = TerminalText.token(in: plain, final: false) {
            Credentials.save(token)
            raw = ""
            phase = .done
            log.log("sign-in token stored")
            cancel()
        } else if signInURL == nil, let url = TerminalText.signInURL(in: plain) {
            signInURL = url
            if phase == .starting { phase = .waitingForBrowser }
        }
        screen = Self.redact(Self.lastLines(plain, 40))
    }

    private func exited(_ code: UInt32) {
        process = nil
        if phase == .done { return }
        let plain = Self.stripANSI(raw)
        if let token = TerminalText.token(in: plain, final: true) {
            Credentials.save(token)
            phase = .done
            return
        }
        phase = .failed(code >= 0xC000_0000 && code != 0xFFFF_FFFF ? String(format: "Claude Code stopped (0x%08X)", code)
                        : "Sign-in ended without a token (exit code \(code)).")
    }

    // MARK: text helpers (tested in HarborKit)

    static func stripANSI(_ s: String) -> String { TerminalText.stripANSI(s) }
    static func redact(_ s: String) -> String { TerminalText.redact(s) }
    static func lastLines(_ s: String, _ n: Int) -> String { TerminalText.lastLines(s, n) }
}
