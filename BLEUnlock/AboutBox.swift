import Cocoa

private var aboutBox: AboutBox? = nil

class AboutBox: NSWindowController {
    @IBOutlet weak var versionLabel: NSTextField!

    convenience init() {
        self.init(windowNibName: "AboutBox")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        if let info = Bundle.main.infoDictionary {
            if let version = info["CFBundleShortVersionString"] as? String {
                if let build = info["CFBundleVersion"] as? String {
                    versionLabel.stringValue = versionLabel.stringValue.replacingOccurrences(of: "#{version}", with: "\(version) (\(build))")
                }
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
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
