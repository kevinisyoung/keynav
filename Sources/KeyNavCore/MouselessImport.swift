import Foundation

/// Translates a Mouseless `config.yaml` into a proposed KeyNav configuration, by meaning, for review.
///
/// Only the keymap and tap threshold are read. Mouseless speeds are frame-based and are not converted;
/// grid, overlay, and label-style commands are listed as unsupported instead of being dropped silently.
/// Nothing here writes to, disables, or depends on Mouseless.
public enum MouselessImport {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String { source }
        /// Mouseless command name.
        public var source: String
        /// Mouseless binding as written in the file.
        public var sourceBinding: String
        /// Proposed KeyNav action and key, or a dash when nothing is proposed.
        public var proposal: String
        /// Why the row needs attention, if it does.
        public var issue: String?
    }

    public struct Result: Equatable, Sendable {
        public var rows: [Row]
        public var proposed: KeyNavConfig
        /// Blocking problems in the proposed configuration. If non-empty, it must not be applied.
        public var problems: [String]
    }

    static let cursorActions: [String: CursorAction] = [
        "move up": .moveUp, "move down": .moveDown, "move left": .moveLeft, "move right": .moveRight,
        "wheel up": .scrollUp, "wheel down": .scrollDown, "wheel left": .scrollLeft, "wheel right": .scrollRight,
        "left mouse button": .leftClick, "left click": .leftClick, "execute mouse action": .leftClick,
        "right mouse button": .rightClick, "right click": .rightClick,
        "middle mouse button": .middleClick, "middle click": .middleClick,
        "back mouse button": .backButton, "back click": .backButton,
        "forward mouse button": .forwardButton, "forward click": .forwardButton,
        "hold for drag": .dragHold,
        "hold for speed decrease": .precision,
        "hold for speed increase": .boost
    ]

    static let semanticNotes: [String: String] = [
        "execute mouse action": "Mouseless runs the selected button; KeyNav maps this key to a left click.",
        "left mouse button": "Mouseless selects the left button; KeyNav clicks it directly."
    ]

    public static func translate(yaml: String, base: KeyNavConfig) -> Result {
        let parsed = parse(yaml)
        var rows: [Row] = []
        var proposed = base
        var newBindings: [CursorAction: [Gesture]] = [:]

        for (name, values) in parsed.entries.sorted(by: { $0.key < $1.key }) {
            let written = values.isEmpty ? "none" : values.joined(separator: ", ")
            guard !values.isEmpty else { continue }

            if let action = cursorActions[name] {
                var proposals: [String] = []
                var issue = semanticNotes[name]
                for value in values {
                    guard let gesture = gesture(from: value) else {
                        issue = "“\(value)” is not a key KeyNav recognizes."
                        continue
                    }
                    if case .modifierTap = gesture {
                        issue = "A modifier tap cannot be an in-mode action."
                        continue
                    }
                    newBindings[action, default: []].append(gesture)
                    proposals.append(gesture.displayName)
                }
                rows.append(Row(source: name, sourceBinding: written,
                                proposal: proposals.isEmpty ? "—" : "\(action.title): \(proposals.joined(separator: ", "))",
                                issue: issue))
            } else if name == "exit free mode", let value = values.first, let gesture = gesture(from: value) {
                proposed.cursorEntry.exit = gesture
                proposed.cursorEntry.separateExit = true
                rows.append(Row(source: name, sourceBinding: written, proposal: "Moving stop: \(gesture.displayName)", issue: nil))
            } else if ["toggle free mode", "enter free mode"].contains(name), let value = values.first, let gesture = gesture(from: value) {
                proposed.cursorEntry.gesture = gesture
                proposed.cursorEntry.separateExit = name == "enter free mode"
                rows.append(Row(source: name, sourceBinding: written, proposal: "Moving start: \(gesture.displayName)",
                                issue: "Check that Mouseless no longer uses this key, or both apps will react."))
            } else if ["toggle label mode", "enter label mode"].contains(name), let value = values.first, let gesture = gesture(from: value) {
                proposed.clickEntry.gesture = gesture
                rows.append(Row(source: name, sourceBinding: written, proposal: "Clicking start: \(gesture.displayName)",
                                issue: "Mouseless labels are grid cells; KeyNav labels accessible controls."))
            } else {
                rows.append(Row(source: name, sourceBinding: written, proposal: "—",
                                issue: "Not supported in KeyNav (grid, overlay, or Mouseless-specific command)."))
            }
        }

        if !newBindings.isEmpty {
            // Actions the file binds are replaced; actions it does not mention keep the current keys.
            var bindings = base.cursorBindings.filter { newBindings[$0.action] == nil }
            for action in CursorAction.allCases {
                for gesture in newBindings[action] ?? [] {
                    bindings.append(CursorBinding(action: action, gesture: gesture))
                }
            }
            proposed.cursorBindings = bindings
            proposed.profileName = "Imported from Mouseless"
        }
        if let threshold = parsed.tapThresholdMs {
            proposed.modifierTapMaxMilliseconds = min(max(threshold, 100), 600)
            rows.append(Row(source: "tap_threshold_ms", sourceBinding: "\(threshold)",
                            proposal: "Modifier tap limit: \(proposed.modifierTapMaxMilliseconds) ms", issue: nil))
        }
        if parsed.hasSpeedSettings {
            rows.append(Row(source: "base_move_speed and multipliers", sourceBinding: "frame-based",
                            proposal: "Keeps \(base.motion.presetName ?? "custom") speed",
                            issue: "Mouseless speeds are per frame and cannot be converted exactly. Tune with the practice area."))
        }
        return Result(rows: rows, proposed: proposed, problems: ConfigValidator.problems(in: proposed))
    }

    /// Parses Mouseless key strings such as "W", "Enter", "ArrowUp", "/", "CommandLeft", "OptionLeft tap", "shift+3".
    public static func gesture(from text: String) -> Gesture? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.first == "'" || value.first == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        let isTap = value.hasSuffix(" tap")
        if isTap { value = String(value.dropLast(4)) }

        let modifierKeys: [String: UInt16] = [
            "CommandLeft": Key.leftCommand, "CommandRight": Key.rightCommand,
            "OptionLeft": Key.leftOption, "OptionRight": Key.rightOption,
            "AltLeft": Key.leftOption, "AltRight": Key.rightOption,
            "ShiftLeft": Key.leftShift, "ShiftRight": Key.rightShift,
            "ControlLeft": Key.leftControl, "ControlRight": Key.rightControl
        ]
        if let code = modifierKeys[value] {
            return isTap ? .modifierTap(code: code) : .key(code: code, modifiers: [])
        }
        guard !isTap else { return nil }

        var modifiers: Modifiers = []
        var parts = value.split(separator: "+").map(String.init)
        if parts.count > 1 {
            let keyPart = parts.removeLast()
            for part in parts {
                switch part.lowercased() {
                case "shift": modifiers.insert(.shift)
                case "cmd", "command": modifiers.insert(.command)
                case "alt", "option": modifiers.insert(.option)
                case "ctrl", "control": modifiers.insert(.control)
                default: return nil
                }
            }
            value = keyPart
        }

        let named: [String: UInt16] = [
            "Enter": Key.returnKey, "Return": Key.returnKey, "Space": Key.space, "Escape": Key.escape,
            "Tab": Key.tab, "Backspace": Key.delete, "ArrowUp": Key.upArrow, "ArrowDown": Key.downArrow,
            "ArrowLeft": Key.leftArrow, "ArrowRight": Key.rightArrow
        ]
        if let code = named[value] { return .key(code: code, modifiers: modifiers) }
        if value.count == 1,
           let code = Key.printableCodes.first(where: { $0.value.count == 1 && $0.value.lowercased() == value.lowercased() })?.key {
            return .key(code: code, modifiers: modifiers)
        }
        return nil
    }

    struct Parsed {
        var entries: [String: [String]] = [:]
        var tapThresholdMs: Int?
        var hasSpeedSettings = false
    }

    /// A deliberately small reader for the parts of the file KeyNav uses. It is not a general YAML parser.
    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        var inEntries = false
        var currentKey: String?
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            let field = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            if field.hasPrefix("tap_threshold_ms:") {
                parsed.tapThresholdMs = Int(field.dropFirst("tap_threshold_ms:".count).trimmingCharacters(in: .whitespaces))
            }
            if field.hasPrefix("base_move_speed:") || field.hasPrefix("move_speed_multiplier:") {
                parsed.hasSpeedSettings = true
            }
            if trimmed == "- entries:" {
                inEntries = true
                currentKey = nil
                continue
            }
            guard inEntries else { continue }
            if indent < 4 {
                inEntries = false
                currentKey = nil
                continue
            }
            if trimmed.hasPrefix("- "), let key = currentKey {
                parsed.entries[key, default: []].append(String(trimmed.dropFirst(2)))
                continue
            }
            guard let colon = trimmed.range(of: ": ") ?? (trimmed.hasSuffix(":") ? trimmed.range(of: ":", options: .backwards) : nil) else {
                continue
            }
            let key = String(trimmed[..<colon.lowerBound])
            let value = String(trimmed[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            currentKey = key
            if value.isEmpty || value == "null" {
                parsed.entries[key] = parsed.entries[key] ?? []
            } else {
                parsed.entries[key] = [value]
            }
        }
        return parsed
    }
}
