import Foundation
import HarborKit
import os

/// Paths used by the app. Inside LiveContainer, NSHomeDirectory() is the
/// guest's data container, so these follow it automatically.
enum AppPaths {
    /// Computed once, before Wine changes HOME for the whole process
    /// (iOS derives these folders from HOME). AppDelegate touches them first.
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let appSupport: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// The Wine prefix (not visible in the Files app).
    static var prefix: URL { appSupport.appendingPathComponent("wine", isDirectory: true) }
    /// Plain log folder, outside the app: inside LiveContainer it is in
    /// LiveContainer's own Documents (Files → On My iPhone → LiveContainer →
    /// Harbor Logs); otherwise in Harbor's Documents.
    static let logs: URL = {
        let fm = FileManager.default
        if ProcessInfo.processInfo.arguments.contains("--selftest") {
            let u = documents.appendingPathComponent("logs", isDirectory: true)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        var base = documents
        if let lc = ProcessInfo.processInfo.environment["LP_HOME_PATH"], !lc.isEmpty {
            base = URL(fileURLWithPath: lc).appendingPathComponent("Documents", isDirectory: true)
        }
        var u = base.appendingPathComponent("Harbor Logs", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        if !fm.isWritableFile(atPath: u.path) {
            u = documents.appendingPathComponent("Harbor Logs", isDirectory: true)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }()
    /// One file per app launch, named by date and time; the 10 newest are kept.
    static let wineLog: URL = {
        if ProcessInfo.processInfo.arguments.contains("--selftest") { return logs.appendingPathComponent("wine.log") }
        let fm = FileManager.default
        let old = ((try? fm.contentsOfDirectory(atPath: logs.path)) ?? [])
            .filter { $0.hasPrefix("harbor-") && $0.hasSuffix(".log") }.sorted()
        for name in old.dropLast(9) { try? fm.removeItem(at: logs.appendingPathComponent(name)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return logs.appendingPathComponent("harbor-\(f.string(from: Date())).log")
    }()
    static var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    /// Where Claude Code and Git live inside the prefix.
    static var toolsDir: URL { driveC.appendingPathComponent("tools", isDirectory: true) }
    static var claudeExe: URL { toolsDir.appendingPathComponent("claude/claude.exe") }
    static var gitDir: URL { toolsDir.appendingPathComponent("git", isDirectory: true) }
    /// %USERPROFILE% (the runtime sets USER=user for Wine).
    static var userProfile: URL { driveC.appendingPathComponent("users/user", isDirectory: true) }
    /// Claude Code's working folder (C:\workspace).
    static var workspace: URL { driveC.appendingPathComponent("workspace", isDirectory: true) }
    /// %USERPROFILE%\.claude
    static var claudeConfig: URL { userProfile.appendingPathComponent(".claude", isDirectory: true) }

    /// unix path inside drive_c -> C:\ path
    static func windowsPath(_ url: URL) -> String {
        let base = driveC.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(base) else { return p }
        let rel = p.dropFirst(base.count).replacingOccurrences(of: "/", with: "\\")
        return "C:" + (rel.hasPrefix("\\") ? rel : "\\" + rel)
    }
}

/// The app's one Wine process. Starting a second Wine session in the same app
/// process is not possible (the in-process wineserver cannot be restarted), so
/// its main program is harbor-host.exe (host/harbor-host.c), which stays up
/// for the app's lifetime and starts every Windows program as a child
/// process, relaying the children's standard streams over its own.
final class WineHost: @unchecked Sendable {
    static let shared = WineHost()

    enum State: Equatable { case stopped, starting, ready, failed(String) }

    private let log = Logger(subsystem: "cli.app", category: "host")
    private let queue = DispatchQueue(label: "cli.host.io")
    private let writeQueue = DispatchQueue(label: "cli.host.write")
    private let lock = NSLock()
    private var _state: State = .stopped
    private var lines = LineBuffer()
    private var processes: [UInt32: HostProcess] = [:]
    private var nextID: UInt32 = 1
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var readSource: DispatchSourceRead?
    private(set) var hostPID: UInt32 = 0
    private var wineStarted = false

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    var isReady: Bool { state == .ready }
    var running: [HostProcess] { lock.lock(); defer { lock.unlock() }; return Array(processes.values) }

    struct HostError: Error, CustomStringConvertible {
        var description: String
    }

    /// Starts Wine and the host program once; later calls wait for it.
    func start() async throws {
        lock.lock()
        // A start refused for missing JIT memory can be retried once JIT is on.
        if case .failed = _state, !wineStarted { _state = .stopped }
        let shouldLaunch = _state == .stopped
        if shouldLaunch { _state = .starting }
        lock.unlock()
        if shouldLaunch { launch() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            switch _state {
            case .ready: lock.unlock(); c.resume()
            case .failed(let m): lock.unlock(); c.resume(throwing: HostError(description: m))
            default: readyWaiters.append(c); lock.unlock()
            }
        }
    }

    private func setState(_ s: State) {
        lock.lock()
        _state = s
        var waiters: [CheckedContinuation<Void, Error>] = []
        switch s {
        case .ready, .failed: waiters = readyWaiters; readyWaiters.removeAll()
        default: break
        }
        lock.unlock()
        for w in waiters {
            if case .failed(let m) = s { w.resume(throwing: HostError(description: m)) } else { w.resume() }
        }
    }

    private func launch() {
        // Without the debugger's JIT memory Wine cannot run code and crash-loops:
        // never start it then.
        var jitInfo = cli_jit_info()
        cli_jit_query(&jitInfo)
        if jitInfo.pool_ready == 0 && jitInfo.simulator == 0 {
            FileHandle.standardError.write(Data("[app] refused to start Wine: no JIT memory\n".utf8))
            setState(.failed("JIT isn't ready yet. Enable JIT in Setup first (StikDebug must be attached)."))
            return
        }
        try? FileManager.default.createDirectory(at: LiveOutputWatcher.directory, withIntermediateDirectories: true)
        let env = [
            "CLI_CAPTURE_DIR=\(LiveOutputWatcher.directory.path)",
            "CLI_CAPTURE_SKIP=claude.exe,conhost.exe,harbor-host.exe",
        ]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer { cEnv.forEach { free($0) } }
        var rc: Int32 = -1
        cEnv.withUnsafeBufferPointer { envBuf in
            AppPaths.prefix.path.withCString { cPrefix in
                "harbor-host.exe".withCString { cExe in
                    "C:\\".withCString { cWork in
                        AppPaths.wineLog.path.withCString { cLog in
                            var p = cli_session_params()
                            p.prefix = cPrefix
                            p.exe = cExe
                            p.args = nil
                            p.workdir = cWork
                            p.log_path = cLog
                            p.env = UnsafePointer(OpaquePointer(envBuf.baseAddress))
                            p.stdin_pipe = 1
                            p.stdout_pipe = 1
                            rc = cli_session_start(&p)
                        }
                    }
                }
            }
        }
        guard rc == 0 else {
            setState(.failed("The Wine runtime failed to start (see logs/wine.log)."))
            return
        }
        lock.lock(); wineStarted = true; lock.unlock()
        let fd = cli_stdout_fd()
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        readSource = src
        src.resume()
        watchSession()
        // The host announces itself with READY; Wine's first start can take a while.
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in
            if self?.state == .starting { self?.setState(.failed("Wine did not start within 5 minutes.")) }
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { cli_stdout_read($0.baseAddress, UInt(65536)) }
            if n > 0 {
                for line in lines.append(Data(buf[0..<Int(n)])) { handle(line) }
                continue
            }
            if n == 0 { readSource?.cancel(); readSource = nil }
            break
        }
    }

    private func watchSession() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if cli_session_running() != 0 { self.watchSession(); return }
            self.drain()
            let crash = cli_session_crash_status()
            let msg = crash != 0 ? String(format: "The Wine host stopped (0x%08X). Restart Harbor.", crash)
                                 : "The Wine host exited. Restart Harbor."
            self.log.error("\(msg, privacy: .public)")
            self.setState(.failed(msg))
            self.lock.lock()
            let procs = Array(self.processes.values)
            self.processes.removeAll()
            self.lock.unlock()
            procs.forEach { $0.finish(code: crash != 0 ? crash : 0xC000_0001) }
        }
    }

    // MARK: protocol

    private func handle(_ line: String) {
        let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let tag = f.first else { return }
        if tag == "READY" {
            hostPID = UInt32(f.count > 1 ? f[1] : "") ?? 0
            log.log("host ready (pid \(self.hostPID))")
            setState(.ready)
            return
        }
        guard f.count >= 2, let id = UInt32(f[1]) else { return }
        lock.lock()
        let proc = processes[id]
        lock.unlock()
        guard let proc else { return }
        switch tag {
        case "OUT", "ERR":
            if f.count > 2, let d = Data(base64Encoded: f[2]) { proc.deliver(d, isError: tag == "ERR") }
        case "STARTED":
            proc.pid = UInt32(f.count > 2 ? f[2] : "") ?? 0
        case "FAILED":
            proc.startError = UInt32(f.count > 2 ? f[2] : "") ?? 0
            remove(id)
            proc.finish(code: 0xFFFF_FFFF)
        case "EXIT":
            remove(id)
            proc.finish(code: UInt32(f.count > 2 ? f[2] : "") ?? 0)
        default: break
        }
    }

    private func remove(_ id: UInt32) {
        lock.lock()
        processes.removeValue(forKey: id)
        lock.unlock()
    }

    fileprivate func send(_ fields: [String]) {
        let line = fields.joined(separator: "\t") + "\n"
        writeQueue.async {
            let d = Data(line.utf8)
            _ = d.withUnsafeBytes { cli_stdin_write($0.baseAddress, UInt(d.count)) }
        }
    }

    private static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    struct Options {
        var exe: String                 // Windows path, or a name in C:\windows\system32
        var args: String = ""           // already quoted, Windows style
        var workdir: String? = nil      // C:\...
        var env: [String: String] = [:]
        var pseudoConsole = false       // ConPTY: the program sees a terminal
        var mergeStderr = false
    }

    /// Starts a Windows program as a child of the host.
    func spawn(_ o: Options) async throws -> HostProcess {
        try await start()
        let exe = o.exe.contains("\\") || o.exe.contains(":") ? o.exe : "C:\\windows\\system32\\" + o.exe
        let cmdline = WinQuote.arg(exe) + (o.args.isEmpty ? "" : " " + o.args)
        let p = HostProcess(host: self)
        lock.lock()
        let id = nextID
        nextID += 1
        processes[id] = p
        lock.unlock()
        p.id = id
        p.commandLine = cmdline
        let env = o.env.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1f}")
        var flags = ""
        if o.pseudoConsole { flags += "p" }
        if o.mergeStderr { flags += "e" }
        send(["RUN", String(id), flags.isEmpty ? "-" : flags, Self.b64(o.workdir ?? "-"), Self.b64(cmdline), Self.b64(env)])
        return p
    }
}

/// A Windows program started by the host.
final class HostProcess: @unchecked Sendable {
    fileprivate unowned let host: WineHost
    fileprivate(set) var id: UInt32 = 0
    fileprivate(set) var pid: UInt32 = 0
    fileprivate(set) var startError: UInt32 = 0
    fileprivate(set) var commandLine = ""
    let startedAt = Date()
    private let lock = NSLock()
    private var exitCode: UInt32?
    private var buffered: [(Data, Bool)] = []
    private var outputHandler: ((Data, Bool) -> Void)?
    private var exitHandler: ((UInt32) -> Void)?

    fileprivate init(host: WineHost) { self.host = host }

    /// Output chunks (stdout, or stderr when the flag is true), on the host's I/O queue.
    func onOutput(_ h: @escaping (Data, Bool) -> Void) {
        lock.lock()
        outputHandler = h
        let pending = buffered
        buffered.removeAll()
        lock.unlock()
        pending.forEach { h($0.0, $0.1) }
    }

    /// Called once with the exit code (NTSTATUS for crashes; 0xFFFFFFFF if it could not start).
    func onExit(_ h: @escaping (UInt32) -> Void) {
        lock.lock()
        exitHandler = h
        let code = exitCode
        lock.unlock()
        if let code { h(code) }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return exitCode == nil }

    fileprivate func deliver(_ d: Data, isError: Bool) {
        lock.lock()
        if let h = outputHandler { lock.unlock(); h(d, isError) } else { buffered.append((d, isError)); lock.unlock() }
    }

    fileprivate func finish(code: UInt32) {
        lock.lock()
        guard exitCode == nil else { lock.unlock(); return }
        exitCode = code
        let h = exitHandler
        lock.unlock()
        h?(code)
    }

    func write(_ d: Data) {
        var off = 0
        while off < d.count {   // keep each protocol line moderate
            let chunk = d.subdata(in: off..<min(d.count, off + 48_000))
            host.send(["IN", String(id), chunk.base64EncodedString()])
            off += chunk.count
        }
    }
    func closeStdin() { host.send(["EOF", String(id)]) }
    func kill() { host.send(["KILL", String(id)]) }
    func resize(cols: Int, rows: Int) { host.send(["RESIZE", String(id), String(cols), String(rows)]) }
}

extension HostProcess {
    /// Runs a program to completion and collects its output (stdout + stderr).
    static func run(_ o: WineHost.Options, timeout: TimeInterval) async -> (output: String, exit: UInt32, timedOut: Bool) {
        let p: HostProcess
        do { p = try await WineHost.shared.spawn(o) } catch { return ("\(error)", 0xFFFF_FFFF, false) }
        let collected = LockedData()
        let done = OnceFlag()
        let result: (String, UInt32, Bool) = await withCheckedContinuation { cont in
            p.onOutput { d, _ in collected.append(d) }
            p.onExit { code in if done.set() { cont.resume(returning: (collected.string, code, false)) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if done.set() { p.kill(); cont.resume(returning: (collected.string, 0xFFFF_FFFF, true)) }
            }
        }
        return result
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
