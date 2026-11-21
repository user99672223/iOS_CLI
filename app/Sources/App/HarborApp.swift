import SwiftUI

@main
struct HarborApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            if AppDelegate.isSelfTest {
                SelfTestScreen()
            } else {
                RootView()
                    .environmentObject(AppModel.shared)
                    .task { AppModel.shared.launch() }
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
