import SwiftUI

@main
struct HarborApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if AppDelegate.isSelfTest {
                SelfTestScreen()
            } else {
                RootView()
                    .environmentObject(AppModel.shared)
                    .task { AppModel.shared.launch() }
                    // Back from StikDebug: pick up the attached debugger at once.
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { AppModel.shared.refreshJIT() }
                    }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let isSelfTest = ProcessInfo.processInfo.arguments.contains("--selftest")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        _ = AppPaths.documents; _ = AppPaths.appSupport   // before Wine sets HOME
        if !Self.isSelfTest { AppLog.start() }
        if Self.isSelfTest {
            Task { @MainActor in
                await SelfTest(arguments: args).run()
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--ui-demo"), i + 1 < args.count {
            UIDemo.install(args[i + 1])
        }
        return true
    }
}

struct SelfTestScreen: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Running self-test…").font(.headline)
        }
    }
}

/// Everything the app and Wine print goes to this launch's log file.
enum AppLog {
    static func start() {
        let path = AppPaths.wineLog.path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 { dup2(fd, STDERR_FILENO); close(fd) }
        setvbuf(stderr, nil, _IONBF, 0)
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        line("Harbor \(v) started; host app \(JITEnabler.hostBundleID ?? "?"), pid \(getpid())")
    }

    static func line(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        FileHandle.standardError.write(Data("[\(f.string(from: Date()))] [app] \(s)\n".utf8))
    }
}
