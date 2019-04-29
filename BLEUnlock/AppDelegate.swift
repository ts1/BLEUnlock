import Cocoa
import Quartz
import ServiceManagement

var appDelegate: AppDelegate? = nil

@_cdecl("onDisplayWake")
func onDisplayWake() {
    appDelegate?.onWake()
}

@_cdecl("onDisplaySleep")
func onDisplaySleep() {
    appDelegate?.onSleep()
}

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let proximityMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem : NSMenuItem?
    let prefs = UserDefaults.standard
    var sleeping = false
    var connected = false
    var userNotification: NSUserNotification?
    var iTunesWasPlaying = false
    
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
            if (!connected) {
                connected = true
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            monitorMenuItem?.title = t("Not detected")
            if (connected) {
                connected = false
                statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            }
        }
    }

    func notifyUser(_ reason: String) {
        let un = NSUserNotification()
        un.title = "BLEUnlock"
        if reason == "lost" {
            un.subtitle = t("notification_lock_reason_lost_signal")
        } else if reason == "away" {
            un.subtitle = t("notification_lock_reason_device_away")
        }
        un.informativeText = t("notification_title_locked")
        un.deliveryDate = Date().addingTimeInterval(1)
        NSUserNotificationCenter.default.scheduleNotification(un)
        userNotification = un
    }

    func runAppleScript(_ script: String) -> NSAppleEventDescriptor? {
        guard let scriptObject = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let output = scriptObject.executeAndReturnError(&error)
        if let e = error {
            debugPrint(e)
            return nil
        }
        return output
    }

    func isItunesPlaying() -> Bool {
        let result = runAppleScript("tell application \"iTunes\" to return player state")
        return result?.stringValue == "kPSP"
    }
    
    func pauseItunes() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        iTunesWasPlaying = isItunesPlaying()
        if iTunesWasPlaying {
            _ = runAppleScript("tell application \"iTunes\" to pause")
        }
    }
    
    func playItunes() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        if iTunesWasPlaying {
            _ = runAppleScript("tell application \"iTunes\" to play")
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            if let un = userNotification {
                NSUserNotificationCenter.default.removeDeliveredNotification(un)
                userNotification = nil
            }
            if prefs.bool(forKey: "wakeOnProximity") && sleeping {
                print("Waking display")
                wakeDisplay()
            }
            unlockScreen()
        } else {
            pauseItunes()
            if lockScreen() {
                self.notifyUser(reason)
            } else {
                debugPrint("Failed to lock")
            }
        }
    }

    func fakeKeyStrokes(_ string: String) {
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
            print("Pending unlock")
            return
        }
        if let password = fetchPassword() { // Fetch password beforehand, as it may ask for permission in modal
            if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
                if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                    if locked == 1 {
                        print("Entering password")
                        fakeKeyStrokes(password)
                        playItunes()
                    }
                }
            }
        }
    }

    func onWake() {
        print("awake")
        sleeping = false
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false, block: { _ in
            if self.ble.presence {
                self.unlockScreen()
            }
        })
    }
    
    func onSleep() {
        sleeping = true
        print("sleep")
    }
    
    @objc func selectDevice(item: NSMenuItem) {
        for (uuid, menuItem) in deviceDict {
            if menuItem == item {
                monitorDevice(uuid: uuid)
                prefs.set(uuid.uuidString, forKey: "device")
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
        }
    }
    
    func monitorDevice(uuid: UUID) {
        monitorMenuItem?.title = t("Not detected")
        ble.startMonitor(uuid: uuid)
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.runModal()
    }
    
    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecAttrLabel): "BLEUnlock",
            String(kSecValueData): pw,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let err = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to store password to Keychain", info: err as String? ?? "Status \(status)")
            return
        }
    }

    func fetchPassword() -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if (status == errSecItemNotFound) {
            print("Password is not stored")
            return nil
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            errorModal("Failed to convert password")
            return nil
        }
        return String(data: data, encoding: .utf8)!
    }
    
    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: "OK")
        msg.addButton(withTitle: t("Cancel"))
        msg.messageText = t("enter password")
        msg.informativeText = t("password is safe")
        
        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let pw = txt.stringValue
            storePassword(pw)
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "wakeOnProximity")
    }

    @objc func setProximity(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "proximity")
        ble.proximityRSSI = value
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, launchAtLogin)
    }

    @objc func togglePauseItunes(_ menuItem: NSMenuItem) {
        let pauseItunes = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseItunes, forKey: "pauseItunes")
        menuItem.state = pauseItunes ? .on : .off
        if pauseItunes {
            _ = isItunesPlaying() // Show permission dialog
        }
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("Device not set"), action: nil, keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        
        var item: NSMenuItem
        item = mainMenu.addItem(withTitle: t("Device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("Scanning..."), action: nil, keyEquivalent: "")
        
        let proximityItem = mainMenu.addItem(withTitle: t("Proximity RSSI"), action: nil, keyEquivalent: "")
        proximityItem.submenu = proximityMenu
        proximityMenu.addItem(withTitle: t("⬆Closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -50, to: -100, by: -10) {
            let item = proximityMenu.addItem(withTitle: String(format: "%ddBm", proximity), action: #selector(setProximity), keyEquivalent: "")
            item.tag = proximity
        }
        proximityMenu.addItem(withTitle: t("⬇Farther"), action: nil, keyEquivalent: "")
        proximityMenu.delegate = self
        
        item = mainMenu.addItem(withTitle: t("Wake on proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("Pause iTunes while locked"), action: #selector(togglePauseItunes), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }
        
        mainMenu.addItem(withTitle: t("Set password..."), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("Launch at login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("Quit BLEUnlock"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if (!AXIsProcessTrustedWithOptions([key: true] as CFDictionary)) {
            // Sometimes Prompt option above doesn't work.
            // Actually trying to send key may open that dialog.
            let src = CGEventSource(stateID: .hidSystemState)
            // "Fn" key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        ble.delegate = self
        if let str = prefs.string(forKey: "device") {
            if let uuid = UUID(uuidString: str) {
                monitorDevice(uuid: uuid)
            }
        }
        let proximity = prefs.integer(forKey: "proximity")
        if proximity != 0 {
            ble.proximityRSSI = proximity
        }
        appDelegate = self;
        setSleepNotification()
        
        if fetchPassword() == nil {
            askPassword()
        }
        checkAccessibility()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
