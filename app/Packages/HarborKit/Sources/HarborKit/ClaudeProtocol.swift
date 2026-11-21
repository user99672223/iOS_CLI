import Foundation

/// Claude Code's headless stream-json protocol
/// (`claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages`).
public enum ClaudeProtocol {

    // MARK: App -> CLI

    public struct ImageAttachment: Sendable, Equatable {
        public var mediaType: String   // image/png, image/jpeg, image/gif, image/webp
        public var base64: String
        public init(mediaType: String, base64: String) { self.mediaType = mediaType; self.base64 = base64 }
    }

    /// One user turn as a JSON line (no trailing newline).
    public static func userMessage(text: String, images: [ImageAttachment] = [], sessionID: String = "") -> String {
        var content: [JSONValue] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": .string($0.mediaType), "data": .string($0.base64)]]
        }
        if !text.isEmpty || content.isEmpty { content.append(["type": "text", "text": .string(text)]) }
        let msg: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": .array(content)],
            "parent_tool_use_id": nil,
            "session_id": .string(sessionID),
        ]
        return msg.serialized()
    }

    public static func controlRequest(id: String, _ request: JSONValue) -> String {
        let msg: JSONValue = ["type": "control_request", "request_id": .string(id), "request": request]
        return msg.serialized()
    }

    public static func initialize(id: String) -> String {
        controlRequest(id: id, ["subtype": "initialize", "hooks": nil])
    }
    public static func interrupt(id: String) -> String {
        controlRequest(id: id, ["subtype": "interrupt"])
    }
    public static func setModel(id: String, model: String?) -> String {
        controlRequest(id: id, ["subtype": "set_model", "model": model.map { JSONValue.string($0) } ?? .null])
    }
    public static func setPermissionMode(id: String, mode: String) -> String {
        controlRequest(id: id, ["subtype": "set_permission_mode", "mode": .string(mode)])
    }

    /// Reply to a control request the CLI sent (e.g. can_use_tool). The app
    /// always runs with bypassPermissions, so tool permission requests are
    /// allowed unchanged should one ever arrive.
    public static func controlResponse(id: String, response: JSONValue) -> String {
        let msg: JSONValue = ["type": "control_response",
                              "response": ["subtype": "success", "request_id": .string(id), "response": response]]
        return msg.serialized()
    }

    /// Command line for the headless CLI.
    public static func arguments(resume: String?, model: String?) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--include-partial-messages", "--permission-mode", "bypassPermissions"]
        if let model, !model.isEmpty { a += ["--model", model] }
        if let resume, !resume.isEmpty { a += ["--resume", resume] }
        return a
    }

    // MARK: CLI -> App

    public enum Event: Equatable, Sendable {
        case systemInit(SystemInit)
        case system(subtype: String, JSONValue)
        case stream(StreamEvent, parentToolUseID: String?)
        case assistant(AssistantMessage, parentToolUseID: String?)
        case user(UserMessage, parentToolUseID: String?)
        case result(TurnResult)
        case controlRequest(id: String, request: JSONValue)
        case controlResponse(id: String, success: Bool, response: JSONValue)
        case other(type: String, JSONValue)
        case unparsable(String)
    }

    public struct SystemInit: Equatable, Sendable {
        public var sessionID: String
        public var model: String
        public var cwd: String
        public var tools: [String]
        public var permissionMode: String
        public var version: String
    }

    public enum ContentBlock: Equatable, Sendable {
        case text(String)
        case thinking(String)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(toolUseID: String, content: String, isError: Bool)
        case image(mediaType: String)
        case other(type: String)
    }

    public struct AssistantMessage: Equatable, Sendable {
        public var id: String
        public var model: String
        public var content: [ContentBlock]
    }

    public struct UserMessage: Equatable, Sendable {
        public var content: [ContentBlock]
        /// For replayed history (`--resume`) a plain user text.
        public var isReplay: Bool
    }

    public enum StreamEvent: Equatable, Sendable {
        case messageStart(id: String)
        case blockStart(index: Int, block: ContentBlock)
        case textDelta(index: Int, text: String)
        case thinkingDelta(index: Int, text: String)
        case inputJSONDelta(index: Int, partial: String)
        case blockStop(index: Int)
        case messageDelta(stopReason: String?)
        case messageStop
        case other(String)
    }

    public struct TurnResult: Equatable, Sendable {
        public var subtype: String
        public var isError: Bool
        public var durationMS: Double
        public var costUSD: Double?
        public var numTurns: Int
        public var sessionID: String
        public var resultText: String?
        public var inputTokens: Int?
        public var outputTokens: Int?
    }

    public static func parse(line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("{"), let v = try? JSONValue(parsing: trimmed) else { return .unparsable(line) }
        return parse(v)
    }

    public static func parse(_ v: JSONValue) -> Event {
        let type = v["type"]?.string ?? ""
        let parent = v["parent_tool_use_id"]?.string
        switch type {
        case "system":
            let subtype = v["subtype"]?.string ?? ""
            if subtype == "init" {
                return .systemInit(SystemInit(
                    sessionID: v["session_id"]?.string ?? "",
                    model: v["model"]?.string ?? "",
                    cwd: v["cwd"]?.string ?? "",
                    tools: v["tools"]?.array?.compactMap(\.string) ?? [],
                    permissionMode: v["permissionMode"]?.string ?? "",
                    version: v["claude_code_version"]?.string ?? ""))
            }
            return .system(subtype: subtype, v)
        case "stream_event":
            return .stream(parseStream(v["event"] ?? .null), parentToolUseID: parent)
        case "assistant":
            let m = v["message"] ?? .null
            return .assistant(AssistantMessage(id: m["id"]?.string ?? "", model: m["model"]?.string ?? "",
                                               content: blocks(m["content"])), parentToolUseID: parent)
        case "user":
            let m = v["message"] ?? .null
            var content = blocks(m["content"])
            if let s = m["content"]?.string { content = [.text(s)] }
            return .user(UserMessage(content: content, isReplay: v["isReplay"]?.bool ?? false), parentToolUseID: parent)
        case "result":
            let usage = v["usage"]
            return .result(TurnResult(
                subtype: v["subtype"]?.string ?? "",
                isError: v["is_error"]?.bool ?? false,
                durationMS: v["duration_ms"]?.double ?? 0,
                costUSD: v["total_cost_usd"]?.double,
                numTurns: v["num_turns"]?.int ?? 0,
                sessionID: v["session_id"]?.string ?? "",
                resultText: v["result"]?.string,
                inputTokens: usage?["input_tokens"]?.int,
                outputTokens: usage?["output_tokens"]?.int))
        case "control_request":
            return .controlRequest(id: v["request_id"]?.string ?? "", request: v["request"] ?? .null)
        case "control_response":
            let r = v["response"] ?? .null
            return .controlResponse(id: r["request_id"]?.string ?? "", success: r["subtype"]?.string == "success",
                                    response: r["response"] ?? r["error"] ?? .null)
        default:
            return .other(type: type, v)
        }
    }

    static func parseStream(_ e: JSONValue) -> StreamEvent {
        let t = e["type"]?.string ?? ""
        let index = e["index"]?.int ?? 0
        switch t {
        case "message_start": return .messageStart(id: e["message"]?["id"]?.string ?? "")
        case "content_block_start": return .blockStart(index: index, block: block(e["content_block"] ?? .null))
        case "content_block_delta":
            let d = e["delta"] ?? .null
            switch d["type"]?.string {
            case "text_delta": return .textDelta(index: index, text: d["text"]?.string ?? "")
            case "thinking_delta": return .thinkingDelta(index: index, text: d["thinking"]?.string ?? "")
            case "input_json_delta": return .inputJSONDelta(index: index, partial: d["partial_json"]?.string ?? "")
            default: return .other("delta:" + (d["type"]?.string ?? ""))
            }
        case "content_block_stop": return .blockStop(index: index)
        case "message_delta": return .messageDelta(stopReason: e["delta"]?["stop_reason"]?.string)
        case "message_stop": return .messageStop
        default: return .other(t)
        }
    }

    static func blocks(_ v: JSONValue?) -> [ContentBlock] {
        v?.array?.map(block) ?? []
    }

    static func block(_ b: JSONValue) -> ContentBlock {
        switch b["type"]?.string ?? "" {
        case "text": return .text(b["text"]?.string ?? "")
        case "thinking": return .thinking(b["thinking"]?.string ?? "")
        case "redacted_thinking": return .thinking("")
        case "tool_use", "server_tool_use":
            return .toolUse(id: b["id"]?.string ?? "", name: b["name"]?.string ?? "", input: b["input"] ?? .object([:]))
        case "tool_result":
            return .toolResult(toolUseID: b["tool_use_id"]?.string ?? "", content: resultText(b["content"]),
                               isError: b["is_error"]?.bool ?? false)
        case "image": return .image(mediaType: b["source"]?["media_type"]?.string ?? "")
        case let other: return .other(type: other)
        }
    }

    /// tool_result content is a string or a list of text/image blocks.
    static func resultText(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        if let s = v.string { return s }
        if let a = v.array {
            return a.compactMap { item -> String? in
                if item["type"]?.string == "text" { return item["text"]?.string }
                if item["type"]?.string == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        }
        return v.serialized()
    }
}
