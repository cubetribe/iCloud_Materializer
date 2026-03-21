import AppKit
import SwiftUI

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSessionLog.shared.append(
            level: .info,
            category: "lifecycle",
            message: "Application launched",
            path: Bundle.main.bundlePath
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSessionLog.shared.append(
            level: .warning,
            category: "lifecycle",
            message: "Application will terminate",
            path: Bundle.main.bundlePath
        )
    }
}

@main
struct iCloudMaterializerApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycleDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowResizability(.contentSize)
    }
}
