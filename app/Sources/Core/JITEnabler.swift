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

    /// The bundle ID of the app iOS actually launched. Inside LiveContainer that is
    /// LiveContainer (Bundle.main is Harbor's guest bundle there), and StikDebug must
    /// switch back to it, not to Harbor's own ID, which iOS does not know.
    static var hostBundleID: String? {
        let sel = NSSelectorFromString("lcMainBundle")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let b = (UserDefaults.self as AnyObject).perform(sel)?.takeUnretainedValue() as? Bundle {
            var url = b.bundleURL
            // Multitask mode runs in LiveContainer's LiveProcess.appex: go up to the app.
            if url.pathExtension == "appex" { url = url.deletingLastPathComponent().deletingLastPathComponent() }
            if let id = Bundle(url: url)?.bundleIdentifier ?? b.bundleIdentifier { return id }
        }
        if inLiveContainer {
            // .../LiveContainer.app/... from the real executable path.
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(getpid(), &path, 4096) > 0 {
                var url = URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
                while url.path.count > 1 && url.pathExtension != "app" { url = url.deletingLastPathComponent() }
                if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier { return id }
            }
        }
        return Bundle.main.bundleIdentifier
    }

    /// StikDebug: attach to this process (by PID) and run the JIT script.
    static func stikDebugURL() -> URL? {
        guard let script = scriptData?.base64EncodedString() else { return nil }
        let scheme = UIApplication.shared.canOpenURL(URL(string: "stikdebug://")!) ? "stikdebug" : "stikjit"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        func enc(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v }
        var q = "pid=\(getpid())&script-data=\(enc(script))"
        if let id = hostBundleID { q += "&bundle-id=\(enc(id))" }
        return URL(string: "\(scheme)://enable-jit?\(q)")
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
