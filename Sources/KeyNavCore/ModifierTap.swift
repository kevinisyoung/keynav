/// Recognizes a lone modifier tap: pressed, released within `maxDuration`, with no other input in between.
///
/// Feed every modifier transition and every other input. A tap is reported on release only.
/// Holding a modifier longer than the threshold never reports a tap, even if nothing else happened.
public struct ModifierTapRecognizer: Sendable {
    public let maxDuration: Double

    private var held: Set<UInt16> = []
    private var candidate: UInt16?
    private var candidateStart: Double = 0
    /// Set when anything other than this recognizer's modifiers has interrupted the current press.
    private var invalidated = false

    public init(maxDuration: Double = 0.25) {
        self.maxDuration = maxDuration
    }

    /// Returns the tapped modifier key code when a valid tap completes.
    /// `down` and `others` (the other modifiers held) come from the event itself, so a release missed while
    /// the event tap was off cannot leave the recognizer out of step with the keyboard.
    public mutating func modifierChanged(code: UInt16, down: Bool, others: Modifiers = [], at time: Double) -> UInt16? {
        guard Key.modifierKeys.contains(code) else { return nil }
        // Forget keys the event says are no longer held. A key sharing this one's flag can't be checked.
        let own = Key.modifierFlag(for: code)
        held = held.filter { key in
            let flag = Key.modifierFlag(for: key)
            return key == code || flag == own || others.isSuperset(of: flag)
        }

        if !down {
            guard held.contains(code) else {
                if held.isEmpty { reset() }
                return nil
            }
            held.remove(code)
            defer {
                if held.isEmpty { reset() }
            }
            guard !invalidated, candidate == code, held.isEmpty else { return nil }
            guard time - candidateStart <= maxDuration else { return nil }
            return code
        }

        // A second modifier while one is held cancels the candidate: both sides held is not a tap.
        held.remove(code)
        if held.isEmpty {
            candidate = code
            candidateStart = time
            invalidated = false
        } else {
            invalidated = true
        }
        held.insert(code)
        return nil
    }

    /// Any non-modifier key, mouse button, wheel, or drag while a modifier is down cancels the candidate.
    public mutating func otherInput() {
        invalidated = true
    }

    /// Clears all state. Call on sleep, permission change, or event-tap interruption.
    public mutating func reset() {
        held.removeAll()
        candidate = nil
        invalidated = false
    }
}
