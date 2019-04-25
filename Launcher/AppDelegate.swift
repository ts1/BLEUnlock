import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let mainId = Bundle.main.bundleIdentifier!.replacingOccurrences(of: ".Launcher", with: "")
        guard NSRunningApplication.runningApplications(withBundleIdentifier: mainId).isEmpty else {
            NSApp.terminate(nil)
            return
        }
        let path = Bundle.main.bundlePath as NSString
        var components = path.pathComponents
        components.removeLast()
        components.removeLast()
        components.removeLast()
        components.removeLast()
        let mainPath = NSString.path(withComponents: components)
        NSWorkspace.shared.launchApplication(mainPath)
        NSApp.terminate(nil)
    }
}
