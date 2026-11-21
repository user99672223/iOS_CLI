import Foundation
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
    /// The Wine prefix (not visible in the Files app: it holds the token-bearing config).
    static var prefix: URL { appSupport.appendingPathComponent("wine", isDirectory: true) }
    static var logs: URL {
        let u = documents.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var wineLog: URL { logs.appendingPathComponent("wine.log") }
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

/// One Windows program run by the in-process Wine runtime.
/// Only one session runs at a time (the runtime owns fds 0/1/2).
final class WineSession: @unchecked Sendable {
    struct Options {
        var exe: String
        var args: String = ""
        var workdir: String? = nil
        var env: [String: String] = [:]
        var stdinPipe = false
        var stdoutPipe = true
    }

    private let log = Logger(subsystem: "cli.app", category: "session")
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "cli.session.io")
    private(set) var startedAt = Date()

    /// Called on the I/O queue with each chunk of stdout.
    var onOutput: ((Data) -> Void)?
    /// Called once, on the I/O queue, after the program exited and stdout drained.
    var onExit: ((Int32, UInt32) -> Void)?

    static var isRunning: Bool { cli_session_running() != 0 }

    func start(_ o: Options) throws {
        guard cli_session_running() == 0 else { throw RuntimeError.busy }
        var envList = o.env.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envList.map { strdup($0) } + [nil]
        defer { cEnv.forEach { free($0) } }
        envList.removeAll()
        let prefix = AppPaths.prefix.path
        let logPath = AppPaths.wineLog.path
        var rc: Int32 = -1
        cEnv.withUnsafeBufferPointer { envBuf in
            prefix.withCString { cPrefix in
                o.exe.withCString { cExe in
                    o.args.withCString { cArgs in
                        logPath.withCString { cLog in
                            let run = { (cWork: UnsafePointer<CChar>?) in
                                var p = cli_session_params()
                                p.prefix = cPrefix
                                p.exe = cExe
                                p.args = cArgs
                                p.workdir = cWork
                                p.log_path = cLog
                                p.env = UnsafePointer(OpaquePointer(envBuf.baseAddress))
                                p.stdin_pipe = o.stdinPipe ? 1 : 0
                                p.stdout_pipe = o.stdoutPipe ? 1 : 0
                                rc = cli_session_start(&p)
                            }
                            if let w = o.workdir { w.withCString { run($0) } } else { run(nil) }
                        }
                    }
                }
            }
        }
        guard rc == 0 else { throw RuntimeError.startFailed }
        startedAt = Date()
        if o.stdoutPipe { attachReader() } else { watchExit() }
    }

    private func attachReader() {
        let fd = cli_stdout_fd()
        guard fd >= 0 else { watchExit(); return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { cli_stdout_read($0.baseAddress, UInt(65536)) }
                if n > 0 { self.onOutput?(Data(buf[0..<Int(n)])); continue }
                if n == 0 { src.cancel(); self.finish(); }   // EOF
                break
            }
        }
        readSource = src
        src.resume()
        // EOF only arrives once every holder of the write end is gone; the
        // runtime closes its copy when the main program ends.
        watchExit()
    }

    private var finished = false
    private func watchExit() {
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if cli_session_running() != 0 { self.watchExit(); return }
            // Drain whatever is left, then report.
            if let src = self.readSource { src.cancel() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { cli_stdout_read($0.baseAddress, UInt(65536)) }
                if n > 0 { self.onOutput?(Data(buf[0..<Int(n)])) } else { break }
            }
            self.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        guard cli_session_running() == 0 else { return }
        finished = true
        onExit?(cli_session_exit_code(), cli_session_crash_status())
    }

    func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { cli_stdin_write($0.baseAddress, UInt(data.count)) } == data.count
    }

    func closeStdin() { cli_stdin_close() }

    enum RuntimeError: Error, CustomStringConvertible {
        case busy, startFailed
        var description: String {
            switch self {
            case .busy: return "A Windows program is already running"
            case .startFailed: return "The Wine runtime failed to start (see logs/wine.log)"
            }
        }
    }
}

extension WineSession {
    /// Run a program to completion and collect its stdout.
    static func run(_ o: Options, timeout: TimeInterval) async -> (output: String, exit: Int32, crash: UInt32, timedOut: Bool) {
        let session = WineSession()
        let collected = LockedData()
        let result: (output: String, exit: Int32, crash: UInt32, timedOut: Bool) = await withCheckedContinuation { cont in
            let done = OnceFlag()
            session.onOutput = { collected.append($0) }
            session.onExit = { code, crash in
                if done.set() { cont.resume(returning: (collected.string, code, crash, false)) }
            }
            do { try session.start(o) } catch {
                if done.set() { cont.resume(returning: ("\(error)", -1, 0, false)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if done.set() { cont.resume(returning: (collected.string, -1, 0, true)) }
            }
        }
        withExtendedLifetime(session) {}   // the I/O handlers hold it weakly
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
