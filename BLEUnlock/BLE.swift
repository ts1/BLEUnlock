import Foundation
import CoreBluetooth

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    
    override var description: String {
        get {
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
            if let adv = advData {
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
            return uuid.description
        }
    }
    
    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?)
    func updatePresence(presence: Bool, reason: String)
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredPeripheral: CBPeripheral?
    var proximityTimer : Timer?
    var signalTimer: Timer?
    var presence = false
    var proximityRSSI = -70
    var proximityTimeout = 8.5
    var signalTimeout = 31.0
    var lastReadAt = 0.0

    func startScanning() {
        scanMode = true
    }

    func stopScanning() {
        scanMode = false
    }

    func startMonitor(uuid: UUID) {
        if let p = monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        monitoredUUID = uuid
        proximityTimer?.invalidate()
        resetSignalTimer()
        presence = true
        monitoredPeripheral = nil
    }

    func resetSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            print("Device is lost")
            self.delegate?.updateRSSI(rssi: nil)
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
            print("central powered on")
            centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            if let p = monitoredPeripheral {
                central.cancelPeripheralConnection(p)
            }
        case .poweredOff:
            print("central powered off")
            presence = false
            signalTimer?.invalidate()
            signalTimer = nil
        default:
            break
        }
    }

    func updateMonitoredPeripheral(_ rssi: Int) {
        if let p = monitoredPeripheral {
            if (!scanMode && p.state == .disconnected) {
                centralMgr.connect(p, options: nil)
            }
        }
        delegate?.updateRSSI(rssi: rssi)
        if (rssi > proximityRSSI) {
            if (!presence) {
                print("Device is close")
                presence = true
                delegate?.updatePresence(presence: presence, reason: "close")
            }
            if let timer = proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled")
                proximityTimer = nil
            }
        } else if (presence) {
            if proximityTimer == nil {
                proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { _ in
                    print("Device is away")
                    self.presence = false
                    self.delegate?.updatePresence(presence: self.presence, reason: "away")
                    self.proximityTimer = nil
                })
                if let timer = proximityTimer {
                    RunLoop.main.add(timer, forMode: .common)
                    print("Proximity timer started")
                }
            }
        }
        resetSignalTimer()
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if let uuid = monitoredUUID {
            if peripheral.identifier.description == uuid.description {
                if monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                if peripheral.state != .connected {
                    updateMonitoredPeripheral(rssi)
                    //print("Discover \(rssi)dBm")
                }
            }
        }

        if (scanMode) {
            let dev = devices[peripheral.identifier]
            var device: Device
            if (dev == nil) {
                device = Device(uuid: peripheral.identifier)
                device.peripheral = peripheral
                device.rssi = rssi
                device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                devices[peripheral.identifier] = device
                central.connect(peripheral, options: nil)
                delegate?.newDevice(device: device)
            } else {
                device = dev!
                device.rssi = rssi
                delegate?.updateDevice(device: device)
            }
            resetScanTimer(device: device)
        }
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

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        peripheral.discoverServices([DeviceInformation])
        if peripheral == monitoredPeripheral {
            peripheral.readRSSI()
            lastReadAt = Date().timeIntervalSince1970
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == monitoredPeripheral else { return }
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == monitoredPeripheral else { return }
        central.connect(peripheral, options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral == monitoredPeripheral else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        updateMonitoredPeripheral(rssi)
        //print("readRSSI \(rssi)dBm")

        var interval: TimeInterval
        if lastReadAt > 0 {
            interval = 2.0 - (Date().timeIntervalSince1970 - lastReadAt)
            if interval < 0 {
                interval = 0
            }
        } else {
            interval = 0
        }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false, block: { _ in
            if peripheral.state == .connected {
                peripheral.readRSSI()
                self.lastReadAt = Date().timeIntervalSince1970
            }
        })
        RunLoop.main.add(timer, forMode: .common)
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

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}
