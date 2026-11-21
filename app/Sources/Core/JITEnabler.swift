import UIKit
import os

/// JIT on a device. Executable memory needs an attached debugger that runs the
/// app's script (madeira-jit.js: BRK #0xf00d protocol, prepares the JIT pool,
/// then detaches). Inside LiveContainer the debugger attaches to
/// LiveContainer's own process, which is ours.
enum JITEnabler {
    enum State: Equatable {
        case simulator
        case ready            // CS_DEBUGGED and a debugger attached: the pool can be made now
        case enabledDetached  // CS_DEBUGGED but nothing attached (JIT enabled without our script)
        case off
    }

    static var state: State {
        #if targetEnvironment(simulator)
        return .simulator
        #else
        var flags: UInt32 = 0
        let debugged = jit_cs_status(&flags) && (flags & 0x1000_0000) != 0
        if !debugged { return .off }
        return cli_debugger_attached() != 0 ? .ready : .enabledDetached
        #endif
    }

    static var scriptData: Data? {
        Bundle.main.url(forResource: "madeira-jit", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
    }

    /// Running inside LiveContainer (the guest's bundle lives in LiveContainer's Documents).
    static var inLiveContainer: Bool {
        Bundle.main.bundlePath.contains("/Documents/Applications/") ||
            ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
    }

    /// StikDebug: attach to this process (by PID) and run the JIT script.
    static func stikDebugURL() -> URL? {
        guard let script = scriptData?.base64EncodedString() else { return nil }
        var c = URLComponents()
        c.scheme = "stikjit"
        c.host = "enable-jit"
        c.queryItems = [URLQueryItem(name: "pid", value: String(getpid())),
                        URLQueryItem(name: "script-data", value: script)]
        if let id = Bundle.main.bundleIdentifier { c.queryItems?.append(URLQueryItem(name: "bundle-id", value: id)) }
        // '+' in base64 must survive form decoding.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    @MainActor
    static func requestFromStikDebug() async -> Bool {
        guard let url = stikDebugURL() else { return false }
        return await UIApplication.shared.open(url)
    }

    /// Wait (polling) until the debugger is attached with CS_DEBUGGED set.
    static func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if state == .ready || state == .simulator { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return state == .ready
    }
}
