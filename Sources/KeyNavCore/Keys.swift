/// Modifier flags tracked by KeyNav. Left/right identity lives in key codes, not here.
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)

    public static let none: Modifiers = []
}

/// macOS virtual key codes (ANSI positions). Physical identity is stored for every binding.
public enum Key {
    public static let a: UInt16 = 0
    public static let s: UInt16 = 1
    public static let d: UInt16 = 2
    public static let f: UInt16 = 3
    public static let h: UInt16 = 4
    public static let g: UInt16 = 5
    public static let z: UInt16 = 6
    public static let x: UInt16 = 7
    public static let c: UInt16 = 8
    public static let v: UInt16 = 9
    public static let b: UInt16 = 11
    public static let q: UInt16 = 12
    public static let w: UInt16 = 13
    public static let e: UInt16 = 14
    public static let r: UInt16 = 15
    public static let y: UInt16 = 16
    public static let t: UInt16 = 17
    public static let o: UInt16 = 31
    public static let u: UInt16 = 32
    public static let i: UInt16 = 34
    public static let p: UInt16 = 35
    public static let l: UInt16 = 37
    public static let j: UInt16 = 38
    public static let k: UInt16 = 40
    public static let n: UInt16 = 45
    public static let m: UInt16 = 46
    public static let slash: UInt16 = 44
    public static let period: UInt16 = 47
    public static let comma: UInt16 = 43
    public static let semicolon: UInt16 = 41
    public static let space: UInt16 = 49
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    public static let f1: UInt16 = 122
    /// The number row's 1 through 9, in order.
    public static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    public static let rightCommand: UInt16 = 54
    public static let leftCommand: UInt16 = 55
    public static let leftShift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let leftOption: UInt16 = 58
    public static let leftControl: UInt16 = 59
    public static let rightShift: UInt16 = 60
    public static let rightOption: UInt16 = 61
    public static let rightControl: UInt16 = 62
    public static let function: UInt16 = 63

    public static let modifierKeys: Set<UInt16> = [
        rightCommand, leftCommand, leftShift, capsLock, leftOption, leftControl,
        rightShift, rightOption, rightControl, function
    ]

    /// Printable keys whose plain press would type a character (US ANSI positions).
    public static let printableCodes: [UInt16: String] = [
        a: "A", s: "S", d: "D", f: "F", h: "H", g: "G", z: "Z", x: "X", c: "C", v: "V",
        b: "B", q: "Q", w: "W", e: "E", r: "R", y: "Y", t: "T", o: "O", u: "U", i: "I",
        p: "P", l: "L", j: "J", k: "K", n: "N", m: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".",
        slash: "/", 50: "`", space: "Space"
    ]

    /// Human names used in Settings. Glyphs are avoided on purpose.
    public static func name(for code: UInt16) -> String {
        switch code {
        case space: return "Space"
        case returnKey: return "Return"
        case tab: return "Tab"
        case delete: return "Delete"
        case escape: return "Escape"
        case leftArrow: return "Left Arrow"
        case rightArrow: return "Right Arrow"
        case upArrow: return "Up Arrow"
        case downArrow: return "Down Arrow"
        case leftCommand: return "Left Command"
        case rightCommand: return "Right Command"
        case leftShift: return "Left Shift"
        case rightShift: return "Right Shift"
        case leftOption: return "Left Option"
        case rightOption: return "Right Option"
        case leftControl: return "Left Control"
        case rightControl: return "Right Control"
        case capsLock: return "Caps Lock"
        case function: return "Fn"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 117: return "Forward Delete"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        default:
            return printableCodes[code] ?? "Key \(code)"
        }
    }

    /// The ordinary modifier flag a modifier key contributes while held.
    public static func modifierFlag(for code: UInt16) -> Modifiers {
        switch code {
        case leftCommand, rightCommand: return .command
        case leftShift, rightShift: return .shift
        case leftOption, rightOption: return .option
        case leftControl, rightControl: return .control
        default: return []
        }
    }

    public static func modifierName(_ modifiers: Modifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        return parts.joined(separator: " ")
    }
}

/// A user-recordable gesture. Entries use `modifierTap`/`key`; actions use `key` (holds included).
public enum Gesture: Codable, Hashable, Sendable {
    /// A single key press, optionally with ordinary modifiers held.
    case key(code: UInt16, modifiers: Modifiers)
    /// A lone modifier pressed and released within the tap threshold, without other input.
    case modifierTap(code: UInt16)

    public var displayName: String {
        switch self {
        case let .key(code, modifiers):
            let base = Key.name(for: code)
            let prefix = Key.modifierName(modifiers)
            return prefix.isEmpty ? base : "\(prefix) \(base)"
        case let .modifierTap(code):
            return "\(Key.name(for: code)) tap"
        }
    }

    public var keyCode: UInt16 {
        switch self {
        case let .key(code, _), let .modifierTap(code): return code
        }
    }
}

/// One normalized key transition from the event tap.
public struct KeyEvent: Equatable, Sendable {
    public enum Kind: Sendable { case down, up }

    public var kind: Kind
    public var code: UInt16
    public var modifiers: Modifiers
    public var isRepeat: Bool
    /// True when the key is a modifier key (flagsChanged in AppKit terms).
    public var isModifierKey: Bool
    /// True when the plain key would type a printable character (no Command/Control/Option).
    public var typesCharacter: Bool
    /// Text produced by the key under the active layout, when the system layer resolved it.
    public var character: String?

    public init(
        kind: Kind,
        code: UInt16,
        modifiers: Modifiers = [],
        isRepeat: Bool = false,
        isModifierKey: Bool? = nil,
        typesCharacter: Bool = false,
        character: String? = nil
    ) {
        self.kind = kind
        self.code = code
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.isModifierKey = isModifierKey ?? Key.modifierKeys.contains(code)
        self.typesCharacter = typesCharacter
        self.character = character
    }
}
