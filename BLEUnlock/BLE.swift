import Foundation
import CoreBluetooth
import IOBluetooth

func macInheritLog(_ message: String) {}


let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

func nameResolutionLogURL() -> URL? {
    let fileManager = FileManager.default
    guard let logsDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("BLEUnlock", isDirectory: true) else {
        return nil
    }

    do {
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    } catch {
        return nil
    }

    return logsDirectory.appendingPathComponent("name-resolution.log", isDirectory: false)
}

func appendNameResolutionLog(_ message: String) {}

// MARK: - Cached system lookups (avoid redundant disk I/O)

var _cachedBTPlists: (timestamp: TimeInterval, plist: NSDictionary?, ledevices: [String: NSDictionary])?
let _btPlistCacheTTL: TimeInterval = 30

private func cachedBTResources() -> (plist: NSDictionary?, ledevices: [String: NSDictionary]) {
    let now = Date().timeIntervalSince1970
    if let cache = _cachedBTPlists, now - cache.timestamp < _btPlistCacheTTL {
        return (cache.plist, cache.ledevices)
    }
    let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist")
    var ledevices: [String: NSDictionary] = [:]
    if let coreCache = plist?["CoreBluetoothCache"] as? NSDictionary {
        for (key, value) in coreCache {
            if let k = key as? String, let v = value as? NSDictionary {
                ledevices[k] = v
            }
        }
    }
    _cachedBTPlists = (now, plist, ledevices)
    return (plist, ledevices)
}

private func flushBTPlistsCache() {
    _cachedBTPlists = nil
}

func getMACFromUUID(_ uuid: String) -> String? {
    let (_, ledevices) = cachedBTResources()
    guard let device = ledevices[uuid] else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    let (plist, _) = cachedBTResources()
    guard let devcache = plist?["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}


/// Cross-reference a newly discovered device against known devices via MAC address.
/// Normalize a MAC address string to canonical form: lowercase with dashes.
func canonicalMAC(_ mac: String) -> String {
    var s = mac.lowercased()
    s = s.replacingOccurrences(of: ":", with: "-")
    s = s.replacingOccurrences(of: ".", with: "-")
    while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func findKnownDeviceByMAC(newMAC: String?, knownDevices: [UUID: Device]) -> Device? {
    guard let newMAC = newMAC else { return nil }
    let normalized = canonicalMAC(newMAC)
    // print("[BLEUnlock][MACInherit] findKnownDeviceByMAC: searching for normalized=\(normalized) in \(knownDevices.count) devices")
    for (_, device) in knownDevices {
        if let knownMAC = device.macAddr, canonicalMAC(knownMAC) == normalized {
            macInheritLog(" findKnownDeviceByMAC: MATCH \(normalized) via device.macAddr -> uuid=\(device.uuid.uuidString)")
            return device
        }
        if let knownInfo = getLEDeviceInfoFromUUID(device.uuid.uuidString),
           let knownMAC2 = knownInfo.macAddr,
           canonicalMAC(knownMAC2) == normalized {
            macInheritLog(" findKnownDeviceByMAC: MATCH \(normalized) via LE-db -> uuid=\(device.uuid.uuidString)")
            return device
        }
    }
    macInheritLog(" findKnownDeviceByMAC: NO MATCH for \(normalized)")
    return nil
}

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var isVisible = false
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    var advertisedLocalName: String?
    var lastNameDebugSnapshot: String?
    /// Timestamp of last MAC resolution attempt; used to throttle redundant lookups.
    var lastMACLookupTime: TimeInterval = 0

    func normalizedName(_ candidate: String?) -> String? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespaces), !candidate.isEmpty else { return nil }
        return candidate
    }

    func looksLikeTemporaryBroadcastName(_ candidate: String) -> Bool {
        if candidate == "N/A" {
            return true
        }
        if candidate.count >= 12 && candidate.contains("/") && !candidate.contains(" ") {
            return true
        }

        if candidate.count < 16 {
            return false
        }

        let hasUpper = candidate.rangeOfCharacter(from: .uppercaseLetters) != nil
        let hasLower = candidate.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasDigit = candidate.rangeOfCharacter(from: .decimalDigits) != nil
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/"))
        let onlySimpleCharacters = candidate.rangeOfCharacter(from: allowed.inverted) == nil
        return onlySimpleCharacters && ((hasUpper && hasLower) || (hasUpper && hasDigit) || (hasLower && hasDigit))
    }

    func isGenericAppleName(_ name: String) -> Bool {
        name == "iPhone" || name == "iPad"
    }

    func updateNameIfNeeded(_ candidate: String?) {
        guard let candidate = normalizedName(candidate) else { return }
        if blName == nil || blName == uuid.description {
            blName = candidate
        }
    }

    func updateAdvertisedNameIfNeeded(_ candidate: String?) {
        guard let candidate = normalizedName(candidate) else { return }
        if looksLikeTemporaryBroadcastName(candidate),
           let peripheralName = normalizedName(peripheral?.name),
           peripheralName != candidate {
            return
        }
        updateNameIfNeeded(candidate)
    }

    func currentResolvedName() -> String? {
        let peripheralName = normalizedName(peripheral?.name)
        if let cachedName = normalizedName(blName),
           looksLikeTemporaryBroadcastName(cachedName),
           let peripheralName,
           peripheralName != cachedName {
            blName = peripheralName
            return peripheralName
        }

        if let name = normalizedName(blName) {
            return name
        }

        if let name = peripheralName {
            blName = name
            return name
        }

        if let manu = manufacture {
            if let mod = model {
                if manu == "Apple Inc.", let appleName = appleDeviceNames[mod] {
                    return appleName
                }
                return String(format: "%@/%@", manu, mod)
            } else {
                return manu
            }
        }

        if let mod = model {
            return mod
        }

        // Throttle IOBluetooth lookups: only retry after cooldown
        let now = Date().timeIntervalSince1970
        if (macAddr == nil || blName == nil), now - lastMACLookupTime >= 5.0 {
            lastMACLookupTime = now
            if let info = getLEDeviceInfoFromUUID(uuid.description) {
                updateNameIfNeeded(info.name)
                macAddr = macAddr ?? info.macAddr
            }
            if macAddr == nil {
                macAddr = getMACFromUUID(uuid.description)
            }
        }

        if let mac = macAddr, blName == nil {
            blName = getNameFromMAC(mac)
        }

        if let adv = advData, adv.count >= 25 {
            var iBeaconPrefix : [uint16] = [0x004c, 0x0215]
            if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                let major = uint16(adv[20]) << 8 | uint16(adv[21])
                let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                let tx = Int8(bitPattern: adv[24])
                let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                let d = String(format:"%.1f", distance)
                return "iBeacon [\(major), \(minor)] \(d)m"
            }
        }

        if let name = blName {
            return name
        }

        if let mac = macAddr {
            return mac
        }

        return nil
    }

    func logNameResolutionIfNeeded(context: String) {
        let peripheralName = normalizedName(peripheral?.name)
        let leInfo = getLEDeviceInfoFromUUID(uuid.description)
        let leName = normalizedName(leInfo?.name)
        let leMac = leInfo?.macAddr
        let plistMac = getMACFromUUID(uuid.description)
        let plistName = normalizedName((plistMac ?? macAddr).flatMap(getNameFromMAC))
        let resolvedName = currentResolvedName()

        let finalSource: String
        if normalizedName(advertisedLocalName) != nil {
            finalSource = "advertisementData.localName"
        } else if peripheralName != nil {
            finalSource = "CBPeripheral.name"
        } else if manufacture != nil || model != nil {
            finalSource = "Device Information service"
        } else if leName != nil {
            finalSource = "Bluetooth database"
        } else if plistName != nil {
            finalSource = "Bluetooth plist cache"
        } else if resolvedName?.hasPrefix("iBeacon [") == true {
            finalSource = "iBeacon manufacturer data"
        } else if leMac != nil || plistMac != nil || macAddr != nil {
            finalSource = "MAC address only"
        } else {
            finalSource = "UUID fallback"
        }

        let snapshot = [
            "uuid=\(uuid!.uuidString)",
            "context=\(context)",
            "rssi=\(rssi)",
            "advLocalName=\(advertisedLocalName ?? "<nil>")",
            "peripheralName=\(peripheralName ?? "<nil>")",
            "manufacturer=\(manufacture ?? "<nil>")",
            "model=\(model ?? "<nil>")",
            "dbName=\(leName ?? "<nil>")",
            "dbMac=\(leMac ?? "<nil>")",
            "plistMac=\(plistMac ?? "<nil>")",
            "plistName=\(plistName ?? "<nil>")",
            "finalSource=\(finalSource)",
            "finalValue=\(resolvedName ?? uuid.uuidString)"
        ].joined(separator: " | ")

        guard snapshot != lastNameDebugSnapshot else { return }
        lastNameDebugSnapshot = snapshot
        let message = "[BLEUnlock][NameResolution] \(snapshot)"
        NSLog("%@", message)
        appendNameResolutionLog(message)
    }
    
    override var description: String {
        get {
            return currentResolvedName() ?? uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func replaceMonitoredDevice(oldUUID: UUID, with newDevice: Device)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(shouldUnlock: Bool, shouldLock: Bool, reason: String, device: UUID?)
    func bluetoothPowerWarn()
}

enum UnlockDeviceLogic: Int {
    case anyClose = 0
    case allClose = 1
}

enum LockDeviceLogic: Int {
    case allAway = 0
    case anyAway = 1
}

class MonitoredDeviceState {
    let uuid: UUID
    weak var peripheral: CBPeripheral?
    var proximityTimer: Timer?
    var signalTimer: Timer?
    var rssiWindow: [Int] = []
    var lastReadAt = 0.0
    var activeModeTimer: Timer?
    var connectionTimer: Timer?
    var presence = true
    var lastRSSI: Int?

    init(uuid: UUID) {
        self.uuid = uuid
    }

    var active: Bool {
        activeModeTimer != nil
    }

    func invalidateTimers() {
        proximityTimer?.invalidate()
        signalTimer?.invalidate()
        activeModeTimer?.invalidate()
        connectionTimer?.invalidate()
        proximityTimer = nil
        signalTimer = nil
        activeModeTimer = nil
        connectionTimer = nil
    }
}

/// Cached paired device list for IOBluetooth MAC resolution.
/// Refreshed lazily to avoid querying system daemon on every BLE discovery.
var cachedPairedDevices: [(name: String, address: String, hasDeviceClass: Bool)]?
var cachedPairedDevicesTimestamp: TimeInterval = 0
let pairedDevicesCacheTTL: TimeInterval = 30

func refreshPairedDevicesCache() {
    let now = Date().timeIntervalSince1970
    guard now - cachedPairedDevicesTimestamp > pairedDevicesCacheTTL else { return }
    cachedPairedDevicesTimestamp = now
    guard let paired = IOBluetoothDevice.pairedDevices() else {
        cachedPairedDevices = nil
        return
    }
    cachedPairedDevices = paired.compactMap { d in
        guard let dev = d as? IOBluetoothDevice,
              let name = dev.name,
              let addr = dev.addressString else { return nil }
        let hasClass = dev.deviceClassMajor != 0 || dev.deviceClassMinor != 0
        return (name: name, address: addr, hasDeviceClass: hasClass)
    }
}

func resolveMACForDeviceName(_ name: String) -> String? {
    refreshPairedDevicesCache()
    guard let devices = cachedPairedDevices else { return nil }
    // Collect all name matches
    let matches = devices.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    if matches.isEmpty { return nil }
    if matches.count == 1 { return matches[0].address }
    // Ambiguous: prefer the entry with a device class (classic Bluetooth paired device)
    // over BLE-only entries which typically have no device class.
    if let classic = matches.first(where: { $0.hasDeviceClass }) {
        return classic.address
    }
    // All are BLE-only — return the first
    return matches[0].address
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var monitoredUUIDs: Set<UUID> = [] {
        didSet {
            macInheritLog("monitoredUUIDs changed: oldCount=\(oldValue.count) newCount=\(monitoredUUIDs.count) uuids=\(monitoredUUIDs.map(\.uuidString).sorted().joined(separator: ", "))")
        }
    }
    var monitoredStates: [UUID: MonitoredDeviceState] = [:]

    // MARK: GATT info-connect throttle
    // Only one GATT device-info connection at a time to avoid BT resource
    // contention. The gate is released by real connection lifecycle events
    // (didConnect/didFailToConnect/didDisconnect) with a watchdog backstop.
    struct GATTInfoRecord {
        var backoffUntil: TimeInterval = 0
        var resolved = false
    }
    var gattInfoState: [UUID: GATTInfoRecord] = [:]
    var gattInfoConnectInProgress = false
    var currentGATTInfoPeripheralUUID: UUID?
    var gattInfoConnectQueue: [UUID] = []
    var gattInfoWatchdogTimer: Timer?
    var gattInfoReadsPending = 0
    let gattInfoConnectTimeout: TimeInterval = 12
    let gattInfoConnectQueueMax = 10

    /// Remap monitored UUID when a physical device's UUID rotates (e.g. privacy rotation).
    /// Transfers monitoredState to the new peripheral and persists the updated set.
    @discardableResult
    func remapMonitoredUUID(from oldUUID: UUID, to newUUID: UUID, peripheral: CBPeripheral?) -> Bool {
        guard isMonitoring(uuid: oldUUID) else { return false }
        // Only remap when the old UUID is no longer visible — if it's still
        // being detected, keep tracking it to prevent flip-flop.
        guard let dev = devices[oldUUID], !dev.isVisible else { return false }
        var updatedUUIDs = monitoredUUIDs
        updatedUUIDs.remove(oldUUID)
        updatedUUIDs.insert(newUUID)
        if let oldState = monitoredStates.removeValue(forKey: oldUUID), let p = peripheral {
            oldState.peripheral = p
            monitoredStates[newUUID] = oldState
        }
        monitoredUUIDs = updatedUUIDs
        UserDefaults.standard.set(monitoredUUIDs.map { $0.uuidString }, forKey: "devices")
        macInheritLog(" remapMonitoredUUID: \(oldUUID) -> \(newUUID)")
        print("Remapped monitoring from \(oldUUID) to \(newUUID)")
        return true
    }


    var presence = false
    var shouldLock = false
    var unlockDeviceLogic: UnlockDeviceLogic = .anyClose
    var lockDeviceLogic: LockDeviceLogic = .allAway
    var lockRSSI = -80
    var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var lastAuthorizationRefreshAt = 0.0
    let minimumAuthorizationRefreshInterval = 2.0
    var monitoringSuspended = false

    var needsPermissionRecovery: Bool {
        guard scanMode || !monitoredUUIDs.isEmpty else { return false }
        switch centralMgr.state {
        case .unauthorized, .unknown, .resetting:
            return true
        default:
            return false
        }
    }

    func recoverAfterPermissionChangeIfNeeded() {
        guard !monitoringSuspended else { return }
        if centralMgr.state == .poweredOn {
            scanForPeripherals()
            return
        }
        guard needsPermissionRecovery else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAuthorizationRefreshAt >= minimumAuthorizationRefreshInterval else { return }
        lastAuthorizationRefreshAt = now
        print("Refreshing Bluetooth authorization state")
        centralMgr.stopScan()
        centralMgr.delegate = nil
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }

    func scanForPeripherals() {
        guard !monitoringSuspended else { return }
        guard !centralMgr.isScanning else { return }
        guard centralMgr.state == .poweredOn else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //print("Start scanning")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        // Keep scanMode true when devices are monitored so UUID rotations
        // are still detected during background/locked-screen operation.
        if !monitoredUUIDs.isEmpty { return }
        scanMode = false
        resetGATTInfoConnectState()
        if monitoredStates.values.contains(where: { $0.active }) {
            centralMgr.stopScan()
        }
    }

    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        if passiveMode {
            for state in monitoredStates.values {
                state.activeModeTimer?.invalidate()
                state.activeModeTimer = nil
                state.connectionTimer?.invalidate()
                state.connectionTimer = nil
                if let p = state.peripheral {
                    centralMgr.cancelPeripheralConnection(p)
                }
            }
        }
        scanForPeripherals()
    }

    func suspendMonitoringForSystemSleep() {
        guard !monitoringSuspended else { return }
        monitoringSuspended = true
        resetGATTInfoConnectState()
        centralMgr.stopScan()

        for state in monitoredStates.values {
            state.invalidateTimers()
            state.lastRSSI = nil
            state.lastReadAt = 0
            state.rssiWindow.removeAll()
            state.presence = false
            if let peripheral = state.peripheral, peripheral.state != .disconnected {
                centralMgr.cancelPeripheralConnection(peripheral)
            }
        }

        for device in devices.values {
            device.scanTimer?.invalidate()
            device.scanTimer = nil
            device.isVisible = false
            if !isMonitoring(uuid: device.uuid),
               let peripheral = device.peripheral,
               peripheral.state != .disconnected {
                centralMgr.cancelPeripheralConnection(peripheral)
            }
        }

        presence = false
        shouldLock = false
        updateAggregateRSSI()
    }

    func resumeMonitoringAfterSystemWake() {
        guard monitoringSuspended else { return }
        monitoringSuspended = false
        guard scanMode || !monitoredUUIDs.isEmpty else { return }
        scanForPeripherals()
    }

    func isMonitoring(uuid: UUID) -> Bool {
        monitoredUUIDs.contains(uuid)
    }

    func stopMonitoring(_ state: MonitoredDeviceState) {
        state.invalidateTimers()
        if let p = state.peripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
    }

    func startMonitor(uuid: UUID) {
        startMonitor(uuids: Set([uuid]))
    }

    func startMonitor(uuids: Set<UUID>) {
        let removed = monitoredUUIDs.subtracting(uuids)
        for uuid in removed {
            if let state = monitoredStates.removeValue(forKey: uuid) {
                stopMonitoring(state)
            }
        }

        monitoredUUIDs = uuids
        for uuid in uuids {
            let state = monitoredStates[uuid] ?? MonitoredDeviceState(uuid: uuid)
            state.presence = true
            state.rssiWindow.removeAll()
            state.proximityTimer?.invalidate()
            state.proximityTimer = nil

            if let device = devices[uuid] {
                state.peripheral = device.peripheral ?? state.peripheral
                                state.lastRSSI = device.rssi < 0 ? device.rssi : nil
                                state.rssiWindow = device.rssi < 0 ? [device.rssi] : []
            } else {
                state.lastRSSI = nil
            }

            monitoredStates[uuid] = state
            resetSignalTimer(for: state)
        }

        presence = !uuids.isEmpty
        shouldLock = false
        updateAggregateRSSI()
        if !uuids.isEmpty {
            scanMode = true
        }
        scanForPeripherals()
    }

    func setUnlockDeviceLogic(_ logic: UnlockDeviceLogic) {
        unlockDeviceLogic = logic
        updateAggregatePresence(reason: "logic")
    }

    func setLockDeviceLogic(_ logic: LockDeviceLogic) {
        lockDeviceLogic = logic
        updateAggregatePresence(reason: "logic")
    }

    func updateAggregatePresence(reason: String, device: UUID? = nil, notify: Bool = true) {
        let states = monitoredUUIDs.compactMap { monitoredStates[$0] }
        let newPresence: Bool
        let newShouldLock: Bool
        if states.isEmpty {
            newPresence = false
            newShouldLock = false
        } else {
            switch unlockDeviceLogic {
            case .anyClose:
                newPresence = states.contains(where: { $0.presence })
            case .allClose:
                newPresence = states.allSatisfy { $0.presence }
            }
            switch lockDeviceLogic {
            case .allAway:
                newShouldLock = states.allSatisfy { !$0.presence }
            case .anyAway:
                newShouldLock = states.contains(where: { !$0.presence })
            }
        }
        guard newPresence != presence || newShouldLock != shouldLock else { return }
        presence = newPresence
        shouldLock = newShouldLock
        if notify {
            delegate?.updatePresence(shouldUnlock: newPresence, shouldLock: newShouldLock, reason: reason, device: device)
        }
    }

    func updateAggregateRSSI() {
        let visibleStates = monitoredStates.values.filter { $0.lastRSSI != nil }
        let bestRSSI = visibleStates.compactMap(\.lastRSSI).max()
        let active = visibleStates.contains(where: { $0.active })
        delegate?.updateRSSI(rssi: bestRSSI, active: active)
    }

    func resetSignalTimer(for state: MonitoredDeviceState) {
        state.signalTimer?.invalidate()
        state.signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { [weak self, weak state] _ in
            guard let self = self, let state = state else { return }
            print("Device \(state.uuid) is lost")
            state.lastRSSI = nil
            state.activeModeTimer?.invalidate()
            state.activeModeTimer = nil
            state.connectionTimer?.invalidate()
            state.connectionTimer = nil
            state.rssiWindow.removeAll()
            self.updateAggregateRSSI()
            if state.presence {
                state.presence = false
                self.updateAggregatePresence(reason: "lost", device: state.uuid)
            }
        })
        if let timer = state.signalTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            lastAuthorizationRefreshAt = 0
            if !monitoringSuspended && !monitoredStates.values.contains(where: { $0.active }) {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
            print("Bluetooth powered off")
            lastAuthorizationRefreshAt = 0
            for state in monitoredStates.values {
                state.invalidateTimers()
                state.lastRSSI = nil
                state.rssiWindow.removeAll()
                state.presence = false
            }
            presence = false
            shouldLock = false
            updateAggregateRSSI()
            if powerWarn {
                powerWarn = false
                delegate?.bluetoothPowerWarn()
            }
        default:
            break
        }
    }
    
    /// Median-of-5 filter: maintains a sliding window of the 3 most recent raw RSSI
    /// values and outputs the median. Single outliers (±20 dBm spikes) are completely
    /// eliminated, while real trends track within 2 samples.
    func getEstimatedRSSI(state: MonitoredDeviceState, rssi: Int) -> Int {
        // Ignore invalid readings that would corrupt the median window
        guard rssi < 0 else { return state.lastRSSI ?? rssi }
        state.rssiWindow.append(rssi)
        if state.rssiWindow.count > 5 {
            state.rssiWindow.removeFirst()
        }
        let sorted = state.rssiWindow.sorted()
        return sorted[state.rssiWindow.count / 2]
    }

    func updateMonitoredState(_ state: MonitoredDeviceState, rssi: Int) {
        if rssi >= (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) && !state.presence {
            print("Device \(state.uuid) is close")
            state.presence = true
            state.rssiWindow.removeAll()
            updateAggregatePresence(reason: "close", device: state.uuid)
        }

        let estimatedRSSI = getEstimatedRSSI(state: state, rssi: rssi)
        state.lastRSSI = estimatedRSSI
        updateAggregateRSSI()

        if estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) {
            if let timer = state.proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled for \(state.uuid)")
                state.proximityTimer = nil
            }
        } else if state.presence && state.proximityTimer == nil {
            state.proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { [weak self, weak state] _ in
                guard let self = self, let state = state else { return }
                print("Device \(state.uuid) is away")
                state.presence = false
                self.updateAggregatePresence(reason: "away", device: state.uuid)
                state.proximityTimer = nil
            })
            if let timer = state.proximityTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
            print("Proximity timer started for \(state.uuid)")
        }
        resetSignalTimer(for: state)
    }

    func monitoredState(for peripheral: CBPeripheral) -> MonitoredDeviceState? {
        monitoredStates[peripheral.identifier]
    }
    /// Check if GATT connection for device-info is warranted — only connect if
    /// the device is monitored itself or its name/MAC matches a monitored
    /// device (rotation evidence), to avoid BT audio interference.
    func shouldGATTConnectForInfo(_ device: Device) -> Bool {
        guard device.manufacture == nil, device.model == nil else { return false }
        if let record = gattInfoState[device.uuid] {
            if record.resolved { return false }
            if record.backoffUntil > Date().timeIntervalSince1970 { return false }
        }
        return gattInfoScopeMatch(device)
    }

    /// Scope filter: monitored itself, or name/MAC matches a monitored device.
    private func gattInfoScopeMatch(_ device: Device) -> Bool {
        if isMonitoring(uuid: device.uuid) { return true }
        if let name = device.currentResolvedName(), !name.isEmpty {
            return devices.contains { isMonitoring(uuid: $0.key) && $0.value.currentResolvedName() == name }
        }
        if let mac = device.macAddr {
            return devices.contains { isMonitoring(uuid: $0.key) && $0.value.macAddr == mac }
        }
        return false
    }

    /// Throttled GATT connect for device-info: one at a time, rest enqueued.
    /// The gate is released by lifecycle events; a watchdog bounds each attempt.
    func tryGATTConnectForInfo(_ peripheral: CBPeripheral) {
        guard let device = devices[peripheral.identifier] else { return }
        guard shouldGATTConnectForInfo(device) else { return }
        // Already connected/connecting: info discovery piggybacks on that
        // connection (didConnect -> discoverServices), no extra connect needed.
        guard peripheral.state == .disconnected else { return }
        guard currentGATTInfoPeripheralUUID != peripheral.identifier,
              !gattInfoConnectQueue.contains(peripheral.identifier) else { return }
        guard gattInfoConnectQueue.count < gattInfoConnectQueueMax else { return }
        gattInfoConnectQueue.append(peripheral.identifier)
        if !gattInfoConnectInProgress {
            popNextGATTInfoConnect()
        }
    }

    private func startGATTInfoConnect(_ peripheral: CBPeripheral) {
        guard !monitoringSuspended, centralMgr.state == .poweredOn else {
            gattInfoConnectQueue.removeAll { $0 == peripheral.identifier }
            return
        }
        gattInfoConnectInProgress = true
        currentGATTInfoPeripheralUUID = peripheral.identifier
        gattInfoReadsPending = 0
        if gattInfoState[peripheral.identifier] == nil {
            gattInfoState[peripheral.identifier] = GATTInfoRecord()
        }
        centralMgr.connect(peripheral, options: nil)

        gattInfoWatchdogTimer?.invalidate()
        gattInfoWatchdogTimer = Timer.scheduledTimer(withTimeInterval: gattInfoConnectTimeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            guard self.gattInfoConnectInProgress,
                  self.currentGATTInfoPeripheralUUID == peripheral.identifier else { return }
            self.centralMgr.cancelPeripheralConnection(peripheral)
            self.finishGATTInfoConnect(peripheral, outcome: .timeout)
        })
        if let timer = gattInfoWatchdogTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func popNextGATTInfoConnect() {
        guard !gattInfoConnectInProgress else { return }
        while !gattInfoConnectQueue.isEmpty {
            let uuid = gattInfoConnectQueue.removeFirst()
            guard let device = devices[uuid], device.isVisible,
                  let peripheral = device.peripheral, peripheral.state == .disconnected else {
                continue  // stale/connected entry - skip
            }
            startGATTInfoConnect(peripheral)
            return
        }
    }

    private enum GATTInfoOutcome {
        case success, noService, readError, failed, disconnected, timeout
    }

    private func finishGATTInfoConnect(_ peripheral: CBPeripheral, outcome: GATTInfoOutcome) {
        guard gattInfoConnectInProgress, currentGATTInfoPeripheralUUID == peripheral.identifier else { return }
        gattInfoWatchdogTimer?.invalidate()
        gattInfoWatchdogTimer = nil
        gattInfoReadsPending = 0

        let now = Date().timeIntervalSince1970
        var record = gattInfoState[peripheral.identifier] ?? GATTInfoRecord()
        switch outcome {
        case .success:
            record.resolved = true
        case .noService:
            record.backoffUntil = now + 900
        case .readError:
            record.backoffUntil = now + 300
        case .failed, .disconnected, .timeout:
            record.backoffUntil = now + 60
        }
        gattInfoState[peripheral.identifier] = record

        gattInfoConnectInProgress = false
        currentGATTInfoPeripheralUUID = nil
        popNextGATTInfoConnect()
    }

    /// Clear queue/gate on shutdown paths (system sleep, scan teardown).
    func resetGATTInfoConnectState() {
        gattInfoConnectQueue.removeAll()
        gattInfoWatchdogTimer?.invalidate()
        gattInfoWatchdogTimer = nil
        gattInfoReadsPending = 0
        if gattInfoConnectInProgress, let uuid = currentGATTInfoPeripheralUUID,
           let peripheral = devices[uuid]?.peripheral {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
        gattInfoConnectInProgress = false
        currentGATTInfoPeripheralUUID = nil
    }


    func connectMonitoredPeripheral(_ state: MonitoredDeviceState) {
        guard let p = state.peripheral else { return }
        guard !monitoringSuspended else { return }
        guard centralMgr.state == .poweredOn else { return }

        if p.state == .connected {
            p.delegate = self
            p.readRSSI()
            return
        }

        guard p.state == .disconnected else { return }
        print("Connecting \(state.uuid)")
        centralMgr.connect(p, options: nil)
        state.connectionTimer?.invalidate()
        state.connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { [weak self, weak state, weak p] _ in
            guard let self = self, let state = state, let p = p else { return }
            if p.state == .connecting {
                print("Connection timeout \(state.uuid)")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        })
        if let timer = state.connectionTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { [weak self, weak device] _ in
            guard let self = self, let device = device else { return }
            device.isVisible = false
            DispatchQueue.main.async { [weak self] in self?.delegate?.removeDevice(device: device) }
            if let p = device.peripheral, !self.isMonitoring(uuid: device.uuid) {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            if !self.isMonitoring(uuid: device.uuid) {
                self.devices.removeValue(forKey: device.uuid)
                self.gattInfoState.removeValue(forKey: device.uuid)
            }
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    //MARK:- CBCentralManagerDelegate start

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue >= 0 ? -100 : RSSI.intValue
        if let state = monitoredStates[peripheral.identifier], !monitoringSuspended {
            state.peripheral = peripheral
            updateMonitoredState(state, rssi: rssi)
            if !state.active && !passiveMode {
                connectMonitoredPeripheral(state)
            }
        }

        if (scanMode) {
            if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //print("Device \(peripheral.identifier) Exposure Notification")
                        return
                    }
                }
            }
            let dev = devices[peripheral.identifier]
            var device: Device!
            let shouldTrackDiscoveredDevice = rssi >= thresholdRSSI || isMonitoring(uuid: peripheral.identifier)
            if (dev == nil) {
                // Build minimal device to resolve its name from all available sources
                let probe = Device(uuid: peripheral.identifier)
                probe.peripheral = peripheral
                probe.manufacture = nil  // will be populated on connect
                probe.model = nil
                // Resolve MAC from advertisement local name, peripheral name, or IOBluetooth
                var resolvedMAC: String?
                if let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                   let mac = resolveMACForDeviceName(advName.trimmingCharacters(in: .whitespaces)) {
                    resolvedMAC = mac
                }
                if resolvedMAC == nil, let pn = peripheral.name?.trimmingCharacters(in: .whitespaces), !pn.isEmpty {
                    resolvedMAC = resolveMACForDeviceName(pn)
                }
                if resolvedMAC == nil, let info = getLEDeviceInfoFromUUID(peripheral.identifier.uuidString) {
                    resolvedMAC = info.macAddr
                }
                if resolvedMAC == nil {
                    macInheritLog(" BLE-discover: uuid=\(peripheral.identifier.uuidString) NO MAC resolved")
                } else {
                    macInheritLog(" BLE-discover: uuid=\(peripheral.identifier.uuidString) resolvedMAC=\(resolvedMAC!) deviceCount=\(devices.count)")
                }
                var mergedViaMAC = false
                if let resolvedMAC = resolvedMAC, let matchedDevice = findKnownDeviceByMAC(newMAC: resolvedMAC, knownDevices: devices) {
                    // If old UUID is still visible and monitored, skip merge — retry later
                    // when it goes invisible so remapMonitoredUUID can succeed.
                    // Premature merge breaks future remap: old UUID gets removed from
                    // devices before remap can fire, making it permanently orphaned.
                    if isMonitoring(uuid: matchedDevice.uuid) && matchedDevice.isVisible {
                        macInheritLog(" Merge-deferred(skip): old-uuid=\(matchedDevice.uuid.uuidString) still visible, new-uuid=\(peripheral.identifier.uuidString)")
                        print("MAC correlation deferred (old still visible): \(matchedDevice.uuid) → \(peripheral.identifier) — skipping")
                        // Old UUID still visible, skip entirely. Don't cache new UUID
                        // in devices — that would create a duplicate MAC entry that
                        // findKnownDeviceByMAC might return first (breaking remap).
                        mergedViaMAC = true
                    } else {
                        // Same physical device — merge: replace old entry with new UUID
                        device = Device(uuid: peripheral.identifier)
                        device.peripheral = peripheral
                        device.rssi = rssi
                        device.isVisible = true
                        device.macAddr = matchedDevice.macAddr ?? resolvedMAC
                        device.blName = matchedDevice.blName
                        print("MAC correlation: merged UUID \(matchedDevice.uuid) → \(peripheral.identifier)")
                        
                        // Remap monitoring if needed
                        let didRemap = remapMonitoredUUID(from: matchedDevice.uuid, to: peripheral.identifier, peripheral: peripheral)
                        
                        // Remove old UUID and add new via merge (preserves menu order)
                        devices.removeValue(forKey: matchedDevice.uuid)
                        devices[peripheral.identifier] = device
                        mergedViaMAC = true
                        if didRemap {
                            delegate?.replaceMonitoredDevice(oldUUID: matchedDevice.uuid, with: device)
                        } else {
                            let oldDevice = Device(uuid: matchedDevice.uuid)
                            oldDevice.blName = matchedDevice.blName
                            oldDevice.macAddr = matchedDevice.macAddr
                            let oldUUID = matchedDevice.uuid
                            DispatchQueue.main.async { [weak self] in
                                self?.delegate?.removeDevice(device: oldDevice)
                                self?.delegate?.newDevice(device: device)
                            }
                        }
                        
                        tryGATTConnectForInfo(peripheral)
                        device.logNameResolutionIfNeeded(context: "discover:merged")
                    }
                }
                if !mergedViaMAC, shouldTrackDiscoveredDevice {
                    device = Device(uuid: peripheral.identifier)
                    device.peripheral = peripheral
                    device.rssi = rssi
                    device.isVisible = true
                    device.advData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
                    device.advertisedLocalName = device.normalizedName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                    device.updateAdvertisedNameIfNeeded(device.advertisedLocalName)
                    
                    // IOBluetooth MAC resolution for paired devices
                    if device.macAddr == nil, let name = device.currentResolvedName() {
                        device.macAddr = resolveMACForDeviceName(name)
                    }
                    
                    devices[peripheral.identifier] = device
                    tryGATTConnectForInfo(peripheral)
                    
                    // Post-hoc MAC correlation: check again now that device.macAddr is set
                    if let mac = device.macAddr, let matched = findKnownDeviceByMAC(newMAC: mac, knownDevices: devices.filter { $0.key != peripheral.identifier }) {
                        // Defer if old UUID still visible and monitored (same logic as discover:merged)
                        if isMonitoring(uuid: matched.uuid) && matched.isVisible {
                            macInheritLog(" Late-correlation(new)-deferred: old-uuid=\(matched.uuid.uuidString) still visible")
                            print("Late correlation (new) deferred (old still visible): \(matched.uuid)")
                            // Device is already cached in devices with MAC; suppress from menu.
                        } else {
                            macInheritLog(" Late-correlation(new): merging \(peripheral.identifier) -> \(matched.uuid)")
                            print("Late correlation: merging \(peripheral.identifier) into \(matched.uuid)")
                            let dr = remapMonitoredUUID(from: matched.uuid, to: peripheral.identifier, peripheral: peripheral)
                            devices.removeValue(forKey: matched.uuid)
                            DispatchQueue.main.async { [weak self] in
                                if dr { self?.delegate?.replaceMonitoredDevice(oldUUID: matched.uuid, with: device) }
                            }
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.delegate?.newDevice(device: device) }
                    }
                    
                    device.logNameResolutionIfNeeded(context: "discover:new")
                }
            } else {
                device = dev!
                device.peripheral = peripheral
                device.rssi = rssi
                device.isVisible = true
                device.advData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? device.advData
                device.advertisedLocalName = device.normalizedName(advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? device.advertisedLocalName
                device.updateAdvertisedNameIfNeeded(device.advertisedLocalName)
                // IOBluetooth MAC resolution for paired devices
                let hadMAC = device.macAddr != nil
                if device.macAddr == nil, let name = device.currentResolvedName() {
                    device.macAddr = resolveMACForDeviceName(name)
                }
                // Check for remap opportunity on every RSSI update (not just first MAC resolution).
                // A monitored UUID may have become invisible since last update — remap to this
                // UUID if it broadcasts the same MAC.
                var didLateCorrelate = false
                if let mac = device.macAddr, let matched = findKnownDeviceByMAC(newMAC: mac, knownDevices: devices.filter { $0.key != peripheral.identifier }) {
                    if !isMonitoring(uuid: matched.uuid) || !matched.isVisible {
                        // Old UUID is either unmonitored or invisible → safe to merge + remap
                        macInheritLog(" Late-correlation(update): merging \(peripheral.identifier) -> \(matched.uuid)")
                        print("Late correlation (update): merging \(peripheral.identifier) into \(matched.uuid)")
                        let dr = remapMonitoredUUID(from: matched.uuid, to: peripheral.identifier, peripheral: peripheral)
                        devices.removeValue(forKey: matched.uuid)
                        didLateCorrelate = true
                        DispatchQueue.main.async { [weak self] in
                            if dr { self?.delegate?.replaceMonitoredDevice(oldUUID: matched.uuid, with: device) }
                            else { self?.delegate?.updateDevice(device: device) }
                        }
                    } else if !hadMAC {
                        macInheritLog(" Late-correlation(update)-deferred: old-uuid=\(matched.uuid.uuidString) still visible")
                        print("Late correlation (update) deferred (old still visible): \(matched.uuid)")
                    }
                }
                if !didLateCorrelate {
                    device.logNameResolutionIfNeeded(context: "discover:update")
                    DispatchQueue.main.async { [weak self] in self?.delegate?.updateDevice(device: device) }
                }
            }
            if let device = device {
                tryGATTConnectForInfo(peripheral)
                resetScanTimer(device: device)
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([DeviceInformation])
        }
        if monitoringSuspended {
            centralMgr.cancelPeripheralConnection(peripheral)
            return
        }
        if let state = monitoredState(for: peripheral), !passiveMode {
            print("Connected \(state.uuid)")
            state.connectionTimer?.invalidate()
            state.connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?)
    {
        guard gattInfoConnectInProgress, currentGATTInfoPeripheralUUID == peripheral.identifier else { return }
        finishGATTInfoConnect(peripheral, outcome: .failed)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?)
    {
        guard gattInfoConnectInProgress, currentGATTInfoPeripheralUUID == peripheral.identifier else { return }
        finishGATTInfoConnect(peripheral, outcome: .disconnected)
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard !monitoringSuspended else { return }
        guard let state = monitoredState(for: peripheral) else { return }
        let rssi = RSSI.intValue >= 0 ? -100 : RSSI.intValue
        updateMonitoredState(state, rssi: rssi)
        state.lastReadAt = Date().timeIntervalSince1970

        if state.activeModeTimer == nil && !passiveMode {
            print("Entering active mode for \(state.uuid)")
            if !scanMode {
                centralMgr.stopScan()
            }
            state.activeModeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { [weak self, weak state, weak peripheral] _ in
                guard let self = self, let state = state, let peripheral = peripheral else { return }
                if Date().timeIntervalSince1970 > state.lastReadAt + 10 {
                    print("Falling back to passive mode for \(state.uuid)")
                    self.centralMgr.cancelPeripheralConnection(peripheral)
                    state.activeModeTimer?.invalidate()
                    state.activeModeTimer = nil
                    self.scanForPeripherals()
                } else if peripheral.state == .connected {
                    peripheral.readRSSI()
                } else {
                    self.connectMonitoredPeripheral(state)
                }
            })
            if let timer = state.activeModeTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        let isCurrentInfoConnect = gattInfoConnectInProgress && currentGATTInfoPeripheralUUID == peripheral.identifier
        if let error = error {
            if isCurrentInfoConnect {
                centralMgr.cancelPeripheralConnection(peripheral)
                finishGATTInfoConnect(peripheral, outcome: .readError)
            }
            return
        }
        guard let services = peripheral.services else { return }
        var foundDeviceInformation = false
        for service in services where service.uuid == DeviceInformation {
            foundDeviceInformation = true
            peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
        }
        if !foundDeviceInformation, isCurrentInfoConnect {
            centralMgr.cancelPeripheralConnection(peripheral)
            finishGATTInfoConnect(peripheral, outcome: .noService)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        let isCurrentInfoConnect = gattInfoConnectInProgress && currentGATTInfoPeripheralUUID == peripheral.identifier
        if let error = error {
            if isCurrentInfoConnect {
                centralMgr.cancelPeripheralConnection(peripheral)
                finishGATTInfoConnect(peripheral, outcome: .readError)
            }
            return
        }
        guard let chars = service.characteristics else { return }
        var infoChars = 0
        for chara in chars {
            if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                infoChars += 1
                peripheral.readValue(for: chara)
            }
        }
        if isCurrentInfoConnect {
            if infoChars == 0 {
                centralMgr.cancelPeripheralConnection(peripheral)
                finishGATTInfoConnect(peripheral, outcome: .noService)
            } else {
                gattInfoReadsPending = infoChars
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        let isInfoChar = characteristic.uuid == ManufacturerName || characteristic.uuid == ModelName
        if isInfoChar, let value = characteristic.value, let s = String(data: value, encoding: .utf8),
           let device = devices[peripheral.identifier] {
            if characteristic.uuid == ManufacturerName {
                device.manufacture = s
                device.logNameResolutionIfNeeded(context: "characteristic:manufacturer")
                DispatchQueue.main.async { [weak self] in self?.delegate?.updateDevice(device: device) }
            }
            if characteristic.uuid == ModelName {
                device.model = s
                device.logNameResolutionIfNeeded(context: "characteristic:model")
                DispatchQueue.main.async { [weak self] in self?.delegate?.updateDevice(device: device) }
            }
        }

        let isCurrentInfoConnect = gattInfoConnectInProgress && currentGATTInfoPeripheralUUID == peripheral.identifier
        if isInfoChar, isCurrentInfoConnect, gattInfoReadsPending > 0 {
            gattInfoReadsPending -= 1
            if gattInfoReadsPending == 0 {
                finishGATTInfoConnect(peripheral, outcome: error == nil ? .success : .readError)
                if !isMonitoring(uuid: peripheral.identifier) {
                    centralMgr.cancelPeripheralConnection(peripheral)
                }
            }
        } else if !isCurrentInfoConnect, let device = devices[peripheral.identifier],
                  device.manufacture != nil, device.model != nil,
                  !isMonitoring(uuid: device.uuid) {
            // Info read through a non-gated connection - release it.
            centralMgr.cancelPeripheralConnection(peripheral)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        peripheral.discoverServices([DeviceInformation])
    }
    //MARK:CBPeripheralDelegate end -

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}
