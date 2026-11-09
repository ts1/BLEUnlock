import Cocoa
import CoreGraphics
import ServiceManagement
import UserNotifications
import IOBluetooth

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

private let currentAppBundleIdentifier = "com.github.Skyearn.BLEUnlock"
private let legacyMainBundleIdentifiers = ["jp.sone.BLEUnlock"]
private let lockNotificationID = "com.github.Skyearn.BLEUnlock.lock"
private let updateNotificationID = "com.github.Skyearn.BLEUnlock.update"
private let notificationKindKey = "kind"
private let launcherBundleIDSuffix = ".Launcher"
private let unlockLogicMenuItemKind = "unlockLogic"
private let lockLogicMenuItemKind = "lockLogic"
private let unlockRSSIMenuItemKind = "unlockRSSI"
private let lockRSSIMenuItemKind = "lockRSSI"
private let pauseNowPlayingNoticeShownKey = "pauseNowPlayingNoticeShown"
private let autoCheckUpdatesKey = "autoCheckUpdates"
private let legacyBundleIDMigrationKey = "legacyBundleIDMigrationComplete"

private enum AppNotificationKind: String {
    case lock
    case update
}

enum ManagedMediaApp: String, CaseIterable, Hashable {
    case music
    case quickTimePlayer
    case spotify
    case safari

    var bundleIdentifier: String {
        switch self {
        case .music:
            return "com.apple.Music"
        case .quickTimePlayer:
            return "com.apple.QuickTimePlayerX"
        case .spotify:
            return "com.spotify.client"
        case .safari:
            return "com.apple.Safari"
        }
    }

    var displayName: String {
        switch self {
        case .music:
            return "Music"
        case .quickTimePlayer:
            return "QuickTime Player"
        case .spotify:
            return "Spotify"
        case .safari:
            return "Safari"
        }
    }
}

private func requestNotificationAuthorization() {
    if #available(macOS 10.14, *) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification authorization failed: \(error.localizedDescription)")
                return
            }
            print("Notification authorization granted: \(granted)")
        }
    }
}

private func removeDeliveredNotification(identifier: String) {
    if #available(macOS 10.14, *) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    } else if let appDelegate = NSApp.delegate as? AppDelegate, let notification = appDelegate.userNotification {
        NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        appDelegate.userNotification = nil
    }
}

private func enqueueNotification(identifier: String,
                                 kind: AppNotificationKind,
                                 title: String,
                                 subtitle: String? = nil,
                                 informativeText: String? = nil,
                                 after delay: TimeInterval? = nil,
                                 sound: Bool = true)
{
    if #available(macOS 10.14, *) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle {
            content.subtitle = subtitle
        }
        if let informativeText = informativeText {
            content.body = informativeText
        }
        if sound {
            content.sound = .default
        }
        content.userInfo = [notificationKindKey: kind.rawValue]

        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification \(identifier): \(error.localizedDescription)")
            }
        }
    } else {
        let notification = NSUserNotification()
        notification.title = title
        notification.subtitle = subtitle
        notification.informativeText = informativeText
        if sound {
            notification.soundName = NSUserNotificationDefaultSoundName
        }
        if let delay = delay {
            notification.deliveryDate = Date().addingTimeInterval(delay)
        }
        NSUserNotificationCenter.default.deliver(notification)
        if kind == .lock, let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.userNotification = notification
        }
    }
}

func notifyUpdateAvailable() {
    if #available(macOS 10.14, *) {
        enqueueNotification(identifier: updateNotificationID,
                            kind: .update,
                            title: "BLEUnlock",
                            subtitle: t("notification_update_available"),
                            sound: false)
    } else {
        let notification = NSUserNotification()
        notification.title = "BLEUnlock"
        notification.subtitle = t("notification_update_available")
        NSUserNotificationCenter.default.deliver(notification)
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSUserNotificationCenterDelegate, UNUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    var deviceMenu = NSMenu()
    let unlockSettingsMenu = NSMenu()
    let lockSettingsMenu = NSMenu()
    let wakeSettingsMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    let updateMenu = NSMenu()
    var updateMenuItem: NSMenuItem?
    var checkForUpdatesMenuItem: NSMenuItem?
    var automaticUpdateChecksMenuItem: NSMenuItem?
    var deviceDict: [UUID: NSMenuItem] = [:]
    var deviceInsertionOrder: [UUID] = []
struct DeviceMenuItemView {
    let checkbox: NSButton
    let label: NSTextField
}

    var deviceCheckboxDict: [UUID: DeviceMenuItemView] = [:]
    var monitorMenuItem : NSMenuItem?
    var lockNowMenuItem: NSMenuItem?
    var deviceMenuItem: NSMenuItem?
    var wakeOnProximityMenuItem: NSMenuItem?
    var wakeWithoutUnlockingMenuItem: NSMenuItem?
    var triggerWatchUnlockMenuItem: NSMenuItem?
    /// Serial queue for ServiceManagement XPC calls to avoid concurrent smd requests.
    let smdQueue = DispatchQueue(label: "com.github.Skyearn.BLEUnlock.smd")
    let prefs = UserDefaults.standard
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var userNotificationID: String?
    var pausedMediaApps: Set<ManagedMediaApp> = []
    let pausedMediaAppsLock = NSLock()
    var aboutBox: AboutBox? = nil
    var manualLock = false
    var unlockedAt = 0.0
    var inScreensaver = false
    var lastRSSI: Int? = nil
    var pendingUnlockDevice: UUID?
    var pendingUnlockDeviceRSSI: Int?
    var pendingLockDevice: UUID?
    var pendingLockDeviceRSSI: Int?
    var mainMenuIsOpen = false
    var deviceMenuIsOpen = false
    var deviceMenuNeedsRefresh = false
    var deviceMenuShowDetails = false
    var flagsEventMonitor: Any?
    var deviceMaxTitleWidth: [UUID: CGFloat] = [:]
    var automationPermissionPromptedApps: Set<ManagedMediaApp> = []
    let mediaControlQueue = DispatchQueue(label: "com.github.Skyearn.BLEUnlock.media-control", qos: .userInitiated)
    var systemWakeTimer: Timer?
    var wakeUnlockTimer: Timer?
    var postUnlockRetryTimer: Timer?
    var permissionRecoveryTimer: Timer?
    var automaticLockTimer: Timer?
    var lastWakeAt = 0.0
    var lastDisplayWakeRequestAt = 0.0
    var lastSystemSleepStartedAt = 0.0
    var lastScreensaverStartedAt = 0.0
    let minimumWakeRequestInterval = 15.0
    let conservativeWakeSleepThreshold = 60.0
    let conservativeWakeUnlockDelay = 1.5
    let screensaverEscapeRetryDelay = 0.35
    let wakeUnlockRetryDelay = 0.5
    let wakeUnlockMaxRetries = 8
    let watchUnlockMaxAttempts = 3
    let watchUnlockRetryDelay = 1.0
    let watchUnlockSessionWindow = 10.0
    var watchUnlockAttempts = 0
    var lastWatchUnlockTriggerAt = 0.0

    func menuWillOpen(_ menu: NSMenu) {
        if menu == mainMenu {
            mainMenuIsOpen = true
            updateMonitorStatusItems()
            wakeOnProximityMenuItem?.state = prefs.bool(forKey: "wakeOnProximity") ? .on : .off
        } else if menu == wakeSettingsMenu {
            wakeWithoutUnlockingMenuItem?.state = prefs.bool(forKey: "wakeWithoutUnlocking") ? .on : .off
            triggerWatchUnlockMenuItem?.state = prefs.bool(forKey: "triggerWatchUnlock") ? .on : .off
        } else if menu == deviceMenu {
            deviceMenuIsOpen = false
            addMissingDeviceRows()
            refreshDeviceMenuSelectionStates(removeStale: false)
            deviceMenuNeedsRefresh = false
            ensureGroupSeparatorExists()
            performDeviceMenuReorder()
            deviceMenuIsOpen = true
            // Option-key toggle: check initial state before starting scan
            let initialOption = NSEvent.modifierFlags.contains(.option)
            setDeviceMenuShowDetails(initialOption)
            flagsEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self = self, self.deviceMenuIsOpen else { return event }
                let newState = event.modifierFlags.contains(.option)
                self.setDeviceMenuShowDetails(newState)
                return event
            }
            ble.startScanning()
        } else if menu == unlockSettingsMenu {
            updateSettingsMenu(menu,
                               logicKind: unlockLogicMenuItemKind,
                               selectedLogic: ble.unlockDeviceLogic.rawValue,
                               rssiKind: unlockRSSIMenuItemKind,
                               selectedRSSI: ble.unlockRSSI)
        } else if menu == lockSettingsMenu {
            updateSettingsMenu(menu,
                               logicKind: lockLogicMenuItemKind,
                               selectedLogic: ble.lockDeviceLogic.rawValue,
                               rssiKind: lockRSSIMenuItemKind,
                               selectedRSSI: ble.lockRSSI)
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

    func deviceListAttributedTitle() -> NSAttributedString {
        let title = t("device") + "\t⌥"
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 185)]
        let attr = NSMutableAttributedString(string: title, attributes: [
            .paragraphStyle: para,
            .font: NSFont.menuFont(ofSize: 0)
        ])
        let optRange = (title as NSString).range(of: "⌥")
        attr.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: optRange)
        return attr
    }

    @objc func openBluetoothSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
        NSWorkspace.shared.open(url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTriggerWatchUnlock) {
            return prefs.bool(forKey: "wakeWithoutUnlocking")
        }
        if let kind = menuItem.representedObject as? String {
            if kind == unlockLogicMenuItemKind || kind == lockLogicMenuItemKind {
                return ble.monitoredUUIDs.count > 1
            }
            if kind == lockRSSIMenuItemKind {
                return menuItem.tag <= ble.unlockRSSI
            }
            if kind == unlockRSSIMenuItemKind {
                return menuItem.tag >= ble.lockRSSI
            }
        }
        return true
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == mainMenu {
            mainMenuIsOpen = false
        } else if menu == deviceMenu {
            deviceMenuIsOpen = false
            ble.stopScanning()
            refreshDeviceMenuSelectionStates(removeStale: true)
            performDeviceMenuReorder()
            if let monitor = flagsEventMonitor {
                NSEvent.removeMonitor(monitor)
                flagsEventMonitor = nil
            }
            let wasShowingDetails = deviceMenuShowDetails
            deviceMaxTitleWidth.removeAll()
            setDeviceMenuShowDetails(false, forceRefresh: true)
            if wasShowingDetails {
                replaceDeviceMenuInstancePreservingItems()
            }
        }
    }
    
    func menuItemTitle(device: Device, showDetails: Bool = false) -> String {
        let name = device.currentResolvedName()
        let hasName = name != nil
        let uuidStr = device.uuid.uuidString
        let segments = uuidStr.split(separator: "-")
        let collapsed = String(segments.first ?? "") + "…" + String(segments.last ?? "")

        var desc : String!
        if showDetails {
            if let mac = device.macAddr {
                let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
                desc = String(format: "%@ (%@) (%@)", device.description, prettifiedMac, uuidStr)
            } else {
                if hasName {
                    desc = String(format: "%@ (%@)", device.description, uuidStr)
                } else {
                    desc = uuidStr
                }
            }
        } else {
            if hasName {
                desc = device.description
            } else {
                desc = collapsed
            }
        }
        if let rssi = displayedRSSI(for: device.uuid) {
            return menuItemTitle(title: desc, rssi: rssi)
        }
        return menuItemTitleNotDetected(title: desc)
    }

    func menuItemTitleNotDetected(title: String) -> String {
        "\(title) (\(t("not_detected")))"
    }

    func menuItemTitleNotDetected(device: Device) -> String {
        menuItemTitleNotDetected(title: device.description)
    }

    func menuItemTitle(title: String, rssi: Int) -> String {
        String(format: "%@ (%ddBm)", title, rssi)
    }

    func ensurePairHintInDeviceMenu() {
        // Check if hint already exists at index 0
        if deviceMenu.numberOfItems > 0, deviceMenu.item(at: 0)?.tag == 999 {
            return
        }
        // Remove old hint if present elsewhere
        for i in stride(from: deviceMenu.numberOfItems - 1, through: 0, by: -1) {
            if deviceMenu.item(at: i)?.tag == 999 {
                deviceMenu.removeItem(at: i)
            }
        }
        // Insert hint at top, before everything — click to open Bluetooth settings
        let hint = NSMenuItem(title: t("pair_for_mac_hint"), action: #selector(openBluetoothSettings), keyEquivalent: "")
        hint.target = self
        hint.tag = 999
        hint.attributedTitle = NSAttributedString(
            string: t("pair_for_mac_hint"),
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        deviceMenu.insertItem(hint, at: 0)
        deviceMenu.insertItem(NSMenuItem.separator(), at: 1)
    }

    /// Resolve MAC addresses for monitored devices at startup.
    /// First restores MACs persisted from the previous session, then falls back to
    /// IOBluetooth for any remaining devices that have a known name.
    /// Persisted MACs are critical for re‑identifying devices whose BLE UUID rotates
    /// while BLEUnlock was not running.
    func resolveMonitoredMACsOnStartup(uuids: Set<UUID>) {
        // ── 1. Restore persisted MAC→UUID mappings from UserDefaults ──
        let savedMACToUUID = loadPersistedMACs()
        let persistedCount = savedMACToUUID.count
        let monitoredUUIDStrings = Set(uuids.map { $0.uuidString })
        macInheritLog("resolveMonitoredMACsOnStartup: persistedCount=\(persistedCount) monitoredCount=\(uuids.count)")
        for (mac, uuidStr) in savedMACToUUID {
            macInheritLog("persisted: mac=\(mac) -> uuid=\(uuidStr)")
            guard let uuid = UUID(uuidString: uuidStr) else {
                macInheritLog("  SKIP: invalid UUID string")
                continue
            }
            if uuids.contains(uuid) {
                macInheritLog("  MATCH: uuid=\(uuidStr) is monitored, setting mac=\(mac)")
                if ble.devices[uuid] == nil {
                    let device = Device(uuid: uuid)
                    device.macAddr = mac
                    ble.devices[uuid] = device
                } else {
                    macInheritLog("  device already exists in ble.devices")
                }
            } else {
                macInheritLog("  NO-MATCH: uuid=\(uuidStr) NOT in monitored set (monitored: \(monitoredUUIDStrings.sorted().joined(separator: ", ")))")
            }
        }
        // ── 3. Ensure all monitored UUIDs have entries in ble.devices ──
        // Without an entry, findKnownDeviceByMAC cannot correlate a newly
        // discovered peripheral against a monitored device whose BLE UUID
        // has rotated since the last session.
        for uuid in uuids where ble.devices[uuid] == nil {
            let device = Device(uuid: uuid)
            if let info = getLEDeviceInfoFromUUID(uuid.uuidString) {
                device.macAddr = info.macAddr
                macInheritLog("LE-db: uuid=\(uuid.uuidString) -> mac=\(info.macAddr ?? "nil")")
            } else {
                macInheritLog("LE-db: uuid=\(uuid.uuidString) -> NO MATCH in LE database, checking persistence...")
                // Fallback: check if any persisted MAC maps to a DIFFERENT UUID — 
                // this means the UUID rotated since last persist. Inject the MAC.
                for (mac, savedUUID) in savedMACToUUID {
                    if !uuids.contains(UUID(uuidString: savedUUID) ?? UUID()) {
                        macInheritLog("  INJECT orphan MAC=\(mac) (was \(savedUUID)) into \(uuid.uuidString)")
                        device.macAddr = mac
                        break
                    }
                }
            }
            ble.devices[uuid] = device
            if device.macAddr == nil {
                macInheritLog("  WARNING: uuid=\(uuid.uuidString) has NO macAddr after all lookups")
            }
        }
    }


    /// Replace old UUID with new UUID in insertion order, preserving position.
    func replaceUUIDInInsertionOrder(old: UUID, new: UUID) {
        if let idx = deviceInsertionOrder.firstIndex(of: old) {
            deviceInsertionOrder[idx] = new
        } else if !deviceInsertionOrder.contains(new) {
            deviceInsertionOrder.append(new)
        }
    }

    func scheduleDeviceMenuReorder() {
        // NOTE: A closed menu is not reordered here. menuWillOpen rebuilds it before it is shown, and with duplicate-reporting scans this is called for every advertisement.
        // During menu tracking only separator visibility is updated, so that it stays in sync as devices appear.
        guard deviceMenuIsOpen else { return }
        updateGroupSeparatorVisibility()
    }

    // MARK: - Device menu ordering

    /// Ensure the group separator and scanning indicator menu items exist.
    /// Safe to call before menu tracking starts (e.g. during menuWillOpen).
    func ensureGroupSeparatorExists() {
        if groupSeparatorItem == nil {
            groupSeparatorItem = NSMenuItem.separator()
        }
        if scanningMenuItem == nil {
            let si = NSMenuItem(title: t("scanning"), action: nil, keyEquivalent: "")
            si.isEnabled = false
            scanningMenuItem = si
        }
    }

    /// Persistent separator between monitored and unmonitored device groups.
    /// Always present in the menu; visibility is toggled via isHidden instead of add/remove
    /// so that it can be updated during NSMenuTrackingSession without crashing.
    var groupSeparatorItem: NSMenuItem?
    /// The "Scanning…" item, placed right after the group separator as a header
    /// for the unmonitored section.
    var scanningMenuItem: NSMenuItem?

    /// Full rebuild of the device menu: monitored first, inter-group separator, then unmonitored.
    /// The separator item itself is persistent — it is never removed, only hidden/shown.
    /// During menu tracking only the separator visibility is updated to avoid NSMenu corruption.
    /// Layout: hint(0) + fixed-sep(1) + monitored devices + group-sep + "Scanning…" + unmonitored devices.
    /// Uses a diff-based approach: only removes stale items and inserts missing ones,
    /// avoiding the wholesale remove+rebuild that can crash NSMenu internals.
    func performDeviceMenuReorder() {
        guard !deviceMenuIsOpen else {
            updateGroupSeparatorVisibility()
            return
        }
        let monitoredSet = ble.monitoredUUIDs
        let orderedUUIDs = deviceInsertionOrder.filter { deviceDict[$0] != nil }
        let snapshot = orderedUUIDs.compactMap { uuid -> (UUID, NSMenuItem)? in
            guard let item = deviceDict[uuid] else { return nil }
            return (uuid, item)
        }
        // Monitored sorted by stable key (MAC > UUID) to prevent reordering as names resolve
        let monitoredFirst = snapshot
            .filter { monitoredSet.contains($0.0) }
            .sorted {
                let keyA = ble.devices[$0.0]?.macAddr ?? $0.0.uuidString
                let keyB = ble.devices[$1.0]?.macAddr ?? $1.0.uuidString
                return keyA.localizedStandardCompare(keyB) == .orderedAscending
            }
        let unmonitoredAfter = snapshot.filter { !monitoredSet.contains($0.0) }
        let wantsSeparator = !monitoredFirst.isEmpty && !unmonitoredAfter.isEmpty

        // Build desired items list (flat)
        var desired: [NSMenuItem] = []
        for (_, item) in monitoredFirst { desired.append(item) }
        if groupSeparatorItem == nil { groupSeparatorItem = NSMenuItem.separator() }
        desired.append(groupSeparatorItem!)
        if scanningMenuItem == nil {
            let si = NSMenuItem(title: t("scanning"), action: nil, keyEquivalent: "")
            si.isEnabled = false
            scanningMenuItem = si
        }
        desired.append(scanningMenuItem!)
        for (_, item) in unmonitoredAfter { desired.append(item) }

        // Full rebuild: remove all items from index 2 (hint=0, fixed-sep=1)
        // and re-add in desired order. Safe because performDeviceMenuReorder
        // only runs when the menu is not being tracked.
        let devStart = 2
        while deviceMenu.numberOfItems > devStart {
            deviceMenu.removeItem(at: devStart)
        }
        for item in desired {
            deviceMenu.addItem(item)
        }

        // Sync visibility
        groupSeparatorItem?.isHidden = !wantsSeparator
        scanningMenuItem?.isHidden = unmonitoredAfter.isEmpty
    }

    /// Toggle the persistent group separator and scanning item visibility.
    /// Safe to call during NSMenuTrackingSession (only isHidden is touched).
    func updateGroupSeparatorVisibility() {
        let monitoredSet = ble.monitoredUUIDs
        let orderedUUIDs = deviceInsertionOrder.filter { deviceDict[$0] != nil }
        let hasMonitored = orderedUUIDs.contains(where: { monitoredSet.contains($0) })
        let hasUnmonitored = orderedUUIDs.contains(where: { !monitoredSet.contains($0) })
        let shouldShow = hasMonitored && hasUnmonitored
        groupSeparatorItem?.isHidden = !shouldShow
        scanningMenuItem?.isHidden = !hasUnmonitored
    }

    /// Move a single device between groups and update the inter-group separator visibility.
    /// During menu tracking only the moved item and the separator's isHidden are touched —
    /// no menu structure changes that would corrupt NSMenuTrackingSession.
    func moveDeviceInMenu(uuid: UUID, nowMonitored: Bool) {
        guard let menuItem = deviceDict[uuid] else { return }
        guard menuItem.menu == deviceMenu else { return }
        let monitoredSet = ble.monitoredUUIDs

        // ── 1. Find current position of item and separator ──
        let oldIdx = deviceMenu.index(of: menuItem)
        var sepIdx: Int?
        for i in 2..<deviceMenu.numberOfItems {
            if let item = deviceMenu.item(at: i), item === groupSeparatorItem { sepIdx = i; break }
        }

        // ── 2. Remove item from its current position ──
        deviceMenu.removeItem(menuItem)
        // Adjust separator index if item was before it
        var adjSepIdx = sepIdx
        if let si = sepIdx, oldIdx < si { adjSepIdx = si - 1 }

        // ── 3. Compute insert position ──
        let insertIdx: Int
        if let si = adjSepIdx {
            if nowMonitored {
                insertIdx = si
            } else {
                // Insert after the scanning item (right after separator)
                let scanIdx = scanningMenuItem.flatMap { deviceMenu.index(of: $0) } ?? (si + 1)
                insertIdx = scanIdx + 1
            }
        } else {
            // Separator exists but was hidden — count visible monitored items
            var monitoredCount = 0
            for i in 3..<deviceMenu.numberOfItems {
                if let item = deviceMenu.item(at: i), !item.isSeparatorItem,
                   let itemUUID = uuidForMenuItem(item), monitoredSet.contains(itemUUID) {
                    monitoredCount += 1
                }
            }
            insertIdx = 3 + monitoredCount
        }
        deviceMenu.insertItem(menuItem, at: min(insertIdx, deviceMenu.numberOfItems))

        // ── 4. Toggle separator visibility ──
        let orderedUUIDs = deviceInsertionOrder.filter { deviceDict[$0] != nil }
        let hasMonitored = orderedUUIDs.contains(where: { monitoredSet.contains($0) })
        let hasUnmonitored = orderedUUIDs.contains(where: { !monitoredSet.contains($0) })
        groupSeparatorItem?.isHidden = !(hasMonitored && hasUnmonitored)
        scanningMenuItem?.isHidden = !hasUnmonitored
    }

    /// Reverse lookup: find the UUID for a menu item currently in the device menu.
    private func uuidForMenuItem(_ item: NSMenuItem) -> UUID? {
        for (uuid, candidate) in deviceDict where candidate === item { return uuid }
        return nil
    }

    func displayedRSSI(for uuid: UUID) -> Int? {
        if let monitoredRSSI = ble.monitoredStates[uuid]?.lastRSSI, monitoredRSSI < 0 {
            return monitoredRSSI
        }
        if let device = ble.devices[uuid], device.isVisible {
            return device.rssi < 0 ? device.rssi : nil
        }
        return nil
    }

    func configuredDeviceCheckbox(uuid: UUID) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleDeviceCheckbox(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(uuid.uuidString)
        checkbox.state = ble.isMonitoring(uuid: uuid) ? .on : .off
        checkbox.font = NSFont.menuFont(ofSize: 0)
        checkbox.alignment = .left
        return checkbox
    }

    func menuItemWidth(for title: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        return (title as NSString).size(withAttributes: attrs).width
    }
    func labelColorForDevice(uuid: UUID) -> NSColor {
        let resolved = ble.devices[uuid]?.macAddr != nil
        guard !resolved else { return NSColor.controlTextColor }
        // disabledControlTextColor renders near-invisible in dark mode on macOS < 26
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        if osVer.majorVersion >= 26 {
            return NSColor.disabledControlTextColor
        }
        if #available(macOS 10.14, *) {
            return NSColor.secondaryLabelColor
        }
        return NSColor.disabledControlTextColor
    }


    func configuredDeviceLabel(title: String, uuid: UUID) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = labelColorForDevice(uuid: uuid)
        label.identifier = NSUserInterfaceItemIdentifier("label-" + uuid.uuidString)
        return label
    }

    func configureDeviceMenuView(_ menuItem: NSMenuItem, uuid: UUID, title: String) -> DeviceMenuItemView {
        let checkbox = configuredDeviceCheckbox(uuid: uuid)
        let label = configuredDeviceLabel(title: title, uuid: uuid)
        let checkboxFit = checkbox.fittingSize
        let labelFit = label.fittingSize
        let totalWidth = checkboxFit.width + labelFit.width + 8
        let height = max(24, max(checkboxFit.height, labelFit.height) + 4)
        let currentWidth = max(300, totalWidth + 28)
        let width = deviceMaxTitleWidth[uuid] ?? currentWidth
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        checkbox.frame = NSRect(x: 14, y: (height - checkboxFit.height) / 2, width: checkboxFit.width, height: checkboxFit.height)
        label.frame = NSRect(x: 14 + checkboxFit.width + 4, y: (height - labelFit.height) / 2, width: labelFit.width, height: labelFit.height)
        container.addSubview(checkbox)
        container.addSubview(label)
        menuItem.view = container
        return DeviceMenuItemView(checkbox: checkbox, label: label)
    }

    func updateDeviceCheckbox(_ view: DeviceMenuItemView, uuid: UUID, title: String) {
        view.checkbox.identifier = NSUserInterfaceItemIdentifier(uuid.uuidString)
        view.checkbox.state = ble.isMonitoring(uuid: uuid) ? .on : .off
        view.label.stringValue = title
        view.label.textColor = labelColorForDevice(uuid: uuid)
        view.label.sizeToFit()
        let checkboxFit = view.checkbox.fittingSize
        let labelFit = view.label.fittingSize
        let totalWidth = checkboxFit.width + labelFit.width + 8
        if let container = view.checkbox.superview {
            let height = max(24, max(checkboxFit.height, labelFit.height) + 4)
            let currentWidth = max(300, totalWidth + 28)
            if let cached = deviceMaxTitleWidth[uuid] {
                deviceMaxTitleWidth[uuid] = max(cached, currentWidth)
            } else {
                deviceMaxTitleWidth[uuid] = currentWidth
            }
            let width = deviceMaxTitleWidth[uuid]!
            container.frame.size = NSSize(width: width, height: height)
            view.checkbox.frame = NSRect(x: 14, y: (height - checkboxFit.height) / 2, width: checkboxFit.width, height: checkboxFit.height)
            view.label.frame = NSRect(x: 14 + checkboxFit.width + 4, y: (height - labelFit.height) / 2, width: labelFit.width, height: labelFit.height)
        }
    }

    func ensureMonitoredDeviceMenuItems() {
        let orderedUUIDs = ble.monitoredUUIDs.sorted {
            monitoredDeviceTitle(uuid: $0).localizedStandardCompare(monitoredDeviceTitle(uuid: $1)) == .orderedAscending
        }
        for uuid in orderedUUIDs where deviceDict[uuid] == nil {
            let menuItem = addDeviceMenuItem(title: "", uuid: uuid)
            let view = configureDeviceMenuView(menuItem,
                                                   uuid: uuid,
                                                   title: menuItemTitleNotDetected(title: monitoredDeviceTitle(uuid: uuid)))
            deviceDict[uuid] = menuItem
            deviceCheckboxDict[uuid] = view
            if !deviceInsertionOrder.contains(uuid) {
                deviceInsertionOrder.append(uuid)
            }
        }
    }
    
    /// Add a menu item at the end (non-tracking) or insert it at the correct
    /// group-relative position when the menu is being tracked. During tracking
    /// monitored items go before the persistent separator, unmonitored after
    /// the "Scanning…" indicator.
    func addDeviceMenuItem(title: String, uuid: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if deviceMenuIsOpen, let sep = groupSeparatorItem {
            let sepIdx = deviceMenu.index(of: sep)
            if ble.isMonitoring(uuid: uuid) {
                deviceMenu.insertItem(item, at: sepIdx)
            } else {
                // Unmonitored: append to end; reorder fixes on menu close
                deviceMenu.addItem(item)
            }
        } else {
            deviceMenu.addItem(item)
        }
        return item
    }

    func addDeviceRow(for device: Device) {
        let menuItem = addDeviceMenuItem(title: "", uuid: device.uuid)
        let checkbox = configureDeviceMenuView(menuItem, uuid: device.uuid, title: menuItemTitle(device: device, showDetails: deviceMenuShowDetails))
        deviceDict[device.uuid] = menuItem
        deviceCheckboxDict[device.uuid] = checkbox
    }

    /// Builds the rows that newDevice and updateDevice skip while the menu is closed.
    func addMissingDeviceRows() {
        for uuid in deviceInsertionOrder where deviceDict[uuid] == nil {
            guard let device = ble.devices[uuid] else { continue }
            addDeviceRow(for: device)
        }
    }

    func newDevice(device: Device) {
        if let checkbox = deviceCheckboxDict[device.uuid] {
            // NOTE: menuWillOpen refreshes every row, so a closed menu skips the per-advertisement layout.
            if deviceMenuIsOpen {
                updateDeviceCheckbox(checkbox, uuid: device.uuid, title: menuItemTitle(device: device, showDetails: deviceMenuShowDetails))
            }
            updateMonitorStatusItems()
            return
        }
        // MAC correlation: if unmonitored device shares MAC with a monitored one, merge.
        // Try resolving MAC first (cached Bluetooth plist lookup, near-zero cost).
        if !ble.isMonitoring(uuid: device.uuid) {
            var mac = device.macAddr
            let leLookupResult: String? = getMACFromUUID(device.uuid.uuidString)
            if mac == nil && leLookupResult != nil {
                mac = leLookupResult
                device.macAddr = mac
            }
            // Fallback: check persistence for exact match only.
            // Never inject MACs from other devices — correlation is done in BLE discovery.
            if mac == nil {
                let persisted = loadPersistedMACs()
                for (pmac, puuid) in persisted {
                    if puuid == device.uuid.uuidString {
                        mac = pmac
                        device.macAddr = pmac
                        macInheritLog("newDevice: uuid=\(device.uuid.uuidString) got MAC=\(pmac) from persistence (exact match)")
                        break
                    }
                }
                if mac == nil {
                    macInheritLog("newDevice: uuid=\(device.uuid.uuidString) NO MAC (LE=\(leLookupResult ?? "nil") persistedKeys=\(persisted.keys.joined(separator: ", ")))")
                }
            }
            if let mac = mac {
                let normalized = canonicalMAC(mac)
                macInheritLog("newDevice: uuid=\(device.uuid.uuidString) MAC=\(mac) normalized=\(normalized) checking monitored devices...")
                for (monUUID, monDev) in ble.devices where ble.isMonitoring(uuid: monUUID) {
                    if let m = monDev.macAddr, canonicalMAC(m) == normalized {
                        macInheritLog("newDevice: MERGE \(device.uuid.uuidString) (MAC=\(mac)) into monitored \(monUUID.uuidString) (MAC=\(m))")
                        if ble.remapMonitoredUUID(from: monUUID, to: device.uuid, peripheral: device.peripheral) {
                            replaceMonitoredDevice(oldUUID: monUUID, with: device)
                        }
                        return
                    }
                }
                macInheritLog("newDevice: no monitored device matched MAC=\(normalized)")
            }
            // Suppress unmonitored device if its name matches a monitored device
            // that already has a confirmed MAC address, skip adding — likely a
            // UUID rotation awaiting correlation.
            if mac == nil, let name = device.currentResolvedName() {
                for (monUUID, monDev) in ble.devices where ble.isMonitoring(uuid: monUUID) && monDev.macAddr != nil {
                    if monDev.currentResolvedName() == name {
                        macInheritLog("newDevice: suppressing name-match duplicate \(device.uuid.uuidString) (\(name)) for monitored \(monUUID.uuidString)")
                        return
                    }
                }
            }
        }
        if !deviceInsertionOrder.contains(device.uuid) {
            deviceInsertionOrder.append(device.uuid)
        }
        if deviceMenuIsOpen {
            addDeviceRow(for: device)
        }
        updateMonitorStatusItems()
        scheduleDeviceMenuReorder()
        if ble.isMonitoring(uuid: device.uuid), device.macAddr != nil {
            persistDeviceMACs()
        }
    }
    
    func updateDevice(device: Device) {
        macInheritLog("updateDevice: uuid=\(device.uuid.uuidString) mac=\(device.macAddr ?? "nil") isMonitored=\(ble.isMonitoring(uuid: device.uuid))")
        // MAC-based merge: unmonitored device that just resolved MAC matching a monitored one
        if !ble.isMonitoring(uuid: device.uuid), let mac = device.macAddr {
            let normalized = canonicalMAC(mac)
            for (monUUID, monDev) in ble.devices where ble.isMonitoring(uuid: monUUID) {
                if let m = monDev.macAddr, canonicalMAC(m) == normalized {
                    macInheritLog("updateDevice: MERGE \(device.uuid.uuidString) (MAC=\(mac)) into monitored \(monUUID.uuidString)")
                    if ble.remapMonitoredUUID(from: monUUID, to: device.uuid, peripheral: device.peripheral) {
                        replaceMonitoredDevice(oldUUID: monUUID, with: device)
                    }
                    return
                }
            }
        }
        // Suppress unmonitored device if its name matches a monitored device
        // that already has a confirmed MAC address (awaiting MAC correlation).
        if !ble.isMonitoring(uuid: device.uuid), let name = device.currentResolvedName() {
            for (monUUID, monDev) in ble.devices where ble.isMonitoring(uuid: monUUID) && monDev.macAddr != nil {
                if monDev.currentResolvedName() == name {
                    macInheritLog("updateDevice: suppressing name-match duplicate \(device.uuid.uuidString) (\(name)) for monitored \(monUUID.uuidString)")
                    // Remove if already in list
                    if let menuItem = deviceDict.removeValue(forKey: device.uuid) {
                        menuItem.menu?.removeItem(menuItem)
                    }
                    deviceCheckboxDict.removeValue(forKey: device.uuid)
                    deviceInsertionOrder.removeAll { $0 == device.uuid }
                    return
                }
            }
        }
        if let checkbox = deviceCheckboxDict[device.uuid] {
            // NOTE: menuWillOpen refreshes every row, so a closed menu skips the per-advertisement layout.
            if deviceMenuIsOpen {
                updateDeviceCheckbox(checkbox, uuid: device.uuid, title: menuItemTitle(device: device, showDetails: deviceMenuShowDetails))
            }
        } else {
            if !deviceInsertionOrder.contains(device.uuid) {
                deviceInsertionOrder.append(device.uuid)
            }
            if deviceMenuIsOpen {
                addDeviceRow(for: device)
            }
        }
        updateMonitorStatusItems()
        scheduleDeviceMenuReorder()
        if ble.isMonitoring(uuid: device.uuid), device.macAddr != nil {
            persistDeviceMACs()
        }
    }
    
    func removeDevice(device: Device) {
        if ble.isMonitoring(uuid: device.uuid) {
            if let checkbox = deviceCheckboxDict[device.uuid] {
                let title: String
                if displayedRSSI(for: device.uuid) != nil {
                    title = menuItemTitle(device: device, showDetails: deviceMenuShowDetails)
                } else {
                    title = menuItemTitleNotDetected(device: device)
                }
                updateDeviceCheckbox(checkbox, uuid: device.uuid, title: title)
            }
            updateMonitorStatusItems()
            return
        }
        if let menuItem = deviceDict[device.uuid] {
            menuItem.menu?.removeItem(menuItem)
        }
        deviceDict.removeValue(forKey: device.uuid)
        deviceCheckboxDict.removeValue(forKey: device.uuid)
        deviceInsertionOrder.removeAll { $0 == device.uuid }
        updateMonitorStatusItems()
    }

    func replaceMonitoredDevice(oldUUID: UUID, with newDevice: Device) {
        macInheritLog("replaceMonitoredDevice: old=\(oldUUID.uuidString) -> new=\(newDevice.uuid.uuidString) mac=\(newDevice.macAddr ?? "nil") isMonitored=\(ble.isMonitoring(uuid: oldUUID)) menuOpen=\(deviceMenuIsOpen)")
        // Clean up insertion order: remove any prior entry for newUUID (from newDevice)
        // before replacing oldUUID's position, preventing duplicates.
        deviceInsertionOrder.removeAll { $0 == newDevice.uuid }
        replaceUUIDInInsertionOrder(old: oldUUID, new: newDevice.uuid)
        
        if deviceMenuIsOpen, let oldItem = deviceDict[oldUUID] {
            // During tracking: repurpose the existing menu item in-place.
            // Remove any stale menu item that newDevice already created for newUUID first,
            // then remap the old item to the new UUID without touching menu structure.
            if let staleItem = deviceDict.removeValue(forKey: newDevice.uuid) {
                staleItem.menu?.removeItem(staleItem)
                deviceCheckboxDict.removeValue(forKey: newDevice.uuid)
            }
            deviceDict.removeValue(forKey: oldUUID)
            deviceDict[newDevice.uuid] = oldItem
            if let checkbox = deviceCheckboxDict.removeValue(forKey: oldUUID) {
                updateDeviceCheckbox(checkbox, uuid: newDevice.uuid, title: menuItemTitle(device: newDevice, showDetails: deviceMenuShowDetails))
                deviceCheckboxDict[newDevice.uuid] = checkbox
            }
            updateMonitorStatusItems()
            persistDeviceMACs()
            return
        }
        
        // Not tracking: safe full rebuild
        // Remove old menu entry
        if let menuItem = deviceDict.removeValue(forKey: oldUUID) {
            menuItem.menu?.removeItem(menuItem)
        }
        deviceCheckboxDict.removeValue(forKey: oldUUID)
        // Remove any existing entry for new UUID (may exist from newDevice before MAC resolved)
        if let existingItem = deviceDict.removeValue(forKey: newDevice.uuid) {
            existingItem.menu?.removeItem(existingItem)
        }
        deviceCheckboxDict.removeValue(forKey: newDevice.uuid)
        // Add new menu entry
        addDeviceRow(for: newDevice)
        scheduleDeviceMenuReorder()
        updateMonitorStatusItems()
        persistDeviceMACs()
    }

    func loadMonitoredUUIDs() -> Set<UUID> {
        if let values = prefs.array(forKey: "devices") as? [String] {
            return Set(values.compactMap(UUID.init(uuidString:)))
        }
        if let value = prefs.string(forKey: "device"), let uuid = UUID(uuidString: value) {
            let uuids: Set<UUID> = [uuid]
            saveMonitoredUUIDs(uuids)
            return uuids
        }
        return []
    }

    func saveMonitoredUUIDs(_ uuids: Set<UUID>) {
        prefs.set(uuids.map(\.uuidString).sorted(), forKey: "devices")
        prefs.removeObject(forKey: "device")
        persistDeviceMACs()
    }

    /// Persist MAC→UUID mappings for currently monitored devices so they survive
    /// app restarts and UUID rotations. Keyed by MAC address (one MAC = one monitored
    /// device at any time; the latest monitored UUID wins).
    /// Merges with existing entries to avoid losing mappings written by other code paths.
    func persistDeviceMACs() {
        var dict = prefs.dictionary(forKey: "deviceMACs") as? [String: String] ?? [:]
        let monitoredUUIDStrings = Set(ble.monitoredUUIDs.map { $0.uuidString })
        for uuid in ble.monitoredUUIDs {
            guard let mac = ble.devices[uuid]?.macAddr else { continue }
            dict[canonicalMAC(mac)] = uuid.uuidString
        }
        // Prune entries for UUIDs that are no longer monitored
        dict = dict.filter { _, uuidStr in monitoredUUIDStrings.contains(uuidStr) }
        prefs.set(dict, forKey: "deviceMACs")
    }


    /// Load persisted MAC→UUID mappings from previous sessions.
    /// Returns [MAC: UUIDString] for efficient MAC-keyed lookup.
    func loadPersistedMACs() -> [String: String] {
        return prefs.dictionary(forKey: "deviceMACs") as? [String: String] ?? [:]
    }


    /// Refresh all device menu item titles (called on Option-key toggle).
    func setDeviceMenuShowDetails(_ showDetails: Bool, forceRefresh: Bool = false) {
        guard forceRefresh || deviceMenuShowDetails != showDetails else { return }
        deviceMenuShowDetails = showDetails
        deviceMaxTitleWidth.removeAll()
        refreshAllDeviceTitles(rebuildViews: true)
    }

    func refreshAllDeviceTitles(rebuildViews: Bool = false) {
        for (uuid, _) in deviceDict {
            if let device = ble.devices[uuid] {
                let title = menuItemTitle(device: device, showDetails: deviceMenuShowDetails)
                if rebuildViews, let menuItem = deviceDict[uuid] {
                    menuItem.view = nil
                    deviceCheckboxDict[uuid] = configureDeviceMenuView(menuItem, uuid: uuid, title: title)
                } else if let checkbox = deviceCheckboxDict[uuid] {
                    updateDeviceCheckbox(checkbox, uuid: uuid, title: title)
                }
            }
        }
        deviceMenu.minimumWidth = 0
        deviceMenu.update()
    }

    func replaceDeviceMenuInstancePreservingItems() {
        let oldMenu = deviceMenu
        let replacement = NSMenu()
        replacement.delegate = self
        replacement.autoenablesItems = oldMenu.autoenablesItems
        replacement.minimumWidth = 0

        while oldMenu.numberOfItems > 0 {
            guard let item = oldMenu.item(at: 0) else { break }
            oldMenu.removeItem(at: 0)
            replacement.addItem(item)
        }

        deviceMenu = replacement
        deviceMenuItem?.submenu = replacement
    }

    func refreshDeviceMenuSelectionStates(removeStale: Bool = true) {
        ensureMonitoredDeviceMenuItems()
        var staleUUIDs: [UUID] = []
        for (uuid, menuItem) in deviceDict {
            let monitoring = ble.isMonitoring(uuid: uuid)
            menuItem.state = monitoring ? .on : .off
            if let device = ble.devices[uuid] {
                if !monitoring && !device.isVisible {
                    staleUUIDs.append(uuid)
                } else if let checkbox = deviceCheckboxDict[uuid] {
                    updateDeviceCheckbox(checkbox, uuid: uuid, title: menuItemTitle(device: device, showDetails: deviceMenuShowDetails))
                }
                // Dedup: stale unmonitored if MAC/name matches a monitored device
                if !monitoring, let device = ble.devices[uuid] {
                    let hasMonitoredMAC: Bool = {
                        if let mac = device.macAddr {
                            let n = canonicalMAC(mac)
                            for (mUUID, mDev) in ble.devices where ble.isMonitoring(uuid: mUUID) {
                                if let m = mDev.macAddr, canonicalMAC(m) == n { return true }
                            }
                        }
                        return false
                    }()
                    let hasMonitoredName: Bool = {
                        if let name = device.currentResolvedName() {
                            for (mUUID, mDev) in ble.devices where ble.isMonitoring(uuid: mUUID) && mDev.macAddr != nil {
                                if mDev.currentResolvedName() == name { return true }
                            }
                        }
                        return false
                    }()
                    if hasMonitoredMAC || hasMonitoredName {
                        staleUUIDs.append(uuid)
                    }
                }
            } else if let checkbox = deviceCheckboxDict[uuid] {
                if monitoring {
                    let title: String
                    if let rssi = displayedRSSI(for: uuid) {
                        title = menuItemTitle(title: monitoredDeviceTitle(uuid: uuid), rssi: rssi)
                    } else {
                        title = menuItemTitleNotDetected(title: monitoredDeviceTitle(uuid: uuid))
                    }
                    updateDeviceCheckbox(checkbox, uuid: uuid, title: title)
                } else {
                    staleUUIDs.append(uuid)
                }
            }
        }
        if removeStale {
            for uuid in staleUUIDs {
                if let menuItem = deviceDict.removeValue(forKey: uuid) {
                    menuItem.menu?.removeItem(menuItem)
                }
                deviceCheckboxDict.removeValue(forKey: uuid)
                deviceInsertionOrder.removeAll { $0 == uuid }
            }
        }
    }

    func monitoredDeviceTitle(uuid: UUID) -> String {
        if let device = ble.devices[uuid] {
            return device.description
        }
        if let name = ble.monitoredStates[uuid]?.peripheral?.name?.trimmingCharacters(in: .whitespaces),
           !name.isEmpty {
            return name
        }
        return uuid.uuidString
    }

    func monitoredDeviceIdentifier(uuid: UUID) -> String {
        if let mac = ble.devices[uuid]?.macAddr, mac.isEmpty == false {
            return mac
        }
        if let mac = getLEDeviceInfoFromUUID(uuid.uuidString)?.macAddr, mac.isEmpty == false {
            return mac
        }
        return uuid.uuidString
    }

    func monitoredDeviceStatusTitle(uuid: UUID) -> String {
        let title = monitoredDeviceTitle(uuid: uuid)
        if let rssi = displayedRSSI(for: uuid) {
            let state = ble.monitoredStates[uuid]
            let activeSuffix = state?.active == true ? t("monitor_status_active_suffix") : ""
            return String(format: t("monitor_status_device_detected"), title, rssi, activeSuffix)
        }
        return String(format: t("monitor_status_device_not_detected"), title, t("not_detected"))
    }

    func monitoredSummaryTitle() -> String {
        let orderedUUIDs = ble.monitoredUUIDs.sorted {
            monitoredDeviceTitle(uuid: $0).localizedStandardCompare(monitoredDeviceTitle(uuid: $1)) == .orderedAscending
        }
        guard !orderedUUIDs.isEmpty else {
            return t("device_not_set")
        }

        let visibleDevices = orderedUUIDs.compactMap { uuid -> (UUID, Int)? in
            guard let rssi = displayedRSSI(for: uuid) else { return nil }
            return (uuid, rssi)
        }

        if let strongest = visibleDevices.max(by: { $0.1 < $1.1 }) {
            let detected = visibleDevices.count
            return String(format: t("monitor_status_strongest_detected"), detected, orderedUUIDs.count, strongest.1)
        }
        return String(format: t("monitor_status_not_detected"), 0, orderedUUIDs.count)
    }

    func updateMonitorStatusItems() {
        // NOTE: menuWillOpen refreshes the summary, so a closed menu skips the per-advertisement rebuild.
        guard mainMenuIsOpen else { return }
        monitorMenuItem?.title = monitoredSummaryTitle()
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        if let r = rssi {
            lastRSSI = r
            updateMonitorStatusItems()
            if (!connected) {
                connected = true
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            updateMonitorStatusItems()
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
        var subtitle: String?
        if reason == "lost" {
            subtitle = t("notification_lost_signal")
        } else if reason == "away" {
            subtitle = t("notification_device_away")
        }
        enqueueNotification(identifier: lockNotificationID,
                            kind: .lock,
                            title: "BLEUnlock",
                            subtitle: subtitle,
                            informativeText: t("notification_locked"),
                            after: 1)
        userNotificationID = lockNotificationID
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if notification != userNotification {
            NSWorkspace.shared.open(URL(string: "https://github.com/Skyearn/BLEUnlock/releases")!)
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        }
    }

    @available(macOS 10.14, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let kind = notification.request.content.userInfo[notificationKindKey] as? String
        if #available(macOS 11.0, *) {
            if kind == AppNotificationKind.update.rawValue {
                completionHandler([.banner, .list])
            } else {
                completionHandler([.banner, .list, .sound])
            }
        } else {
            if kind == AppNotificationKind.update.rawValue {
                completionHandler([.alert])
            } else {
                completionHandler([.alert, .sound])
            }
        }
    }

    @available(macOS 10.14, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = response.notification.request.content.userInfo[notificationKindKey] as? String
        if kind == AppNotificationKind.update.rawValue {
            NSWorkspace.shared.open(URL(string: "https://github.com/Skyearn/BLEUnlock/releases")!)
            removeDeliveredNotification(identifier: updateNotificationID)
        }
        completionHandler()
    }

    func runScript(_ arg: String, device: UUID? = nil, deviceRSSI: Int? = nil) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        var arguments = [arg]
        if let r = lastRSSI {
            arguments.append(String(r))
        }
        if let device = device {
            if lastRSSI == nil {
                arguments.append("")
            }
            arguments.append(monitoredDeviceTitle(uuid: device))
            arguments.append(monitoredDeviceIdentifier(uuid: device))
            arguments.append(deviceRSSI.map(String.init) ?? "")
        }
        process.arguments = arguments
        try? process.run()
    }

    func isRunning(_ app: ManagedMediaApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    @discardableResult
    func runAppleScript(_ source: String, label: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            print("AppleScript compile failed for \(label)")
            return nil
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            print("AppleScript \(label) failed: \(error)")
            return nil
        }

        if let stringValue = result.stringValue {
            return stringValue
        }
        if result.descriptorType == typeSInt32 {
            return String(result.int32Value)
        }
        return nil
    }

    func automationPermissionStatus(for app: ManagedMediaApp, askUserIfNeeded: Bool) -> OSStatus {
        guard #available(macOS 10.14, *) else { return noErr }
        return BLEUnlockDeterminePermissionToAutomateBundleID(app.bundleIdentifier as CFString, askUserIfNeeded)
    }

    func hasAutomationPermission(for app: ManagedMediaApp) -> Bool {
        let status = automationPermissionStatus(for: app, askUserIfNeeded: false)
        if status == noErr {
            return true
        }

        if status == OSStatus(procNotFound) {
            return false
        }

        if #available(macOS 10.14, *) {
            let consentRequired = OSStatus(errAEEventWouldRequireUserConsent)
            let eventNotPermitted = OSStatus(errAEEventNotPermitted)
            let targetNotPermitted = OSStatus(errAETargetAddressNotPermitted)
            if status == consentRequired || status == eventNotPermitted || status == targetNotPermitted {
                return false
            }
        }

        print("Automation permission check for \(app.displayName) returned \(status)")
        return false
    }

    func requestAutomationPermissionsIfNeeded() {
        guard prefs.bool(forKey: "pauseItunes") else { return }

        for app in ManagedMediaApp.allCases where isRunning(app) && !hasAutomationPermission(for: app) {
            guard !automationPermissionPromptedApps.contains(app) else { continue }
            automationPermissionPromptedApps.insert(app)

            let status = automationPermissionStatus(for: app, askUserIfNeeded: true)
            if status == noErr {
                print("Automation permission granted for \(app.displayName)")
            } else {
                print("Automation permission request for \(app.displayName) returned \(status)")
            }
        }
    }

    func pauseScript(for app: ManagedMediaApp) -> String {
        switch app {
        case .music:
            return """
            tell application "Music"
                if player state is playing then
                    pause
                    return "paused"
                end if
                return "noop"
            end tell
            """
        case .quickTimePlayer:
            return """
            tell application "QuickTime Player"
                set didPause to false
                repeat with aDocument in documents
                    try
                        if playing of aDocument then
                            pause aDocument
                            set didPause to true
                        end if
                    end try
                end repeat
                if didPause then
                    return "paused"
                end if
                return "noop"
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
                if player state is playing then
                    pause
                    return "paused"
                end if
                return "noop"
            end tell
            """
        case .safari:
            return """
            tell application "Safari"
                set pausedCount to 0
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        try
                            set tabResult to do JavaScript "
                                (() => {
                                    let paused = 0;
                                    for (const media of document.querySelectorAll('video, audio')) {
                                        if (!media.paused) {
                                            media.dataset.bleunlockPaused = '1';
                                            media.pause();
                                            paused += 1;
                                        }
                                    }
                                    return String(paused);
                                })();
                            " in aTab
                            set pausedCount to pausedCount + (tabResult as integer)
                        end try
                    end repeat
                end repeat
                return pausedCount as string
            end tell
            """
        }
    }

    func resumeScript(for app: ManagedMediaApp) -> String {
        switch app {
        case .music:
            return """
            tell application "Music"
                if player state is paused then
                    play
                    return "played"
                end if
                return "noop"
            end tell
            """
        case .quickTimePlayer:
            return """
            tell application "QuickTime Player"
                set didPlay to false
                repeat with aDocument in documents
                    try
                        if not playing of aDocument then
                            play aDocument
                            set didPlay to true
                        end if
                    end try
                end repeat
                if didPlay then
                    return "played"
                end if
                return "noop"
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
                if player state is paused then
                    play
                    return "played"
                end if
                return "noop"
            end tell
            """
        case .safari:
            return """
            tell application "Safari"
                set resumedCount to 0
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        try
                            set tabResult to do JavaScript "
                                (() => {
                                    let resumed = 0;
                                    for (const media of document.querySelectorAll('video, audio')) {
                                        if (media.dataset.bleunlockPaused === '1') {
                                            delete media.dataset.bleunlockPaused;
                                            media.play();
                                            resumed += 1;
                                        }
                                    }
                                    return String(resumed);
                                })();
                            " in aTab
                            set resumedCount to resumedCount + (tabResult as integer)
                        end try
                    end repeat
                end repeat
                return resumedCount as string
            end tell
            """
        }
    }

    func didPauseMediaApp(_ app: ManagedMediaApp, result: String?) -> Bool {
        guard let result else { return false }
        switch app {
        case .safari:
            return (Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        default:
            return result == "paused"
        }
    }

    func didResumeMediaApp(_ app: ManagedMediaApp, result: String?) -> Bool {
        guard let result else { return false }
        switch app {
        case .safari:
            return (Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        default:
            return result == "played"
        }
    }

    func pauseNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }

        mediaControlQueue.async {
            self.pausedMediaAppsLock.lock()
            self.pausedMediaApps.removeAll()
            self.pausedMediaAppsLock.unlock()
            for app in ManagedMediaApp.allCases {
                guard self.isRunning(app) else { continue }
                guard self.hasAutomationPermission(for: app) else { continue }
                let result = self.runAppleScript(self.pauseScript(for: app), label: "pause \(app.displayName)")
                if self.didPauseMediaApp(app, result: result) {
                    self.pausedMediaAppsLock.lock()
                    self.pausedMediaApps.insert(app)
                    self.pausedMediaAppsLock.unlock()
                    print("Paused \(app.displayName)")
                }
            }
        }
    }
    
    func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        mediaControlQueue.asyncAfter(deadline: .now() + 0.5) {
            self.pausedMediaAppsLock.lock()
            let appsToResume = self.pausedMediaApps
            self.pausedMediaApps.removeAll()
            self.pausedMediaAppsLock.unlock()
            guard !appsToResume.isEmpty else { return }

            for app in ManagedMediaApp.allCases where appsToResume.contains(app) && self.isRunning(app) {
                guard self.hasAutomationPermission(for: app) else { continue }
                let result = self.runAppleScript(self.resumeScript(for: app), label: "resume \(app.displayName)")
                if self.didResumeMediaApp(app, result: result) {
                    print("Resumed \(app.displayName)")
                }
            }
        }
    }

    func lockOrSaveScreenAsync() {
        DispatchQueue.main.async {
            self.lockOrSaveScreen()
        }
    }

    func lockOrSaveScreen() {
        if prefs.bool(forKey: "screensaver") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
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

    func updatePresence(shouldUnlock: Bool, shouldLock: Bool, reason: String, device: UUID?, deviceRSSI: Int?) {
        if manualLock && shouldLock {
            manualLock = false
            if shouldUnlock {
                return
            }
        }

        // Lock takes precedence when both rules fire together. This is required
        // for "anyAway" with multiple monitored devices.
        if shouldLock {
            pendingUnlockDevice = nil
            pendingUnlockDeviceRSSI = nil
            pendingLockDevice = device
            pendingLockDeviceRSSI = deviceRSSI
            cancelUnlockTimers()
            startAutomaticLockChecks()
            manualLock = false
        } else if shouldUnlock {
            pendingLockDevice = nil
            pendingLockDeviceRSSI = nil
            cancelAutomaticLockChecks()
            guard ble.hasStableUnlockEvidence() else { return }
            if ble.unlockRSSI != ble.UNLOCK_DISABLED {
                if let identifier = userNotificationID {
                    removeDeliveredNotification(identifier: identifier)
                    userNotificationID = nil
                }
                if let notification = userNotification {
                    NSUserNotificationCenter.default.removeDeliveredNotification(notification)
                    userNotification = nil
                }
                if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                    pendingUnlockDevice = device
                    pendingUnlockDeviceRSSI = deviceRSSI
                    let now = Date().timeIntervalSince1970
                    if now - lastDisplayWakeRequestAt >= minimumWakeRequestInterval {
                        print("Waking display")
                        lastDisplayWakeRequestAt = now
                        wakeDisplay()
                    } else {
                        print("Skipping wake display retry while display wake is still pending")
                    }
                }
                tryUnlockScreen(device: device, deviceRSSI: deviceRSSI)
            }
        } else {
            pendingLockDevice = nil
            pendingLockDeviceRSSI = nil
            cancelAutomaticLockChecks()
        }
    }

    func cancelAutomaticLockChecks() {
        automaticLockTimer?.invalidate()
        automaticLockTimer = nil
    }

    func startAutomaticLockChecks() {
        guard automaticLockTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.evaluateAutomaticLock()
        }
        automaticLockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        evaluateAutomaticLock()
    }

    func evaluateAutomaticLock() {
        guard !systemSleep, !manualLock, ble.shouldLock,
              ble.lockRSSI != ble.LOCK_DISABLED, !isScreenLocked() else {
            pendingLockDevice = nil
            pendingLockDeviceRSSI = nil
            cancelAutomaticLockChecks()
            return
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                         eventType: CGEventType(rawValue: UInt32.max)!)
        let protectWhileActive = prefs.bool(forKey: "preventLockWhileActive")
        if let reason = ble.automaticLockReason(idleSeconds: idle, protectWhileActive: protectWhileActive) {
            let device = pendingLockDevice
            let deviceRSSI = pendingLockDeviceRSSI
            pendingLockDevice = nil
            pendingLockDeviceRSSI = nil
            cancelAutomaticLockChecks()
            pauseNowPlaying()
            lockOrSaveScreen()
            notifyUser(reason.rawValue)
            runScript(reason.rawValue, device: device, deviceRSSI: deviceRSSI)
            return
        }
        // Keep polling while an away timer is still accumulating, or while
        // activity protection is merely deferring an already-confirmed lock.
        // Otherwise cancel the timer; disabling signal-loss locking must not
        // leave a 1 Hz timer running forever.
        let hasPotentialReason = ble.automaticLockReason(idleSeconds: 0, protectWhileActive: false) != nil
        if !hasPotentialReason && !ble.hasFreshWeakEvidence() {
            pendingLockDevice = nil
            pendingLockDeviceRSSI = nil
            cancelAutomaticLockChecks()
        }
    }

    func fakeKeyStrokes(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Send 20 characters per keyboard event. That seems to be the limit.
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
            buffer.deallocate()
        }
        
        // Return key
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func sendEscapeKey() {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Harmless input event used to nudge the lock screen so that Apple Watch
    /// offers to unlock it. Synthetic mouse moves (both a one-pixel nudge and
    /// a larger shake) did not trigger Apple Watch unlock in testing, while a
    /// key event does, so this sends Escape.
    func sendWakeInputEvent() {
        sendEscapeKey()
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }

    func recentlyWoke() -> Bool {
        Date().timeIntervalSince1970 - lastWakeAt < 5
    }

    func conservativeWakeUnlockNeeded() -> Bool {
        guard recentlyWoke() else { return false }
        let now = Date().timeIntervalSince1970
        let sleepReference = max(lastSystemSleepStartedAt, lastScreensaverStartedAt)
        guard sleepReference > 0 else { return false }
        return now - sleepReference >= conservativeWakeSleepThreshold
    }
    
    func tryUnlockScreen(retryCount: Int = 0, device: UUID? = nil, deviceRSSI: Int? = nil) {
        guard !manualLock else { return }
        guard ble.presence else { return }
        guard ble.hasStableUnlockEvidence() else { return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { return }
        guard !systemSleep else { return }
        guard !displaySleep else { return }
        let wakeWithoutUnlocking = self.prefs.bool(forKey: "wakeWithoutUnlocking")
        let triggerWatchUnlock = wakeWithoutUnlocking && self.prefs.bool(forKey: "triggerWatchUnlock")
        guard !wakeWithoutUnlocking || triggerWatchUnlock else { return }
        // Repeated close observations must not postpone queued input indefinitely.
        guard wakeUnlockTimer == nil, postUnlockRetryTimer == nil else { return }
        guard checkAccessibility(showPrompt: false) else {
            startPermissionRecovery(promptAccessibility: false)
            return
        }
        let recentlyWoke = recentlyWoke()
        let conservativeWakeUnlock = conservativeWakeUnlockNeeded()

        if inScreensaver && !recentlyWoke && retryCount == 0 {
            // Only dismiss a live screensaver outside the fragile wake window.
            if triggerWatchUnlock {
                // Counted and throttled like every other Watch-unlock input.
                triggerWatchUnlockInput(retryCount: retryCount, device: device, deviceRSSI: deviceRSSI)
                return
            }
            sendEscapeKey()
            scheduleWakeUnlock(after: screensaverEscapeRetryDelay, retryCount: retryCount + 1, device: device, deviceRSSI: deviceRSSI)
            return
        } else if inScreensaver && recentlyWoke {
            print("Skipping Escape key during wake recovery")
        }

        guard isScreenLocked() else {
            if (recentlyWoke || inScreensaver) && retryCount < wakeUnlockMaxRetries {
                scheduleWakeUnlock(after: wakeUnlockRetryDelay, retryCount: retryCount + 1, device: device, deviceRSSI: deviceRSSI)
            }
            return
        }

        if triggerWatchUnlock {
            triggerWatchUnlockInput(retryCount: retryCount, device: device, deviceRSSI: deviceRSSI)
            return
        }

        let unlockDelay = conservativeWakeUnlock ? conservativeWakeUnlockDelay : (recentlyWoke ? 0.75 : 0.5)
        wakeUnlockTimer?.invalidate()
        wakeUnlockTimer = Timer.scheduledTimer(withTimeInterval: unlockDelay, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            self.wakeUnlockTimer = nil
            guard !self.manualLock, !self.systemSleep, !self.displaySleep,
                  self.ble.presence, self.ble.hasStableUnlockEvidence(),
                  self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED,
                  !self.prefs.bool(forKey: "wakeWithoutUnlocking"),
                  self.checkAccessibility(showPrompt: false) else { return }
            guard self.isScreenLocked() else {
                if (recentlyWoke || self.inScreensaver) && retryCount < self.wakeUnlockMaxRetries {
                    self.scheduleWakeUnlock(after: self.wakeUnlockRetryDelay, retryCount: retryCount + 1, device: device, deviceRSSI: deviceRSSI)
                }
                return
            }
            guard let password = self.fetchPassword(warn: true) else { return }
            
            self.unlockedAt = Date().timeIntervalSince1970
            self.fakeKeyStrokes(password)
            self.playNowPlaying()
            self.runScript("unlocked", device: device, deviceRSSI: deviceRSSI)

            // On wake, the first attempt can land before the login UI is fully ready.
            if (recentlyWoke || self.inScreensaver) && retryCount < self.wakeUnlockMaxRetries {
                self.postUnlockRetryTimer?.invalidate()
                let retryDelay = conservativeWakeUnlock ? 2.0 : 1.5
                self.postUnlockRetryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false, block: { [weak self] _ in
                    guard let self = self else { return }
                    self.postUnlockRetryTimer = nil
                    guard self.isScreenLocked() else { return }
                    self.scheduleWakeUnlock(after: self.wakeUnlockRetryDelay, retryCount: retryCount + 1, device: device, deviceRSSI: deviceRSSI)
                })
            }
        })
    }

    /// "Wake without unlocking" + "Trigger Apple Watch unlock": never type the
    /// password, only send a few harmless input events so the lock screen
    /// notices user activity and Apple Watch can unlock the Mac.
    func triggerWatchUnlockInput(retryCount: Int, device: UUID?, deviceRSSI: Int?) {
        let now = Date().timeIntervalSince1970
        if now - lastWatchUnlockTriggerAt >= watchUnlockSessionWindow {
            watchUnlockAttempts = 0
        }
        guard watchUnlockAttempts < watchUnlockMaxAttempts else { return }

        if inScreensaver && recentlyWoke() {
            print("Skipping Escape key during wake recovery")
            if retryCount < wakeUnlockMaxRetries {
                scheduleWakeUnlock(after: watchUnlockRetryDelay, retryCount: retryCount + 1, device: device, deviceRSSI: deviceRSSI)
            }
            return
        }

        // Several paths (presence, display wake, retries) can land here; keep
        // at most one input event per retry interval.
        let sinceLast = now - lastWatchUnlockTriggerAt
        if sinceLast < watchUnlockRetryDelay {
            scheduleWakeUnlock(after: watchUnlockRetryDelay - sinceLast, retryCount: retryCount, device: device, deviceRSSI: deviceRSSI)
            return
        }

        print("Sending input event to trigger Apple Watch unlock")
        watchUnlockAttempts += 1
        lastWatchUnlockTriggerAt = now
        sendWakeInputEvent()
        if watchUnlockAttempts < watchUnlockMaxAttempts {
            // tryUnlockScreen re-checks isScreenLocked() and stops once unlocked.
            scheduleWakeUnlock(after: watchUnlockRetryDelay, retryCount: retryCount + 1, device: device, deviceRSSI: deviceRSSI)
        }
    }

    func resetWatchUnlockAttempts() {
        watchUnlockAttempts = 0
        lastWatchUnlockTriggerAt = 0
    }

    func cancelUnlockTimers() {
        wakeUnlockTimer?.invalidate()
        wakeUnlockTimer = nil
        postUnlockRetryTimer?.invalidate()
        postUnlockRetryTimer = nil
    }

    func cancelAllWakeTimers() {
        systemWakeTimer?.invalidate()
        systemWakeTimer = nil
        cancelUnlockTimers()
    }

    /// Complete the work that normally runs about one second after system wake.
    ///
    /// A fast screen unlock can arrive before `systemWakeTimer` fires. If that
    /// unlock path merely cancels every wake-related timer, monitoring remains
    /// suspended forever. This method is idempotent and can be called from both
    /// the timer and the unlock notification.
    func completeSystemWakeRecovery() {
        let hadPendingWork = systemWakeTimer != nil || systemSleep || ble.monitoringSuspended
        systemWakeTimer?.invalidate()
        systemWakeTimer = nil
        guard hadPendingWork else { return }

        print("complete system wake recovery")
        NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
        systemSleep = false
        ble.resumeMonitoringAfterSystemWake()
        lastWakeAt = Date().timeIntervalSince1970
    }

    func completePendingSystemWakeRecoveryIfNeeded() {
        guard systemWakeTimer != nil || systemSleep || ble.monitoringSuspended else { return }
        completeSystemWakeRecovery()
    }

    func scheduleWakeUnlock(after delay: TimeInterval, retryCount: Int = 0, device: UUID? = nil, deviceRSSI: Int? = nil) {
        wakeUnlockTimer?.invalidate()
        wakeUnlockTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            self.wakeUnlockTimer = nil
            self.tryUnlockScreen(retryCount: retryCount, device: device, deviceRSSI: deviceRSSI)
        })
    }

    @objc func onDisplayWake() {
        print("display wake")
        //unlockedAt = Date().timeIntervalSince1970
        displaySleep = false
        lastWakeAt = Date().timeIntervalSince1970
        lastDisplayWakeRequestAt = 0
        let device = pendingUnlockDevice
        let deviceRSSI = pendingUnlockDeviceRSSI
        pendingUnlockDevice = nil
        pendingUnlockDeviceRSSI = nil
        scheduleWakeUnlock(after: 0.75, device: device, deviceRSSI: deviceRSSI)
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        pendingUnlockDevice = nil
        pendingUnlockDeviceRSSI = nil
        displaySleep = true
        cancelUnlockTimers()
        resetWatchUnlockAttempts()
        // Do not cancel systemWakeTimer here. It owns the BLE monitoring
        // resume path and the Dock icon restoration. If display sleep happens
        // while wake recovery is still pending, complete it immediately so the
        // later timer cannot schedule an unlock attempt after the display is off.
        if systemWakeTimer != nil {
            completeSystemWakeRecovery()
        }
    }

    @objc func onSystemWake() {
        print("system wake")
        systemWakeTimer?.invalidate()
        systemWakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            print("delayed system wake job")
            self.completeSystemWakeRecovery()
            self.scheduleWakeUnlock(after: 1.0)
        })
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        pendingUnlockDevice = nil
        pendingUnlockDeviceRSSI = nil
        pendingLockDevice = nil
        pendingLockDeviceRSSI = nil
        systemSleep = true
        lastSystemSleepStartedAt = Date().timeIntervalSince1970
        cancelAllWakeTimers()
        cancelAutomaticLockChecks()
        ble.suspendMonitoringForSystemSleep()
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
    }

    @objc func onUnlock() {
        pendingUnlockDevice = nil
        pendingUnlockDeviceRSSI = nil
        cancelUnlockTimers()
        resetWatchUnlockAttempts()
        // The system can unlock before the delayed wake-recovery timer fires.
        // Finish that recovery now instead of cancelling it; otherwise BLE
        // monitoring stays suspended until the app is restarted.
        completePendingSystemWakeRecoveryIfNeeded()
        inScreensaver = false
        lastSystemSleepStartedAt = 0
        lastScreensaverStartedAt = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            print("onUnlock")
            if Date().timeIntervalSince1970 >= self.unlockedAt + 10 {
                if self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED {
                    self.runScript("intruded")
                }
                self.playNowPlaying()
            }
        })
        manualLock = false
        // A manual unlock must not be immediately undone just because the
        // device is still away. Wait for a fresh proximity/lock transition.
        pendingLockDevice = nil
        pendingLockDeviceRSSI = nil
        cancelAutomaticLockChecks()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { [weak self] _ in
            self?.runAutomaticUpdateCheck()
        })
    }

    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
        lastScreensaverStartedAt = Date().timeIntervalSince1970
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
        lastScreensaverStartedAt = 0
    }

    @objc func toggleDeviceCheckbox(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue, let uuid = UUID(uuidString: rawValue) else { return }
        var uuids = ble.monitoredUUIDs
        if uuids.contains(uuid) {
            uuids.remove(uuid)
        } else {
            uuids.insert(uuid)
        }
        saveMonitoredUUIDs(uuids)
        persistDeviceMACs()
        monitorDevices(uuids: uuids)
        // If menu is open, move the toggled item in real time
        if deviceMenuIsOpen {
            moveDeviceInMenu(uuid: uuid, nowMonitored: uuids.contains(uuid))
        }
    }

    func monitorDevice(uuid: UUID) {
        monitorDevices(uuids: Set([uuid]))
    }

    func monitorDevices(uuids: Set<UUID>) {
        connected = false
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        ble.startMonitor(uuids: uuids)
        refreshDeviceMenuSelectionStates()
        refreshSettingsMenus()
        updateMonitorStatusItems()
        performDeviceMenuReorder()
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func infoModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        alert.addButton(withTitle: t("ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showPauseNowPlayingNoticeIfNeeded() {
        guard !prefs.bool(forKey: pauseNowPlayingNoticeShownKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Pause Now Playing Setup"
        alert.informativeText = """
        BLEUnlock can pause Music, QuickTime Player, Spotify, and Safari when your Mac locks.

        macOS may ask you to allow BLEUnlock to control those apps. Safari also requires enabling:
        Develop > Allow JavaScript from Apple Events
        """
        alert.window.title = "BLEUnlock"
        alert.addButton(withTitle: t("ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        prefs.set(true, forKey: pauseNowPlayingNoticeShownKey)
    }

    func keychainQuery(service: String) -> [String: Any] {
        [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): service,
        ]
    }

    func currentKeychainServiceIdentifier() -> String {
        Bundle.main.bundleIdentifier ?? currentAppBundleIdentifier
    }

    func keychainServiceIdentifiersForLookup() -> [String] {
        [currentKeychainServiceIdentifier()] + legacyMainBundleIdentifiers
    }

    func retrievePasswordData(service: String) -> (status: OSStatus, data: Data?) {
        var query = keychainQuery(service: service)
        query[String(kSecReturnData)] = kCFBooleanTrue!
        query[String(kSecMatchLimit)] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }
    
    func storePassword(_ password: String) {
        guard let pw = password.data(using: .utf8) else {
            errorModal("Failed to encode password")
            return
        }
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): currentKeychainServiceIdentifier(),
            String(kSecAttrLabel): "BLEUnlock",
            String(kSecAttrAccessible): kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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

    func fetchPassword(warn: Bool = false) -> String? {
        var lastFailureStatus: OSStatus?

        for service in keychainServiceIdentifiersForLookup() {
            let result = retrievePasswordData(service: service)
            if result.status == errSecItemNotFound {
                continue
            }
            guard result.status == errSecSuccess else {
                lastFailureStatus = result.status
                continue
            }
            guard let data = result.data else {
                errorModal("Failed to convert password")
                return nil
            }
            guard let password = String(data: data, encoding: .utf8) else {
                errorModal("Stored password is unreadable", info: "The Keychain item may be corrupted. Please set the password again.")
                return nil
            }

            if service != currentKeychainServiceIdentifier() {
                storePassword(password)
            }
            return password
        }

        if let status = lastFailureStatus {
            let info = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            return nil
        }

        print("Password is not stored")
        if warn {
            errorModal(t("password_not_set"))
        }
        return nil
    }

    func migrateLegacyDefaultsIfNeeded() {
        guard !prefs.bool(forKey: legacyBundleIDMigrationKey) else { return }

        for legacyBundleIdentifier in legacyMainBundleIdentifiers {
            guard let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier),
                  let legacyDomain = legacyDefaults.persistentDomain(forName: legacyBundleIdentifier) else {
                continue
            }

            for (key, value) in legacyDomain where prefs.object(forKey: key) == nil {
                prefs.set(value, forKey: key)
            }
        }

        prefs.set(true, forKey: legacyBundleIDMigrationKey)
    }

    func legacyLauncherBundleIdentifiers() -> [String] {
        legacyMainBundleIdentifiers.map { $0 + launcherBundleIDSuffix }
    }

    func disableLegacyLoginItems() {
        for legacyLauncherBundleIdentifier in legacyLauncherBundleIdentifiers() {
            _ = SMLoginItemSetEnabled(legacyLauncherBundleIdentifier as CFString, false)
            if #available(macOS 13.0, *) {
                let service = SMAppService.loginItem(identifier: legacyLauncherBundleIdentifier)
                try? service.unregister()
            }
        }
    }

    func migrateLegacyAppDataIfNeeded() {
        migrateLegacyDefaultsIfNeeded()
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

    @objc func toggleLockOnSignalLoss(_ menuItem: NSMenuItem) {
        ble.lockOnSignalLoss.toggle()
        prefs.set(ble.lockOnSignalLoss, forKey: "lockOnSignalLoss")
        menuItem.state = ble.lockOnSignalLoss ? .on : .off
        if ble.shouldLock { startAutomaticLockChecks() }
    }

    @objc func togglePreventLockWhileActive(_ menuItem: NSMenuItem) {
        let enabled = !prefs.bool(forKey: "preventLockWhileActive")
        prefs.set(enabled, forKey: "preventLockWhileActive")
        menuItem.state = enabled ? .on : .off
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func setUnlockDeviceLogic(_ menuItem: NSMenuItem) {
        guard let logic = UnlockDeviceLogic(rawValue: menuItem.tag) else { return }
        prefs.set(logic.rawValue, forKey: "unlockDeviceLogic")
        ble.setUnlockDeviceLogic(logic)
    }

    @objc func setLockDeviceLogic(_ menuItem: NSMenuItem) {
        guard let logic = LockDeviceLogic(rawValue: menuItem.tag) else { return }
        prefs.set(logic.rawValue, forKey: "lockDeviceLogic")
        ble.setLockDeviceLogic(logic)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let targetEnabled = !isLaunchAtLoginEnabled()
        menuItem.state = targetEnabled ? .on : .off
        // SMAppService XPC — offload to serial queue. Revert on failure.
        smdQueue.async { [weak self, weak menuItem] in
            guard let self = self else { return }
            let ok = self.setLaunchAtLogin(targetEnabled)
            if ok {
                self.prefs.set(targetEnabled, forKey: "launchAtLogin")
            } else {
                DispatchQueue.main.async {
                    menuItem?.state = targetEnabled ? .off : .on
                }
            }
        }
    }

    @objc func togglePauseNowPlaying(_ menuItem: NSMenuItem) {
        let pauseNowPlaying = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseNowPlaying, forKey: "pauseItunes")
        menuItem.state = pauseNowPlaying ? .on : .off
        if pauseNowPlaying {
            showPauseNowPlayingNoticeIfNeeded()
            requestAutomationPermissionsIfNeeded()
        }
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

    @objc func toggleTriggerWatchUnlock(_ menuItem: NSMenuItem) {
        let triggerWatchUnlock = !prefs.bool(forKey: "triggerWatchUnlock")
        prefs.set(triggerWatchUnlock, forKey: "triggerWatchUnlock")
        menuItem.state = triggerWatchUnlock ? .on : .off
        startPermissionRecovery(promptAccessibility: true)
    }

    @objc func toggleAutomaticUpdateChecks(_ menuItem: NSMenuItem) {
        let enabled = !automaticUpdateChecksEnabled()
        prefs.set(enabled, forKey: autoCheckUpdatesKey)
        menuItem.state = enabled ? .on : .off
        if !enabled {
            clearPendingUpdate()
        }
        refreshUpdateMenuItems()
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        pauseNowPlaying()
        lockOrSaveScreenAsync()
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }

    @objc func checkForUpdates() {
        checkUpdate(force: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .available(let version, let downloadURL, let releaseURL):
                    savePendingUpdate(version: version, downloadURL: downloadURL, releaseURL: releaseURL)
                    self.refreshUpdateMenuItems()
                    let alert = NSAlert()
                    alert.messageText = t("update_available_title")
                    alert.informativeText = String(format: t("update_available_message"), version)
                    alert.window.title = "BLEUnlock"
                    if downloadURL != nil {
                        alert.addButton(withTitle: t("download_update"))
                    }
                    alert.addButton(withTitle: t("open_releases"))
                    alert.addButton(withTitle: t("cancel"))
                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        if let downloadURL {
                            NSWorkspace.shared.open(downloadURL)
                        } else {
                            NSWorkspace.shared.open(releaseURL)
                        }
                    } else if downloadURL != nil && response == .alertSecondButtonReturn {
                        NSWorkspace.shared.open(releaseURL)
                    }
                case .upToDate:
                    clearPendingUpdate()
                    self.refreshUpdateMenuItems()
                    self.infoModal(t("update_up_to_date"))
                case .failure(let message):
                    self.errorModal(t("update_check_failed"), info: message)
                }
            }
        }
    }

    func runAutomaticUpdateCheck() {
        checkUpdate { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard automaticUpdateChecksEnabled() else {
                    clearPendingUpdate()
                    self.refreshUpdateMenuItems()
                    return
                }

                switch result {
                case .available(let version, let downloadURL, let releaseURL):
                    savePendingUpdate(version: version, downloadURL: downloadURL, releaseURL: releaseURL)
                case .upToDate:
                    clearPendingUpdate()
                case .failure:
                    break
                }
                self.refreshUpdateMenuItems()
            }
        }
    }

    func refreshUpdateMenuItems() {
        let hasPendingUpdate = pendingUpdate() != nil
        updateMenuItem?.title = hasPendingUpdate ? t("updates_available") : t("updates")
        checkForUpdatesMenuItem?.title = t("check_for_updates")
        automaticUpdateChecksMenuItem?.state = automaticUpdateChecksEnabled() ? .on : .off
    }

    func updateSettingsMenu(_ menu: NSMenu, logicKind: String, selectedLogic: Int, rssiKind: String, selectedRSSI: Int) {
        let logicEnabled = ble.monitoredUUIDs.count > 1
        for item in menu.items {
            guard let kind = item.representedObject as? String else {
                item.state = .off
                continue
            }

            if kind == logicKind {
                item.state = item.tag == selectedLogic ? .on : .off
                item.isEnabled = logicEnabled
            } else if kind == rssiKind {
                item.state = item.tag == selectedRSSI ? .on : .off
                if kind == lockRSSIMenuItemKind {
                    item.isEnabled = item.tag <= ble.unlockRSSI
                } else if kind == unlockRSSIMenuItemKind {
                    item.isEnabled = item.tag >= ble.lockRSSI
                }
            } else {
                item.state = .off
            }
        }
    }

    func refreshSettingsMenus() {
        updateSettingsMenu(unlockSettingsMenu,
                           logicKind: unlockLogicMenuItemKind,
                           selectedLogic: ble.unlockDeviceLogic.rawValue,
                           rssiKind: unlockRSSIMenuItemKind,
                           selectedRSSI: ble.unlockRSSI)
        updateSettingsMenu(lockSettingsMenu,
                           logicKind: lockLogicMenuItemKind,
                           selectedLogic: ble.lockDeviceLogic.rawValue,
                           rssiKind: lockRSSIMenuItemKind,
                           selectedRSSI: ble.lockRSSI)
        unlockSettingsMenu.update()
        lockSettingsMenu.update()
    }

    @discardableResult
    func addSettingsItem(_ menu: NSMenu, title: String, action: Selector, tag: Int, kind: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.tag = tag
        item.representedObject = kind
        return item
    }

    func constructRSSISection(_ menu: NSMenu, _ action: Selector, kind: String, disabledTag: Int, disabledFirst: Bool) {
        if disabledFirst {
            addSettingsItem(menu, title: t("disabled"), action: action, tag: disabledTag, kind: kind)
        }

        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            addSettingsItem(menu, title: String(format: "%ddBm", proximity), action: action, tag: proximity, kind: kind)
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")

        if !disabledFirst {
            addSettingsItem(menu, title: t("disabled"), action: action, tag: disabledTag, kind: kind)
        }

        menu.delegate = self
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        lockNowMenuItem = item
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        item.attributedTitle = deviceListAttributedTitle()
        item.submenu = deviceMenu
        deviceMenuItem = item
        deviceMenu.delegate = self
        // Hint at top (static, never reordered)
        let hint = NSMenuItem(title: t("pair_for_mac_hint"), action: #selector(openBluetoothSettings), keyEquivalent: "")
        hint.target = self
        hint.tag = 999
        hint.attributedTitle = NSAttributedString(
            string: t("pair_for_mac_hint"),
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        deviceMenu.addItem(hint)
        deviceMenu.addItem(NSMenuItem.separator())
        // "Scanning…" is now managed by performDeviceMenuReorder (placed below group separator)
        let scanItem = NSMenuItem(title: t("scanning"), action: nil, keyEquivalent: "")
        scanItem.isEnabled = false
        deviceMenu.addItem(scanItem)
        scanningMenuItem = scanItem

        let unlockSettingsItem = mainMenu.addItem(withTitle: t("unlock_settings"), action: nil, keyEquivalent: "")
        unlockSettingsItem.submenu = unlockSettingsMenu
        addSettingsItem(unlockSettingsMenu, title: t("any_short"), action: #selector(setUnlockDeviceLogic), tag: UnlockDeviceLogic.anyClose.rawValue, kind: unlockLogicMenuItemKind)
        addSettingsItem(unlockSettingsMenu, title: t("all_short"), action: #selector(setUnlockDeviceLogic), tag: UnlockDeviceLogic.allClose.rawValue, kind: unlockLogicMenuItemKind)
        unlockSettingsMenu.addItem(NSMenuItem.separator())
        constructRSSISection(unlockSettingsMenu,
                             #selector(setUnlockRSSI),
                             kind: unlockRSSIMenuItemKind,
                             disabledTag: ble.UNLOCK_DISABLED,
                             disabledFirst: true)

        let lockSettingsItem = mainMenu.addItem(withTitle: t("lock_settings"), action: nil, keyEquivalent: "")
        lockSettingsItem.submenu = lockSettingsMenu
        addSettingsItem(lockSettingsMenu, title: t("any_short"), action: #selector(setLockDeviceLogic), tag: LockDeviceLogic.anyAway.rawValue, kind: lockLogicMenuItemKind)
        addSettingsItem(lockSettingsMenu, title: t("all_short"), action: #selector(setLockDeviceLogic), tag: LockDeviceLogic.allAway.rawValue, kind: lockLogicMenuItemKind)
        lockSettingsMenu.addItem(NSMenuItem.separator())
        constructRSSISection(lockSettingsMenu,
                             #selector(setLockRSSI),
                             kind: lockRSSIMenuItemKind,
                             disabledTag: ble.LOCK_DISABLED,
                             disabledFirst: false)

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

        item = mainMenu.addItem(withTitle: NSLocalizedString("lock_on_signal_loss", value: "Lock When Signal Is Lost", comment: "Signal-loss locking option"),
                                action: #selector(toggleLockOnSignalLoss), keyEquivalent: "")
        item.state = ble.lockOnSignalLoss ? .on : .off
        item.toolTip = NSLocalizedString("lock_on_signal_loss_help", value: "Turn off for devices that stop advertising while asleep. A device that goes out of range without weak signals will then not trigger locking.", comment: "Signal-loss locking tradeoff")
        item = mainMenu.addItem(withTitle: NSLocalizedString("prevent_lock_while_active", value: "Prevent Locking While Mac Is in Use", comment: "Keyboard and mouse activity protection"),
                                action: #selector(togglePreventLockWhileActive), keyEquivalent: "")
        item.state = prefs.bool(forKey: "preventLockWhileActive") ? .on : .off

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        wakeOnProximityMenuItem = item
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }

        let wakeSettingsItem = mainMenu.addItem(withTitle: t("wake_settings"), action: nil, keyEquivalent: "")
        wakeSettingsItem.submenu = wakeSettingsMenu
        wakeSettingsMenu.delegate = self

        item = wakeSettingsMenu.addItem(withTitle: t("wake_without_unlocking"), action: #selector(toggleWakeWithoutUnlocking), keyEquivalent: "")
        wakeWithoutUnlockingMenuItem = item
        if prefs.bool(forKey: "wakeWithoutUnlocking") {
            item.state = .on
        }

        item = wakeSettingsMenu.addItem(withTitle: t("trigger_watch_unlock"), action: #selector(toggleTriggerWatchUnlock), keyEquivalent: "")
        triggerWatchUnlockMenuItem = item
        if prefs.bool(forKey: "triggerWatchUnlock") {
            item.state = .on
        }

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
        // Defer smd XPC to serial queue to avoid blocking main thread / concurrent smd calls.
        item.state = .off
        smdQueue.async { [weak self, weak item] in
            guard let self else { return }
            let enabled = self.isLaunchAtLoginEnabled()
            DispatchQueue.main.async { item?.state = enabled ? .on : .off }
        }
        
        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")
        let updateItem = mainMenu.addItem(withTitle: t("updates"), action: nil, keyEquivalent: "")
        updateMenuItem = updateItem
        updateItem.submenu = updateMenu
        item = updateMenu.addItem(withTitle: t("automatically_check_for_updates"), action: #selector(toggleAutomaticUpdateChecks), keyEquivalent: "")
        automaticUpdateChecksMenuItem = item
        item.state = automaticUpdateChecksEnabled() ? .on : .off
        checkForUpdatesMenuItem = updateMenu.addItem(withTitle: t("check_for_updates"), action: #selector(checkForUpdates),
                                                     keyEquivalent: "")
        refreshUpdateMenuItems()

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        mainMenu.delegate = self
        statusItem.menu = mainMenu
    }

    @discardableResult
    func checkAccessibility(showPrompt: Bool = true) -> Bool {
        let trusted: Bool
        if showPrompt {
            let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
            trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }
        if !trusted && showPrompt {
            // Sometimes Prompt option above doesn't work.
            // Actually trying to send key may open that dialog.
            let src = CGEventSource(stateID: .hidSystemState)
            // "Fn" key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
        if #available(macOS 10.15, *) {
            let canPostEvents = showPrompt ? CGRequestPostEventAccess() : CGPreflightPostEventAccess()
            return trusted && canPostEvents
        }
        return trusted
    }

    func requiresAccessibilityPermission() -> Bool {
        ble.unlockRSSI != ble.UNLOCK_DISABLED
            && (!prefs.bool(forKey: "wakeWithoutUnlocking") || prefs.bool(forKey: "triggerWatchUnlock"))
    }

    func refreshPermissionRecovery() {
        let accessibilityTrusted = !requiresAccessibilityPermission() || checkAccessibility(showPrompt: false)
        ble.recoverAfterPermissionChangeIfNeeded()
        guard !accessibilityTrusted || ble.needsPermissionRecovery else {
            let recovered = permissionRecoveryTimer != nil
            permissionRecoveryTimer?.invalidate()
            permissionRecoveryTimer = nil
            if recovered { tryUnlockScreen() }
            return
        }
        guard permissionRecoveryTimer == nil else { return }
        permissionRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { [weak self] _ in
            self?.refreshPermissionRecovery()
        })
        if let timer = permissionRecoveryTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func startPermissionRecovery(promptAccessibility: Bool) {
        if requiresAccessibilityPermission() {
            _ = checkAccessibility(showPrompt: promptAccessibility)
        }
        refreshPermissionRecovery()
    }

    func launcherBundleIdentifier() -> String {
        (Bundle.main.bundleIdentifier ?? currentAppBundleIdentifier) + launcherBundleIDSuffix
    }

    func disableLegacyLoginItem() {
        disableLegacyLoginItems()
        _ = SMLoginItemSetEnabled(launcherBundleIdentifier() as CFString, false)
    }

    func isLaunchAtLoginEnabled() -> Bool {
        return prefs.bool(forKey: "launchAtLogin")
    }

    // Clean up ALL legacy login items: old SMLoginItemSetEnabled entries
    // (both current and jp.sone bundle IDs) and old SMAppService.loginItem
    // registrations that used the Launcher helper instead of mainApp.
    func cleanupAllLegacyLoginItems() {
        let allLauncherIDs = legacyLauncherBundleIdentifiers() + [launcherBundleIdentifier()]
        for bid in allLauncherIDs {
            _ = SMLoginItemSetEnabled(bid as CFString, false)
        }
        if #available(macOS 13.0, *) {
            for bid in allLauncherIDs {
                let helperService = SMAppService.loginItem(identifier: bid)
                try? helperService.unregister()
            }
        }
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool, showErrors: Bool = true) -> Bool {
        if #available(macOS 13.0, *) {
            // Clean up legacy helper registrations when enabling
            if enabled {
                cleanupAllLegacyLoginItems()
            }
            // Use mainApp — registers the main app itself, no Launcher helper needed.
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                    // Clean up any leftover legacy registrations on disable too
                    cleanupAllLegacyLoginItems()
                }
                return true
            } catch {
                if showErrors {
                    errorModal("Failed to update Launch at Login", info: error.localizedDescription)
                } else {
                    print("Launch at Login update failed: \(error.localizedDescription)")
                }
                return false
            }
        }

        let ok = SMLoginItemSetEnabled(launcherBundleIdentifier() as CFString, enabled)
        if !ok && showErrors {
            errorModal("Failed to update Launch at Login")
        }
        return ok
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        migrateLegacyAppDataIfNeeded()
        if prefs.object(forKey: "lockOnSignalLoss") != nil {
            ble.lockOnSignalLoss = prefs.bool(forKey: "lockOnSignalLoss")
        }
        // Clean up all legacy login items and sync pref with actual registration state.
        smdQueue.async { [weak self] in
            guard let self = self else { return }
            self.cleanupAllLegacyLoginItems()
            if #available(macOS 13.0, *) {
                let status = SMAppService.mainApp.status
                let registered = (status == .enabled || status == .requiresApproval)
                if registered != self.prefs.bool(forKey: "launchAtLogin") {
                    self.prefs.set(registered, forKey: "launchAtLogin")
                }
            }
        }

        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        ble.delegate = self
        let monitoredUUIDs = loadMonitoredUUIDs()
        // Resolve MAC addresses for monitored devices at startup so cross-correlation works
        if !monitoredUUIDs.isEmpty {
            resolveMonitoredMACsOnStartup(uuids: monitoredUUIDs)
        }
        if !monitoredUUIDs.isEmpty {
            monitorDevices(uuids: monitoredUUIDs)
        }
        if prefs.object(forKey: "unlockDeviceLogic") != nil,
           let logic = UnlockDeviceLogic(rawValue: prefs.integer(forKey: "unlockDeviceLogic")) {
            ble.unlockDeviceLogic = logic
        } else if prefs.object(forKey: "multiDeviceLogic") != nil,
                  let legacyLogic = UnlockDeviceLogic(rawValue: prefs.integer(forKey: "multiDeviceLogic")) {
            ble.unlockDeviceLogic = legacyLogic
        }
        if prefs.object(forKey: "lockDeviceLogic") != nil,
           let logic = LockDeviceLogic(rawValue: prefs.integer(forKey: "lockDeviceLogic")) {
            ble.lockDeviceLogic = logic
        } else if prefs.object(forKey: "multiDeviceLogic") != nil {
            let legacyValue = prefs.integer(forKey: "multiDeviceLogic")
            ble.lockDeviceLogic = legacyValue == 0 ? .allAway : .anyAway
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

        if #available(macOS 10.14, *) {
            let notificationCenter = UNUserNotificationCenter.current()
            notificationCenter.delegate = self
            requestNotificationAuthorization()
        } else {
            NSUserNotificationCenter.default.delegate = self
        }

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        if ble.unlockRSSI != ble.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && fetchPassword() == nil {
            askPassword()
        }
        if prefs.bool(forKey: "launchAtLogin") {
            // setLaunchAtLogin may block on smd XPC; use serial queue to avoid concurrent smd calls.
            smdQueue.async { [weak self] in
                _ = self?.setLaunchAtLogin(true, showErrors: false)
            }
        }
        startPermissionRecovery(promptAccessibility: true)
        runAutomaticUpdateCheck()
        if prefs.bool(forKey: "pauseItunes") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.requestAutomationPermissionsIfNeeded()
            }
        }

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionRecovery()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        cancelAutomaticLockChecks()
        permissionRecoveryTimer?.invalidate()
        permissionRecoveryTimer = nil
    }
}
