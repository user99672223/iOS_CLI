import Foundation

/// A tool invocation shown as a card.
public struct ToolCall: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case running, success, error, interrupted }
    public var id: String
    public var name: String
    public var input: JSONValue
    /// Accumulated input JSON while it streams in.
    public var partialInput: String = ""
    public var status: Status = .running
    public var result: String = ""
    /// Output captured while the command runs (Bash), before its tool_result.
    public var liveOutput: String = ""
    public var startedAt: Date
    public var finishedAt: Date?

    public var kind: ToolKind { ToolKind(name: name) }
    public var command: String? { input["command"]?.string }
    public var filePath: String? { input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string }
    public var description: String? { input["description"]?.string }
}

public enum ToolKind: Equatable, Sendable {
    case bash, edit, write, multiEdit, read, grep, glob, todo, task, webFetch, webSearch, other(String)
    init(name: String) {
        switch name {
        case "Bash", "PowerShell", "BashOutput": self = .bash
        case "Edit", "NotebookEdit": self = .edit
        case "Write": self = .write
        case "MultiEdit": self = .multiEdit
        case "Read", "LS": self = .read
        case "Grep": self = .grep
        case "Glob": self = .glob
        case "TodoWrite": self = .todo
        case "Task", "Agent": self = .task
        case "WebFetch": self = .webFetch
        case "WebSearch": self = .webSearch
        default: self = .other(name)
        }
    }
    public var isCompact: Bool {
        switch self { case .read, .grep, .glob, .webFetch, .webSearch: return true; default: return false }
    }
}

public struct TodoItem: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    public var id: Int
    public var content: String
    public var activeForm: String
    public var status: Status
}

public struct TurnFooter: Equatable, Sendable {
    public var durationMS: Double
    public var costUSD: Double?
    public var isError: Bool
    public var subtype: String
    public var outputTokens: Int?
}

public struct ChatItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case user(text: String, imageCount: Int)
        case assistant(text: String)
        case thinking(text: String)
        case tool(ToolCall)
        case footer(TurnFooter)
        case notice(text: String, isError: Bool)
    }
    public var id: String
    public var kind: Kind
    public var isStreaming: Bool = false
    public var date: Date
}

/// The conversation as the UI shows it. Pure value type: feed it protocol
/// events with `apply(_:)`; unit-tested on Linux.
public struct ChatState: Equatable, Sendable {
    public private(set) var items: [ChatItem] = []
    /// Items produced by sub-agents, keyed by the Task tool call that owns them.
    public private(set) var children: [String: [ChatItem]] = [:]
    public private(set) var todos: [TodoItem] = []
    public private(set) var sessionID: String?
    public private(set) var model: String?
    public private(set) var cliVersion: String?
    public private(set) var isTurnRunning = false
    public private(set) var lastError: String?

    // Streaming bookkeeping per list (top level = "").
    private var streamMessageID: [String: String] = [:]
    private var streamBlockItem: [String: [Int: String]] = [:]
    /// Streamed text/thinking items not yet confirmed by an `assistant` message, in order.
    private var unconfirmed: [String: [String]] = [:]
    private var toolLocation: [String: String] = [:]   // tool id -> list key
    private var seq = 0
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public static func == (a: ChatState, b: ChatState) -> Bool {
        a.items == b.items && a.children == b.children && a.todos == b.todos && a.sessionID == b.sessionID
            && a.isTurnRunning == b.isTurnRunning && a.model == b.model && a.lastError == b.lastError
    }

    private mutating func nextID(_ prefix: String) -> String { seq += 1; return "\(prefix)-\(seq)" }

    // MARK: list access

    private func list(_ key: String) -> [ChatItem] { key.isEmpty ? items : (children[key] ?? []) }
    private mutating func setList(_ key: String, _ value: [ChatItem]) {
        if key.isEmpty { items = value } else { children[key] = value }
    }
    private mutating func append(_ item: ChatItem, to key: String) {
        var l = list(key); l.append(item); setList(key, l)
    }
    private mutating func update(_ id: String, in key: String, _ body: (inout ChatItem) -> Void) {
        var l = list(key)
        if let i = l.firstIndex(where: { $0.id == id }) { body(&l[i]); setList(key, l) }
    }
    private func contains(_ id: String, in key: String) -> Bool { list(key).contains { $0.id == id } }

    public func children(of toolID: String) -> [ChatItem] { children[toolID] ?? [] }

    // MARK: app-side actions

    public mutating func addUserMessage(_ text: String, imageCount: Int = 0) {
        append(ChatItem(id: nextID("user"), kind: .user(text: text, imageCount: imageCount), date: now()), to: "")
        isTurnRunning = true
        lastError = nil
    }

    public mutating func addNotice(_ text: String, isError: Bool = false) {
        append(ChatItem(id: nextID("notice"), kind: .notice(text: text, isError: isError), date: now()), to: "")
        if isError { lastError = text }
    }

    /// The CLI process ended or the turn was stopped: settle anything still streaming.
    public mutating func endTurn(interrupted: Bool) {
        isTurnRunning = false
        for key in [""] + Array(children.keys) {
            var l = list(key)
            for i in l.indices {
                l[i].isStreaming = false
                if case .tool(var t) = l[i].kind, t.status == .running {
                    t.status = interrupted ? .interrupted : .success
                    t.finishedAt = now()
                    l[i].kind = .tool(t)
                }
            }
            setList(key, l)
        }
        streamBlockItem.removeAll(); unconfirmed.removeAll(); streamMessageID.removeAll()
    }

    /// Live output of a running command (from the per-process output capture).
    public mutating func appendLiveOutput(toolID: String, _ text: String) {
        guard let key = toolLocation[toolID] else { return }
        update(toolID, in: key) { item in
            if case .tool(var t) = item.kind, t.status == .running {
                t.liveOutput += text
                if t.liveOutput.utf8.count > 200_000 { t.liveOutput = String(t.liveOutput.suffix(150_000)) }
                item.kind = .tool(t)
            }
        }
    }

    /// The most recently started command that is still running (for live output routing).
    public var runningCommandIDs: [String] {
        ([""] + Array(children.keys)).flatMap { key in
            list(key).compactMap { item -> String? in
                if case .tool(let t) = item.kind, t.status == .running, t.kind == .bash { return t.id }
                return nil
            }
        }
    }

    // MARK: protocol events

    public mutating func apply(_ event: ClaudeProtocol.Event) {
        switch event {
        case .systemInit(let i):
            sessionID = i.sessionID.isEmpty ? sessionID : i.sessionID
            model = i.model.isEmpty ? model : i.model
            cliVersion = i.version.isEmpty ? cliVersion : i.version
        case .stream(let e, let parent):
            applyStream(e, key: parent ?? "")
        case .assistant(let m, let parent):
            applyAssistant(m, key: parent ?? "")
        case .user(let m, let parent):
            applyUser(m, key: parent ?? "")
        case .result(let r):
            if !r.sessionID.isEmpty { sessionID = r.sessionID }
            endTurn(interrupted: r.subtype == "error_during_execution" && r.isError)
            append(ChatItem(id: nextID("footer"), kind: .footer(TurnFooter(
                durationMS: r.durationMS, costUSD: r.costUSD, isError: r.isError, subtype: r.subtype,
                outputTokens: r.outputTokens)), date: now()), to: "")
            if r.isError, let t = r.resultText, !t.isEmpty { lastError = t }
        default:
            break
        }
    }

    private mutating func applyStream(_ e: ClaudeProtocol.StreamEvent, key: String) {
        switch e {
        case .messageStart(let id):
            streamMessageID[key] = id
            streamBlockItem[key] = [:]
        case .blockStart(let index, let block):
            let date = now()
            switch block {
            case .text(let s):
                let id = nextID("text")
                append(ChatItem(id: id, kind: .assistant(text: s), isStreaming: true, date: date), to: key)
                streamBlockItem[key, default: [:]][index] = id
                unconfirmed[key, default: []].append(id)
            case .thinking(let s):
                let id = nextID("thinking")
                append(ChatItem(id: id, kind: .thinking(text: s), isStreaming: true, date: date), to: key)
                streamBlockItem[key, default: [:]][index] = id
                unconfirmed[key, default: []].append(id)
            case .toolUse(let id, let name, let input):
                startTool(id: id, name: name, input: input, key: key, streaming: true)
                streamBlockItem[key, default: [:]][index] = id
            default: break
            }
        case .textDelta(let index, let text), .thinkingDelta(let index, let text):
            guard let id = streamBlockItem[key]?[index] else { return }
            update(id, in: key) { item in
                switch item.kind {
                case .assistant(let s): item.kind = .assistant(text: s + text)
                case .thinking(let s): item.kind = .thinking(text: s + text)
                default: break
                }
            }
        case .inputJSONDelta(let index, let partial):
            guard let id = streamBlockItem[key]?[index] else { return }
            update(id, in: key) { item in
                if case .tool(var t) = item.kind { t.partialInput += partial; item.kind = .tool(t) }
            }
        case .blockStop(let index):
            guard let id = streamBlockItem[key]?[index] else { return }
            update(id, in: key) { item in
                if case .tool(var t) = item.kind {
                    if !t.partialInput.isEmpty, let v = try? JSONValue(parsing: t.partialInput) { t.input = v }
                    item.kind = .tool(t)
                } else {
                    item.isStreaming = false
                }
            }
            if let item = list(key).first(where: { $0.id == id }), case .tool(let t) = item.kind, t.kind == .todo {
                setTodos(from: t.input)
            }
        case .messageDelta, .messageStop, .other:
            break
        }
    }

    private mutating func applyAssistant(_ m: ClaudeProtocol.AssistantMessage, key: String) {
        for block in m.content {
            switch block {
            case .text(let s):
                if let id = takeUnconfirmed(key, kindText: true) {
                    update(id, in: key) { $0.kind = .assistant(text: s); $0.isStreaming = false }
                } else if !s.isEmpty {
                    append(ChatItem(id: nextID("text"), kind: .assistant(text: s), date: now()), to: key)
                }
            case .thinking(let s):
                if let id = takeUnconfirmed(key, kindText: false) {
                    update(id, in: key) { $0.kind = .thinking(text: s); $0.isStreaming = false }
                } else if !s.isEmpty {
                    append(ChatItem(id: nextID("thinking"), kind: .thinking(text: s), date: now()), to: key)
                }
            case .toolUse(let id, let name, let input):
                if contains(id, in: key) {
                    update(id, in: key) { item in
                        if case .tool(var t) = item.kind { t.input = input; t.partialInput = ""; item.kind = .tool(t) }
                    }
                    if ToolKind(name: name) == .todo { setTodos(from: input) }
                } else {
                    startTool(id: id, name: name, input: input, key: key, streaming: false)
                }
            default: break
            }
        }
    }

    private mutating func takeUnconfirmed(_ key: String, kindText: Bool) -> String? {
        guard var ids = unconfirmed[key] else { return nil }
        for (n, id) in ids.enumerated() {
            guard let item = list(key).first(where: { $0.id == id }) else { continue }
            let isText: Bool
            switch item.kind {
            case .assistant: isText = true
            case .thinking: isText = false
            default: continue
            }
            if isText == kindText {
                ids.remove(at: n)
                unconfirmed[key] = ids
                return id
            }
        }
        return nil
    }

    private mutating func startTool(id: String, name: String, input: JSONValue, key: String, streaming: Bool) {
        let t = ToolCall(id: id, name: name, input: input, startedAt: now())
        append(ChatItem(id: id, kind: .tool(t), isStreaming: streaming, date: now()), to: key)
        toolLocation[id] = key
        if t.kind == .todo, input["todos"] != nil { setTodos(from: input) }
    }

    private mutating func applyUser(_ m: ClaudeProtocol.UserMessage, key: String) {
        for block in m.content {
            switch block {
            case .toolResult(let toolID, let content, let isError):
                let loc = toolLocation[toolID] ?? key
                let date = now()
                update(toolID, in: loc) { item in
                    if case .tool(var t) = item.kind {
                        t.result = content
                        t.status = isError ? .error : .success
                        t.finishedAt = date
                        item.kind = .tool(t)
                        item.isStreaming = false
                    }
                }
            case .text(let s) where m.isReplay && key.isEmpty:
                append(ChatItem(id: nextID("user"), kind: .user(text: s, imageCount: 0), date: now()), to: key)
            default: break
            }
        }
    }

    private mutating func setTodos(from input: JSONValue) {
        guard let list = input["todos"]?.array else { return }
        todos = list.enumerated().map { i, t in
            TodoItem(id: i, content: t["content"]?.string ?? "",
                     activeForm: t["activeForm"]?.string ?? t["content"]?.string ?? "",
                     status: TodoItem.Status(rawValue: t["status"]?.string ?? "") ?? .pending)
        }
    }

    // MARK: history

    /// Rebuild a conversation from a transcript (.jsonl) written by Claude Code.
    public static func fromTranscript(_ text: String) -> ChatState {
        var s = ChatState()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let v = try? JSONValue(parsing: String(line)) else { continue }
            let type = v["type"]?.string
            guard type == "user" || type == "assistant" else { continue }
            if v["isSidechain"]?.bool == true || v["isMeta"]?.bool == true { continue }
            if let sid = v["sessionId"]?.string { s.sessionID = sid }
            if type == "user" {
                let content = v["message"]?["content"]
                if let text = content?.string {
                    if !TranscriptFilter.isInternal(text) { s.addUserMessage(text) }
                } else if let arr = content?.array {
                    let texts = arr.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                        .filter { !TranscriptFilter.isInternal($0) }
                    let images = arr.filter { $0["type"]?.string == "image" }.count
                    if !texts.isEmpty || images > 0 {
                        s.addUserMessage(texts.joined(separator: "\n"), imageCount: images)
                    }
                    s.apply(ClaudeProtocol.parse(v))
                }
            } else {
                s.apply(ClaudeProtocol.parse(v))
            }
        }
        s.endTurn(interrupted: false)
        return s
    }
}

enum TranscriptFilter {
    /// Local-command and caveat wrappers Claude Code stores as user text.
    static func isInternal(_ s: String) -> Bool {
        s.hasPrefix("<command-") || s.hasPrefix("<local-command") || s.hasPrefix("Caveat:") || s.hasPrefix("<system-reminder>")
    }
}
