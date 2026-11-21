import Foundation
import HarborKit

/// Claude Code's saved conversations: %USERPROFILE%\.claude\projects\<project>\<session-id>.jsonl
struct SessionSummary: Identifiable, Hashable {
    var id: String          // session id (file name without .jsonl)
    var title: String       // first user message, shortened
    var modified: Date
    var url: URL
    var project: String
}

enum SessionStore {
    static var projectsDir: URL { AppPaths.claudeConfig.appendingPathComponent("projects", isDirectory: true) }

    static func list() -> [SessionSummary] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [SessionSummary] = []
        for p in projects {
            guard let files = try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard (rv?.fileSize ?? 0) > 0 else { continue }
                let title = firstUserText(f) ?? "Untitled session"
                out.append(SessionSummary(id: f.deletingPathExtension().lastPathComponent, title: title,
                                          modified: rv?.contentModificationDate ?? .distantPast, url: f,
                                          project: p.lastPathComponent))
            }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    static var mostRecent: SessionSummary? { list().first }

    static func load(_ s: SessionSummary) -> ChatState {
        guard let text = try? String(contentsOf: s.url, encoding: .utf8) else { return ChatState() }
        return ChatState.fromTranscript(text)
    }

    static func delete(_ s: SessionSummary) {
        try? FileManager.default.removeItem(at: s.url)
    }

    /// Reads only the start of the file to find the first real user message.
    private static func firstUserText(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("\"type\":\"user\""), let v = try? JSONValue(parsing: String(line)) else { continue }
            if v["isMeta"]?.bool == true { continue }
            var text = v["message"]?["content"]?.string
            if text == nil {
                text = v["message"]?["content"]?.array?.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.first
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") {
                return String(t.prefix(80))
            }
        }
        return nil
    }
}
