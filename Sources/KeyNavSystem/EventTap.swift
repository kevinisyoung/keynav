import CoreGraphics
import Foundation
import KeyNavCore

/// Turns CoreGraphics events into router inputs. Pure mapping; no state.
public enum EventClassifier {
    public static let mask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .mouseMoved
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    /// Device-dependent flag bits that report whether a specific modifier key is down.
    static let deviceMasks: [UInt16: UInt64] = [
        Key.leftControl: 0x0000_0001,
        Key.leftShift: 0x0000_0002,
        Key.rightShift: 0x0000_0004,
        Key.leftCommand: 0x0000_0008,
        Key.rightCommand: 0x0000_0010,
        Key.leftOption: 0x0000_0020,
        Key.rightOption: 0x0000_0040,
        Key.rightControl: 0x0000_2000,
    ]

    public static func modifiers(_ flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result
    }

    /// The ordinary modifier that a modifier key itself contributes, removed so a key is not "held with itself".
    static func ownModifier(for code: UInt16) -> Modifiers {
        switch code {
        case Key.leftCommand, Key.rightCommand: return .command
        case Key.leftShift, Key.rightShift: return .shift
        case Key.leftOption, Key.rightOption: return .option
        case Key.leftControl, Key.rightControl: return .control
        default: return []
        }
    }

    public static func input(for type: CGEventType, event: CGEvent, time: Double) -> RouterInput? {
        switch type {
        case .keyDown, .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let repeats = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let modifiers = modifiers(event.flags)
            let text = unicodeText(event)
            let typesCharacter = (text.first.map { !$0.isNewline && !$0.isASCIIControl } ?? false)
                && modifiers.isDisjoint(with: [.command, .control, .option])
            return .key(KeyEvent(
                kind: type == .keyDown ? .down : .up,
                code: code,
                modifiers: modifiers,
                isRepeat: repeats,
                isModifierKey: false,
                typesCharacter: typesCharacter,
                character: text.isEmpty ? nil : text
            ))

        case .flagsChanged:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let pressed: Bool
            if let mask = deviceMasks[code] {
                pressed = event.flags.rawValue & mask != 0
            } else {
                // Caps Lock and Fn: the ordinary flag reports state for these keys.
                pressed = code == Key.capsLock
                    ? event.flags.contains(.maskAlphaShift)
                    : event.flags.contains(.maskSecondaryFn)
            }
            let others = modifiers(event.flags).subtracting(ownModifier(for: code))
            return .key(KeyEvent(
                kind: pressed ? .down : .up,
                code: code,
                modifiers: others,
                isRepeat: false,
                isModifierKey: true,
                typesCharacter: false,
                character: nil
            ))

        case .mouseMoved:
            return .externalPointerMoved

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .scrollWheel:
            return .pointerButton

        default:
            return nil
        }
    }

    static func unicodeText(_ event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}

private extension Character {
    var isASCIIControl: Bool {
        guard let value = unicodeScalars.first?.value else { return true }
        return value < 0x20 || value == 0x7F
    }
}

/// Owns the active event tap. The callback runs on the main run loop and must stay bounded.
@MainActor
public final class EventTap {
    /// Returns true to consume the event. Called on the main actor from the tap callback.
    public typealias Handler = @MainActor (CGEventType, CGEvent) -> Bool
    /// Called when the system disabled the tap; the owner must reset held state.
    public typealias Interruption = @MainActor () -> Void

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler
    private let interruption: Interruption

    public init(handler: @escaping Handler, interruption: @escaping Interruption) {
        self.handler = handler
        self.interruption = interruption
    }

    public var isInstalled: Bool { port != nil }

    /// Installs an active tap. Returns false when macOS refuses (usually: Accessibility not granted).
    public func install() -> Bool {
        guard port == nil else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: EventClassifier.mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            return false
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        port = tap
        source = runLoopSource
        return true
    }

    public func uninstall() {
        guard let tap = port else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        port = nil
        source = nil
    }

    fileprivate func deliver(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = port { CGEvent.tapEnable(tap: tap, enable: true) }
            interruption()
            return false
        }
        // Events KeyNav posted itself pass straight through.
        if event.getIntegerValueField(.eventSourceUserData) == CursorOutput.marker {
            return false
        }
        return handler(type, event)
    }
}

/// Carries a value across the callback boundary. The tap callback runs on the main thread, so the value stays there.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    let box = UncheckedBox(event)
    let consumed = MainActor.assumeIsolated { tap.deliver(type, box.value) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
