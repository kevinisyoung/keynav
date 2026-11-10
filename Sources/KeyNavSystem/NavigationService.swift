import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KeyNavCore
import Observation

/// Views that capture keys for themselves (shortcut recorders). While one is focused, navigation pauses.
@MainActor
public protocol SuspendsNavigation: AnyObject {}

/// Owns the event tap, the router, pointer output, discovery, and overlays. Settings observes this object.
///
/// Every input goes through `router.handle`; every effect goes through `execute`. Nothing else decides
/// which mode owns the keyboard or what KeyNav holds down.
@Observable
@MainActor
public final class NavigationService {
    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        /// Content-free description. Never contains typed text, labels, queries, or window titles.
        public let text: String
    }

    public struct DiscoveryStats: Sendable {
        public var targets: Int
        public var milliseconds: Double
        public var visitedNodes: Int
        public var truncated: Bool
        public var scope: String
        public var contentTargets: Int
    }

    public struct ActivationRecord: Sendable {
        public var outcome: String
        public var usedPointer: Bool
    }

    public private(set) var router: NavigationRouter
    public private(set) var readiness: PermissionReport
    public private(set) var tapInstalled = false
    /// Short, user-facing status for the most recent problem, such as a changed target.
    public private(set) var message: String?
    /// Name of the app Label-click mode is reading.
    public private(set) var targetName: String?
    /// A KeyNav text field or shortcut recorder is focused, so keys go to it instead of the mode.
    public private(set) var editingSettings = false
    /// Name of the excluded app in front, if any. Navigation is suspended there.
    public private(set) var excludedAppInFront: String?
    public private(set) var log: [LogEntry] = []
    public private(set) var lastDiscovery: DiscoveryStats?
    public private(set) var lastActivation: ActivationRecord?

    @ObservationIgnored private let output = CursorOutput()
    @ObservationIgnored private let overlayModel = OverlayModel()
    @ObservationIgnored private lazy var badge = HostedOverlay(BadgeView(model: overlayModel))
    @ObservationIgnored private lazy var hud = HostedOverlay(ClickHUDView(model: overlayModel))
    @ObservationIgnored private lazy var help = HostedOverlay(HelpView(model: overlayModel))
    @ObservationIgnored private let hints = HintOverlay()
    @ObservationIgnored private let scanBar = ScanProgressBar()
    @ObservationIgnored private let dot = PointerDot()
    @ObservationIgnored private let scrollOutline = ScrollOutline()
    @ObservationIgnored private let clickHider = PointerHider()
    /// The pointer moved while a click key (Space) held the left button, or the person is dragging the mouse.
    @ObservationIgnored private var keyDragMoved = false
    @ObservationIgnored private var mouseDragging = false
    /// Set when Scroll mode stops; the pointer goes home only if no other mode starts in the same step.
    @ObservationIgnored private var pendingScrollReturn: (home: CGPoint, parked: CGPoint)?
    @ObservationIgnored private var tap: EventTap?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var labelTimer: Timer?
    @ObservationIgnored private var labelTimerDeadline: Double?
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var targetPID: pid_t?
    @ObservationIgnored private var lastExternalPID: pid_t?
    @ObservationIgnored private var frontBundleID: String?
    @ObservationIgnored private var frontName: String?
    @ObservationIgnored private var snapshotCounter = 0
    @ObservationIgnored private var elementsBySnapshot: [Int: [AXElementBox]] = [:]
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var scrollTask: Task<Void, Never>?
    /// Where the pointer was when Scroll mode started, and where Scroll mode last parked it.
    @ObservationIgnored private var scrollHome: CGPoint?
    @ObservationIgnored private var scrollParked: CGPoint?
    /// Where the person last clicked (with the mouse or a label) or scrolled in each app, whichever came last:
    /// Scrolling starts there, even after switching away and back.
    @ObservationIgnored private var lastSpots: [pid_t: (point: CGPoint, scrolled: Bool)] = [:]
    /// Finds a spot for the pointer that hovers nothing; replaced by each new park.
    @ObservationIgnored private var parkTask: Task<Void, Never>?
    /// While a password field holds Secure Input the tap sees no keys, so each mode's shortcut is also registered
    /// with the system then, and a running mode reads its keys through an invisible key panel instead.
    @ObservationIgnored private let secureHotKeys = SystemHotKeys()
    @ObservationIgnored private var secureWatch: Timer?
    @ObservationIgnored private lazy var keyCatcher = KeyCatcher { [weak self] type, event in
        _ = self?.handleTapEvent(type, event)
    }
    /// Asked each time a mode starts: false once the free trial has ended without a license.
    @ObservationIgnored public var mayStart: () -> Bool = { true }
    /// Called when a mode was refused because the trial has ended.
    @ObservationIgnored public var onTrialEnded: (() -> Void)?
    /// A screenshot is being taken: Scroll mode's dot and outline hold still for it.
    @ObservationIgnored private var screenshotting = false
    /// What the scroll outline last showed: the outlined pane and its number.
    @ObservationIgnored private var lastOutline: (HintTarget.Frame?, Int?) = (nil, nil)
    @ObservationIgnored private var areaRefresh: Task<Void, Never>?
    /// Each app's scroll areas as last found, with the window they were found in.
    @ObservationIgnored private var scrollAreasByApp: [pid_t: (window: HintTarget.Frame?, areas: [HintTarget.Frame])] = [:]
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(config: KeyNavConfig) {
        router = NavigationRouter(config: config, doubleClickInterval: NSEvent.doubleClickInterval)
        readiness = Permissions.report()
        output.confineToCurrentDisplay = config.confineToCurrentDisplay
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            lastExternalPID = front.processIdentifier
            frontBundleID = front.bundleIdentifier
            frontName = front.localizedName
        }
    }

    public var mode: InteractionMode { router.mode }
    public var config: KeyNavConfig { router.config }
    /// Current pointer speed in points per second, for the practice area.
    public var currentSpeed: Double { router.cursor.needsTicks ? router.cursor.currentMoveSpeed() : 0 }
    /// The app Label-click mode would read if started now.
    public var clickTargetCandidate: String? {
        lastExternalPID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }

    // MARK: - Lifecycle

    /// Installs the event tap if macOS allows it and starts watching focus, sleep, displays, and activation.
    public func start() {
        observeSystem()
        installTapIfPossible()
        updateExclusion()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSecureHotKey() }
        }
        RunLoop.main.add(timer, forMode: .common)
        secureWatch = timer
    }

    /// Releases all input and removes the tap. Called on quit.
    public func shutdown() {
        apply(router.handle(.forceOff, at: now, pointer: pointer).effects)
        output.releaseAll()
        dot.hide()
        scrollOutline.hide()
        clickHider.show()
        secureWatch?.invalidate()
        secureHotKeys.unregisterAll()
        tap?.uninstall()
        tap = nil
        tapInstalled = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// Re-probes the running app's real capabilities, e.g. after access was granted in System Settings.
    public func recheckReadiness() {
        installTapIfPossible()
        readiness = Permissions.report()
    }

    // MARK: - Commands from Settings, menus, and the Dock

    public func setMode(_ target: InteractionMode) {
        guard target != .off else {
            stopNavigation()
            return
        }
        guard tapInstalled else {
            message = readiness.status == .needsAccess
                ? "Allow Accessibility access first. KeyNav cannot take over the keyboard yet."
                : "KeyNav cannot read the keyboard right now. See Diagnostics."
            return
        }
        if target == .click || target == .scroll || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            // Modes act on the app the person was using, not on KeyNav's own window.
            if let pid = lastExternalPID { NSRunningApplication(processIdentifier: pid)?.activate() }
        }
        apply(router.requestMode(target))
    }

    public func stopNavigation() {
        apply(router.requestOff())
        output.releaseAll()
    }

    /// Applies a validated configuration. Held input is released first.
    public func apply(config newConfig: KeyNavConfig) {
        output.confineToCurrentDisplay = newConfig.confineToCurrentDisplay
        apply(router.updateConfig(newConfig))
        updateExclusion()
    }

    // MARK: - Tap

    private func installTapIfPossible() {
        if tap?.isInstalled == true { return }
        let newTap = EventTap(
            handler: { [weak self] type, event in
                self?.handleTapEvent(type, event) ?? false
            },
            interruption: { [weak self] in
                self?.forceOff(reason: "macOS paused KeyNav’s keyboard access, so navigation stopped.")
            }
        )
        if newTap.install() {
            tap = newTap
            tapInstalled = true
            record("Keyboard access ready")
        } else {
            tap = nil
            tapInstalled = false
        }
    }

    private func handleTapEvent(_ type: CGEventType, _ event: CGEvent) -> Bool {
        updateEditingState()
        guard let input = EventClassifier.input(for: type, event: event, time: now) else { return false }
        if type == .leftMouseDown || type == .rightMouseDown || type == .scrollWheel,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            lastSpots[pid] = (event.location, type == .scrollWheel)
        }
        if input == .externalPointerMoved || input == .pointerButton { clickHider.show() }
        // The person moved the mouse while Moving is on: the badge keeps up with the pointer.
        if router.mode == .cursor, input == .externalPointerMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged {
            placeBadge(at: event.location)
        }
        if router.mode == .cursor, type == .leftMouseDragged || type == .leftMouseUp {
            let dragging = type == .leftMouseDragged
            if dragging != mouseDragging {
                mouseDragging = dragging
                refreshOverlays()
            }
        }
        // The person moved the mouse while scrolling: the dot follows it, and the pointer stays where they put it.
        let followsMouse = router.mode == .scroll && !screenshotting
            && (input == .externalPointerMoved || input == .pointerButton)
        if followsMouse {
            dot.show(atGlobal: event.location)
            scrollParked = nil
        }
        let mouse = input == .externalPointerMoved ? (Double(event.location.x), Double(event.location.y)) : pointer
        let decision = router.handle(input, at: now, pointer: mouse)
        apply(decision.effects)
        // Scrolling goes wherever the mouse is now, so the outline moves to the area under it.
        if followsMouse { showScrollOutline() }
        return decision.consumed
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var pointer: (x: Double, y: Double) {
        let p = output.location()
        return (Double(p.x), Double(p.y))
    }

    /// Settings text fields and recorders own the keyboard while focused; the mode stays selected.
    private func updateEditingState() {
        var editing = false
        var recording = false
        // Once Label-click is labelling KeyNav's own window, letters belong to the labels, not a focused field.
        if NSApp.isActive, router.mode != .click, router.mode != .scroll, let responder = NSApp.keyWindow?.firstResponder {
            recording = responder is SuspendsNavigation
            editing = responder is NSText || recording
        }
        // In an ordinary field the start and stop shortcuts still work; a shortcut recorder needs every key.
        let allowEntries = editing && !recording
        if allowEntries != router.entriesAllowedWhileSuspended {
            _ = router.handle(.allowEntriesWhileSuspended(allowEntries), at: now, pointer: pointer)
        }
        if editing != editingSettings {
            editingSettings = editing
            syncSuspension()
        }
    }

    private func syncSuspension() {
        let suspended = editingSettings || excludedAppInFront != nil
        if suspended != router.routingSuspended {
            apply(router.handle(.suspendRouting(suspended), at: now, pointer: pointer).effects)
        }
    }

    // MARK: - Effects

    private func apply(_ effects: [NavigationEffect]) {
        guard !effects.isEmpty else {
            updateTimers()
            return
        }
        for effect in effects where effect != .refreshOverlay {
            execute(effect)
        }
        // Leaving Scroll mode for Off puts the pointer back where it was, unless the person moved it.
        // Switching to another mode leaves it in the scroll area, so Cursor mode carries on from there.
        if let pending = pendingScrollReturn {
            pendingScrollReturn = nil
            let location = output.location()
            if router.mode == .off, hypot(location.x - pending.parked.x, location.y - pending.parked.y) < 2 {
                output.move(to: pending.home)
            }
        }
        updateTimers()
        refreshOverlays()
    }

    private func execute(_ effect: NavigationEffect) {
        switch effect {
        case let .started(mode):
            guard mayStart() else {
                message = "Your free trial has ended. Buy KeyNav to keep using it."
                apply(router.requestOff())
                onTrialEnded?()
                return
            }
            // Behind a password field the tap sees no keys; they come through the invisible key panel instead.
            if IsSecureEventInputEnabled() { keyCatcher.begin() }
            if mode == .click || mode == .scroll {
                // Started while KeyNav's own window is in front: act on that window and leave it where it is.
                let pid: pid_t? = NSApp.isActive && NSApp.keyWindow != nil ? getpid()
                    : AccessibilityTargets.keyboardPanelApp() ?? lastExternalPID
                guard let pid else {
                    message = "\(mode.name) needs an app in front. Switch to the app, then try again."
                    apply(router.requestOff())
                    return
                }
                targetPID = pid
                targetName = NSRunningApplication(processIdentifier: pid)?.localizedName
            }
            message = nil
            // Started from a shortcut while a Settings field was being edited: the mode takes the keyboard.
            if editingSettings, NSApp.isActive, !(NSApp.keyWindow?.firstResponder is SuspendsNavigation) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                updateEditingState()
            }
            if mode == .cursor {
                lastTick = now
                clickHider.show()
            }
            if mode == .scroll { scrollHome = output.location() }
            record("\(mode.name) on")

        case let .stopped(mode):
            if router.mode == .off {
                keyCatcher.end()
                syncSecureHotKey()
            }
            badge.hide()
            help.hide()
            hints.clear()
            hud.hide()
            scanBar.hide()
            discoveryTask?.cancel()
            discoveryTask = nil
            elementsBySnapshot.removeAll()
            targetPID = nil
            targetName = nil
            scrollTask?.cancel()
            scrollTask = nil
            parkTask?.cancel()
            parkTask = nil
            scrollOutline.hide()
            // The next Scroll draws its outline afresh, even over the same pane.
            lastOutline = (nil, nil)
            dot.hide()
            if mode == .scroll, let home = scrollHome, let parked = scrollParked {
                pendingScrollReturn = (home, parked)
            }
            scrollHome = nil
            scrollParked = nil
            record("\(mode.name) off")

        case let .cursor(command):
            if !output.perform(command) {
                record("A pointer event could not be posted")
            }
            if case .scroll = command, let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier {
                lastSpots[pid] = (output.location(), true)
                if router.mode == .scroll { followScrolledAreas(pid: pid) }
            }

        case let .discoverTargets(generation):
            scheduleDiscovery(generation: generation)

        case let .activate(index, snapshot, generation, action):
            // Leave the tap callback quickly; AX calls can take a moment.
            DispatchQueue.main.async { [weak self] in
                self?.activate(index: index, snapshot: snapshot, generation: generation, action: action)
            }

        case let .findScrollWindow(generation):
            guard let pid = targetPID else { return }
            scrollTask?.cancel()
            let spot = lastSpots[pid]
            // The window and what was last clicked come back at once, so the dot shows straight away, with the
            // panes found last time in this window. Finding the panes reads the whole window; that follows, and
            // the outline fades in or moves only if they changed.
            scrollTask = Task { @MainActor [weak self] in
                var quick = await AccessibilityTargets.scrollContext(pid: pid, clickedAt: spot?.point, areas: false)
                guard let self, !Task.isCancelled, self.router.generation == generation else { return }
                quick.areas = self.scrollAreasByApp[pid].flatMap { $0.window == quick.window ? $0.areas : nil } ?? []
                let resume = spot.flatMap { $0.scrolled ? ScrollPoint(x: $0.point.x, y: $0.point.y) : nil }
                self.apply(self.router.handle(.scrollWindowFound(generation: generation, frame: quick.window,
                                                                 clickChain: quick.clickChain, focusChain: quick.focusChain,
                                                                 areas: quick.areas, resume: resume),
                                              at: self.now, pointer: self.pointer).effects)
                // Whether or not the pointer moved, the dot now marks where scrolling goes. A pointer being parked
                // shows the outline when it lands; one that stays put shows it now, with the panes found last time.
                if self.router.mode == .scroll, self.parkTask == nil {
                    let location = self.output.location()
                    self.scrollParked = location
                    self.dot.show(atGlobal: location)
                    self.showScrollOutline(force: true)
                }
                let areas = await AccessibilityTargets.scrollAreas(pid: pid, afterWaking: quick.treeWasAsleep)
                guard !Task.isCancelled, self.router.generation == generation else { return }
                self.scrollAreasByApp[pid] = (quick.window, areas)
                guard areas != quick.areas else { return }
                self.apply(self.router.handle(.scrollAreasMoved(generation: generation, areas: areas),
                                              at: self.now, pointer: self.pointer).effects)
                self.showScrollOutline(fade: true)
            }

        case let .parkPointer(x, y):
            // A spot the person scrolled at before is used as is; a computed one moves off any link or button
            // first, since the app would show its tooltip or hover effect.
            let point = CGPoint(x: x, y: y)
            let resumed = targetPID.flatMap { lastSpots[$0] }.map { $0.scrolled && $0.point == point } ?? false
            parkTask?.cancel()
            parkTask = Task { @MainActor [weak self] in
                var spot = point
                if !resumed, let pid = self?.targetPID {
                    spot = await AccessibilityTargets.quietPoint(pid: pid, near: point)
                }
                guard let self, !Task.isCancelled else { return }
                self.parkTask = nil
                guard self.router.mode == .scroll else { return }
                self.output.move(to: spot)
                self.scrollParked = spot
                self.dot.show(atGlobal: spot)
                self.showScrollOutline(force: true)
            }

        case .refreshOverlay:
            break
        }
    }

    /// Scrolling moves what's inside the page and can show which pane really scrolls (Gmail's). The outline holds
    /// still while scrolling; 0.3 s after it stops, the areas are read again and the outline moves if its pane changed.
    private func followScrolledAreas(pid: pid_t) {
        areaRefresh?.cancel()
        let generation = router.generation
        areaRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let context = await AccessibilityTargets.scrollContext(pid: pid, clickedAt: nil)
            guard let self, !Task.isCancelled else { return }
            self.areaRefresh = nil
            guard self.router.mode == .scroll, self.router.generation == generation, context.window != nil else { return }
            self.apply(self.router.handle(.scrollAreasMoved(generation: generation, areas: context.areas),
                                          at: self.now, pointer: self.pointer).effects)
            self.showScrollOutline(fade: true)
        }
    }

    /// Outlines the pane being scrolled and numbers the others; redrawn only when that pane changes.
    private func showScrollOutline(force: Bool = false, fade: Bool = false) {
        guard let session = router.scroll else { return }
        // Outside every pane scrolling goes to the window itself (and some apps, like Claude's, show no panes until
        // they've scrolled), so the whole window is outlined: there's always a border saying where keys go.
        let current = session.outlined ?? (session.areaIndex == nil ? session.window : nil)
        let shown = (current, session.areaIndex)
        guard force || shown.0 != lastOutline.0 || shown.1 != lastOutline.1 else { return }
        lastOutline = shown
        let rect = { (f: HintTarget.Frame) in CGRect(x: f.x, y: f.y, width: f.width, height: f.height) }
        scrollOutline.show(current: current.map(rect), areas: session.areas.map(rect), currentIndex: session.areaIndex,
                           coversWindow: session.outlined == nil, fade: fade)
    }

    /// Registers each mode's shortcut with the system while Secure Input is on and nothing is running. Moving's
    /// default, a Right Option tap, can't be registered; it still reaches the tap as a modifier change.
    private func syncSecureHotKey() {
        guard IsSecureEventInputEnabled(), router.mode == .off else {
            if !secureHotKeys.isEmpty { secureHotKeys.unregisterAll() }
            return
        }
        guard secureHotKeys.isEmpty else { return }
        let entries: [(UInt32, InteractionMode, Gesture)] = [
            (1, .click, config.clickEntry.gesture), (2, .scroll, config.scrollEntry.gesture), (3, .cursor, config.cursorEntry.gesture)
        ]
        for (id, mode, gesture) in entries {
            guard case let .key(code, modifiers) = gesture, !modifiers.isEmpty else { continue }
            secureHotKeys.register(id, code: code, modifiers: modifiers) { [weak self] in self?.setMode(mode) }
        }
    }

    private func forceOff(reason: String) {
        message = reason
        record(reason)
        apply(router.handle(.forceOff, at: now, pointer: pointer).effects)
        output.releaseAll()
        readiness = Permissions.report()
    }

    // MARK: - Click discovery and activation

    private var emptyRetryGeneration: Int?

    private func scheduleDiscovery(generation: Int) {
        guard let pid = targetPID else { return }
        let isRefresh = router.click?.hasSnapshot ?? false
        discoveryTask?.cancel()
        let budget = AccessibilityTargets.Budget()
        let extras = AccessibilityTargets.Extras(menuBar: config.clickLabelsMenuBar, dock: config.clickLabelsDock)
        let screen = NSRunningApplication(processIdentifier: pid).flatMap { _ in
            router.click?.targets.first.map { ScreenSpace.screen(containingGlobal: CGPoint(x: $0.frame.x, y: $0.frame.y)) } ?? nil
        } ?? NSScreen.main
        discoveryTask = Task { @MainActor [weak self] in
            // A refresh after scrolling waits for the app to settle; the first discovery runs at once.
            if isRefresh { try? await Task.sleep(for: .milliseconds(220)) }
            guard !Task.isCancelled else { return }
            if let screen { self?.scanBar.start(on: screen, budget: budget.seconds) }
            let result = await AccessibilityTargets.discover(pid: pid, budget: budget, extras: extras)
            guard let self, !Task.isCancelled else { return }
            self.publish(result, generation: generation)
        }
    }

    private func publish(_ result: DiscoveryResult, generation: Int) {
        scanBar.finish()
        guard router.generation == generation, router.mode == .click else { return }
        snapshotCounter += 1
        let snapshot = snapshotCounter
        elementsBySnapshot[snapshot] = result.elements
        elementsBySnapshot = elementsBySnapshot.filter { $0.key > snapshot - 3 }
        lastDiscovery = DiscoveryStats(targets: result.targets.count, milliseconds: result.elapsed * 1000,
                                       visitedNodes: result.visitedNodes, truncated: result.truncated, scope: result.scope,
                                       contentTargets: result.contentTargets)
        if !result.foundWindow || !result.windowCanBeFullScreen, !result.targets.isEmpty, result.contentTargets == 0 {
            // No real window (Finder on the desktop, say), but the menu bar or Dock still have labels.
            message = nil
        } else if result.contentTargets == 0 {
            message = result.foundWindow
                ? "No keyboard targets found in this window. Use Moving here (\(config.cursorEntry.gesture.displayName))."
                : "This app does not expose its window to Accessibility. Use Moving here."
        } else if result.truncated {
            message = "Showing the first \(result.targets.count) targets; this window is larger than KeyNav reads at once."
        } else {
            message = nil
        }
        record("Found \(result.targets.count) targets in \(Int(result.elapsed * 1000)) ms")
        apply(router.handle(.targetsDiscovered(generation: generation, snapshot: snapshot, targets: result.targets),
                            at: now, pointer: pointer).effects)
        // A web view's first answer can come too late for the budget (System Settings' sheets): try once more.
        if result.contentTargets == 0, result.foundWindow, emptyRetryGeneration != generation {
            emptyRetryGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.router.generation == generation, self.router.mode == .click else { return }
                self.scheduleDiscovery(generation: generation)
            }
        }
        // A browser just asked for its full tree may still be building it; read again to label the rest.
        if result.treeWasAsleep {
            for delay in [0.3, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.router.generation == generation, self.router.mode == .click else { return }
                    self.scheduleDiscovery(generation: generation)
                }
            }
        }
    }

    private func activate(index: Int, snapshot: Int, generation: Int, action: TargetAction) {
        guard router.generation == generation, router.mode == .click else { return }
        func finish(_ succeeded: Bool, _ outcome: String, pointer usedPointer: Bool = false) {
            lastActivation = ActivationRecord(outcome: outcome, usedPointer: usedPointer)
            record("Activation: \(outcome)")
            if succeeded { clickHider.hide() }
            apply(router.handle(.activationFinished(generation: generation, succeeded: succeeded), at: now, pointer: pointer).effects)
        }
        guard let box = elementsBySnapshot[snapshot]?[safe: index],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
                || AccessibilityTargets.keyboardPanelApp() == targetPID else {
            message = "This target changed. Refreshing…"
            return finish(false, "stale snapshot")
        }
        // Runs on the main thread for every app, KeyNav's own window included: its accessibility is answered
        // in-process by AppKit and SwiftUI.
        let validation = AccessibilityTargets.revalidate(box)
        // A group whose controls appear on hover: put the pointer over it, then label again once they show.
        if box.pressAction == AXElementBox.hover, action == .press, case let .valid(frame) = validation {
            output.move(to: ClickPoint.of(frame.rect, scale: config.appearance.hintSize.scale).point)
            finish(true, "hovered", pointer: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.router.mode == .off else { return }
                self.setMode(.click)
            }
            return
        }
        let outcome = validation == .changed ? nil : AccessibilityTargets.performSemantic(box, action: action)
        complete(validation, outcome, action: action, box: box, finish: finish)
    }

    private func complete(_ validation: AccessibilityTargets.Revalidation, _ outcome: AccessibilityTargets.SemanticOutcome?,
                          action: TargetAction, box: AXElementBox? = nil, finish report: (Bool, String, Bool) -> Void) {
        func finish(_ succeeded: Bool, _ text: String, pointer: Bool = false) { report(succeeded, text, pointer) }
        guard case let .valid(frame) = validation, let outcome else {
            message = "This target changed. Refreshing…"
            return finish(false, "target changed")
        }
        // The same point the label's tail shows, computed from the revalidated frame.
        var center = ClickPoint.of((box?.clickFrame ?? frame).rect, scale: config.appearance.hintSize.scale).point
        // Pointer actions go where the app confirms the click reaches the control.
        if case .unsupported = outcome, let box { center = AccessibilityTargets.reachablePoint(box, preferred: center) }
        if let targetPID { lastSpots[targetPID] = (center, false) }

        switch outcome {
        case .pressed:
            finish(true, "pressed")
        case .focused:
            finish(true, "focused")
        case let .unsupported(reason):
            switch action {
            case .press:
                guard config.clickPointerFallback else {
                    message = "This control does not accept a keyboard press (\(reason)). Try Moving."
                    return finish(false, "press unsupported")
                }
                output.click(at: center, button: .left, count: 1)
                finish(true, "pointer click", pointer: true)
            case .rightClick:
                output.click(at: center, button: .right, count: 1)
                finish(true, "pointer right click", pointer: true)
            case .doubleClick:
                output.click(at: center, button: .left, count: 2)
                finish(true, "pointer double click", pointer: true)
            case .movePointer:
                output.move(to: center)
                finish(true, "pointer moved", pointer: true)
            }
        }
    }

    // MARK: - Timers and overlays

    private func updateTimers() {
        if router.cursorNeedsTicks {
            if tickTimer == nil {
                lastTick = now
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                tickTimer = timer
            }
        } else if let timer = tickTimer {
            timer.invalidate()
            tickTimer = nil
            // Scrolling just landed: let the app see what is now under the pointer.
            if router.mode == .scroll {
                output.refreshHover()
                dot.show(atGlobal: output.location())
            }
            lastTick = nil
        }
        // One shot per half-typed label, rescheduled whenever another letter moves the deadline.
        let deadline = router.typedLabelDeadline
        if deadline != labelTimerDeadline {
            labelTimer?.invalidate()
            labelTimer = nil
            labelTimerDeadline = deadline
            if let deadline {
                let timer = Timer(timeInterval: max(deadline - now, 0) + 0.01, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.labelTimerDeadline = nil
                        self.apply(self.router.handle(.typedLabelTimeout, at: self.now, pointer: self.pointer).effects)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                labelTimer = timer
            }
        }
        // The permission watchdog runs only while a mode is on; nothing polls while Off.
        if router.mode != .off {
            if watchdog == nil {
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkStillAllowed() }
                }
                RunLoop.main.add(timer, forMode: .common)
                watchdog = timer
            }
        } else if let timer = watchdog {
            timer.invalidate()
            watchdog = nil
        }
    }

    private func tick() {
        let current = now
        let dt = min(current - (lastTick ?? current), 0.05)
        lastTick = current
        let effects = router.tickCursor(dt: dt)
        for effect in effects { execute(effect) }
        if !keyDragMoved, clickKeyHoldsLeft, effects.contains(where: { if case .cursor(.move) = $0 { return true } else { return false } }) {
            keyDragMoved = true
            refreshOverlays()
        }
        if !router.cursorNeedsTicks { updateTimers() }
        placeBadge()
    }

    private func checkStillAllowed() {
        if !AXIsProcessTrusted() {
            tap?.uninstall()
            tap = nil
            tapInstalled = false
            forceOff(reason: "Accessibility access was turned off, so KeyNav stopped. Allow access again to continue.")
        } else if IsSecureEventInputEnabled(), !keyCatcher.isActive {
            // A password field took the keyboard mid-mode: read keys through the key panel from now on.
            keyCatcher.begin()
        }
    }

    private func refreshOverlays() {
        let appearance = config.appearance
        switch router.mode {
        case .off:
            badge.hide()
            help.hide()
            hints.clear()
            hud.hide()

        case .scroll:
            // The dot says enough; no badge, outline, or labels.
            badge.hide()
            help.hide()
            hud.hide()
            hints.clear()

        case .cursor:
            var details: [String] = []
            if router.routingSuspended { details.append(editingSettings ? "paused while editing" : "paused here") }
            if router.cursor.held.contains(.precision) { details.append("Precision") }
            if router.cursor.held.contains(.boost) { details.append("Boost") }
            if !clickKeyHoldsLeft { keyDragMoved = false }
            if isDragging { details.append("Dragging") }
            overlayModel.badgeTitle = "Moving"
            overlayModel.badgeDetail = details.isEmpty ? nil : details.joined(separator: " · ")
            overlayModel.badgeDragging = isDragging
            overlayModel.badgeScale = appearance.badgeSize.scale
            placeBadge()
            if router.helpVisible {
                fillHelp()
                if let screen = ScreenSpace.screen(containingGlobal: output.location()) {
                    let size = help.size
                    help.show(at: NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
                }
            } else {
                help.hide()
            }

        case .click:
            badge.hide()
            help.hide()
            guard let session = router.click else { return }
            let visible = session.visible
            let selected = session.selectedTarget
            let showSelection = session.substate == .search || (session.requireReturn && !session.typedPrefix.isEmpty)
            let items = visible.enumerated().map { position, index in
                HintOverlay.Item(
                    label: session.substate == .labels ? session.labels[index] : (position < 9 ? "\(position + 1)" : "·"),
                    typed: session.substate == .labels ? session.typedPrefix.count : 0,
                    frame: session.targets[index].frame,
                    selected: showSelection && index == selected
                )
            }
            let highlight = showSelection ? selected.map { session.targets[$0].frame } : nil
            hints.render(items, highlight: highlight, appearance: appearance)

            let exitName = config.clickEntry.separateExit ? config.clickEntry.exit.displayName : config.clickEntry.gesture.displayName
            overlayModel.hudTitle = session.substate == .labels ? "Clicking" : "Search"
            overlayModel.hudApp = targetName ?? ""
            overlayModel.hudCount = session.targets.count
            overlayModel.hudAction = session.pendingAction == .press ? nil : session.pendingAction.title
            overlayModel.hudQuery = session.substate == .search ? session.query : nil
            overlayModel.hudMessage = session.hasSnapshot ? message : nil
            let search = config.clickControls[.startSearch]?.displayName ?? "/"
            let cycle = config.clickControls[.cycleAction]?.displayName ?? "."
            overlayModel.hudLine = session.substate == .labels
                ? "Type a label · \(search) search · \(cycle) change action · \(exitName) exits"
                : "Return activates · Tab next · Delete on empty goes back · \(exitName) exits"
            // Labels speak for themselves; the panel appears only to show a search query or a problem.
            guard session.substate == .search || overlayModel.hudMessage != nil else {
                hud.hide()
                return
            }
            let anchor = session.targets.first.map { CGPoint(x: $0.frame.x, y: $0.frame.y) } ?? output.location()
            if let screen = ScreenSpace.screen(containingGlobal: anchor) {
                let size = hud.size
                hud.show(at: NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12))
            }
        }
    }

    private var clickKeyHoldsLeft: Bool {
        router.cursor.heldButtons.values.contains { $0.button == .left }
    }

    /// Dragging with the drag key, by holding the click key and moving, or with the mouse itself.
    private var isDragging: Bool {
        router.cursor.leftDown || (clickKeyHoldsLeft && keyDragMoved) || mouseDragging
    }

    private func placeBadge(at point: CGPoint? = nil) {
        guard router.mode == .cursor else { return }
        let location = point ?? output.location()
        guard let screen = ScreenSpace.screen(containingGlobal: location) else { return }
        let size = badge.size
        var origin: NSPoint
        switch config.appearance.badgePlacement {
        case .nearPointer:
            let anchor = ScreenSpace.appKitPoint(fromGlobal: location)
            origin = NSPoint(x: anchor.x + 16, y: anchor.y - size.height - 18)
        case .screenCorner:
            origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.maxY - size.height - 12)
        }
        origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        origin.y = min(max(origin.y, screen.frame.minY + 4), screen.frame.maxY - size.height - 4)
        badge.show(at: origin)
    }

    private func fillHelp() {
        var groups: [(group: String, rows: [(action: String, keys: String)])] = []
        for group in CursorAction.Group.allCases {
            let rows = CursorAction.allCases.filter { $0.group == group }.compactMap { action -> (action: String, keys: String)? in
                let keys = config.cursorBindings.filter { $0.action == action }.map(\.gesture.displayName)
                return keys.isEmpty ? nil : (action.title, keys.joined(separator: ", "))
            }
            if !rows.isEmpty { groups.append((group.rawValue, rows)) }
        }
        overlayModel.helpRows = groups
        overlayModel.helpExit = config.cursorEntry.separateExit ? config.cursorEntry.exit.displayName : config.cursorEntry.gesture.displayName
    }

    // MARK: - System observation

    private func observeSystem() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundle = app?.bundleIdentifier
            let name = app?.localizedName
            MainActor.assumeIsolated { self?.frontmostChanged(pid: pid, bundleID: bundle, name: name) }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { [weak self] _ in
                MainActor.assumeIsolated { self?.forceOff(reason: "Navigation stopped for sleep, lock, or a user switch.") }
            }
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.applicationQuit(pid: pid) }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.router.mode != .off else { return }
                self.forceOff(reason: "The display arrangement changed, so navigation stopped.")
            }
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckReadiness() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ block: @escaping @Sendable (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: block)))
    }

    /// macOS's screenshot tools (Command Shift 3, 4, 5) come to the front while capturing; a mode stays on through them.
    private static let screenshotApps: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher"]

    private func frontmostChanged(pid: pid_t?, bundleID: String?, name: String?) {
        guard let pid else { return }
        screenshotting = bundleID.map(Self.screenshotApps.contains) ?? false
        if screenshotting { return }
        if pid == getpid() {
            // KeyNav's own window came forward while Label-click or Scroll was acting on another app.
            if router.mode == .click || router.mode == .scroll, let targetPID, targetPID != pid {
                apply(router.handle(.focusChanged, at: now, pointer: pointer).effects)
            }
            return
        }
        lastExternalPID = pid
        frontBundleID = bundleID
        frontName = name
        if router.mode == .click || router.mode == .scroll, pid != targetPID {
            apply(router.handle(.focusChanged, at: now, pointer: pointer).effects)
        }
        if router.mode == .cursor, !router.routingSuspended {
            // Cursor mode survives an app switch but never carries a drag or held motion into the new app.
            apply(router.handle(.suspendRouting(true), at: now, pointer: pointer).effects)
            apply(router.handle(.suspendRouting(false), at: now, pointer: pointer).effects)
        }
        updateExclusion()
    }

    /// The app Label-click or Scroll was acting on quit: nothing of its labels or outline may stay on screen.
    private func applicationQuit(pid: pid_t?) {
        guard let pid else { return }
        if pid == lastExternalPID { lastExternalPID = nil }
        lastSpots[pid] = nil
        if router.mode == .click || router.mode == .scroll, pid == targetPID {
            apply(router.handle(.focusChanged, at: now, pointer: pointer).effects)
        }
    }

    private func updateExclusion() {
        let excluded = frontBundleID.map { config.excludedBundleIDs.contains($0) } ?? false
        let newValue = excluded ? (frontName ?? frontBundleID) : nil
        guard newValue != excludedAppInFront else { return }
        excludedAppInFront = newValue
        if excluded, router.mode != .off {
            forceOff(reason: "KeyNav is turned off in \(newValue ?? "this app").")
        }
        syncSuspension()
    }

    private func record(_ text: String) {
        log.append(LogEntry(date: Date(), text: text))
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
