import Foundation
import HarborKit

/// `--ui-demo <screen>`: shows the UI with a canned conversation (no Wine),
/// for the XCUITest screenshot flows. Screens: chat, setup.
@MainActor
enum UIDemo {
    static var active: String?

    static func install(_ screen: String) {
        active = screen
    }

    static func apply(to model: AppModel) -> Bool {
        guard let screen = active else { return false }
        switch screen {
        case "setup":
            model.screen = .setup
        default:
            model.engine.loadDemo(ChatState.fromStream(sampleStream))
            model.screen = .chat
        }
        return true
    }

    static let sampleStream: [String] = [
        ##"{"type":"system","subtype":"init","session_id":"demo","model":"claude-opus-5-5","cwd":"C:\\workspace","tools":[],"claude_code_version":"2.1.330"}"##,
        ##"{"type":"user","isReplay":true,"message":{"role":"user","content":"Create a small Python script that prints the first 10 primes, then run it."}}"##,
        ##"{"type":"assistant","message":{"id":"d1","content":[{"type":"text","text":"I'll set up a plan, write the script, and run it."}]}}"##,
        ##"{"type":"assistant","message":{"id":"d1","content":[{"type":"tool_use","id":"t0","name":"TodoWrite","input":{"todos":[{"content":"Write primes.py","activeForm":"Writing primes.py","status":"completed"},{"content":"Run the script","activeForm":"Running the script","status":"in_progress"},{"content":"Commit the result","activeForm":"Committing the result","status":"pending"}]}}]}}"##,
        ##"{"type":"assistant","message":{"id":"d2","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"C:\\workspace\\primes.py","content":"def primes(n):\n    out, k = [], 2\n    while len(out) < n:\n        if all(k % p for p in out):\n            out.append(k)\n        k += 1\n    return out\n\nprint(primes(10))"}}]}}"##,
        ##"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"File created"}]}}"##,
        ##"{"type":"assistant","message":{"id":"d3","content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"C:\\workspace\\README.md"}}]}}"##,
        ##"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"# Demo"}]}}"##,
        ##"{"type":"assistant","message":{"id":"d4","content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"C:\\workspace\\README.md","old_string":"# Demo","new_string":"# Demo\n\nPrints the first ten primes."}}]}}"##,
        ##"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]}}"##,
        ##"{"type":"assistant","message":{"id":"d5","content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"git add -A && git commit -m \"Add primes script\"","description":"Commit"}}]}}"##,
        ##"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":"[main 3f2a1c9] Add primes script\n 2 files changed, 12 insertions(+)"}]}}"##,
        ##"{"type":"assistant","message":{"id":"d6","content":[{"type":"text","text":"Done. **primes.py** prints:\n\n```\n[2, 3, 5, 7, 11, 13, 17, 19, 23, 29]\n```\n\nThe change is committed on `main`."}]}}"##,
        ##"{"type":"result","subtype":"success","is_error":false,"duration_ms":18400,"num_turns":6,"session_id":"demo","total_cost_usd":0.0412,"usage":{"output_tokens":512}}"##,
    ]
}

extension ChatState {
    static func fromStream(_ lines: [String]) -> ChatState {
        var s = ChatState()
        for l in lines { if let e = ClaudeProtocol.parse(line: l) { s.apply(e) } }
        return s
    }
}
