import XCTest
@testable import HarborKit

final class ChatStateTests: XCTestCase {
    func feed(_ s: inout ChatState, _ lines: [String]) {
        for l in lines { if let e = ClaudeProtocol.parse(line: l) { s.apply(e) } }
    }

    func testLineBuffer() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("{\"a\":1}\n{\"b\"".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(b.append(Data(":2}\r\n\n".utf8)), ["{\"b\":2}", ""])
        XCTAssertNil(b.flush())
    }

    func testUserMessageEncoding() throws {
        let line = ClaudeProtocol.userMessage(text: "hi", images: [.init(mediaType: "image/png", base64: "AAA=")])
        let v = try JSONValue(parsing: line)
        XCTAssertEqual(v["type"]?.string, "user")
        XCTAssertEqual(v["message"]?["role"]?.string, "user")
        XCTAssertEqual(v["message"]?["content"]?[0]?["type"]?.string, "image")
        XCTAssertEqual(v["message"]?["content"]?[1]?["text"]?.string, "hi")
        XCTAssertFalse(line.contains("\n"))
        let ctl = try JSONValue(parsing: ClaudeProtocol.interrupt(id: "r1"))
        XCTAssertEqual(ctl["request"]?["subtype"]?.string, "interrupt")
        XCTAssertEqual(ctl["request_id"]?.string, "r1")
    }

    func testBooleansAndNumbers() throws {
        let v = try JSONValue(parsing: #"{"t":true,"f":false,"n":1,"d":2.5}"#)
        XCTAssertEqual(v["t"], .bool(true))
        XCTAssertEqual(v["f"], .bool(false))
        XCTAssertEqual(v["n"], .number(1))
        XCTAssertEqual(v["d"], .number(2.5))
    }

    func testStreamingTextAndToolRoundTrip() {
        var s = ChatState()
        s.addUserMessage("list files")
        feed(&s, [
            #"{"type":"system","subtype":"init","session_id":"S1","model":"claude-opus-5-5","cwd":"C:\\w","tools":["Bash"],"permissionMode":"bypassPermissions","claude_code_version":"2.1.330"}"#,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"look."}}}"#,
        ])
        XCTAssertEqual(s.sessionID, "S1")
        XCTAssertEqual(s.cliVersion, "2.1.330")
        XCTAssertEqual(s.items.last?.kind, .assistant(text: "Let me look."))
        XCTAssertTrue(s.items.last?.isStreaming ?? false)
        feed(&s, [
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Let me look."}]},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu1","name":"Bash","input":{}}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"ls"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" -la\"}"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":1}}"#,
        ])
        XCTAssertEqual(s.items.count, 3)
        XCTAssertEqual(s.items[1].kind, .assistant(text: "Let me look."))
        XCTAssertFalse(s.items[1].isStreaming)
        guard case .tool(let t) = s.items[2].kind else { return XCTFail("no tool") }
        XCTAssertEqual(t.command, "ls -la")
        XCTAssertEqual(s.runningCommandIDs, ["tu1"])
        s.appendLiveOutput(toolID: "tu1", "a.txt\n")
        feed(&s, [
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls -la"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"a.txt\nb.txt","is_error":false}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"num_turns":2,"result":"done","session_id":"S1","total_cost_usd":0.0123,"usage":{"output_tokens":42}}"#,
        ])
        guard case .tool(let t2) = s.items[2].kind else { return XCTFail("no tool") }
        XCTAssertEqual(t2.status, .success)
        XCTAssertEqual(t2.result, "a.txt\nb.txt")
        XCTAssertEqual(t2.liveOutput, "a.txt\n")
        XCTAssertFalse(s.isTurnRunning)
        guard case .footer(let f) = s.items.last?.kind else { return XCTFail("no footer") }
        XCTAssertEqual(f.durationMS, 1234)
        XCTAssertEqual(f.costUSD, 0.0123)
        XCTAssertEqual(f.outputTokens, 42)
    }

    func testThinkingThenTextConfirmation() {
        var s = ChatState()
        feed(&s, [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m2"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"thinking","thinking":"hmm."}]}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Hi!"}]}}"#,
        ])
        XCTAssertEqual(s.items.map(\.kind), [.thinking(text: "hmm."), .assistant(text: "Hi!")])
    }

    func testNonStreamedAssistant() {
        var s = ChatState()
        feed(&s, [#"{"type":"assistant","message":{"id":"m3","content":[{"type":"text","text":"Plain"}]}}"#])
        XCTAssertEqual(s.items.map(\.kind), [.assistant(text: "Plain")])
    }

    func testSubagentNestingAndTodos() {
        var s = ChatState()
        feed(&s, [
            #"{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"task1","name":"Task","input":{"description":"Explore","prompt":"x"}}]}}"#,
            #"{"type":"assistant","message":{"id":"m5","content":[{"type":"tool_use","id":"g1","name":"Grep","input":{"pattern":"foo"}}]},"parent_tool_use_id":"task1"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g1","content":[{"type":"text","text":"found"}]}]},"parent_tool_use_id":"task1"}"#,
            #"{"type":"assistant","message":{"id":"m6","content":[{"type":"tool_use","id":"td","name":"TodoWrite","input":{"todos":[{"content":"Build","activeForm":"Building","status":"in_progress"},{"content":"Test","activeForm":"Testing","status":"pending"}]}}]}}"#,
        ])
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.children(of: "task1").count, 1)
        guard case .tool(let g) = s.children(of: "task1")[0].kind else { return XCTFail() }
        XCTAssertEqual(g.result, "found")
        XCTAssertEqual(g.status, .success)
        XCTAssertEqual(s.todos.map(\.status), [.inProgress, .pending])
        XCTAssertEqual(s.todos.first?.activeForm, "Building")
    }

    func testInterruptSettlesRunningTools() {
        var s = ChatState()
        s.addUserMessage("go")
        feed(&s, [#"{"type":"assistant","message":{"id":"m7","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"sleep 100"}}]}}"#])
        s.endTurn(interrupted: true)
        guard case .tool(let t) = s.items[1].kind else { return XCTFail() }
        XCTAssertEqual(t.status, .interrupted)
        XCTAssertFalse(s.isTurnRunning)
    }

    func testTranscript() {
        let jsonl = [
            #"{"type":"summary","summary":"x"}"#,
            #"{"type":"user","sessionId":"T1","message":{"role":"user","content":"hello there"}}"#,
            #"{"type":"assistant","sessionId":"T1","message":{"id":"a1","content":[{"type":"text","text":"Hi"},{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"C:\\a.txt"}}]}}"#,
            #"{"type":"user","sessionId":"T1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"r1","content":"text"}]}}"#,
            #"{"type":"user","sessionId":"T1","isMeta":true,"message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
        ].joined(separator: "\n")
        let s = ChatState.fromTranscript(jsonl)
        XCTAssertEqual(s.sessionID, "T1")
        XCTAssertEqual(s.items.count, 3)
        guard case .tool(let t) = s.items[2].kind else { return XCTFail() }
        XCTAssertEqual(t.status, .success)
        XCTAssertEqual(t.filePath, "C:\\a.txt")
    }

    func testUnparsableAndUnknown() {
        XCTAssertEqual(ClaudeProtocol.parse(line: "not json"), .unparsable("not json"))
        if case .other(let type, _) = ClaudeProtocol.parse(line: #"{"type":"rate_limit_event"}"#)! {
            XCTAssertEqual(type, "rate_limit_event")
        } else { XCTFail() }
        XCTAssertNil(ClaudeProtocol.parse(line: "  "))
    }
}
