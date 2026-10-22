import Foundation
import CoreGraphics

enum UnlockKeyboard {
    // kVK_Return from HIToolbox/Events.h. Decimal 52 is not the Return key.
    static let returnKeyCode: CGKeyCode = 0x24

    enum InputError: Error {
        case emptyPassword
        case cannotCreateEvent
    }

    static func unicodeChunks(_ string: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var chunk: [UniChar] = []
        for scalar in string.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 {
                chunks.append(chunk)
                chunk = []
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    // Constructing events has no input side effects; the caller controls delivery.
    static func events(for password: String) throws -> [CGEvent] {
        guard !password.isEmpty else { throw InputError.emptyPassword }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InputError.cannotCreateEvent
        }
        var events: [CGEvent] = []
        for chunk in unicodeChunks(password) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: down) else {
                    throw InputError.cannotCreateEvent
                }
                event.flags = []
                chunk.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                events.append(event)
            }
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: down) else {
                throw InputError.cannotCreateEvent
            }
            event.flags = []
            events.append(event)
        }
        return events
    }

    static func deliver(_ events: [CGEvent], canContinue: () -> Bool,
                        willSubmit: () -> Void, post: (CGEvent) -> Void) -> Bool {
        guard !events.isEmpty, events.count % 2 == 0 else { return false }
        for offset in stride(from: 0, to: events.count, by: 2) {
            guard canContinue() else { return false }
            if events[offset].getIntegerValueField(.keyboardEventKeycode) == Int64(returnKeyCode) {
                willSubmit()
            }
            // Release an already-sent key even if Return immediately unlocks the screen.
            // Both events still go to the same captured loginwindow process.
            post(events[offset])
            post(events[offset + 1])
        }
        return true
    }
}
