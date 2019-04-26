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
    var lockScript: NSAppleScript?
    var unlockScript: NSAppleScript?
    
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
        un.deliveryDate = Date().addingTimeInterval(0.5)
        NSUserNotificationCenter.default.scheduleNotification(un)
        userNotification = un
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
            if lockScreen() {
                self.notifyUser(reason)
            }
        }
    }

    func prepareUnlockScript(_ password: String) {
        let script = """
            activate application "SystemUIServer"
            tell application "System Events"
                tell process "SystemUIServer"
                    keystroke "\(password)"
                    key code 52
                end tell
            end tell
            """
        
        if let scriptObject = NSAppleScript(source: script) {
            var error: NSDictionary?
            scriptObject.compileAndReturnError(&error)
            if let e = error {
                print(e)
            } else {
                unlockScript = scriptObject
            }
        }
    }

    func enterPassword() {
        if let scriptObject = unlockScript {
            var error: NSDictionary?
            scriptObject.executeAndReturnError(&error)
            if let e = error {
                errorModal(t("error_unlock_screen"), info: e.object(forKey: "NSAppleScriptErrorMessage") as? String)
                return
            }
        }
    }
    
    func prepareLockScript() {
        let script = """
            activate application "SystemUIServer"
            tell application "System Events"
                tell process "SystemUIServer" to keystroke "q" using {command down, control down}
            end tell
            """
        if let scriptObject = NSAppleScript(source: script) {
            var error: NSDictionary?
            scriptObject.compileAndReturnError(&error)
            if let e = error {
                print(e)
            } else {
                lockScript = scriptObject
            }
        }
    }

    func lockScreen() -> Bool {
        if let scriptObject = lockScript {
            var error: NSDictionary?
            scriptObject.executeAndReturnError(&error)
            if let e = error {
                errorModal(t("error_lock_screen"), info: e.object(forKey: "NSAppleScriptErrorMessage") as? String)
                return false
            } else {
                return true
            }
        }
        return false
    }

    func unlockScreen() {
        if sleeping {
            print("Pending unlock")
            return
        }
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                if locked == 1 {
                    print("Entering password")
                    enterPassword()
                }
            }
        }
    }

    func onWake() {
        print("awake")
        sleeping = false
        if ble.presence {
            self.unlockScreen()
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
                prefs.set(uuid.uuidString, forKey: "device")
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
        }
    }
    
    func monitorDevice(uuid: UUID) {
        monitorMenuItem?.isHidden = false
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
            prepareUnlockScript(pw)
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
        SMLoginItemSetEnabled("jp.sone.takeshi.BLEUnlock.Launcher" as CFString, launchAtLogin)
    }

    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("Not detected"), action: nil, keyEquivalent: "")
        monitorMenuItem?.isHidden = true
        
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
        mainMenu.addItem(withTitle: t("Set password..."), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("Launch at login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("Quit BLEUnlock"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func askForPermission() {
        // AXIsProcessTrustedWithOptions doesn't work in sandbox.
        // Run some dummy script to let system ask for permission.
        let script = """
            activate application "SystemUIServer"
            tell application "System Events"
                tell process "SystemUIServer" to key code 56 # shift key
            end tell
            """
        if let scriptObject = NSAppleScript(source: script) {
            var error: NSDictionary?
            scriptObject.executeAndReturnError(&error)
            if let e = error {
                print(e)
            }
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
        
        let password = fetchPassword()
        if let pw = password {
            prepareUnlockScript(pw)
        } else {
            askPassword()
        }
        askForPermission()
        prepareLockScript()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
