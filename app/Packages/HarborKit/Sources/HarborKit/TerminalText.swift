import Foundation

/// Helpers for terminal output (the sign-in flow runs a console program).
public enum TerminalText {
    public static let tokenPattern = #"sk-ant-oat[0-9]{2}-[A-Za-z0-9_\-]{20,}"#
    public static let signInURLPattern = #"https://(claude\.ai|console\.anthropic\.com|platform\.claude\.com)/oauth/authorize[^\s"'\u001b\u0007]*"#

    /// Removes VT escape sequences (CSI, OSC, two-character escapes), CR and other controls.
    public static func stripANSI(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\u{1B}" {
                guard let n = it.next() else { break }
                if n == "[" {
                    while let x = it.next(), !(0x40...0x7E).contains(x.value) {}
                } else if n == "]" {
                    var prev: Unicode.Scalar = " "
                    while let x = it.next() {
                        if x == "\u{07}" || (prev == "\u{1B}" && x == "\\") { break }
                        prev = x
                    }
                }
                continue
            }
            if c == "\r" { continue }
            if c.value < 0x20 && c != "\n" && c != "\t" { continue }
            out.append(c)
        }
        return String(out)
    }

    public static func redact(_ s: String) -> String {
        s.replacingOccurrences(of: #"sk-ant-[A-Za-z0-9_\-]+"#, with: "sk-ant-•••• (hidden)", options: .regularExpression)
    }

    /// A complete token: followed by whitespace, or at the end when `final`.
    public static func token(in plain: String, final: Bool) -> String? {
        let pattern = final ? tokenPattern : tokenPattern + #"(?=\s)"#
        guard let r = plain.range(of: pattern, options: .regularExpression) else { return nil }
        return String(plain[r])
    }

    public static func signInURL(in plain: String) -> URL? {
        guard let r = plain.range(of: signInURLPattern, options: .regularExpression) else { return nil }
        return URL(string: String(plain[r]))
    }

    public static func lastLines(_ s: String, _ n: Int) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var compact: [String] = []
        for l in lines where !(l.isEmpty && compact.last?.isEmpty == true) { compact.append(l) }
        return compact.suffix(n).joined(separator: "\n")
    }
}
