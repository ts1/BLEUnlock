import Cocoa
import Quartz
import LaunchAtLogin

var appDelegate: AppDelegate? = nil

@_cdecl("onDisplayWake")
func onDisplayWake() {
    appDelegate?.onWake()
}

@_cdecl("onDisplaySleep")
func onDisplaySleep() {
    appDelegate?.onSleep()
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let proximityMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem : NSMenuItem? = nil
    let pref = UserDefaults.standard
    var sleeping = false
    let keychainService = "BLEUnlock"
    let keychainAccount = "BLEUnlock"
    
    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.startScanning()
        } else if menu == proximityMenu {
            for item in menu.items {
                if item.tag == ble.proximityRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        }
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.stopScanning()
        }
    }
    
    func menuItemTitle(device: Device) -> String {
        return String(format: "%@ (%ddBm)", device.description, device.rssi)
    }
    
    func newDevice(device: Device) {
        let menuItem = deviceMenu.addItem(withTitle: menuItemTitle(device: device), action:#selector(selectDevice), keyEquivalent: "")
        deviceDict[device.uuid] = menuItem
        if (device.uuid == ble.monitorUUID) {
            menuItem.state = .on
        }
    }
    
    func updateDevice(device: Device) {
        if let menu = deviceDict[device.uuid] {
            menu.title = menuItemTitle(device: device)
        }
    }
    
    func removeDevice(device: Device) {
        if let menuItem = deviceDict[device.uuid] {
            menuItem.menu?.removeItem(menuItem)
        }
        deviceDict.removeValue(forKey: device.uuid)
    }

    func updateRSSI(rssi: Int?) {
        if let r = rssi {
            monitorMenuItem?.title = String(format:"%ddBm", r)
            statusItem.button?.image = NSImage(named: "StatusBarConnected")
        } else {
            monitorMenuItem?.title = NSLocalizedString("Not detected", comment:"")
            statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        }
    }

    func updatePresence(presence: Bool) {
        if presence {
            if pref.bool(forKey: "wakeOnProximity") && sleeping {
                print("Waking display")
                wakeDisplay()
            }
            unlockScreen()
        } else {
            lockScreen()
        }
    }

    func fakeKeyStrokes(string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
        let len = string.count
        let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
        NSString(string:string).getCharacters(buffer)
        pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
        pressEvent?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        
        // Return key
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
    }
    
    func unlockScreen() {
        if sleeping {
            print("pending unlock")
            return
        }
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                if locked == 1 {
                    fakeKeyStrokes(string: fetchPassword());
                }
            }
        }
    }

    func onWake() {
        print("awake")
        sleeping = false
        if ble.presence {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
                self.unlockScreen()
            })
        }
    }
    
    func onSleep() {
        sleeping = true
        print("sleep")
    }
    
    @objc func selectDevice(item: NSMenuItem) {
        for (uuid, menuItem) in deviceDict {
            if menuItem == item {
                monitorDevice(uuid: uuid)
                pref.set(uuid.uuidString, forKey: "device")
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
        }
    }
    
    func monitorDevice(uuid: UUID) {
        monitorMenuItem?.isHidden = false
        ble.startMonitor(uuid: uuid)
        statusItem.button?.image = NSImage(named: "StatusBarConnected")
    }
    
    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): keychainAccount,
            String(kSecAttrService): keychainService,
            String(kSecValueData): pw,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if (status != errSecSuccess) {
            if let err = SecCopyErrorMessageString(status, nil) {
                let alert = NSAlert()
                alert.messageText = String("Failed to store password to KeyChain")
                alert.informativeText = err as String
                alert.runModal()
                return
            }
        }
    }

    func fetchPassword() -> String {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): keychainAccount,
            String(kSecAttrService): keychainService,
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if (status == errSecItemNotFound) {
            print("Password int not stored!")
            return ""
        }
        if (status != errSecSuccess) {
            if let err = SecCopyErrorMessageString(status, nil) {
                let msg = NSAlert()
                msg.messageText = "Failed to retrieve password: \(err)"
                msg.runModal()
            }
            return ""
        }
        if let data = item as? Data {
            print("fetch password success")
            return String(data: data, encoding: .utf8)!
        }
        let msg = NSAlert()
        msg.messageText = "Failed to convert password"
        msg.runModal()
        return ""
    }
    
    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: "OK")
        msg.addButton(withTitle: NSLocalizedString("Cancel", comment:""))
        msg.messageText = NSLocalizedString("enter password", comment:"")
        msg.informativeText = NSLocalizedString("password is safe", comment:"")
        
        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            storePassword(txt.stringValue)
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !pref.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        pref.setValue(value, forKey: "wakeOnProximity")
    }

    @objc func setProximity(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        pref.setValue(value, forKey: "proximity")
        ble.proximityRSSI = value
    }
    
    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        LaunchAtLogin.isEnabled = !LaunchAtLogin.isEnabled
        menuItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: NSLocalizedString("Not detected", comment: ""), action: nil, keyEquivalent: "")
        monitorMenuItem?.isHidden = true
        
        var item: NSMenuItem
        item = mainMenu.addItem(withTitle: NSLocalizedString("Device", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: NSLocalizedString("Scanning...", comment: ""), action: nil, keyEquivalent: "")
        
        let proximityItem = mainMenu.addItem(withTitle: NSLocalizedString("Proximity RSSI", comment: ""), action: nil, keyEquivalent: "")
        proximityItem.submenu = proximityMenu
        proximityMenu.addItem(withTitle: NSLocalizedString("⬆Closer", comment:""), action: nil, keyEquivalent: "")
        for proximity in stride(from: -50, to: -100, by: -10) {
            let item = proximityMenu.addItem(withTitle: String(format: "%ddBm", proximity), action: #selector(setProximity), keyEquivalent: "")
            item.tag = proximity
        }
        proximityMenu.addItem(withTitle: NSLocalizedString("⬇Farther", comment:""), action: nil, keyEquivalent: "")
        proximityMenu.delegate = self
        
        item = mainMenu.addItem(withTitle: NSLocalizedString("Wake on proximity", comment:""), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if pref.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }
        mainMenu.addItem(withTitle: NSLocalizedString("Set password...", comment:""), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: NSLocalizedString("Launch at login", comment:""), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = LaunchAtLogin.isEnabled ? .on : .off

        mainMenu.addItem(withTitle: NSLocalizedString("Quit BLEUnlock", comment:""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        ble.delegate = self
        if let str = pref.string(forKey: "device") {
            if let uuid = UUID(uuidString: str) {
                monitorDevice(uuid: uuid)
            }
        }
        let proximity = pref.integer(forKey: "proximity")
        if proximity != 0 {
            ble.proximityRSSI = proximity
        }
        appDelegate = self;
        setSleepNotification()
        
        if (fetchPassword() == "") {
            askPassword()
        }
        checkAccessibility()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
}
