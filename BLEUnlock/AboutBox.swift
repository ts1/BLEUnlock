import Cocoa

private var aboutBox: AboutBox? = nil

class AboutBox: NSWindowController, NSWindowDelegate {
    @IBOutlet weak var versionLabel: NSTextField!

    convenience init() {
        self.init(windowNibName: "AboutBox")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        if let info = Bundle.main.infoDictionary {
            if let version = info["CFBundleShortVersionString"] as? String {
                versionLabel.stringValue = versionLabel.stringValue.replacingOccurrences(of: "#{version}", with: version)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        aboutBox = nil
    }

    static func showAboutBox() {
        if (aboutBox == nil) {
            aboutBox = AboutBox()
        }
        aboutBox?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutBox?.window?.orderFront(self)
    }
}


