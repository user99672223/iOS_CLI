import Foundation

/// Tails the per-process output files written by the ntdll capture hook
/// (build/ntdll-unix/cli_capture.c) and attributes them to running Bash tool
/// calls. Each file starts with "#pid <pid> <unix time> <command line>".
@MainActor
final class LiveOutputWatcher {
    static var directory: URL { AppPaths.logs.appendingPathComponent("proc", isDirectory: true) }

    private var offsets: [String: UInt64] = [:]
    private var owner: [String: String] = [:]   // file name -> tool id
    private var timer: Timer?
    /// (toolID, command) of the running Bash calls, newest last.
    var runningCommands: () -> [(id: String, command: String)] = { [] }
    var deliver: (String, String) -> Void = { _, _ in }

    static func reset() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start() {
        Self.reset()
        offsets.removeAll(); owner.removeAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let running = runningCommands()
        guard !running.isEmpty else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.directory.path) else { return }
        for name in files where name.hasSuffix(".log") {
            let url = Self.directory.appendingPathComponent(name)
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let start = offsets[name] ?? 0
            try? h.seek(toOffset: start)
            guard let data = try? h.read(upToCount: 1 << 20), !data.isEmpty else { continue }
            var text = String(decoding: data, as: UTF8.self)
            if start == 0, let nl = text.firstIndex(of: "\n") {
                let header = String(text[..<nl])
                text = String(text[text.index(after: nl)...])
                owner[name] = attribute(header: header, running: running)
            }
            offsets[name] = start + UInt64(data.count)
            if owner[name] == nil { owner[name] = running.last?.id }
            if let id = owner[name], running.contains(where: { $0.id == id }), !text.isEmpty {
                deliver(id, text)
            }
        }
    }

    /// The tool whose command appears in the process's command line; else the newest running one.
    private func attribute(header: String, running: [(id: String, command: String)]) -> String? {
        let cmdline = header.split(separator: " ", maxSplits: 3).dropFirst(3).first.map(String.init) ?? ""
        for r in running.reversed() {
            let probe = String(r.command.prefix(40))
            if !probe.isEmpty, cmdline.contains(probe) { return r.id }
        }
        return running.last?.id
    }
}
