import Cocoa
import Quartz
import ServiceManagement
import os.log

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let unlockRSSIMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem : NSMenuItem?
    let prefs = UserDefaults.standard
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var nowPlayingWasPlaying = false
    var aboutBox: AboutBox? = nil
    var wakeTimer: Timer?
    var manualLock = false
    var unlockedAt = 0.0
    var inScreensaver = false
    var lastRSSI: Int? = nil
    var unlockTimer: Timer?
    var unlockSubmissionAt: TimeInterval?
    var unlockAttemptInProgress = false
    var unlockGeneration: UInt = 0
    var screenStateTimer: Timer?
    var lastScreenLocked: Bool?
    var lastUnlockHandledAt = 0.0
    private let unlockLogger = OSLog(subsystem: "jp.sone.BLEUnlock", category: "Unlock")
    private var lastDiagnosticScreenState: String?
    private var lastDiagnosticSnapshotAt = 0.0

    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.startScanning()
        } else if menu == lockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.lockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == unlockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.unlockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == timeoutMenu {
            for item in menu.items {
                if item.tag == Int(ble.signalTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == lockDelayMenu {
            for item in menu.items {
                if item.tag == Int(ble.proximityTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.menu == lockRSSIMenu {
            return menuItem.tag <= ble.unlockRSSI
        } else if menuItem.menu == unlockRSSIMenu {
            return menuItem.tag >= ble.lockRSSI
        }
        return true
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.stopScanning()
        }
    }
    
    func menuItemTitle(device: Device) -> String {
        var desc : String!
        if let mac = device.macAddr {
            let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
            desc = String(format: "%@ (%@)", device.description, prettifiedMac)
        } else {
            desc = device.description
        }
        return String(format: "%@ (%ddBm)", desc, device.rssi)
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

    func updateRSSI(rssi: Int?, active: Bool) {
        if let r = rssi {
            lastRSSI = r
            monitorMenuItem?.title = String(format:"%ddBm", r) + (active ? " (Active)" : "")
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

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
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

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if notification != userNotification {
            NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        }
    }

    func runScript(_ arg: String) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        if let r = lastRSSI {
            process.arguments = [arg, String(r)]
        } else {
            process.arguments = [arg]
        }
        try? process.run()
    }

    func pauseNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(
            DispatchQueue.main,
            { (playing) in
                self.nowPlayingWasPlaying = playing
                if self.nowPlayingWasPlaying {
                    print("pause")
                    MRMediaRemoteSendCommand(MRCommandPause, nil)
                }
            }
        )
    }
    
    func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        if nowPlayingWasPlaying {
            print("play")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
                MRMediaRemoteSendCommand(MRCommandPlay, nil)
                self.nowPlayingWasPlaying = false
            })
        }
    }

    func lockOrSaveScreen() {
        if prefs.bool(forKey: "screensaver") {
            NSWorkspace.shared.launchApplication("ScreenSaverEngine")
        } else {
            if SACLockScreenImmediate() != 0 {
                print("Failed to lock screen")
            }
            if prefs.bool(forKey: "sleepDisplay") {
                print("sleep display")
                sleepDisplay()
            }
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        let diagnosticReason = ["close", "away", "lost"].contains(reason) ? reason : "other"
        logUnlock("Presence edge: present=\(presence) reason=\(diagnosticReason)")
        if presence {
            if ble.unlockRSSI != ble.UNLOCK_DISABLED {
                if let un = userNotification {
                    NSUserNotificationCenter.default.removeDeliveredNotification(un)
                    userNotification = nil
                }
                if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                    logUnlock("Presence requested display wake")
                    wakeDisplay()
                    wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { _ in
                        print("Retrying waking display")
                        wakeDisplay()
                    })
                }
                tryUnlockScreen(trigger: "presence-\(diagnosticReason)")
            } else {
                logUnlock("Presence did not request unlock: unlock-disabled")
            }
        } else {
            cancelUnlockAttempt(reason: "presence-\(diagnosticReason)")
            if (ScreenLockState.current() == false && ble.lockRSSI != ble.LOCK_DISABLED) {
                pauseNowPlaying()
                lockOrSaveScreen()
                notifyUser(reason)
                runScript(reason)
            }
            manualLock = false
        }
    }

    func logUnlock(_ message: String) {
        os_log("%{public}@", log: unlockLogger, type: .default, message)
    }

    private func lockStateDescription(_ state: Bool?) -> String {
        guard let state = state else { return "unknown" }
        return state ? "locked" : "unlocked"
    }

    private func unlockEligibilityReasons() -> [String] {
        var reasons: [String] = []
        if manualLock { reasons.append("manual-lock") }
        if !ble.presence { reasons.append("presence-absent") }
        if ble.unlockRSSI == ble.UNLOCK_DISABLED { reasons.append("unlock-disabled") }
        if systemSleep { reasons.append("system-asleep") }
        if displaySleep { reasons.append("display-asleep") }
        if prefs.bool(forKey: "wakeWithoutUnlocking") { reasons.append("wake-only") }
        return reasons
    }

    private func logUnlockSnapshot(reason: String) {
        guard prefs.bool(forKey: "unlockDiagnostics") else { return }
        lastDiagnosticSnapshotAt = Date().timeIntervalSince1970
        let trusted = AXIsProcessTrusted()
        let postAccess: Bool
        if #available(macOS 10.15, *) {
            postAccess = CGPreflightPostEventAccess()
        } else {
            postAccess = trusted
        }
        let rssi = lastRSSI.map { String($0) } ?? "unknown"
        let bluetoothState = ble.centralMgr?.state.rawValue ?? -1
        logUnlock("Snapshot reason=\(reason) configured=\(ble.monitoredUUID != nil) " +
            "btState=\(bluetoothState) presence=\(ble.presence) rssi=\(rssi) " +
            "lockRSSI=\(ble.lockRSSI) unlockRSSI=\(ble.unlockRSSI) " +
            "screen=\(lockStateDescription(ScreenLockState.current())) manualLock=\(manualLock) " +
            "systemSleep=\(systemSleep) displaySleep=\(displaySleep) " +
            "wakeOnly=\(prefs.bool(forKey: "wakeWithoutUnlocking")) " +
            "timerPending=\(unlockTimer != nil) submissionPending=\(unlockSubmissionAt != nil) " +
            "attemptInProgress=\(unlockAttemptInProgress) axTrusted=\(trusted) " +
            "postEvents=\(postAccess) inputTargetReady=\(systemUnlockTarget() != nil)")
    }

    func isScreenLocked() -> Bool {
        return ScreenLockState.current() == true
    }

    func cancelUnlockAttempt(reason: String = "unspecified") {
        if unlockTimer != nil || unlockSubmissionAt != nil || unlockAttemptInProgress {
            logUnlock("Cancel attempt: reason=\(reason) timerPending=\(unlockTimer != nil) " +
                "submissionPending=\(unlockSubmissionAt != nil) inProgress=\(unlockAttemptInProgress)")
        }
        unlockGeneration &+= 1
        unlockTimer?.invalidate()
        unlockTimer = nil
        unlockSubmissionAt = nil
    }

    func unlockIsEligible() -> Bool {
        return !manualLock && ble.presence && ble.unlockRSSI != ble.UNLOCK_DISABLED &&
            !systemSleep && !displaySleep && !prefs.bool(forKey: "wakeWithoutUnlocking")
    }

    func systemUnlockTarget() -> SystemUnlockTarget? {
        return SystemUnlockTarget.frontmost(allowPlatformSSO: prefs.bool(forKey: "allowPlatformSSOUnlock"))
    }

    func canSendUnlock(to target: SystemUnlockTarget) -> Bool {
        return unlockIsEligible() && isScreenLocked() &&
            (!target.isPlatformSSO || prefs.bool(forKey: "allowPlatformSSOUnlock")) && target.isCurrent()
    }

    func canPostKeyboardEvents() -> Bool {
        if #available(macOS 10.15, *) { return CGPreflightPostEventAccess() }
        return AXIsProcessTrusted()
    }

    func sendPassword(_ password: String, to target: SystemUnlockTarget) -> Bool {
        do {
            logUnlock("Constructing input events")
            let events = try UnlockKeyboard.events(for: password)
            logUnlock("Input events constructed; starting directed delivery")
            let generation = unlockGeneration
            let delivered = UnlockKeyboard.deliver(events, canContinue: {
                generation == self.unlockGeneration && self.canSendUnlock(to: target)
            }, willSubmit: {
                self.lastScreenLocked = true
                self.unlockSubmissionAt = Date().timeIntervalSince1970
            }, post: { event in
                // Never route credentials through the system-wide foreground event stream.
                event.postToPid(target.processIdentifier)
            })
            if !delivered { logUnlock("Cancelled: lock, proximity, or login window changed") }
            return delivered
        } catch UnlockKeyboard.InputError.emptyPassword {
            logUnlock("Cancelled: stored credential is empty")
            return false
        } catch {
            logUnlock("Cancelled: could not construct keyboard events")
            return false
        }
    }

    func refreshScreenLockState() {
        let observedState = ScreenLockState.current()
        let description = lockStateDescription(observedState)
        if description != lastDiagnosticScreenState {
            logUnlock("Screen state changed: \(lastDiagnosticScreenState ?? "initial") -> \(description)")
            lastDiagnosticScreenState = description
        }
        if prefs.bool(forKey: "unlockDiagnostics"),
           Date().timeIntervalSince1970 - lastDiagnosticSnapshotAt >= 15 {
            logUnlockSnapshot(reason: "periodic")
        }
        guard let locked = observedState else { return }
        let wasLocked = lastScreenLocked
        lastScreenLocked = locked
        if !locked && (wasLocked == true || unlockSubmissionAt != nil) { onUnlock() }
        if let submittedAt = unlockSubmissionAt,
           Date().timeIntervalSince1970 - submittedAt > 10 {
            logUnlock("No unlock confirmation received; password will not be retried automatically")
            unlockSubmissionAt = nil
        }
    }
    
    func tryUnlockScreen(trigger: String = "unspecified", readinessDeadline: TimeInterval? = nil) {
        var blockers = unlockEligibilityReasons()
        if unlockTimer != nil { blockers.append("timer-pending") }
        if unlockSubmissionAt != nil { blockers.append("submission-pending") }
        if unlockAttemptInProgress { blockers.append("attempt-in-progress") }
        logUnlock("Attempt requested: trigger=\(trigger) blockers=\(blockers.isEmpty ? "none" : blockers.joined(separator: ","))")
        guard blockers.isEmpty else { return }

        if readinessDeadline == nil, inScreensaver, isScreenLocked(), canPostKeyboardEvents(),
           let target = systemUnlockTarget() {
            // In screensaver, make sure Login panel is displayed
            let src = CGEventSource(stateID: .hidSystemState)
            // Esc key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.postToPid(target.processIdentifier)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.postToPid(target.processIdentifier)
        }

        let readyBy = readinessDeadline ?? Date().timeIntervalSince1970 + 5
        let generation = unlockGeneration
        logUnlock("Attempt timer scheduled: trigger=\(trigger) generation=\(generation)")
        unlockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            self.unlockTimer = nil
            self.logUnlock("Attempt timer fired: trigger=\(trigger) generation=\(generation)")
            guard !self.unlockAttemptInProgress else {
                self.logUnlock("Cancelled before fetch: attempt-in-progress")
                return
            }
            self.unlockAttemptInProgress = true
            defer { self.unlockAttemptInProgress = false }
            guard generation == self.unlockGeneration else {
                self.logUnlock("Cancelled before fetch: generation-changed")
                return
            }
            let eligibilityReasons = self.unlockEligibilityReasons()
            guard eligibilityReasons.isEmpty else {
                self.logUnlock("Cancelled before fetch: \(eligibilityReasons.joined(separator: ","))")
                return
            }
            let state = ScreenLockState.current()
            guard state == true else {
                self.logUnlock("Skipped: console is not confirmed locked; screen=\(self.lockStateDescription(state))")
                return
            }
            guard self.canPostKeyboardEvents() else {
                self.logUnlock("Skipped: keyboard event permission is missing")
                return
            }
            guard let target = self.systemUnlockTarget() else {
                self.logUnlock("Input target not ready: \(SystemUnlockTarget.diagnostic())")
                if generation == self.unlockGeneration, self.unlockIsEligible(),
                   self.isScreenLocked(), Date().timeIntervalSince1970 < readyBy {
                    // Only wait for a ready UI before reading or submitting any credential.
                    self.unlockAttemptInProgress = false
                    self.tryUnlockScreen(trigger: trigger, readinessDeadline: readyBy)
                } else {
                    self.logUnlock("Skipped: no verified input target became ready within five seconds")
                }
                return
            }
            self.logUnlock("Automatic Keychain fetch starting: allowUI=false")
            guard let password = self.fetchPassword(warn: false, allowUI: false) else {
                self.logUnlock("Cancelled after fetch: no usable stored credential")
                return
            }
            self.logUnlock("Automatic Keychain fetch returned a credential")
            guard generation == self.unlockGeneration else {
                self.logUnlock("Cancelled after fetch: generation-changed")
                return
            }
            let remainingReasons = self.unlockEligibilityReasons()
            guard remainingReasons.isEmpty else {
                self.logUnlock("Cancelled after fetch: \(remainingReasons.joined(separator: ","))")
                return
            }
            guard self.canSendUnlock(to: target) else {
                self.logUnlock("Cancelled after fetch: confirmed lock or verified active login window changed")
                return
            }
            if self.sendPassword(password, to: target) {
                self.logUnlock("Password submitted to verified system UI; awaiting confirmation")
            }
        })
    }

    @objc func onDisplayWake() {
        logUnlock("Display wake observed")
        //unlockedAt = Date().timeIntervalSince1970
        displaySleep = false
        wakeTimer?.invalidate()
        wakeTimer = nil
        tryUnlockScreen(trigger: "display-wake")
    }

    @objc func onDisplaySleep() {
        logUnlock("Display sleep observed")
        displaySleep = true
        cancelUnlockAttempt(reason: "display-sleep")
    }

    @objc func onSystemWake() {
        logUnlock("System wake observed")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            self.logUnlock("System wake delay completed")
            NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
            self.systemSleep = false
            self.tryUnlockScreen(trigger: "system-wake")
        })
    }
    
    @objc func onSystemSleep() {
        logUnlock("System sleep observed")
        systemSleep = true
        cancelUnlockAttempt(reason: "system-sleep")
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
    }

    @objc func onUnlock() {
        let state = ScreenLockState.current()
        guard state == false else {
            logUnlock("Unlock handler skipped: screen=\(lockStateDescription(state))")
            return
        }
        let now = Date().timeIntervalSince1970
        guard now - lastUnlockHandledAt > 1 else { return }
        lastUnlockHandledAt = now
        lastScreenLocked = false
        let submitted = unlockSubmissionAt.map { now - $0 <= 10 } ?? false
        cancelUnlockAttempt(reason: "unlock-observed")
        if submitted {
            unlockedAt = now
            logUnlock("Unlock confirmed")
            playNowPlaying()
            runScript("unlocked")
        } else {
            logUnlock("Unlock observed without a pending submission")
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            print("onUnlock")
            if Date().timeIntervalSince1970 >= self.unlockedAt + 10 {
                if self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED {
                    self.runScript("intruded")
                }
                self.playNowPlaying()
            }
        })
        manualLock = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            checkUpdate()
        })
    }

    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
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
        connected = false
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        monitorMenuItem?.title = t("not_detected")
        ble.startMonitor(uuid: uuid)
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
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

    func fetchPassword(warn: Bool = false, allowUI: Bool = true) -> String? {
        var query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        if !allowUI {
            query[String(kSecUseAuthenticationUI)] = kSecUseAuthenticationUIFail
        }
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        logUnlock("Keychain fetch completed: status=\(status) allowUI=\(allowUI)")
        if (status == errSecItemNotFound) {
            if allowUI && warn {
                errorModal(t("password_not_set"))
            }
            return nil
        }
        guard status == errSecSuccess else {
            if allowUI {
                let info = SecCopyErrorMessageString(status, nil)
                errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            }
            return nil
        }
        guard let data = item as? Data else {
            logUnlock("Keychain fetch cancelled: unexpected result type")
            if allowUI { errorModal("Failed to convert password") }
            return nil
        }
        guard let password = String(data: data, encoding: .utf8) else {
            logUnlock("Keychain fetch cancelled: invalid UTF-8 data")
            if allowUI { errorModal("Failed to convert password") }
            return nil
        }
        return password
    }
    
    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "BLEUnlock"

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
    
    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLEUnlock"
        
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let val = txt.intValue
            ble.thresholdRSSI = Int(val)
            prefs.set(val, forKey: "thresholdRSSI")
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "wakeOnProximity")
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockRSSI")
        ble.lockRSSI = value
    }
    
    @objc func setUnlockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "unlockRSSI")
        ble.unlockRSSI = value
    }

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "timeout")
        ble.signalTimeout = Double(value)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, launchAtLogin)
    }

    @objc func togglePauseNowPlaying(_ menuItem: NSMenuItem) {
        let pauseNowPlaying = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseNowPlaying, forKey: "pauseItunes")
        menuItem.state = pauseNowPlaying ? .on : .off
    }
    
    @objc func toggleUseScreensaver(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "screensaver")
        prefs.set(value, forKey: "screensaver")
        menuItem.state = value ? .on : .off
    }

    @objc func toggleSleepDisplay(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "sleepDisplay")
        prefs.set(value, forKey: "sleepDisplay")
        menuItem.state = value ? .on : .off
    }
    
    @objc func togglePassiveMode(_ menuItem: NSMenuItem) {
        let passiveMode = !prefs.bool(forKey: "passiveMode")
        prefs.set(passiveMode, forKey: "passiveMode")
        menuItem.state = passiveMode ? .on : .off
        ble.setPassiveMode(passiveMode)
    }

    @objc func toggleWakeWithoutUnlocking(_ menuItem: NSMenuItem) {
        let wakeWithoutUnlocking = !prefs.bool(forKey: "wakeWithoutUnlocking")
        prefs.set(wakeWithoutUnlocking, forKey: "wakeWithoutUnlocking")
        menuItem.state = wakeWithoutUnlocking ? .on : .off
    }

    @objc func togglePlatformSSOUnlock(_ menuItem: NSMenuItem) {
        let enabled = !prefs.bool(forKey: "allowPlatformSSOUnlock")
        prefs.set(enabled, forKey: "allowPlatformSSOUnlock")
        menuItem.state = enabled ? .on : .off
        cancelUnlockAttempt(reason: "platform-sso-setting-changed")
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        pauseNowPlaying()
        lockOrSaveScreen()
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }

    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
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

        let unlockRSSIItem = mainMenu.addItem(withTitle: t("unlock_rssi"), action: nil, keyEquivalent: "")
        unlockRSSIItem.submenu = unlockRSSIMenu
        item = unlockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setUnlockRSSI), keyEquivalent: "")
        item.tag = ble.UNLOCK_DISABLED
        constructRSSIMenu(unlockRSSIMenu, #selector(setUnlockRSSI))

        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: "")
        item.tag = ble.LOCK_DISABLED

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("wake_without_unlocking"), action: #selector(toggleWakeWithoutUnlocking), keyEquivalent: "")
        if prefs.bool(forKey: "wakeWithoutUnlocking") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: NSLocalizedString("allow_platform_sso_unlock",
            value: "Use Platform SSO Lock Screen", comment: "Opt in to native Platform SSO Mac unlock"),
            action: #selector(togglePlatformSSOUnlock), keyEquivalent: "")
        item.state = prefs.bool(forKey: "allowPlatformSSOUnlock") ? .on : .off
        item.toolTip = NSLocalizedString("platform_sso_unlock_help",
            value: "Enable only for the native Mac lock screen that accepts your Mac login password.",
            comment: "Scope of the native Platform SSO unlock option")

        item = mainMenu.addItem(withTitle: t("pause_now_playing"), action: #selector(togglePauseNowPlaying), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver), keyEquivalent: "")
        if prefs.bool(forKey: "screensaver") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("sleep_display"), action: #selector(toggleSleepDisplay), keyEquivalent: "")
        if prefs.bool(forKey: "sleepDisplay") {
            item.state = .on
        }
        
        mainMenu.addItem(withTitle: t("set_password"), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off
        
        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        // Platform SSO target validation reads only AX focus roles and ownership.
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if #available(macOS 10.15, *) {
            if !CGPreflightPostEventAccess() {
                // This requests consent without posting a synthetic key.
                // Its immediate result can precede the user's decision.
                let granted = CGRequestPostEventAccess()
                logUnlock("Event-posting permission requested: immediateResult=\(granted)")
            }
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        logUnlock("Startup version=\(version) build=\(build)")
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
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI != 0 {
            ble.lockRSSI = lockRSSI
        }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI")
        if unlockRSSI != 0 {
            ble.unlockRSSI = unlockRSSI
        }
        let timeout = prefs.integer(forKey: "timeout")
        if timeout != 0 {
            ble.signalTimeout = Double(timeout)
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if thresholdRSSI != 0 {
            ble.thresholdRSSI = thresholdRSSI
        }
        let lockDelay = prefs.integer(forKey: "lockDelay")
        if lockDelay != 0 {
            ble.proximityTimeout = Double(lockDelay)
        }

        NSUserNotificationCenter.default.delegate = self

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.sessionagent.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        lastScreenLocked = ScreenLockState.current()
        lastDiagnosticScreenState = lockStateDescription(lastScreenLocked)
        screenStateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { [weak self] _ in
            self?.refreshScreenLockState()
        })
        if let timer = screenStateTimer { RunLoop.main.add(timer, forMode: .common) }

        if ble.unlockRSSI != ble.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && fetchPassword() == nil {
            askPassword()
        }
        checkAccessibility()
        checkUpdate()

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        NSApp.setActivationPolicy(.accessory)
        logUnlockSnapshot(reason: "startup-ready")
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        logUnlock("Application terminating")
        cancelUnlockAttempt(reason: "application-terminate")
        screenStateTimer?.invalidate()
    }
}
