import Foundation

public enum InteractionMode: String, Equatable, Sendable {
    case off
    case cursor
    case click
    case scroll

    /// The name people see.
    public var name: String {
        switch self {
        case .off: return "Typing"
        case .cursor: return "Moving"
        case .click: return "Clicking"
        case .scroll: return "Scrolling"
        }
    }
}

/// Work the system layer must perform. The router decides; it never performs OS calls.
public enum NavigationEffect: Equatable, Sendable {
    case started(InteractionMode)
    case stopped(InteractionMode)
    case cursor(CursorCommand)
    /// Revalidate and act on target `index` of discovery `snapshot`, issued during `generation`.
    case activate(index: Int, snapshot: Int, generation: Int, action: TargetAction)
    /// Discover targets for the Click target app, tagged with `generation`.
    case discoverTargets(generation: Int)
    /// Overlay content changed (labels, selection, query, help, badge state).
    case refreshOverlay
    /// Find the window in front for Scroll mode, tagged with `generation`.
    case findScrollWindow(generation: Int)
    /// Move the pointer into the window in front so scroll events reach it.
    case parkPointer(x: Double, y: Double)
}

public enum RouterInput: Equatable, Sendable {
    case key(KeyEvent)
    /// A physical mouse button or wheel event. Cancels pending modifier taps.
    case pointerButton
    /// Physical pointer movement. Clears keyboard acceleration without stopping motion.
    case externalPointerMoved
    /// Sleep, lock, permission loss, display change, or tap interruption. Forces Off.
    case forceOff
    /// The Click target app lost focus. Label-click mode must not outlive its snapshot.
    case focusChanged
    /// Discovery `snapshot` finished for `generation`.
    case targetsDiscovered(generation: Int, snapshot: Int, targets: [HintTarget])
    /// Activation finished. A failed activation requests fresh targets rather than clicking a coordinate.
    case activationFinished(generation: Int, succeeded: Bool)
    /// A KeyNav text field or recorder, or an excluded app, owns the keyboard. Routing pauses.
    case suspendRouting(Bool)
    /// The clock reached `typedLabelDeadline`: a half-typed label is forgotten.
    case typedLabelTimeout
    /// The window in front for Scroll mode, found for `generation` (nil when it could not be read), the ancestry
    /// of the control last clicked or scrolled there and of the focused control, every scroll area Tab can move
    /// between, and the spot the person last scrolled at if that came after any click.
    case scrollWindowFound(generation: Int, frame: HintTarget.Frame?, clickChain: [ScrollNode] = [],
                           focusChain: [ScrollNode] = [], areas: [HintTarget.Frame] = [], resume: ScrollPoint? = nil)
    /// The window's scroll areas read again for `generation` after scrolling moved them.
    case scrollAreasMoved(generation: Int, areas: [HintTarget.Frame])
    /// While routing is suspended for an ordinary text field, start, stop, and switch shortcuts still work.
    /// Shortcut recorders and excluded apps keep this off: they need every key.
    case allowEntriesWhileSuspended(Bool)
}

public struct RouterDecision: Equatable, Sendable {
    public var consumed: Bool
    public var effects: [NavigationEffect]

    public static let passThrough = RouterDecision(consumed: false, effects: [])
}

/// The single authority for which mode owns input. Pure: time and pointer come in as parameters.
public struct NavigationRouter: Sendable {
    public private(set) var mode: InteractionMode = .off
    /// Increments on every start and stop. Async results with a stale generation are discarded.
    public private(set) var generation = 0
    public private(set) var config: KeyNavConfig
    public private(set) var cursor: CursorEngine
    public private(set) var click: ClickSession?
    public private(set) var scroll: ScrollSession?
    public private(set) var routingSuspended = false
    public private(set) var entriesAllowedWhileSuspended = false
    /// The Cursor-mode key list overlay. Hidden whenever the mode stops.
    public private(set) var helpVisible = false

    private var tapRecognizer: ModifierTapRecognizer
    /// Keys whose key-down was consumed. Their key-up and repeats are consumed too, even after the mode ended.
    private var consumedKeys: Set<UInt16> = []
    private var controlMap: [Gesture: ClickControl] = [:]
    /// When the current half-typed label was last extended.
    private var typedLabelAt: Double?

    /// How long a half-typed label waits for its next letter before the labels reset.
    public static let typedLabelTimeout = 3.0

    public init(config: KeyNavConfig, doubleClickInterval: Double = 0.5) {
        self.config = config
        self.cursor = Self.makeCursor(config, doubleClickInterval: doubleClickInterval)
        self.tapRecognizer = ModifierTapRecognizer(maxDuration: Double(config.modifierTapMaxMilliseconds) / 1000)
        self.controlMap = Self.makeControlMap(config)
    }

    private static func makeCursor(_ config: KeyNavConfig, doubleClickInterval: Double) -> CursorEngine {
        CursorEngine(
            bindings: config.cursorBindings,
            motion: config.motion,
            scrolling: config.scrolling,
            doubleClickInterval: doubleClickInterval,
            dragStyle: config.dragStyle
        )
    }

    private static func makeControlMap(_ config: KeyNavConfig) -> [Gesture: ClickControl] {
        var map: [Gesture: ClickControl] = [:]
        for (control, gesture) in config.clickControls { map[gesture] = control }
        return map
    }

    /// Applies a validated configuration. Held input is released first, so a change never leaves input down.
    public mutating func updateConfig(_ newConfig: KeyNavConfig) -> [NavigationEffect] {
        let releases = releaseCursor()
        cursor = Self.makeCursor(newConfig, doubleClickInterval: cursor.doubleClickInterval)
        tapRecognizer = ModifierTapRecognizer(maxDuration: Double(newConfig.modifierTapMaxMilliseconds) / 1000)
        controlMap = Self.makeControlMap(newConfig)
        config = newConfig
        return releases + [.refreshOverlay]
    }

    /// Starts or stops a mode from Settings, menus, or the Dock. Same exclusivity as the entry gestures,
    /// but a visible toggle may always turn its own mode off.
    public mutating func requestMode(_ target: InteractionMode) -> [NavigationEffect] {
        if target == .off || mode == target {
            return stop()
        }
        return start(target)
    }

    public mutating func requestOff() -> [NavigationEffect] {
        stop()
    }

    /// Advances continuous cursor motion by `dt` seconds. Returns nothing unless Cursor mode owns input.
    public mutating func tickCursor(dt: Double) -> [NavigationEffect] {
        guard !routingSuspended else { return [] }
        switch mode {
        case .cursor: return cursor.tick(dt: dt).map { NavigationEffect.cursor($0) }
        case .scroll: return (scroll?.tick(dt: dt) ?? []).map { NavigationEffect.cursor($0) }
        default: return []
        }
    }

    /// When a half-typed label resets if no further letter arrives. Nil when nothing is half-typed.
    public var typedLabelDeadline: Double? {
        guard mode == .click, let typedLabelAt, let session = click, !session.typedPrefix.isEmpty else { return nil }
        return typedLabelAt + Self.typedLabelTimeout
    }

    /// Whether the tick timer should be running: something is moving or scrolling.
    public var cursorNeedsTicks: Bool {
        guard !routingSuspended else { return false }
        switch mode {
        case .cursor: return cursor.needsTicks
        case .scroll: return scroll?.needsTicks ?? false
        default: return false
        }
    }

    public mutating func handle(_ input: RouterInput, at time: Double, pointer: (x: Double, y: Double)) -> RouterDecision {
        switch input {
        case let .key(event):
            return handleKey(event, at: time, pointer: pointer)

        case .pointerButton:
            tapRecognizer.otherInput()
            if mode == .cursor, config.exitCursorOnMouse {
                return RouterDecision(consumed: false, effects: stop())
            }
            return .passThrough

        case .externalPointerMoved:
            if mode == .cursor { cursor.resetRamp() }
            if mode == .scroll { scroll?.pointerMoved(to: pointer) }
            return .passThrough

        case .forceOff:
            tapRecognizer.reset()
            return RouterDecision(consumed: false, effects: stop())

        case .focusChanged:
            guard mode == .click || mode == .scroll else { return .passThrough }
            return RouterDecision(consumed: false, effects: stop())

        case let .targetsDiscovered(targetGeneration, snapshot, targets):
            guard mode == .click, targetGeneration == generation, var session = click else { return .passThrough }
            // A refresh never replaces codes under a half-typed label.
            guard !session.hasSnapshot || session.acceptsNewSnapshot else { return .passThrough }
            session.setTargets(targets, snapshot: snapshot)
            click = session
            return RouterDecision(consumed: false, effects: [.refreshOverlay])

        case let .activationFinished(activationGeneration, succeeded):
            guard activationGeneration == generation, mode == .click else { return .passThrough }
            if succeeded && !config.clickStaysActive {
                return RouterDecision(consumed: false, effects: stop())
            }
            // A changed target, or a session that stays, rediscovers instead of reusing old coordinates.
            // The typed code was used up, so the fresh snapshot may replace the labels.
            click?.clearTypedLabel()
            return RouterDecision(consumed: false, effects: [.discoverTargets(generation: generation), .refreshOverlay])

        case let .scrollWindowFound(windowGeneration, frame, clickChain, focusChain, areas, resume):
            guard mode == .scroll, windowGeneration == generation, var session = scroll else { return .passThrough }
            let park = session.setWindow(frame, clickChain: clickChain, focusChain: focusChain, areas: areas,
                                         resume: resume.map { ($0.x, $0.y) }, pointer: pointer)
            scroll = session
            return RouterDecision(consumed: false, effects: park.map { [.parkPointer(x: $0.x, y: $0.y)] } ?? [])

        case let .scrollAreasMoved(windowGeneration, areas):
            guard mode == .scroll, windowGeneration == generation, var session = scroll else { return .passThrough }
            session.areasMoved(areas, pointer: pointer)
            scroll = session
            return .passThrough

        case .typedLabelTimeout:
            guard let deadline = typedLabelDeadline, time >= deadline else { return .passThrough }
            click?.clearTypedLabel()
            typedLabelAt = nil
            return RouterDecision(consumed: false, effects: [.refreshOverlay])

        case let .allowEntriesWhileSuspended(allowed):
            entriesAllowedWhileSuspended = allowed
            return .passThrough

        case let .suspendRouting(suspended):
            guard suspended != routingSuspended else { return .passThrough }
            routingSuspended = suspended
            tapRecognizer.reset()
            guard suspended else { return RouterDecision(consumed: false, effects: [.refreshOverlay]) }
            scroll?.reset()
            return RouterDecision(consumed: false, effects: releaseCursor() + [.refreshOverlay])
        }
    }

    // MARK: - Keys

    private mutating func handleKey(_ event: KeyEvent, at time: Double, pointer: (x: Double, y: Double)) -> RouterDecision {
        if routingSuspended, !entriesAllowedWhileSuspended {
            return .passThrough
        }

        // Every modifier transition reaches the tap recognizer, including releases of keys KeyNav consumed
        // (Left Command after a drag); otherwise it would believe the modifier is still held.
        var tapped: UInt16?
        if event.isModifierKey {
            tapped = tapRecognizer.modifierChanged(code: event.code, down: event.kind == .down, others: event.modifiers, at: time)
        } else {
            tapRecognizer.otherInput()
        }

        // The release (and repeats) of a consumed key stays consumed, even if the mode has since ended.
        if consumedKeys.contains(event.code) {
            if event.kind == .up {
                consumedKeys.remove(event.code)
                return RouterDecision(consumed: true, effects: modeHandle(event, at: time, pointer: pointer).effects)
            }
            if event.isRepeat {
                return RouterDecision(consumed: true, effects: [])
            }
        }

        if let tapped, let effects = entryForTap(tapped) {
            return RouterDecision(consumed: false, effects: effects)
        }

        if event.kind == .down {
            // The active mode's root exit comes before anything that could compete with it.
            if mode != .off, rootExitMatches(event) {
                consumedKeys.insert(event.code)
                return RouterDecision(consumed: true, effects: stop())
            }
            // Then the global entries, including switching to the other mode.
            if let target = keyEntryMode(for: event) {
                consumedKeys.insert(event.code)
                // Enter-only entry does nothing when already in that mode; the key is still ours.
                return RouterDecision(consumed: true, effects: toggleOrSwitch(target) ?? [])
            }
        }

        // A text field keeps every other key while it is being edited.
        if routingSuspended { return .passThrough }
        let result = modeHandle(event, at: time, pointer: pointer)
        if result.consumed, event.kind == .down {
            consumedKeys.insert(event.code)
        }
        return RouterDecision(consumed: result.consumed, effects: result.effects)
    }

    /// Passes a key to the active mode. Off consumes nothing.
    private mutating func modeHandle(
        _ event: KeyEvent, at time: Double, pointer: (x: Double, y: Double)
    ) -> (consumed: Bool, effects: [NavigationEffect]) {
        switch mode {
        case .off:
            return (false, [])

        case .cursor:
            if event.kind == .down, !event.isRepeat,
               cursor.bindings.action(forKey: event.code, modifiers: event.modifiers) == .help {
                helpVisible.toggle()
                return (true, [.refreshOverlay])
            }
            let draggingBefore = cursor.leftDown
            let heldBefore = cursor.held
            let buttonsBefore = cursor.heldButtons.count
            let result = event.kind == .down
                ? cursor.keyDown(event, at: time, pointer: pointer)
                : cursor.keyUp(event)
            var effects = result.commands.map { NavigationEffect.cursor($0) }
            if cursor.held != heldBefore || cursor.leftDown != draggingBefore || cursor.heldButtons.count != buttonsBefore {
                effects.append(.refreshOverlay)
            }
            return (result.consumed, effects)

        case .scroll:
            guard var session = scroll else { return (false, []) }
            let result = event.kind == .down ? session.keyDown(event) : session.keyUp(event)
            scroll = session
            var effects = result.commands.map { NavigationEffect.cursor($0) }
            if let park = result.park { effects.append(.parkPointer(x: park.x, y: park.y)) }
            return (result.consumed, effects)

        case .click:
            guard event.kind == .down, var session = click else { return (false, []) }
            if let deadline = typedLabelDeadline, time >= deadline {
                session.clearTypedLabel()
            }
            let typedBefore = session.typedPrefix
            let decision = session.handle(event, controls: controlMap)
            click = session
            if session.typedPrefix.isEmpty {
                typedLabelAt = nil
            } else if session.typedPrefix != typedBefore {
                typedLabelAt = time
            }
            switch decision {
            case .unhandled:
                return (false, [])
            case .consumed:
                return (true, [.refreshOverlay])
            case let .activate(target, action):
                return (true, [.activate(index: target, snapshot: session.snapshot, generation: generation, action: action)])
            case let .scroll(dx, dy):
                return (true, [.cursor(.scroll(dx: dx, dy: dy)), .discoverTargets(generation: generation)])
            case .refresh:
                return (true, [.discoverTargets(generation: generation), .refreshOverlay])
            }
        }
    }

    // MARK: - Mode transitions

    private mutating func releaseCursor() -> [NavigationEffect] {
        cursor.reset().map { NavigationEffect.cursor($0) }
    }

    /// Starts `target`, stopping any other mode first. Stop releases held input before the new mode starts,
    /// so there is no moment when both modes route keys.
    private mutating func start(_ target: InteractionMode) -> [NavigationEffect] {
        var effects: [NavigationEffect] = []
        if mode != .off {
            effects += stop()
        }
        mode = target
        generation += 1
        if target == .click {
            click = ClickSession(
                alphabet: LabelGenerator.usableAlphabet(config.clickAlphabet, reserved: reservedClickCharacters()),
                requireReturn: config.clickRequireReturn,
                searchFirst: config.clickSearchFirst
            )
        }
        if target == .scroll {
            scroll = ScrollSession(scrolling: config.scrolling)
        }
        effects.append(.started(target))
        if target == .click {
            effects.append(.discoverTargets(generation: generation))
        }
        if target == .scroll {
            effects.append(.findScrollWindow(generation: generation))
        }
        effects.append(.refreshOverlay)
        return effects
    }

    /// The single stop path. Releases held input before reporting the stop. Idempotent.
    @discardableResult
    private mutating func stop() -> [NavigationEffect] {
        guard mode != .off else { return [] }
        let previous = mode
        var effects = releaseCursor()
        mode = .off
        generation += 1
        click = nil
        scroll = nil
        helpVisible = false
        effects.append(.stopped(previous))
        return effects
    }

    /// Entry semantics: with a separate exit, the entry only enters (same-mode presses do nothing).
    /// Without it, the entry toggles the mode.
    private mutating func toggleOrSwitch(_ target: InteractionMode) -> [NavigationEffect]? {
        guard let entry = config.entry(for: target) else { return nil }
        if mode == target {
            guard !entry.separateExit else { return nil }
            return stop()
        }
        return start(target)
    }

    private mutating func entryForTap(_ code: UInt16) -> [NavigationEffect]? {
        guard let target = config.entries.first(where: { $0.entry.gesture == .modifierTap(code: code) })?.mode else { return nil }
        return toggleOrSwitch(target)
    }

    private func keyEntryMode(for event: KeyEvent) -> InteractionMode? {
        let gesture = Gesture.key(code: event.code, modifiers: event.modifiers)
        return config.entries.first { $0.entry.gesture == gesture }?.mode
    }

    private func rootExitMatches(_ event: KeyEvent) -> Bool {
        guard let entry = config.entry(for: mode), entry.separateExit else { return false }
        if entry.exit == .key(code: event.code, modifiers: event.modifiers) { return true }
        // Modifier keys held as Cursor hold actions (Left Command for drag) do not change what the exit means:
        // Escape still exits while dragging.
        guard mode == .cursor else { return false }
        var ownHeld: Modifiers = []
        for binding in config.cursorBindings where cursor.held.contains(binding.action) || (binding.action == .dragHold && cursor.leftDown) {
            ownHeld.formUnion(Key.modifierFlag(for: binding.gesture.keyCode))
        }
        return entry.exit == .key(code: event.code, modifiers: event.modifiers.subtracting(ownHeld))
    }

    /// Printable keys bound as Click controls or as an exit cannot also be label characters.
    private func reservedClickCharacters() -> Set<Character> {
        var reserved = Set<Character>()
        var gestures = Array(config.clickControls.values)
        for entry in config.entries.map(\.entry) where entry.separateExit {
            gestures.append(entry.exit)
        }
        for gesture in gestures {
            if case let .key(code, modifiers) = gesture, modifiers.isDisjoint(with: [.command, .control, .option]),
               let text = Key.printableCodes[code], text.count == 1 {
                reserved.formUnion(text.lowercased())
            }
        }
        return reserved
    }
}
