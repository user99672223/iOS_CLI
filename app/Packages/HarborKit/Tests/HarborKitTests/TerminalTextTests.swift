import XCTest
@testable import HarborKit

final class TerminalTextTests: XCTestCase {
    func testStripANSI() {
        let s = "\u{1B}[?25l\u{1B}[2J\u{1B}[1;1HBrowser didn't open? Use the url below\r\n\u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07}\u{1B}[0m done"
        XCTAssertEqual(TerminalText.stripANSI(s), "Browser didn't open? Use the url below\nlink done")
    }

    func testURLAndToken() {
        let url = "https://claude.ai/oauth/authorize?code=true&client_id=abc&response_type=code&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&state=xyz"
        let screen = "Use the url below to sign in:\n\n\(url)\n\nPaste code here if prompted >"
        XCTAssertEqual(TerminalText.signInURL(in: screen)?.absoluteString, url)
        let tok = "sk-ant-oat01-" + String(repeating: "Ab3_-", count: 20)
        XCTAssertNil(TerminalText.token(in: "Your token: \(tok.prefix(40))", final: false), "partial token must wait")
        XCTAssertEqual(TerminalText.token(in: "Your token: \(tok)\n", final: false), tok)
        XCTAssertEqual(TerminalText.token(in: "Your token: \(tok)", final: true), tok)
        XCTAssertFalse(TerminalText.redact("x \(tok) y").contains("Ab3_"))
    }

    func testLastLines() {
        XCTAssertEqual(TerminalText.lastLines("a\n\n\n\nb\nc", 2), "b\nc")
    }
}
