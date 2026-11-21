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
        report = Report(started: Date(), platform: platform, passed: false, jit: [:], memory: [:], steps: [])
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
        let rc = cli_jit_setup(512, &info)
        report.jit = JITStatus.describe(info)
        record("jit_pool", rc == 0, rc == 0 ? "method=\(JITStatus.method(info))" : JITStatus.error(info), since: t)
        guard rc == 0 else { return finish() }

        // 2. cmd /c ver
        if want("cmd_ver") {
            t = Date()
            let r = await WineSession.run(.init(exe: "cmd.exe", args: "/c ver"), timeout: 180)
            let ok = !r.timedOut && r.output.contains("Windows")
            record("cmd_ver", ok, "exit=\(r.exit) crash=\(String(r.crash, radix: 16)) timedOut=\(r.timedOut) out=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))", since: t)
        }

        // 3. A second session in the same app process (relaunch).
        if want("relaunch") {
            t = Date()
            let r = await WineSession.run(.init(exe: "cmd.exe", args: "/c echo relaunch-ok"), timeout: 120)
            record("relaunch", r.output.contains("relaunch-ok"), "exit=\(r.exit) out=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))", since: t)
        }

        finish()
    }

    private func finish() {
        report.memory = MemoryStats.snapshot()
        report.finished = Date()
        report.passed = !report.steps.isEmpty && report.steps.allSatisfy(\.ok)
        save()
        log.log("selftest finished: \(self.report.passed ? "PASSED" : "FAILED", privacy: .public)")
    }
}
