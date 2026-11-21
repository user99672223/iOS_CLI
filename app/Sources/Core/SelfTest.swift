import Foundation
import os

/// Headless self-test (launch argument `--selftest`). Writes a
/// machine-readable report to Documents/selftest/report.json and exits.
/// Steps run in order; later milestones add more. Never logs secrets.
@MainActor
final class SelfTest {
    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
        var seconds: Double
    }
    struct Report: Codable {
        var started: Date
        var finished: Date?
        var platform: String
        var passed: Bool
        var jit: [String: String]
        var memory: [String: String]
        var metrics: [String: String]
        var steps: [Step]
    }

    private let log = Logger(subsystem: "cli.app", category: "selftest")
    private var report: Report
    private let only: Set<String>

    init(arguments: [String]) {
        #if targetEnvironment(simulator)
        let platform = "simulator"
        #else
        let platform = "device"
        #endif
        report = Report(started: Date(), platform: platform, passed: false, jit: [:], memory: [:], metrics: [:], steps: [])
        if let i = arguments.firstIndex(of: "--selftest-only"), i + 1 < arguments.count {
            only = Set(arguments[i + 1].split(separator: ",").map(String.init))
        } else { only = [] }
    }

    static var reportURL: URL {
        let dir = AppPaths.documents.appendingPathComponent("selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("report.json")
    }

    private func want(_ name: String) -> Bool { only.isEmpty || only.contains(name) }

    private func record(_ name: String, _ ok: Bool, _ detail: String, since start: Date) {
        let s = Step(name: name, ok: ok, detail: String(detail.prefix(4000)), seconds: Date().timeIntervalSince(start))
        report.steps.append(s)
        log.log("selftest \(name, privacy: .public): \(ok ? "PASS" : "FAIL", privacy: .public)")
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(report) { try? d.write(to: Self.reportURL) }
    }

    func run() async {
        try? FileManager.default.removeItem(at: AppPaths.wineLog)
        save()

        // 1. JIT pool
        var t = Date()
        var info = cli_jit_info()
        let rc = cli_jit_setup(1024, &info)
        report.jit = JITStatus.describe(info)
        record("jit_pool", rc == 0, rc == 0 ? "method=\(JITStatus.method(info))" : JITStatus.error(info), since: t)
        guard rc == 0 else { return finish() }

        // 2. cmd /c ver
        if want("cmd_ver") {
            t = Date()
            let r = await WineSession.run(.init(exe: "cmd.exe", args: "/c ver"), timeout: 300)
            let ok = !r.timedOut && r.output.contains("Windows")
            record("cmd_ver", ok, "exit=\(r.exit) crash=\(String(r.crash, radix: 16)) timedOut=\(r.timedOut) out=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))", since: t)
            report.metrics["cmd_ver_seconds"] = String(format: "%.1f", Date().timeIntervalSince(t))
        }

        // 3. A second session in the same app process (relaunch).
        if want("relaunch") {
            t = Date()
            let r = await WineSession.run(.init(exe: "cmd.exe", args: "/c echo relaunch-ok"), timeout: 180)
            record("relaunch", r.output.contains("relaunch-ok"), "exit=\(r.exit) out=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))", since: t)
        }

        // 4. Download Claude Code and Git (first-run path, SHA-256 verified).
        if want("install") || want("claude_version") || want("git_bash") || want("stream_json") || want("setup_token") {
            t = Date()
            do {
                try await ToolInstaller.shared.installClaude()
                try await ToolInstaller.shared.installGit()
                try ToolInstaller.writeConfiguration()
                record("install", true, "claude=\(ToolInstaller.installedClaudeVersion ?? "?") git=\(ToolInstaller.installedGitVersion ?? "?")", since: t)
                report.metrics["claude_version_installed"] = ToolInstaller.installedClaudeVersion ?? ""
            } catch {
                record("install", false, "\(error)", since: t)
                return finish()
            }
        }

        // 5. claude.exe --version
        if want("claude_version") {
            t = Date()
            var o = WineSession.Options(exe: AppPaths.windowsPath(AppPaths.claudeExe), args: "--version")
            o.env = ClaudeEnvironment.make(token: nil)
            o.workdir = AppPaths.windowsPath(AppPaths.workspace)
            let r = await WineSession.run(o, timeout: 600)
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            record("claude_version", out.contains("Claude Code") || out.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) != nil,
                   "exit=\(r.exit) crash=\(String(r.crash, radix: 16)) timedOut=\(r.timedOut) out=\(out)", since: t)
            report.metrics["claude_version_seconds"] = String(format: "%.1f", Date().timeIntervalSince(t))
            report.metrics["footprint_after_claude_version"] = MemoryStats.mb(MemoryStats.physFootprint)
        }

        // 6. Git Bash round trip: busybox bash runs git.
        if want("git_bash") {
            t = Date()
            let bin = AppPaths.windowsPath(AppPaths.gitDir.appendingPathComponent("clangarm64/bin"))
            var o = WineSession.Options(exe: bin + "\\bash.exe", args: "-lc \"echo ok && git --version && cd /c/workspace && git init -q rt && cd rt && echo hi > f && git add f && git -c user.name=t -c user.email=t@t commit -qm m && git log --oneline | wc -l\"")
            o.env = ClaudeEnvironment.make(token: nil)
            o.workdir = AppPaths.windowsPath(AppPaths.workspace)
            let r = await WineSession.run(o, timeout: 300)
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            record("git_bash", out.contains("ok") && out.contains("git version"), "exit=\(r.exit) timedOut=\(r.timedOut) out=\(out)", since: t)
        }

        // 7. Sign-in pipeline (claude setup-token in a console) up to the sign-in link.
        if want("setup_token") {
            t = Date()
            let flow = SignInFlow()
            flow.start()
            var gotURL = false
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if flow.signInURL != nil { gotURL = true; break }
                if flow.isFailed { break }
            }
            let screen = flow.screen
            flow.cancel()
            for _ in 0..<100 where WineSession.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            record("setup_token", gotURL, "url=\(flow.signInURL?.host ?? "none") screen=\(screen.suffix(600))", since: t)
        }

        // 8. stream-json round trip (a real turn with the token; without one, up to the auth error).
        if want("stream_json") {
            await streamJSON()
        }
        finish()
    }

    private func streamJSON() async {
        let t = Date()
        let token = Credentials.token
        let engine = ClaudeEngine()
        var raw: [String] = []
        engine.onRawLine = { raw.append(String($0.prefix(2000))) }
        engine.start(resume: nil)
        // Wait for the CLI to answer initialize / report system init.
        var initOK = false
        for _ in 0..<1500 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if raw.contains(where: { $0.contains("\"control_response\"") || $0.contains("\"subtype\":\"init\"") }) { initOK = true; break }
            if case .failed = engine.phase { break }
        }
        report.metrics["stream_json_init_seconds"] = String(format: "%.1f", Date().timeIntervalSince(t))
        guard initOK else {
            record("stream_json", false, "no initialize response; phase=\(engine.phase) lines=\(raw.suffix(5).joined(separator: " | "))", since: t)
            engine.stop()
            return
        }
        let prompt = token == nil
            ? "Reply with the single word pong."
            : "Use the Bash tool to run: git --version. Then reply with exactly: pong <the git version number>."
        engine.send(text: prompt)
        var done = false
        for _ in 0..<3000 {   // up to 10 minutes
            try? await Task.sleep(nanoseconds: 200_000_000)
            if raw.contains(where: { $0.contains("\"type\":\"result\"") }) { done = true; break }
            if case .failed = engine.phase { break }
        }
        let resultLine = raw.last(where: { $0.contains("\"type\":\"result\"") }) ?? ""
        let text = engine.chat.items.compactMap { item -> String? in
            if case .assistant(let s) = item.kind { return s }
            return nil
        }.joined(separator: " ")
        var gitSeen = false
        for item in engine.chat.items {
            if case .tool(let tc) = item.kind, tc.kind == .bash, tc.result.contains("git version") { gitSeen = true }
        }
        report.metrics["stream_json_turn_seconds"] = String(format: "%.1f", Date().timeIntervalSince(t))
        report.metrics["footprint_during_session"] = MemoryStats.mb(MemoryStats.physFootprint)
        if token != nil {
            let ok = done && text.lowercased().contains("pong") && gitSeen
            record("stream_json", ok, "conversation: done=\(done) git_tool=\(gitSeen) text=\(text.prefix(300)) result=\(resultLine.prefix(400))", since: t)
        } else {
            // Without a token the pipeline must reach Claude Code's own authentication error.
            let auth = resultLine.lowercased().contains("login") || resultLine.lowercased().contains("auth")
                || resultLine.contains("401") || text.lowercased().contains("login") || resultLine.lowercased().contains("api key")
            record("stream_json", done && auth, "no token: expected auth error; done=\(done) text=\(text.prefix(300)) result=\(resultLine.prefix(400))", since: t)
        }
        engine.stop()
        for _ in 0..<100 where WineSession.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    private func finish() {
        report.memory = MemoryStats.snapshot()
        report.finished = Date()
        report.passed = !report.steps.isEmpty && report.steps.allSatisfy(\.ok)
        save()
        log.log("selftest finished: \(self.report.passed ? "PASSED" : "FAILED", privacy: .public)")
    }
}
