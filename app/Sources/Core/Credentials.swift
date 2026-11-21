import Foundation
import Security
import os

/// The Claude subscription OAuth token (from `claude setup-token`).
/// Stored in the Keychain; inside LiveContainer the Keychain is redirected to
/// LiveContainer's shared access group, and if Keychain access fails the token
/// falls back to a file in Application Support with complete file protection.
/// The token is never logged or shown.
enum Credentials {
    private static let service = "app.harbor.cli.oauth"
    private static let account = "claude-code"
    private static let log = Logger(subsystem: "cli.app", category: "credentials")
    private static var fallbackURL: URL {
        AppPaths.appSupport.appendingPathComponent("credentials", isDirectory: false)
    }

    /// Where the token is kept: "keychain", "file" or "none".
    static var storage: String {
        if keychainRead() != nil { return "keychain" }
        if fileRead() != nil { return "file" }
        return "none"
    }

    static var token: String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty { return env }
        return keychainRead() ?? fileRead()
    }

    static var isSignedIn: Bool { token != nil }

    @discardableResult
    static func save(_ token: String) -> String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if keychainWrite(t), keychainRead() == t {
            try? FileManager.default.removeItem(at: fallbackURL)
            return "keychain"
        }
        log.error("Keychain unavailable; using the protected file fallback")
        fileWrite(t)
        return "file"
    }

    static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    /// Looks like a Claude OAuth token (format check only).
    static func looksValid(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("sk-ant-") && t.count > 40 && !t.contains(" ")
    }

    // MARK: Keychain

    private static func keychainRead() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func keychainWrite(_ t: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        if st != errSecSuccess { log.error("SecItemAdd failed: \(st)") }
        return st == errSecSuccess
    }

    // MARK: file fallback

    private static func fileRead() -> String? {
        guard let d = try? Data(contentsOf: fallbackURL) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func fileWrite(_ t: String) {
        try? Data(t.utf8).write(to: fallbackURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = fallbackURL
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }
}
