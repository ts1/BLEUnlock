import Foundation
import IOKit.ps

enum PowerSource {
    case battery
    case external
    case unknown
}

final class PowerSourceMonitor {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    static func currentSource() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return .unknown
        }
        switch type as String {
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMACPowerKey, kIOPMUPSPowerKey: return .external
        default: return .unknown
        }
    }

    static func shouldPauseAutomaticLock(batteryOnly: Bool, source: PowerSource) -> Bool {
        // An unavailable power reading must not silently disable automatic locking.
        return batteryOnly && source == .external
    }

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.onChange?()
        }, context)?.takeRetainedValue()
        if let source = source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func stop() {
        if let source = source {
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
    }

    deinit {
        stop()
    }
}
