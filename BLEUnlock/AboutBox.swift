import Cocoa

private var aboutBox: AboutBox? = nil

class AboutBox: NSWindowController, NSWindowDelegate {
    @IBOutlet weak var versionLabel: NSTextField!

    @IBAction func visitHomepage(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock#readme")!)
    }

    @IBAction func checkReleases(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
    }
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
