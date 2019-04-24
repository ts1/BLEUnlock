import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let path = Bundle.main.bundlePath as NSString
        var components = path.pathComponents
        components.removeLast()
        components.removeLast()
        components.removeLast()
        components.removeLast()
        let newPath = NSString.path(withComponents: components)
        NSWorkspace.shared.launchApplication(newPath)
        NSApp.terminate(nil)
    }
}
