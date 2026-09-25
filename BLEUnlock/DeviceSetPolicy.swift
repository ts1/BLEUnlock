import Foundation

enum SignalMode: String {
    case strongest
    case weakest
}

struct DeviceSetSettings {
    var uuids: Set<UUID>
    var mode: SignalMode

    static func load(from defaults: UserDefaults) -> DeviceSetSettings {
        let uuids: Set<UUID>
        if let saved = defaults.array(forKey: "devices") as? [String] {
            uuids = Set(saved.compactMap(UUID.init(uuidString:)))
        } else if let old = defaults.string(forKey: "device"), let uuid = UUID(uuidString: old) {
            uuids = [uuid]
        } else {
            uuids = []
        }
        let mode = SignalMode(rawValue: defaults.string(forKey: "signalMode") ?? "") ?? .weakest
        return DeviceSetSettings(uuids: uuids, mode: mode)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(uuids.map(\.uuidString).sorted(), forKey: "devices")
        defaults.set(mode.rawValue, forKey: "signalMode")
        if uuids.count == 1 {
            defaults.set(uuids.first!.uuidString, forKey: "device")
        } else {
            defaults.removeObject(forKey: "device")
        }
    }
}

enum GroupSignal: Equatable {
    case waiting
    case lost
    case value(raw: Int, estimated: Int)
    case partial(raw: Int, estimated: Int, mode: SignalMode)

    var estimatedRSSI: Int? {
        if case .value(_, let estimated) = self { return estimated }
        if case .partial(_, let estimated, _) = self { return estimated }
        return nil
    }

    func isClose(unlockRSSI: Int, lockRSSI: Int, unlockDisabled: Int) -> Bool {
        let raw: Int
        switch self {
        case .value(let value, _), .partial(let value, _, .strongest): raw = value
        default: return false
        }
        return raw >= (unlockRSSI == unlockDisabled ? lockRSSI : unlockRSSI)
    }

    func isAway(lockRSSI: Int, unlockRSSI: Int, lockDisabled: Int) -> Bool {
        switch self {
        case .waiting: return false
        case .lost: return true
        case .partial(_, _, .strongest): return false
        case .value(_, let estimated), .partial(_, let estimated, .weakest):
            return estimated < (lockRSSI == lockDisabled ? unlockRSSI : lockRSSI)
        }
    }
}

struct DeviceSetPolicy {
    private struct Reading {
        var selectedAt: TimeInterval
        var receivedAt: TimeInterval?
        var raw: Int = 0
        var samples: [Int] = []
        var expired = false

        var estimated: Int { samples.reduce(0, +) / samples.count }
    }

    private var readings: [UUID: Reading] = [:]
    var mode: SignalMode
    private(set) var timeout: TimeInterval

    init(uuids: Set<UUID>, mode: SignalMode, timeout: TimeInterval, now: TimeInterval) {
        self.mode = mode
        self.timeout = timeout
        setSelected(uuids, now: now)
    }

    var uuids: Set<UUID> { Set(readings.keys) }

    mutating func setSelected(_ uuids: Set<UUID>, now: TimeInterval) {
        readings = readings.filter { uuids.contains($0.key) }
        for uuid in uuids where readings[uuid] == nil {
            readings[uuid] = Reading(selectedAt: now)
        }
    }

    mutating func record(_ rssi: Int, for uuid: UUID, now: TimeInterval) {
        guard var reading = readings[uuid] else { return }
        if reading.expired || (reading.receivedAt.map { now >= $0 + timeout } ?? false) {
            reading.samples.removeAll()
        }
        reading.receivedAt = now
        reading.raw = rssi
        reading.expired = false
        reading.samples.append(rssi)
        if reading.samples.count > 5 { reading.samples.removeFirst() }
        readings[uuid] = reading
    }

    mutating func setTimeout(_ value: TimeInterval, now: TimeInterval) {
        for uuid in readings.keys {
            guard let reading = readings[uuid] else { continue }
            if now >= (reading.receivedAt ?? reading.selectedAt) + timeout {
                readings[uuid]?.expired = true
            }
        }
        timeout = value
    }

    mutating func clearSmoothing() {
        for uuid in readings.keys {
            if let raw = readings[uuid]?.raw, readings[uuid]?.receivedAt != nil {
                readings[uuid]?.samples = [raw]
            }
        }
    }

    func nextDeadline(after now: TimeInterval) -> TimeInterval? {
        readings.values.filter { !$0.expired }
            .map { ($0.receivedAt ?? $0.selectedAt) + timeout }
            .filter { $0 > now }.min()
    }

    func signal(at now: TimeInterval) -> GroupSignal {
        guard !readings.isEmpty else { return .waiting }
        var values: [(raw: Int, estimated: Int)] = []
        var pending = false
        var lost = false
        for reading in readings.values {
            let deadline = (reading.receivedAt ?? reading.selectedAt) + timeout
            if reading.expired || now >= deadline {
                lost = true
            } else if reading.receivedAt == nil {
                pending = true
            } else {
                values.append((reading.raw, reading.estimated))
            }
        }
        if mode == .weakest {
            if lost { return .lost }
            guard !values.isEmpty else { return .waiting }
            let raw = values.map(\.raw).min()!
            let estimated = values.map(\.estimated).min()!
            return pending ? .partial(raw: raw, estimated: estimated, mode: .weakest)
                : .value(raw: raw, estimated: estimated)
        }
        if !values.isEmpty {
            let raw = values.map(\.raw).max()!
            let estimated = values.map(\.estimated).max()!
            return pending ? .partial(raw: raw, estimated: estimated, mode: .strongest)
                : .value(raw: raw, estimated: estimated)
        }
        return pending ? .waiting : .lost
    }
}
