import Cocoa
import Quartz
import ServiceManagement

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
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var iTunesWasPlaying = false
    var aboutBox: AboutBox? = nil
    
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
        if (device.uuid == ble.monitoredUUID) {
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
            monitorMenuItem?.title = t("not_detected")
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
            un.subtitle = t("notification_lost_signal")
        } else if reason == "away" {
            un.subtitle = t("notification_device_away")
        }
        un.informativeText = t("notification_locked")
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
            iTunesWasPlaying = false
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            if let un = userNotification {
                NSUserNotificationCenter.default.removeDeliveredNotification(un)
                userNotification = nil
            }
            if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                print("Waking display")
                wakeDisplay()
            }
            tryUnlockScreen()
        } else {
            if (!isScreenLocked()) {
                pauseItunes()
                if lockScreen() {
                    self.notifyUser(reason)
                } else {
                    print("Failed to lock")
                }
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

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }
    
    func tryUnlockScreen() {
        guard ble.presence else { return }
        guard !systemSleep else { return }
        guard !displaySleep else { return }
        guard isScreenLocked() else { return }
        guard let password = fetchPassword() else { return }

        print("Entering password")
        fakeKeyStrokes(password)
        playItunes()
    }

    @objc func onDisplayWake() {
        print("display wake")
        displaySleep = false
        tryUnlockScreen()
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("system wake")
        systemSleep = false
        tryUnlockScreen()
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        systemSleep = true
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
        monitorMenuItem?.title = t("not_detected")
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
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        
        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
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
    
    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        pauseItunes()
        lockScreen()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            sleepDisplay()
        })
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("scanning"), action: nil, keyEquivalent: "")
        
        let proximityItem = mainMenu.addItem(withTitle: t("proximity_rssi"), action: nil, keyEquivalent: "")
        proximityItem.submenu = proximityMenu
        proximityMenu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -50, to: -100, by: -10) {
            let item = proximityMenu.addItem(withTitle: String(format: "%ddBm", proximity), action: #selector(setProximity), keyEquivalent: "")
            item.tag = proximity
        }
        proximityMenu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        proximityMenu.delegate = self
        
        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("pause_itunes"), action: #selector(togglePauseItunes), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }
        
        mainMenu.addItem(withTitle: t("set_password"), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
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

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        if fetchPassword() == nil {
            askPassword()
        }
        checkAccessibility()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
