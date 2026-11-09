import Foundation

public enum MouseButton: Hashable, Sendable {
    case left, right, middle, back, forward
}

/// Output of the Cursor engine. The system layer executes these; the engine never touches the OS.
public enum CursorCommand: Equatable, Sendable {
    /// Pointer displacement in points for one tick.
    case move(dx: Double, dy: Double)
    /// Scroll displacement in points. Positive `dy` means "show earlier content" (wheel up).
    case scroll(dx: Double, dy: Double)
    case press(MouseButton)
    case release(MouseButton)
    case click(MouseButton, clickCount: Int)
    /// One half of a click whose key is held: the button stays down until the key comes up, so moving drags.
    case buttonDown(MouseButton, clickCount: Int)
    case buttonUp(MouseButton, clickCount: Int)
}

/// Continuous Cursor mode behavior. Pure and deterministic: time comes in as a parameter.
public struct CursorEngine: Sendable {
    public private(set) var bindings: BindingTable<CursorAction>
    public var motion: MotionProfile
    public var scrolling: ScrollProfile
    public var doubleClickInterval: Double
    public var doubleClickTolerance: Double
    public var dragStyle: DragStyle

    /// Actions whose key is currently down. Holds, movement, and scrolling read from this set.
    public private(set) var held: Set<CursorAction> = []
    private var moveElapsed: Double = 0
    private var scrollElapsed: Double = 0
    public private(set) var leftDown = false
    /// Modifier keys currently held as Cursor actions (for example Left Command for drag).
    /// Their flags are ignored when matching other keys, so I/J/K/L still move while dragging.
    private var heldModifierCodes: Set<UInt16> = []
    /// Buttons held down by a click key (Space), by key code, with their click count.
    public private(set) var heldButtons: [UInt16: (button: MouseButton, count: Int)] = [:]
    private var lastClick: (time: Double, x: Double, y: Double, button: MouseButton, count: Int)?

    public init(
        bindings: [CursorBinding],
        motion: MotionProfile = .gentle,
        scrolling: ScrollProfile = .standard,
        doubleClickInterval: Double = 0.5,
        doubleClickTolerance: Double = 5,
        dragStyle: DragStyle = .hold
    ) {
        self.dragStyle = dragStyle
        self.bindings = BindingTable(bindings.map { (($0.gesture), $0.action) })
        self.motion = motion.clamped
        self.scrolling = scrolling
        self.doubleClickInterval = doubleClickInterval
        self.doubleClickTolerance = doubleClickTolerance
    }

    public mutating func replaceBindings(_ bindings: [CursorBinding]) -> [CursorCommand] {
        let release = resetCommands()
        self.bindings = BindingTable(bindings.map { (($0.gesture), $0.action) })
        return release
    }

    /// Returns whether the key is consumed and any immediate commands.
    /// `pointer` is the current pointer location, used for click-count detection.
    public mutating func keyDown(
        _ event: KeyEvent, at time: Double, pointer: (x: Double, y: Double)
    ) -> (consumed: Bool, commands: [CursorCommand]) {
        guard let action = lookup(event) else {
            return (consumesUnmatched(event), [])
        }
        if event.isModifierKey { heldModifierCodes.insert(event.code) }
        if event.isRepeat {
            // Key repeat must not restart ramps or clicks; the held state already reflects the key.
            return (true, [])
        }
        switch action {
        case .dragHold:
            if dragStyle == .toggle {
                leftDown.toggle()
                return (true, [leftDown ? .press(.left) : .release(.left)])
            }
            held.insert(action)
            leftDown = true
            return (true, [.press(.left)])
        case .help:
            // The router turns this into a help overlay; the engine only owns the key.
            return (true, [])
        case .precision, .boost, .moveUp, .moveDown, .moveLeft, .moveRight,
             .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            // A first movement or scroll key starts from the slow end of the ramp.
            if Self.moveActions.contains(action), held.isDisjoint(with: Self.moveActions) { moveElapsed = 0 }
            if Self.scrollActions.contains(action), held.isDisjoint(with: Self.scrollActions) { scrollElapsed = 0 }
            held.insert(action)
            return (true, [])
        case .leftClick:
            return (true, buttonDown(.left, code: event.code, time, pointer))
        case .rightClick:
            return (true, buttonDown(.right, code: event.code, time, pointer))
        case .middleClick:
            return (true, buttonDown(.middle, code: event.code, time, pointer))
        case .backButton:
            return (true, [click(.back, count: 1, time, pointer)])
        case .forwardButton:
            return (true, [click(.forward, count: 1, time, pointer)])
        case .doubleClick:
            return (true, [click(.left, count: 2, time, pointer)])
        }
    }

    public mutating func keyUp(_ event: KeyEvent) -> (consumed: Bool, commands: [CursorCommand]) {
        // Released by key code, so a modifier pressed mid-drag cannot strand the button down.
        if let held = heldButtons.removeValue(forKey: event.code) {
            return (true, [.buttonUp(held.button, clickCount: held.count)])
        }
        guard let action = lookup(event) else {
            return (consumesUnmatched(event), [])
        }
        if event.isModifierKey { heldModifierCodes.remove(event.code) }
        if action == .dragHold {
            guard dragStyle == .hold else { return (true, []) }
            held.remove(.dragHold)
            leftDown = false
            return (true, [.release(.left)])
        }
        held.remove(action)
        // The tick timer stops once nothing moves, so the ramp has to restart here, not in `tick`.
        if held.isDisjoint(with: Self.moveActions) { moveElapsed = 0 }
        if held.isDisjoint(with: Self.scrollActions) { scrollElapsed = 0 }
        return (true, [])
    }

    static let moveActions: Set<CursorAction> = [.moveUp, .moveDown, .moveLeft, .moveRight]
    static let scrollActions: Set<CursorAction> = [.scrollUp, .scrollDown, .scrollLeft, .scrollRight]

    /// Advances continuous motion and scrolling. Call at a steady rate while any movement or scroll is held.
    public mutating func tick(dt: Double) -> [CursorCommand] {
        guard dt > 0 else { return [] }
        var commands: [CursorCommand] = []

        var dx = 0.0
        var dy = 0.0
        if held.contains(.moveRight) { dx += 1 }
        if held.contains(.moveLeft) { dx -= 1 }
        if held.contains(.moveDown) { dy += 1 }
        if held.contains(.moveUp) { dy -= 1 }
        if dx == 0, dy == 0 {
            moveElapsed = 0
        } else {
            moveElapsed += dt
            let length = (dx * dx + dy * dy).squareRoot()
            let speed = currentMoveSpeed() * dt
            commands.append(.move(dx: dx / length * speed, dy: dy / length * speed))
        }

        var sx = 0.0
        var sy = 0.0
        if held.contains(.scrollUp) { sy += 1 }
        if held.contains(.scrollDown) { sy -= 1 }
        if held.contains(.scrollRight) { sx += 1 }
        if held.contains(.scrollLeft) { sx -= 1 }
        if sx == 0, sy == 0 {
            scrollElapsed = 0
        } else {
            scrollElapsed += dt
            let speed = currentScrollSpeed() * dt
            let sign = scrolling.reverse ? -1.0 : 1.0
            commands.append(.scroll(dx: sx * speed * sign, dy: sy * speed * sign))
        }
        return commands
    }

    /// True while any movement or scroll action is held, i.e. when a tick timer is needed.
    public var needsTicks: Bool {
        !held.isDisjoint(with: [.moveUp, .moveDown, .moveLeft, .moveRight,
                                .scrollUp, .scrollDown, .scrollLeft, .scrollRight])
    }

    /// Ends all KeyNav-owned input. Safe to call repeatedly.
    public mutating func reset() -> [CursorCommand] {
        resetCommands()
    }

    /// Clears acceleration, e.g. after the person moves the physical mouse.
    public mutating func resetRamp() {
        moveElapsed = 0
        scrollElapsed = 0
    }

    /// Current pointer speed in points per second, for display and tests.
    public func currentMoveSpeed() -> Double {
        let ramp = smoothRamp(moveElapsed, duration: motion.rampSeconds)
        let base = motion.initialSpeed + (motion.maximumSpeed - motion.initialSpeed) * ramp
        // Precision wins over boost when both are held, so the person can always slow down.
        if held.contains(.precision) { return base * motion.precisionMultiplier }
        if held.contains(.boost) { return base * motion.boostMultiplier }
        return base
    }

    public func currentScrollSpeed() -> Double {
        let ramp = smoothRamp(scrollElapsed, duration: scrolling.rampSeconds)
        let speed = scrolling.maximumSpeed * (0.2 + 0.8 * ramp)
        if held.contains(.precision) { return speed * motion.precisionMultiplier }
        if held.contains(.boost) { return speed * motion.boostMultiplier }
        return speed
    }

    // MARK: - Private

    private func lookup(_ event: KeyEvent) -> CursorAction? {
        if let action = bindings.action(forKey: event.code, modifiers: event.modifiers) { return action }
        let own = heldModifierCodes.reduce(Modifiers()) { $0.union(Key.modifierFlag(for: $1)) }
        if !own.isEmpty, let action = bindings.action(forKey: event.code, modifiers: event.modifiers.subtracting(own)) {
            return action
        }
        return modifierFreeMatch(event)
    }

    private func modifierFreeMatch(_ event: KeyEvent) -> CursorAction? {
        // Modifier keys are bound without their own flag; this covers bindings like Left Command.
        guard event.isModifierKey else { return nil }
        return bindings.action(forKey: event.code, modifiers: [])
    }

    /// Unbound unmodified printable keys are consumed so they do not type into the app underneath.
    /// Unbound Command/Control/Option shortcuts pass through to the app.
    private func consumesUnmatched(_ event: KeyEvent) -> Bool {
        let own = heldModifierCodes.reduce(Modifiers()) { $0.union(Key.modifierFlag(for: $1)) }
        // While a modifier is held as a Cursor action, its shortcuts belong to KeyNav, not the app.
        if !own.isEmpty, !event.modifiers.intersection(own).isEmpty { return true }
        return event.typesCharacter && event.modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// Click keys press on key down and release on key up, like a mouse button.
    private mutating func buttonDown(
        _ button: MouseButton, code: UInt16, _ time: Double, _ pointer: (x: Double, y: Double)
    ) -> [CursorCommand] {
        // The button is already down (a drag, or the other key bound to it); pressing again would confuse apps.
        if heldButtons.values.contains(where: { $0.button == button }) || (button == .left && leftDown) { return [] }
        let count = nextClickCount(button, time, pointer)
        lastClick = (time, pointer.x, pointer.y, button, count)
        heldButtons[code] = (button, count)
        return [.buttonDown(button, clickCount: count)]
    }

    private mutating func click(_ button: MouseButton, count: Int, _ time: Double, _ pointer: (x: Double, y: Double)) -> CursorCommand {
        lastClick = (time, pointer.x, pointer.y, button, count)
        return .click(button, clickCount: count)
    }

    private func nextClickCount(_ button: MouseButton, _ time: Double, _ pointer: (x: Double, y: Double)) -> Int {
        guard let last = lastClick, last.button == button else { return 1 }
        let near = abs(last.x - pointer.x) <= doubleClickTolerance && abs(last.y - pointer.y) <= doubleClickTolerance
        guard near, time - last.time <= doubleClickInterval else { return 1 }
        return min(last.count + 1, 3)
    }

    private mutating func resetCommands() -> [CursorCommand] {
        var commands: [CursorCommand] = []
        if leftDown { commands.append(.release(.left)) }
        for held in heldButtons.values { commands.append(.buttonUp(held.button, clickCount: held.count)) }
        heldButtons.removeAll()
        held.removeAll()
        heldModifierCodes.removeAll()
        leftDown = false
        lastClick = nil
        moveElapsed = 0
        scrollElapsed = 0
        return commands
    }
}

/// Smoothstep ramp from 0 to 1 over `duration` seconds.
public func smoothRamp(_ elapsed: Double, duration: Double) -> Double {
    guard duration > 0 else { return 1 }
    let x = min(max(elapsed / duration, 0), 1)
    return x * x * (3 - 2 * x)
}
