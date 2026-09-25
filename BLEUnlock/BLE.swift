import Foundation
import CoreBluetooth
import Accelerate

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    
    override var description: String {
        get {
            if macAddr == nil || blName == nil {
                if let info = getLEDeviceInfoFromUUID(uuid.description) {
                    blName = info.name
                    macAddr = info.macAddr
                }
            }
            if macAddr == nil {
                macAddr = getMACFromUUID(uuid.description)
            }
            if let mac = macAddr {
                if blName == nil {
                    blName = getNameFromMAC(mac)
                }
                if let name = blName {
                    // If it's just "iPhone" or "iPad", there's a chance we can get the model name in the following code
                    if name != "iPhone" && name != "iPad" {
                        return name
                    }
                }
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            }
            if let name = peripheral?.name {
                if name.trimmingCharacters(in: .whitespaces).count != 0 {
                    return name
                }
            }
            if let mod = model {
                return mod
            }
            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac // better than uuid
            }
            return uuid.description
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
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
}

private class GroupPeripheral {
    var peripheral: CBPeripheral
    var readTimer: Timer?
    var connectionTimer: Timer?
    var lastReadAt: TimeInterval = 0

    init(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredPeripheral: CBPeripheral?
    var proximityTimer : Timer?
    var signalTimer: Timer?
    var presence = false
    var lockRSSI = -80
    var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var lastReadAt = 0.0
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var latestRSSIs: [Double] = []
    var latestN: Int = 5
    var activeModeTimer : Timer? = nil
    var connectionTimer : Timer? = nil
    private var groupPolicy: DeviceSetPolicy?
    private var groupPeripherals: [UUID: GroupPeripheral] = [:]
    private var groupSignalTimer: Timer?
    private var groupNow: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func scanForPeripherals() {
        guard !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //print("Start scanning")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        if activeModeTimer != nil || (monitoredUUID == nil && groupPolicy == nil) {
            centralMgr.stopScan()
        }
    }

    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        if passiveMode {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            if let p = monitoredPeripheral {
                centralMgr.cancelPeripheralConnection(p)
            }
            for state in groupPeripherals.values {
                state.readTimer?.invalidate()
                state.readTimer = nil
                state.connectionTimer?.invalidate()
                state.connectionTimer = nil
                centralMgr.cancelPeripheralConnection(state.peripheral)
            }
        } else {
            for state in groupPeripherals.values {
                connectGroupPeripheral(state)
            }
        }
        scanForPeripherals()
    }

    func startMonitor(uuid: UUID) {
        stopGroupMonitor()
        if let p = monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        connectionTimer?.invalidate()
        connectionTimer = nil
        monitoredUUID = uuid
        proximityTimer?.invalidate()
        resetSignalTimer()
        presence = true
        monitoredPeripheral = nil
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        scanForPeripherals()
    }

    func stopMonitor() {
        stopGroupMonitor()
        if let p = monitoredPeripheral { centralMgr.cancelPeripheralConnection(p) }
        monitoredUUID = nil
        monitoredPeripheral = nil
        proximityTimer?.invalidate()
        proximityTimer = nil
        signalTimer?.invalidate()
        signalTimer = nil
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        connectionTimer?.invalidate()
        connectionTimer = nil
        presence = false
        if !scanMode { centralMgr.stopScan() }
    }

    func startMonitorGroup(uuids: Set<UUID>, mode: SignalMode) {
        precondition(uuids.count > 1)
        let now = groupNow
        if groupPolicy == nil {
            if let p = monitoredPeripheral { centralMgr.cancelPeripheralConnection(p) }
            monitoredUUID = nil
            monitoredPeripheral = nil
            signalTimer?.invalidate()
            signalTimer = nil
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            connectionTimer?.invalidate()
            connectionTimer = nil
            proximityTimer?.invalidate()
            proximityTimer = nil
            latestRSSIs.removeAll()
            presence = true
            groupPolicy = DeviceSetPolicy(uuids: uuids, mode: mode, timeout: signalTimeout, now: now)
        } else {
            if groupPolicy?.uuids != uuids || groupPolicy?.mode != mode {
                proximityTimer?.invalidate()
                proximityTimer = nil
            }
            for uuid in Set(groupPeripherals.keys).subtracting(uuids) {
                if let state = groupPeripherals.removeValue(forKey: uuid) {
                    cancelGroupPeripheral(state)
                }
            }
            groupPolicy?.setSelected(uuids, now: now)
            groupPolicy?.mode = mode
        }
        evaluateGroupSignal(now: now)
        resetGroupSignalTimer(now: now)
        scanForPeripherals()
    }

    func setSignalMode(_ mode: SignalMode) {
        guard let policy = groupPolicy, policy.mode != mode else { return }
        proximityTimer?.invalidate()
        proximityTimer = nil
        groupPolicy?.mode = mode
        evaluateGroupSignal(now: groupNow)
    }

    func setSignalTimeout(_ timeout: TimeInterval) {
        signalTimeout = timeout
        guard groupPolicy != nil else { return }
        let now = groupNow
        groupPolicy?.setTimeout(timeout, now: now)
        evaluateGroupSignal(now: now)
        resetGroupSignalTimer(now: now)
    }

    private func cancelGroupPeripheral(_ state: GroupPeripheral) {
        state.readTimer?.invalidate()
        state.connectionTimer?.invalidate()
        centralMgr.cancelPeripheralConnection(state.peripheral)
    }

    private func stopGroupMonitor() {
        groupSignalTimer?.invalidate()
        groupSignalTimer = nil
        for state in groupPeripherals.values { cancelGroupPeripheral(state) }
        groupPeripherals.removeAll()
        groupPolicy = nil
    }

    private func resetGroupSignalTimer(now: TimeInterval) {
        groupSignalTimer?.invalidate()
        guard let deadline = groupPolicy?.nextDeadline(after: now) else { return }
        groupSignalTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, deadline - now), repeats: false) { _ in
            let current = self.groupNow
            self.evaluateGroupSignal(now: current)
            self.resetGroupSignalTimer(now: current)
        }
        RunLoop.main.add(groupSignalTimer!, forMode: .common)
    }

    private func updateGroupRSSI(_ rssi: Int, uuid: UUID) {
        let now = groupNow
        groupPolicy?.record(rssi, for: uuid, now: now)
        evaluateGroupSignal(now: now)
        resetGroupSignalTimer(now: now)
    }

    private func evaluateGroupSignal(now: TimeInterval) {
        guard var signal = groupPolicy?.signal(at: now) else { return }
        if signal == .waiting {
            proximityTimer?.invalidate()
            proximityTimer = nil
            delegate?.updateRSSI(rssi: nil, active: false)
            return
        }
        if signal.isClose(unlockRSSI: unlockRSSI, lockRSSI: lockRSSI, unlockDisabled: UNLOCK_DISABLED), !presence {
            presence = true
            delegate?.updatePresence(presence: true, reason: "close")
            groupPolicy?.clearSmoothing()
            signal = groupPolicy!.signal(at: now)
        }
        delegate?.updateRSSI(rssi: signal.estimatedRSSI,
                             active: groupPeripherals.values.contains { $0.readTimer != nil })

        if !signal.isAway(lockRSSI: lockRSSI, unlockRSSI: unlockRSSI, lockDisabled: LOCK_DISABLED) {
            proximityTimer?.invalidate()
            proximityTimer = nil
        } else if presence && proximityTimer == nil {
            proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false) { _ in
                guard let current = self.groupPolicy?.signal(at: self.groupNow),
                      current.isAway(lockRSSI: self.lockRSSI, unlockRSSI: self.unlockRSSI, lockDisabled: self.LOCK_DISABLED) else {
                    self.proximityTimer = nil
                    return
                }
                self.presence = false
                self.delegate?.updatePresence(presence: false, reason: current == .lost ? "lost" : "away")
                self.proximityTimer = nil
            }
            RunLoop.main.add(proximityTimer!, forMode: .common)
        }
    }

    private func connectGroupPeripheral(_ state: GroupPeripheral) {
        guard !passiveMode else { return }
        let peripheral = state.peripheral
        peripheral.readRSSI()
        guard peripheral.state == .disconnected, state.connectionTimer == nil else { return }
        centralMgr.connect(peripheral, options: nil)
        state.connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            state.connectionTimer = nil
            if peripheral.state == .connecting {
                self.centralMgr.cancelPeripheralConnection(peripheral)
            }
        }
        RunLoop.main.add(state.connectionTimer!, forMode: .common)
    }

    func resetSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            print("Device is lost")
            self.delegate?.updateRSSI(rssi: nil, active: false)
            if self.presence {
                self.presence = false
                self.delegate?.updatePresence(presence: self.presence, reason: "lost")
            }
        })
        if let timer = signalTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            if groupPolicy != nil {
                let now = groupNow
                evaluateGroupSignal(now: now)
                resetGroupSignalTimer(now: now)
            }
            powerWarn = false
        case .poweredOff:
            print("Bluetooth powered off")
            presence = false
            signalTimer?.invalidate()
            signalTimer = nil
            groupSignalTimer?.invalidate()
            groupSignalTimer = nil
            for state in groupPeripherals.values {
                state.readTimer?.invalidate()
                state.readTimer = nil
                state.connectionTimer?.invalidate()
                state.connectionTimer = nil
            }
            groupPeripherals.removeAll()
            if let group = groupPolicy {
                groupPolicy = DeviceSetPolicy(uuids: group.uuids, mode: group.mode,
                                              timeout: group.timeout, now: groupNow)
            }
            if powerWarn {
                powerWarn = false
                delegate?.bluetoothPowerWarn()
            }
        default:
            break
        }
    }
    
    func getEstimatedRSSI(rssi: Int) -> Int {
        if latestRSSIs.count >= latestN {
            latestRSSIs.removeFirst()
        }
        latestRSSIs.append(Double(rssi))
        var mean: Double = 0.0
        var sddev: Double = 0.0
        vDSP_normalizeD(latestRSSIs, 1, nil, 1, &mean, &sddev, vDSP_Length(latestRSSIs.count))
        return Int(mean)
    }

    func updateMonitoredPeripheral(_ rssi: Int) {
        // print(String(format: "rssi: %d", rssi))
        if rssi >= (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) && !presence {
            print("Device is close")
            presence = true
            delegate?.updatePresence(presence: presence, reason: "close")
            latestRSSIs.removeAll() // Avoid bouncing
        }

        let estimatedRSSI = getEstimatedRSSI(rssi: rssi)
        delegate?.updateRSSI(rssi: estimatedRSSI, active: activeModeTimer != nil)

        if estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) {
            if let timer = proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled")
                proximityTimer = nil
            }
        } else if presence && proximityTimer == nil {
            proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { _ in
                print("Device is away")
                self.presence = false
                self.delegate?.updatePresence(presence: self.presence, reason: "away")
                self.proximityTimer = nil
            })
            RunLoop.main.add(proximityTimer!, forMode: .common)
            print("Proximity timer started")
        }
        resetSignalTimer()
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            self.delegate?.removeDevice(device: device)
            if let p = device.peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.devices.removeValue(forKey: device.uuid)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitoredPeripheral() {
        guard let p = monitoredPeripheral else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        print("Connecting")
        centralMgr.connect(p, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { _ in
            if p.state == .connecting {
                print("Connection timeout")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        })
        RunLoop.main.add(connectionTimer!, forMode: .common)
    }

    //MARK:- CBCentralManagerDelegate start

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if groupPolicy?.uuids.contains(peripheral.identifier) == true {
            let state: GroupPeripheral
            if let existing = groupPeripherals[peripheral.identifier] {
                state = existing
                if state.peripheral !== peripheral {
                    cancelGroupPeripheral(state)
                    state.peripheral = peripheral
                    state.readTimer = nil
                    state.connectionTimer = nil
                }
            } else {
                state = GroupPeripheral(peripheral)
                groupPeripherals[peripheral.identifier] = state
            }
            if state.readTimer == nil {
                updateGroupRSSI(rssi, uuid: peripheral.identifier)
                connectGroupPeripheral(state)
            }
        }
        if let uuid = monitoredUUID {
            if peripheral.identifier.description == uuid.description {
                if monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                if activeModeTimer == nil {
                    //print("Discover \(rssi)dBm")
                    updateMonitoredPeripheral(rssi)
                    if !passiveMode {
                        connectMonitoredPeripheral()
                    }
                }
            }
        }

        if (scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //print("Device \(peripheral.identifier) Exposure Notification")
                        return
                    }
                }
            }
            let dev = devices[peripheral.identifier]
            var device: Device
            if (dev == nil) {
                device = Device(uuid: peripheral.identifier)
                if (rssi >= thresholdRSSI) {
                    device.peripheral = peripheral
                    device.rssi = rssi
                    device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                    devices[peripheral.identifier] = device
                    central.connect(peripheral, options: nil)
                    delegate?.newDevice(device: device)
                }
            } else {
                device = dev!
                device.rssi = rssi
                delegate?.updateDevice(device: device)
            }
            resetScanTimer(device: device)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([DeviceInformation])
        }
        if let state = groupPeripherals[peripheral.identifier], state.peripheral == peripheral {
            state.connectionTimer?.invalidate()
            state.connectionTimer = nil
            if !passiveMode { peripheral.readRSSI() }
        }
        if peripheral == monitoredPeripheral && !passiveMode {
            print("Connected")
            connectionTimer?.invalidate()
            connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let state = groupPeripherals[peripheral.identifier], state.peripheral == peripheral {
            guard error == nil else { return }
            let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
            updateGroupRSSI(rssi, uuid: peripheral.identifier)
            state.lastReadAt = groupNow
            if state.readTimer == nil && !passiveMode {
                state.readTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    if self.groupNow > state.lastReadAt + 10 {
                        state.readTimer?.invalidate()
                        state.readTimer = nil
                        self.centralMgr.cancelPeripheralConnection(peripheral)
                        self.scanForPeripherals()
                    } else if peripheral.state == .connected {
                        peripheral.readRSSI()
                    } else {
                        self.connectGroupPeripheral(state)
                    }
                }
                RunLoop.main.add(state.readTimer!, forMode: .common)
            }
            return
        }
        guard peripheral == monitoredPeripheral else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        //print("readRSSI \(rssi)dBm")
        updateMonitoredPeripheral(rssi)
        lastReadAt = Date().timeIntervalSince1970

        if activeModeTimer == nil && !passiveMode {
            print("Entering active mode")
            if !scanMode {
                centralMgr.stopScan()
            }
            activeModeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { _ in
                if Date().timeIntervalSince1970 > self.lastReadAt + 10 {
                    print("Falling back to passive mode")
                    self.centralMgr.cancelPeripheralConnection(peripheral)
                    self.activeModeTimer?.invalidate()
                    self.activeModeTimer = nil
                    self.scanForPeripherals()
                } else if peripheral.state == .connected {
                    peripheral.readRSSI()
                } else {
                    self.connectMonitoredPeripheral()
                }
            })
            RunLoop.main.add(activeModeTimer!, forMode: .common)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                if service.uuid == DeviceInformation {
                    peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        if let chars = service.characteristics {
            for chara in chars {
                if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                    peripheral.readValue(for:chara)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                if let device = devices[peripheral.identifier] {
                    if characteristic.uuid == ManufacturerName {
                        device.manufacture = s
                        delegate?.updateDevice(device: device)
                    }
                    if characteristic.uuid == ModelName {
                        device.model = s
                        delegate?.updateDevice(device: device)
                    }
                    if device.model != nil && device.model != nil && device.peripheral != monitoredPeripheral {
                        centralMgr.cancelPeripheralConnection(peripheral)
                    }
                }
            }
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
