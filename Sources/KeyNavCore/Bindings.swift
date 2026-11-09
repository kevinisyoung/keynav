/// A compiled, immutable lookup from gesture to action for one context.
public struct BindingTable<Action: Hashable & Sendable>: Sendable {
    public struct Conflict: Equatable, Sendable {
        public let gesture: Gesture
        public let first: Action
        public let second: Action
    }

    public private(set) var lookup: [Gesture: Action]
    public let conflicts: [Conflict]

    /// Compiles bindings for one context. Duplicate gestures are reported, never silently overwritten.
    /// The first binding is kept in the lookup so behavior stays deterministic; callers must refuse to save conflicts.
    public init(_ pairs: [(Gesture, Action)]) {
        var lookup: [Gesture: Action] = [:]
        var conflicts: [Conflict] = []
        for (gesture, action) in pairs {
            if let existing = lookup[gesture] {
                if existing != action {
                    conflicts.append(Conflict(gesture: gesture, first: existing, second: action))
                }
                continue
            }
            lookup[gesture] = action
        }
        self.lookup = lookup
        self.conflicts = conflicts
    }

    public subscript(gesture: Gesture) -> Action? {
        lookup[gesture]
    }

    /// Plain key lookup used by the routers; modifiers are part of the gesture identity.
    public func action(forKey code: UInt16, modifiers: Modifiers) -> Action? {
        lookup[.key(code: code, modifiers: modifiers)]
    }
}
