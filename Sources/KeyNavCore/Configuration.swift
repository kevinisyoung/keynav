import Foundation

/// Cursor-mode actions. Holds and movement are time-based; clicks are one-shot.
public enum CursorAction: String, Codable, CaseIterable, Sendable {
    case moveUp, moveDown, moveLeft, moveRight
    case scrollUp, scrollDown, scrollLeft, scrollRight
    case leftClick, rightClick, middleClick, backButton, forwardButton
    case doubleClick
    case dragHold
    case precision, boost
    case help

    public var title: String {
        switch self {
        case .moveUp: return "Move up"
        case .moveDown: return "Move down"
        case .moveLeft: return "Move left"
        case .moveRight: return "Move right"
        case .scrollUp: return "Scroll up"
        case .scrollDown: return "Scroll down"
        case .scrollLeft: return "Scroll left"
        case .scrollRight: return "Scroll right"
        case .leftClick: return "Left click"
        case .rightClick: return "Right click"
        case .middleClick: return "Middle click"
        case .backButton: return "Back button"
        case .forwardButton: return "Forward button"
        case .doubleClick: return "Double click"
        case .dragHold: return "Drag"
        case .precision: return "Precision"
        case .boost: return "Speed boost"
        case .help: return "Show keys"
        }
    }

    public enum Group: String, CaseIterable, Sendable {
        case move = "Move"
        case scroll = "Scroll"
        case buttons = "Mouse buttons"
        case holds = "Hold keys"
        case other = "Other"
    }

    public var group: Group {
        switch self {
        case .moveUp, .moveDown, .moveLeft, .moveRight: return .move
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return .scroll
        case .leftClick, .rightClick, .middleClick, .backButton, .forwardButton, .doubleClick: return .buttons
        case .dragHold, .precision, .boost: return .holds
        case .help: return .other
        }
    }

    /// True when the action lasts while its key is held.
    public var isHold: Bool {
        switch group {
        case .move, .scroll, .holds: return true
        case .buttons, .other: return false
        }
    }
}

/// Click-mode controls. They are bound outside the label alphabet so a key never means two things.
public enum ClickControl: String, Codable, CaseIterable, Sendable {
    case startSearch
    case nextTarget
    case previousTarget
    case activateSelected
    case backspace
    case cycleAction
    case refresh

    public var title: String {
        switch self {
        case .startSearch: return "Search targets"
        case .nextTarget: return "Next target"
        case .previousTarget: return "Previous target"
        case .activateSelected: return "Activate selected"
        case .backspace: return "Back / delete"
        case .cycleAction: return "Change action"
        case .refresh: return "Refresh targets"
        }
    }
}

/// What happens to a chosen Click target.
public enum TargetAction: String, Codable, CaseIterable, Sendable {
    case press
    case rightClick
    case doubleClick
    case movePointer

    public var title: String {
        switch self {
        case .press: return "Click"
        case .rightClick: return "Right click"
        case .doubleClick: return "Double click"
        case .movePointer: return "Move pointer"
        }
    }

    public var next: TargetAction {
        let all = TargetAction.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum DragStyle: String, Codable, CaseIterable, Sendable {
    /// The drag lasts while the drag key is held (default).
    case hold
    /// The drag key picks up; pressing it again drops.
    case toggle
}

/// Entry and exit for one interaction mode.
public struct EntryConfig: Codable, Equatable, Sendable {
    public var gesture: Gesture
    /// When true the entry gesture only enters the mode; `exit` leaves it.
    /// When false the entry gesture toggles the mode.
    public var separateExit: Bool
    public var exit: Gesture

    public init(gesture: Gesture, separateExit: Bool = true, exit: Gesture = .key(code: Key.escape, modifiers: [])) {
        self.gesture = gesture
        self.separateExit = separateExit
        self.exit = exit
    }
}

/// Continuous pointer motion. Values are points per second and seconds.
public struct MotionProfile: Codable, Equatable, Sendable {
    public var initialSpeed: Double
    public var maximumSpeed: Double
    public var rampSeconds: Double
    public var precisionMultiplier: Double
    public var boostMultiplier: Double

    /// Gentle is the proposed default from the product spec. These are tuning hypotheses, not measurements.
    public static let gentle = MotionProfile(initialSpeed: 80, maximumSpeed: 1100, rampSeconds: 0.9,
                                             precisionMultiplier: 0.2, boostMultiplier: 2.0)
    public static let balanced = MotionProfile(initialSpeed: 120, maximumSpeed: 1600, rampSeconds: 0.6,
                                               precisionMultiplier: 0.2, boostMultiplier: 2.0)
    public static let fast = MotionProfile(initialSpeed: 200, maximumSpeed: 2400, rampSeconds: 0.4,
                                           precisionMultiplier: 0.2, boostMultiplier: 2.0)

    public static let presets: [(name: String, profile: MotionProfile)] = [
        ("Gentle", .gentle), ("Balanced", .balanced), ("Fast", .fast)
    ]

    public init(initialSpeed: Double, maximumSpeed: Double, rampSeconds: Double,
                precisionMultiplier: Double, boostMultiplier: Double) {
        self.initialSpeed = initialSpeed
        self.maximumSpeed = maximumSpeed
        self.rampSeconds = rampSeconds
        self.precisionMultiplier = precisionMultiplier
        self.boostMultiplier = boostMultiplier
    }

    /// Name of the matching preset, or nil for custom values.
    public var presetName: String? {
        Self.presets.first { $0.profile == self }?.name
    }

    /// Clamps every value into a range that cannot strand the pointer or overflow.
    public var clamped: MotionProfile {
        var copy = self
        copy.initialSpeed = min(max(initialSpeed, 10), 2000)
        copy.maximumSpeed = min(max(maximumSpeed, copy.initialSpeed), 5000)
        copy.rampSeconds = min(max(rampSeconds, 0.05), 5)
        copy.precisionMultiplier = min(max(precisionMultiplier, 0.05), 1)
        copy.boostMultiplier = min(max(boostMultiplier, 1), 4)
        return copy
    }
}

public struct ScrollProfile: Codable, Equatable, Sendable {
    public var maximumSpeed: Double
    public var rampSeconds: Double
    public var reverse: Bool

    public static let standard = ScrollProfile(maximumSpeed: 900, rampSeconds: 0.6, reverse: false)

    public init(maximumSpeed: Double, rampSeconds: Double, reverse: Bool) {
        self.maximumSpeed = maximumSpeed
        self.rampSeconds = rampSeconds
        self.reverse = reverse
    }
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public enum BadgePlacement: String, Codable, CaseIterable, Sendable {
        case nearPointer
        case screenCorner
    }

    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, regular, large

        public var scale: Double {
            switch self {
            case .small: return 0.85
            case .regular: return 1
            case .large: return 1.3
            }
        }
    }

    public var badgePlacement: BadgePlacement = .nearPointer
    public var badgeSize: Size = .regular
    public var hintSize: Size = .regular
    /// Label background opacity, 0.6–1. Kept high enough for contrast.
    public var hintOpacity: Double = 0.92

    public init() {}
}

/// One user-facing binding in Cursor mode. Aliases are separate entries with the same action.
public struct CursorBinding: Codable, Equatable, Hashable, Sendable {
    public var action: CursorAction
    public var gesture: Gesture

    public init(action: CursorAction, gesture: Gesture) {
        self.action = action
        self.gesture = gesture
    }
}

/// Serialized configuration. Everything here is local data; nothing is transmitted.
///
/// Decoding is tolerant: missing keys take their defaults, so adding a setting never resets the others.
public struct KeyNavConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let defaultAlphabet = "asdfghjklqwertyuiopzxcvbnm"

    public var schemaVersion = KeyNavConfig.currentSchemaVersion
    public var profileName = Presets.standard.name
    public var cursorEntry = EntryConfig(gesture: .modifierTap(code: Key.rightOption))
    public var clickEntry = EntryConfig(gesture: .key(code: Key.space, modifiers: [.command, .shift]))
    public var scrollEntry = EntryConfig(gesture: .key(code: Key.j, modifiers: [.command, .shift]))
    public var cursorBindings = Presets.standard.cursorBindings
    public var clickControls = Presets.standardClickControls
    public var motion = MotionProfile.gentle
    public var scrolling = ScrollProfile.standard
    public var dragStyle = DragStyle.hold
    public var exitCursorOnMouse = false
    public var confineToCurrentDisplay = false
    public var clickSearchFirst = false
    public var clickRequireReturn = false
    public var clickStaysActive = false
    public var clickPointerFallback = true
    /// Also label the frontmost app's menu bar and the status icons on the right of it.
    public var clickLabelsMenuBar = true
    /// Also label the Dock.
    public var clickLabelsDock = true
    public var clickAlphabet = KeyNavConfig.defaultAlphabet
    public var modifierTapMaxMilliseconds = 250
    public var excludedBundleIDs: [String] = []
    public var appearance = AppearanceSettings()
    public var showMenuBarIcon = false

    public init() {}

    public static let `default` = KeyNavConfig()

    /// Start and stop keys of each mode, in display order.
    public var entries: [(mode: InteractionMode, entry: EntryConfig)] {
        [(.cursor, cursorEntry), (.click, clickEntry), (.scroll, scrollEntry)]
    }

    public func entry(for mode: InteractionMode) -> EntryConfig? {
        switch mode {
        case .off: return nil
        case .cursor: return cursorEntry
        case .click: return clickEntry
        case .scroll: return scrollEntry
        }
    }

    public mutating func setEntry(_ entry: EntryConfig, for mode: InteractionMode) {
        switch mode {
        case .off: break
        case .cursor: cursorEntry = entry
        case .click: clickEntry = entry
        case .scroll: scrollEntry = entry
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profileName, cursorEntry, clickEntry, scrollEntry, cursorBindings, clickControls, motion, scrolling
        case dragStyle, exitCursorOnMouse, confineToCurrentDisplay, clickSearchFirst, clickRequireReturn
        case clickStaysActive, clickPointerFallback, clickLabelsMenuBar, clickLabelsDock, clickAlphabet, modifierTapMaxMilliseconds
        case excludedBundleIDs, appearance, showMenuBarIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyNavConfig()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? d.profileName
        cursorEntry = try c.decodeIfPresent(EntryConfig.self, forKey: .cursorEntry) ?? d.cursorEntry
        clickEntry = try c.decodeIfPresent(EntryConfig.self, forKey: .clickEntry) ?? d.clickEntry
        scrollEntry = try c.decodeIfPresent(EntryConfig.self, forKey: .scrollEntry) ?? d.scrollEntry
        cursorBindings = try c.decodeIfPresent([CursorBinding].self, forKey: .cursorBindings) ?? d.cursorBindings
        // Schema 1 stored controls as an array; those files fall back to the default controls.
        let controls = (try? c.decodeIfPresent([String: Gesture].self, forKey: .clickControls)) ?? nil
        clickControls = d.clickControls
        for (key, gesture) in controls ?? [:] {
            if let control = ClickControl(rawValue: key) { clickControls[control] = gesture }
        }
        motion = try c.decodeIfPresent(MotionProfile.self, forKey: .motion) ?? d.motion
        scrolling = try c.decodeIfPresent(ScrollProfile.self, forKey: .scrolling) ?? d.scrolling
        dragStyle = try c.decodeIfPresent(DragStyle.self, forKey: .dragStyle) ?? d.dragStyle
        exitCursorOnMouse = try c.decodeIfPresent(Bool.self, forKey: .exitCursorOnMouse) ?? d.exitCursorOnMouse
        confineToCurrentDisplay = try c.decodeIfPresent(Bool.self, forKey: .confineToCurrentDisplay) ?? d.confineToCurrentDisplay
        clickSearchFirst = try c.decodeIfPresent(Bool.self, forKey: .clickSearchFirst) ?? d.clickSearchFirst
        clickRequireReturn = try c.decodeIfPresent(Bool.self, forKey: .clickRequireReturn) ?? d.clickRequireReturn
        clickStaysActive = try c.decodeIfPresent(Bool.self, forKey: .clickStaysActive) ?? d.clickStaysActive
        clickPointerFallback = try c.decodeIfPresent(Bool.self, forKey: .clickPointerFallback) ?? d.clickPointerFallback
        clickLabelsMenuBar = try c.decodeIfPresent(Bool.self, forKey: .clickLabelsMenuBar) ?? d.clickLabelsMenuBar
        clickLabelsDock = try c.decodeIfPresent(Bool.self, forKey: .clickLabelsDock) ?? d.clickLabelsDock
        clickAlphabet = try c.decodeIfPresent(String.self, forKey: .clickAlphabet) ?? d.clickAlphabet
        modifierTapMaxMilliseconds = try c.decodeIfPresent(Int.self, forKey: .modifierTapMaxMilliseconds) ?? d.modifierTapMaxMilliseconds
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? d.excludedBundleIDs
        appearance = try c.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? d.appearance
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(profileName, forKey: .profileName)
        try c.encode(cursorEntry, forKey: .cursorEntry)
        try c.encode(clickEntry, forKey: .clickEntry)
        try c.encode(scrollEntry, forKey: .scrollEntry)
        try c.encode(cursorBindings, forKey: .cursorBindings)
        // Human-readable: control names as keys.
        try c.encode(Dictionary(uniqueKeysWithValues: clickControls.map { ($0.key.rawValue, $0.value) }), forKey: .clickControls)
        try c.encode(motion, forKey: .motion)
        try c.encode(scrolling, forKey: .scrolling)
        try c.encode(dragStyle, forKey: .dragStyle)
        try c.encode(exitCursorOnMouse, forKey: .exitCursorOnMouse)
        try c.encode(confineToCurrentDisplay, forKey: .confineToCurrentDisplay)
        try c.encode(clickSearchFirst, forKey: .clickSearchFirst)
        try c.encode(clickRequireReturn, forKey: .clickRequireReturn)
        try c.encode(clickStaysActive, forKey: .clickStaysActive)
        try c.encode(clickPointerFallback, forKey: .clickPointerFallback)
        try c.encode(clickLabelsMenuBar, forKey: .clickLabelsMenuBar)
        try c.encode(clickLabelsDock, forKey: .clickLabelsDock)
        try c.encode(clickAlphabet, forKey: .clickAlphabet)
        try c.encode(modifierTapMaxMilliseconds, forKey: .modifierTapMaxMilliseconds)
        try c.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
    }
}

/// Built-in presets. Presets are selected explicitly; updates never replace a saved config.
public enum Presets {
    public static let standardClickControls: [ClickControl: Gesture] = [
        .startSearch: .key(code: Key.slash, modifiers: []),
        .nextTarget: .key(code: Key.tab, modifiers: []),
        .previousTarget: .key(code: Key.tab, modifiers: [.shift]),
        .activateSelected: .key(code: Key.returnKey, modifiers: []),
        .backspace: .key(code: Key.delete, modifiers: []),
        .cycleAction: .key(code: Key.period, modifiers: []),
        .refresh: .key(code: Key.r, modifiers: [.command])
    ]

    private static func key(_ code: UInt16, _ modifiers: Modifiers = []) -> Gesture {
        .key(code: code, modifiers: modifiers)
    }

    /// Movement on I/J/K/L, scrolling on arrows, Space clicks (hold it to drag) and Shift-Space right-clicks,
    /// E/W/Q for the other buttons. No modifier drags by default: Command held for a shortcut would grab the mouse.
    public static let standard = Preset(
        name: "Standard",
        summary: "I J K L move, arrows scroll, Space clicks, Shift-Space right-clicks.",
        cursorBindings: [
            CursorBinding(action: .moveUp, gesture: key(Key.i)),
            CursorBinding(action: .moveLeft, gesture: key(Key.j)),
            CursorBinding(action: .moveDown, gesture: key(Key.k)),
            CursorBinding(action: .moveRight, gesture: key(Key.l)),
            CursorBinding(action: .scrollUp, gesture: key(Key.upArrow)),
            CursorBinding(action: .scrollDown, gesture: key(Key.downArrow)),
            CursorBinding(action: .scrollLeft, gesture: key(Key.leftArrow)),
            CursorBinding(action: .scrollRight, gesture: key(Key.rightArrow)),
            CursorBinding(action: .leftClick, gesture: key(Key.space)),
            CursorBinding(action: .rightClick, gesture: key(Key.space, [.shift])),
            CursorBinding(action: .middleClick, gesture: key(Key.e)),
            CursorBinding(action: .backButton, gesture: key(Key.w)),
            CursorBinding(action: .forwardButton, gesture: key(Key.q)),
            CursorBinding(action: .precision, gesture: key(Key.a)),
            CursorBinding(action: .boost, gesture: key(Key.s)),
            CursorBinding(action: .help, gesture: key(Key.slash, [.shift]))
        ]
    )

    /// For people coming from Mouseless: "/" scrolls right, D and F also boost.
    public static let mouseless: Preset = {
        var bindings = standard.cursorBindings.filter { $0.action != .scrollRight }
        bindings.append(CursorBinding(action: .scrollRight, gesture: key(Key.slash)))
        bindings.append(CursorBinding(action: .boost, gesture: key(Key.d)))
        bindings.append(CursorBinding(action: .boost, gesture: key(Key.f)))
        return Preset(name: "Mouseless",
                      summary: "Standard, plus / scrolls right, D and F boost.",
                      cursorBindings: bindings)
    }()

    /// Vim-style movement on H/J/K/L, arrows still scroll.
    public static let vim: Preset = {
        let bindings = standard.cursorBindings.map { binding -> CursorBinding in
            switch binding.action {
            case .moveUp: return CursorBinding(action: .moveUp, gesture: key(Key.k))
            case .moveDown: return CursorBinding(action: .moveDown, gesture: key(Key.j))
            case .moveLeft: return CursorBinding(action: .moveLeft, gesture: key(Key.h))
            case .moveRight: return CursorBinding(action: .moveRight, gesture: key(Key.l))
            default: return binding
            }
        }
        return Preset(name: "Vim HJKL", summary: "H J K L move, arrows scroll.", cursorBindings: bindings)
    }()

    /// Arrow keys move; scrolling moves to Shift-arrows so the two never overlap.
    public static let arrows: Preset = {
        var bindings = standard.cursorBindings.filter { $0.action.group != .move && $0.action.group != .scroll }
        bindings += [
            CursorBinding(action: .moveUp, gesture: key(Key.upArrow)),
            CursorBinding(action: .moveDown, gesture: key(Key.downArrow)),
            CursorBinding(action: .moveLeft, gesture: key(Key.leftArrow)),
            CursorBinding(action: .moveRight, gesture: key(Key.rightArrow)),
            CursorBinding(action: .scrollUp, gesture: key(Key.upArrow, [.shift])),
            CursorBinding(action: .scrollDown, gesture: key(Key.downArrow, [.shift])),
            CursorBinding(action: .scrollLeft, gesture: key(Key.leftArrow, [.shift])),
            CursorBinding(action: .scrollRight, gesture: key(Key.rightArrow, [.shift]))
        ]
        return Preset(name: "Arrow keys", summary: "Arrows move, Shift-arrows scroll.", cursorBindings: bindings)
    }()

    public static let all: [Preset] = [standard, mouseless, vim, arrows]
}

public struct Preset: Equatable, Sendable {
    public var name: String
    public var summary: String
    public var cursorBindings: [CursorBinding]
    /// Optional Click start shortcut that comes with the preset.
    public var clickEntry: Gesture?

    public init(name: String, summary: String = "", cursorBindings: [CursorBinding], clickEntry: Gesture? = nil) {
        self.name = name
        self.summary = summary
        self.cursorBindings = cursorBindings
        self.clickEntry = clickEntry
    }
}

/// A reviewable list of binding changes, used before replacing bindings with a preset or an import.
public struct BindingChange: Equatable, Sendable, Identifiable {
    public var id: String { action.rawValue }
    public var action: CursorAction
    public var before: [Gesture]
    public var after: [Gesture]

    public static func diff(from old: [CursorBinding], to new: [CursorBinding]) -> [BindingChange] {
        CursorAction.allCases.compactMap { action in
            let before = old.filter { $0.action == action }.map(\.gesture)
            let after = new.filter { $0.action == action }.map(\.gesture)
            return Set(before) == Set(after) ? nil : BindingChange(action: action, before: before, after: after)
        }
    }
}
