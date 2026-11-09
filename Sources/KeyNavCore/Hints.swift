import Foundation

/// A target the Click engine can label. `frame` is in global CoreGraphics coordinates (top-left origin).
public struct HintTarget: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var center: (x: Double, y: Double) {
            (x + width / 2, y + height / 2)
        }
    }

    public var name: String
    public var role: String
    public var frame: Frame

    public init(name: String, role: String, frame: Frame) {
        self.name = name
        self.role = role
        self.frame = frame
    }
}

public enum LabelGenerator {
    /// Fixed-length, prefix-free labels. Every label has the same length, so no label prefixes another.
    /// Returns an empty list when the alphabet cannot make `count` distinct labels of any length.
    public static func labels(count: Int, alphabet: [Character]) -> [String] {
        guard count > 0 else { return [] }
        let base = alphabet.count
        guard base >= 2 else { return [] }
        var length = 1
        var capacity = base
        while capacity < count {
            length += 1
            capacity *= base
            if length > 6 { return [] }
        }
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            var value = index
            var chars: [Character] = []
            for _ in 0..<length {
                chars.append(alphabet[value % base])
                value /= base
            }
            result.append(String(chars.reversed()))
        }
        return result
    }

    /// Removes characters that are reserved for navigation, so no label ever needs a reserved key.
    public static func usableAlphabet(_ alphabet: String, reserved: Set<Character>) -> [Character] {
        var seen = Set<Character>()
        var result: [Character] = []
        for character in alphabet.lowercased() where !reserved.contains(character) && !seen.contains(character) {
            if character.isLetter || character.isNumber {
                seen.insert(character)
                result.append(character)
            }
        }
        return result
    }
}

/// Deterministic, Unicode-aware search matching. Diacritics and case are folded; ordering is stable.
public enum TargetSearch {
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Indices of `names` that match every query token, best match first.
    public static func rank(query: String, names: [String]) -> [Int] {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        let indexed = names.enumerated().map { index, name in (index, normalize(name)) }
        guard !tokens.isEmpty else { return indexed.map(\.0) }

        var scored: [(index: Int, tier: Int, length: Int)] = []
        for (index, name) in indexed {
            guard tokens.allSatisfy({ name.contains($0) }) else { continue }
            let first = tokens[0]
            let tier: Int
            if name.hasPrefix(first) {
                tier = 0
            } else if name.contains(" " + first) {
                tier = 1
            } else {
                tier = 2
            }
            scored.append((index, tier, name.count))
        }
        scored.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.index < rhs.index
        }
        return scored.map(\.index)
    }
}

/// The state of one Click-mode session: labels or search, a frozen target snapshot, and the pending action.
public struct ClickSession: Sendable {
    public enum Substate: Equatable, Sendable {
        case labels
        case search
    }

    /// What the engine wants the system to do after a key.
    public enum Decision: Equatable, Sendable {
        case unhandled
        case consumed
        case activate(target: Int, action: TargetAction)
        /// Scroll the area under the pointer (labels view arrows). Points; positive dy shows earlier content.
        case scroll(dx: Double, dy: Double)
        case refresh
    }

    public private(set) var substate: Substate
    public private(set) var targets: [HintTarget] = []
    public private(set) var labels: [String] = []
    /// Identifies the discovery snapshot the labels belong to. Activation must name the same snapshot.
    public private(set) var snapshot = 0
    public private(set) var hasSnapshot = false
    public private(set) var typedPrefix = ""
    public private(set) var query = ""
    /// Index into the currently visible list (labels or search results).
    public private(set) var selection = 0
    public private(set) var pendingAction = TargetAction.press
    public var alphabet: [Character]
    public var requireReturn: Bool

    public init(alphabet: [Character], requireReturn: Bool = false, searchFirst: Bool = false) {
        self.alphabet = alphabet
        self.requireReturn = requireReturn
        self.substate = searchFirst ? .search : .labels
    }

    /// A refresh must not change codes under a half-typed label.
    public var acceptsNewSnapshot: Bool {
        typedPrefix.isEmpty
    }

    /// Replaces the snapshot. The search query survives a refresh of the same window.
    public mutating func setTargets(_ newTargets: [HintTarget], snapshot: Int) {
        targets = newTargets
        labels = LabelGenerator.labels(count: newTargets.count, alphabet: alphabet)
        self.snapshot = snapshot
        hasSnapshot = true
        typedPrefix = ""
        selection = 0
    }

    /// Forgets a typed label, e.g. after it was used for an activation attempt.
    public mutating func clearTypedLabel() {
        typedPrefix = ""
        selection = 0
    }

    /// Indices of targets currently visible in the active substate, in display order.
    public var visible: [Int] {
        switch substate {
        case .labels:
            return labels.indices.filter { labels[$0].hasPrefix(typedPrefix) }
        case .search:
            return TargetSearch.rank(query: query, names: targets.map(\.name))
        }
    }

    public var selectedTarget: Int? {
        let list = visible
        return list.indices.contains(selection) ? list[selection] : nil
    }

    public mutating func handle(_ event: KeyEvent, controls: [Gesture: ClickControl]) -> Decision {
        guard event.kind == .down else { return .consumed }
        if let control = controls[.key(code: event.code, modifiers: event.modifiers)] {
            return handleControl(control)
        }
        if let arrow = arrowDirection(event.code), event.modifiers.isDisjoint(with: [.command, .control, .option]) {
            switch substate {
            case .labels:
                return .scroll(dx: arrow.dx * 120, dy: arrow.dy * 120)
            case .search:
                if arrow.dy != 0 { moveSelection(arrow.dy > 0 ? -1 : 1) }
                return .consumed
            }
        }
        guard event.modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return .unhandled
        }
        guard let character = event.character?.lowercased(), character.count == 1 else {
            return event.typesCharacter ? .consumed : .unhandled
        }
        switch substate {
        case .labels:
            return typeLabelCharacter(Character(character))
        case .search:
            query.append(Character(character))
            selection = 0
            return .consumed
        }
    }

    private func arrowDirection(_ code: UInt16) -> (dx: Double, dy: Double)? {
        switch code {
        case Key.upArrow: return (0, 1)
        case Key.downArrow: return (0, -1)
        case Key.leftArrow: return (-1, 0)
        case Key.rightArrow: return (1, 0)
        default: return nil
        }
    }

    private mutating func handleControl(_ control: ClickControl) -> Decision {
        switch control {
        case .startSearch:
            guard substate == .labels else { return .consumed }
            substate = .search
            typedPrefix = ""
            selection = 0
            return .consumed
        case .nextTarget:
            moveSelection(1)
            return .consumed
        case .previousTarget:
            moveSelection(-1)
            return .consumed
        case .activateSelected:
            guard let target = selectedTarget else { return .consumed }
            return .activate(target: target, action: pendingAction)
        case .cycleAction:
            pendingAction = pendingAction.next
            return .consumed
        case .refresh:
            typedPrefix = ""
            return .refresh
        case .backspace:
            switch substate {
            case .labels:
                if !typedPrefix.isEmpty { typedPrefix.removeLast() }
            case .search:
                if query.isEmpty {
                    substate = .labels
                } else {
                    query.removeLast()
                }
            }
            selection = 0
            return .consumed
        }
    }

    private mutating func typeLabelCharacter(_ character: Character) -> Decision {
        guard alphabet.contains(character) else { return .consumed }
        let candidate = typedPrefix + String(character)
        guard labels.contains(where: { $0.hasPrefix(candidate) }) else {
            // An unused code is ignored rather than starting a new selection.
            return .consumed
        }
        typedPrefix = candidate
        selection = 0
        guard let exact = labels.firstIndex(of: candidate) else { return .consumed }
        if requireReturn {
            selection = visible.firstIndex(of: exact) ?? 0
            return .consumed
        }
        return .activate(target: exact, action: pendingAction)
    }

    private mutating func moveSelection(_ step: Int) {
        let count = visible.count
        guard count > 0 else {
            selection = 0
            return
        }
        selection = ((selection + step) % count + count) % count
    }
}
