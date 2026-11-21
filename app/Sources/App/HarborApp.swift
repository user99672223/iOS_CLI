import SwiftUI

@main
struct HarborApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--selftest") {
            Task { @MainActor in
                await SelfTest(arguments: args).run()
                // Give the report writer a moment, then end the process for CI.
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(0)
            }
        }
        return true
    }
}

struct RootView: View {
    var body: some View {
        Text("Harbor")
    }
}
