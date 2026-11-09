import AppKit
import ApplicationServices
import KeyNavCore
import KeyNavSystem

/// Live end-to-end checks run inside the real, permission-holding KeyNav.app against the KeyNav Fixture.
///
/// Input is synthetic: CGEvents posted at the HID level, so they pass through KeyNav's real event tap,
/// router, pointer output, Accessibility discovery, and the fixture's real controls. This is NOT a
/// hardware test: physical keyboards, modifier timing by hand, and display refresh are not exercised.
/// All pointer, click, and scroll activity stays inside the fixture windows.
@MainActor
final class LiveSelfTest {
    struct Check: Codable {
        var id: String
        var acceptance: [String]
        var title: String
        var passed: Bool
        var detail: String
        var metrics: [String: Double] = [:]
    }

    private let model: AppModel
    private let outputDirectory: URL
    private let fixtureURL: URL?
    private let showSettings: () -> NSWindow?
    private var checks: [Check] = []
    private var fixture: NSRunningApplication?
    private var canvas: NSRunningApplication?
    private let source = CGEventSource(stateID: .hidSystemState)
    private var navigation: NavigationService { model.navigation }

    init(model: AppModel, output: URL, fixturePath: String?, showSettings: @escaping () -> NSWindow?) {
        self.model = model
        self.outputDirectory = output
        self.fixtureURL = fixturePath.map { URL(fileURLWithPath: $0) }
        self.showSettings = showSettings
    }

    private var stateURL: URL { outputDirectory.appendingPathComponent("fixture-state.json") }
    private var canvasStateURL: URL { outputDirectory.appendingPathComponent("canvas-state.json") }

    // MARK: - Run

    func run() async -> Bool {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let started = Date()
        let originalPointer = pointer()
        defer {
            releaseAllModifiers()
            move(to: originalPointer)
        }

        guard navigation.tapInstalled else {
            record("L00", [], "Readiness", false, "The running KeyNav.app could not install its event tap: \(navigation.readiness.status.rawValue).")
            writeReport(started: started)
            return false
        }
        record("L00", ["M0"], "Real app identity can install an active keyboard tap", true,
               "Bundle \(navigation.readiness.bundleIdentifier); Accessibility \(navigation.readiness.accessibilityTrusted); Input Monitoring \(navigation.readiness.listenEventAccess).")

        guard await launchFixture() else {
            record("L01", [], "Fixture launch", false, "KeyNav Fixture did not start.")
            writeReport(started: started)
            return false
        }

        await offPassThrough()
        await optionShortcutDoesNotEnter()
        await cursorEntry()
        await movement()
        await diagonal()
        await clicks()
        await scrolling()
        await drag()
        await exitWhileDragging()
        await clickDirectEntry()
        await searchField()
        await escapeFromSearch()
        await staleTarget()
        await switching()
        await separateExitOn()
        await separateExitOff()
        await settingsEditing()
        await inaccessibleCanvas()
        await focusChangeDuringDiscovery()
        await forcedStopWhileDragging()
        await scrollMode()
        await stability()
        await idleCPU()

        fixture?.terminate()
        canvas?.terminate()
        writeReport(started: started)
        return checks.allSatisfy(\.passed)
    }

    /// Opens Click mode on the fixture and keeps the labels up for `seconds`, for visual review.
    func demoLabels(seconds: Double) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        guard navigation.tapInstalled, await launchFixture() else { return }
        await focusFixture()
        clickEntryChord()
        try? "labels".write(to: outputDirectory.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        await wait(Int(seconds * 1000))
        tapKey(Key.escape)
        fixture?.terminate()
    }

    /// Runs only the Scroll-mode check against the fixture and writes the report.
    func scrollCheck() async -> Bool {
        let started = Date()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        guard navigation.tapInstalled, await launchFixture() else { return false }
        await scrollMode()
        fixture?.terminate()
        writeReport(started: started)
        return checks.allSatisfy(\.passed)
    }

    // MARK: - Checks

    /// Scroll mode: with the pointer over the fixture's scroll view, holding J scrolls it down, Shift-K jumps back
    /// up, and Escape exits with the pointer where it was.
    private func scrollMode() async {
        await ensureOff()
        await focusFixture()
        move(to: center("scroll"))
        await wait(200)
        let home = pointer()
        let scrollY = { self.state()["scrollY"] as? Double ?? 0 }
        let before = scrollY()
        key(Key.j, down: true, flags: [.maskControl, .maskCommand])
        key(Key.j, down: false, flags: [.maskControl, .maskCommand])
        let started = await waitFor(2) { self.navigation.mode == .scroll && self.navigation.router.scroll?.window != nil }
        await wait(200)
        let parked = pointer()
        key(Key.j, down: true, text: "j")
        await wait(600)
        key(Key.j, down: false, text: "j")
        await wait(300)
        let afterJ = scrollY()
        key(Key.k, down: true, flags: [.maskShift], text: "K")
        key(Key.k, down: false, flags: [.maskShift], text: "K")
        await wait(500)
        let afterDash = scrollY()
        tapKey(Key.escape)
        await wait(300)
        let back = pointer()
        let passed = started && afterJ > before + 20 && afterDash < afterJ - 50 && distance(back, home) < 2 && navigation.mode == .off
        record("L24", ["Scroll"], "Scroll mode scrolls what is under the pointer", passed,
               "Started: \(started); pointer moved \(fmt(distance(parked, home))) pt away; J scrolled \(fmt(before)) → \(fmt(afterJ)) pt; Shift-K back to \(fmt(afterDash)) pt; pointer returned within \(fmt(distance(back, home))) pt; mode \(navigation.mode.rawValue). Log: \(navigation.log.suffix(3).map(\.text).joined(separator: " / "))")
    }

    /// A03: action letters and arrows type normally while Off.
    private func offPassThrough() async {
        await focusFixture()
        await clickField("typing")
        let before = pointer()
        let padBefore = padCount("leftDown") + padCount("rightDown") + padCount("otherDown")
        type("ijklrewq")
        for code in [Key.upArrow, Key.downArrow, Key.leftArrow, Key.rightArrow] { tapKey(code) }
        await wait(300)
        let typing = state()["typing"] as? String ?? ""
        let moved = distance(before, pointer())
        let padAfter = padCount("leftDown") + padCount("rightDown") + padCount("otherDown")
        record("L01", ["A03"], "Off: I J K L R E W Q and arrows type normally", typing.hasSuffix("ijklrewq") && moved < 1 && padAfter == padBefore && navigation.mode == .off,
               "Field received “\(typing)”; pointer moved \(fmt(moved)) pt; mouse events \(padAfter - padBefore); mode \(navigation.mode.rawValue).")
    }

    /// A05: Option-letter shortcuts and long Option holds never enter.
    private func optionShortcutDoesNotEnter() async {
        await clickField("typing")
        let before = (state()["typing"] as? String ?? "").count
        modifier(Key.rightOption, down: true)
        await wait(40)
        key(Key.a, down: true, flags: flags(Key.rightOption), text: "å")
        key(Key.a, down: false, flags: flags(Key.rightOption), text: "å")
        await wait(40)
        modifier(Key.rightOption, down: false)
        await wait(150)
        let afterShortcut = navigation.mode
        let typed = (state()["typing"] as? String ?? "")
        modifier(Key.rightOption, down: true)
        await wait(450)
        modifier(Key.rightOption, down: false)
        await wait(150)
        let afterHold = navigation.mode
        record("L02", ["A05"], "Option-letter and a long Option hold do not start Cursor mode",
               afterShortcut == .off && afterHold == .off && typed.count == before + 1 && typed.hasSuffix("å"),
               "After Option-A: \(afterShortcut.rawValue), field gained “\(typed.suffix(1))”; after a 450 ms hold: \(afterHold.rawValue).")
    }

    /// A04: Right Option tap enters with no click or jump.
    private func cursorEntry() async {
        await focusFixture()
        move(to: center("pad"))
        await wait(250)
        let before = pointer()
        let downs = padCount("leftDown") + padCount("rightDown")
        let entered = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        await wait(200)
        let badgeVisible = visibleOverlayCount() > 0
        record("L03", ["A04"], "Right Option tap starts Cursor mode without clicking or moving",
               entered && distance(before, pointer()) < 1 && padCount("leftDown") + padCount("rightDown") == downs && badgeVisible,
               "Mode \(navigation.mode.rawValue); pointer moved \(fmt(distance(before, pointer()))) pt; badge visible \(badgeVisible).")
    }

    /// A06: motion starts quickly, ramps, and stops promptly on release, independent of key repeat.
    private func movement() async {
        await ensureCursor()
        move(to: point(in: "pad", 0.15, 0.5))
        await wait(250)
        let start = pointer()
        let pressed = ProcessInfo.processInfo.systemUptime
        key(Key.l, down: true, text: "l")
        var firstMotion: Double?
        while ProcessInfo.processInfo.systemUptime - pressed < 0.4 {
            if firstMotion == nil, pointer().x != start.x { firstMotion = ProcessInfo.processInfo.systemUptime - pressed }
            await wait(2)
        }
        let beforeRelease = pointer()
        let released = ProcessInfo.processInfo.systemUptime
        key(Key.l, down: false, text: "l")
        var lastChange = released
        var last = pointer()
        while ProcessInfo.processInfo.systemUptime - released < 0.3 {
            let now = pointer()
            if now != last { lastChange = ProcessInfo.processInfo.systemUptime; last = now }
            await wait(2)
        }
        let stopMs = (lastChange - released) * 1000
        let travelled = beforeRelease.x - start.x
        record("L04", ["A06"], "Holding L moves right smoothly and stops on release",
               (firstMotion ?? 1) < 0.05 && travelled > 20 && stopMs < 40,
               "First motion after \(fmt((firstMotion ?? -1) * 1000)) ms; moved \(fmt(travelled)) pt in 400 ms with no key repeats; last motion \(fmt(stopMs)) ms after release.",
               ["firstMotionMs": (firstMotion ?? -1) * 1000, "stopAfterReleaseMs": stopMs, "distance400ms": travelled])
    }

    /// A07: diagonal speed is normalized.
    private func diagonal() async {
        await ensureCursor()
        move(to: point(in: "pad", 0.2, 0.2))
        await wait(250)
        let start = pointer()
        key(Key.l, down: true, text: "l")
        key(Key.k, down: true, text: "k")
        await wait(300)
        key(Key.l, down: false, text: "l")
        key(Key.k, down: false, text: "k")
        await wait(80)
        let end = pointer()
        let dx = end.x - start.x
        let dy = end.y - start.y
        move(to: point(in: "pad", 0.2, 0.5))
        await wait(250)
        let straightStart = pointer()
        key(Key.l, down: true, text: "l")
        await wait(300)
        key(Key.l, down: false, text: "l")
        await wait(80)
        let straight = pointer().x - straightStart.x
        let diagonalLength = hypot(dx, dy)
        let ratio = straight > 0 ? diagonalLength / straight : 0
        record("L05", ["A07"], "Diagonal movement is normalized",
               abs(dx - dy) <= max(dx, dy) * 0.2 && ratio > 0.8 && ratio < 1.2,
               "Diagonal moved \(fmt(dx)) × \(fmt(dy)) pt (length \(fmt(diagonalLength))); straight moved \(fmt(straight)) pt in the same time; ratio \(fmt(ratio)).",
               ["diagonalToStraightRatio": ratio])
    }

    /// Mouse buttons with real click counts.
    private func clicks() async {
        await ensureCursor()
        move(to: center("pad"))
        await wait(250)
        let downs = padCount("leftDown")
        tapKey(Key.space, text: " ")
        await wait(120)
        tapKey(Key.space, text: " ")
        await wait(250)
        let rights = padCount("rightDown")
        let others = padCount("otherDown")
        key(Key.space, down: true, flags: .maskShift, text: " ")
        key(Key.space, down: false, flags: .maskShift, text: " ")
        tapKey(Key.e, text: "e")
        await wait(250)
        record("L06", ["M1"], "Space clicks (twice = double-click), Shift-Space right-clicks, E middle-clicks",
               padCount("leftDown") == downs + 2 && padCount("maxClickCount") >= 2 && padCount("rightDown") == rights + 1 && padCount("otherDown") == others + 1,
               "Left downs +\(Int(padCount("leftDown") - downs)), max click count \(Int(padCount("maxClickCount"))), right +\(Int(padCount("rightDown") - rights)), middle +\(Int(padCount("otherDown") - others)).")
    }

    private func scrolling() async {
        await ensureCursor()
        move(to: center("scroll"))
        await wait(250)
        let before = state()["scrollY"] as? Double ?? 0
        key(Key.downArrow, down: true)
        await wait(350)
        key(Key.downArrow, down: false)
        await wait(250)
        let afterDown = state()["scrollY"] as? Double ?? 0
        key(Key.upArrow, down: true)
        await wait(200)
        key(Key.upArrow, down: false)
        await wait(250)
        let afterUp = state()["scrollY"] as? Double ?? 0
        record("L07", ["M1"], "Down/Up arrows scroll the area under the pointer",
               afterDown > before + 20 && afterUp < afterDown,
               "Scrolled from \(fmt(before)) to \(fmt(afterDown)) pt with Down, back to \(fmt(afterUp)) with Up. Direction follows this Mac’s scrolling setting.",
               ["scrolledDown": afterDown - before])
    }

    private func drag() async {
        await ensureCursor()
        move(to: point(in: "pad", 0.2, 0.5))
        await wait(250)
        let distanceBefore = padCount("dragDistance")
        let upsBefore = padCount("leftUp")
        key(Key.space, down: true, text: " ")
        await wait(80)
        key(Key.l, down: true, text: "l")
        await wait(250)
        key(Key.l, down: false, text: "l")
        await wait(80)
        key(Key.space, down: false, text: " ")
        await wait(250)
        let dragged = padCount("dragDistance") - distanceBefore
        record("L08", ["M1"], "Holding Space drags while I J K L move",
               dragged > 20 && padCount("leftUp") == upsBefore + 1 && !leftButtonDown(),
               "Dragged \(fmt(dragged)) pt; button released \(Int(padCount("leftUp") - upsBefore)) time(s); button still down: \(leftButtonDown()).")
    }

    /// A08: Exit mid-drag and mid-motion releases the button and stops motion; held keys do not leak.
    private func exitWhileDragging() async {
        await ensureCursor()
        await clickField("typing")
        await ensureCursor()
        move(to: point(in: "pad", 0.2, 0.3))
        await wait(250)
        let typingBefore = state()["typing"] as? String ?? ""
        let upsBefore = padCount("leftUp")
        modifier(Key.leftCommand, down: true)
        await wait(60)
        key(Key.l, down: true, flags: flags(Key.leftCommand), text: "l")
        await wait(200)
        key(Key.escape, down: true, flags: flags(Key.leftCommand))
        key(Key.escape, down: false, flags: flags(Key.leftCommand))
        await wait(60)
        let afterExit = pointer()
        await wait(200)
        let drift = distance(afterExit, pointer())
        key(Key.l, down: false, flags: flags(Key.leftCommand), text: "l")
        modifier(Key.leftCommand, down: false)
        await wait(200)
        record("L09", ["A08"], "Escape while dragging and moving stops motion and releases the button",
               navigation.mode == .off && padCount("leftUp") == upsBefore + 1 && drift < 1 && !leftButtonDown()
                   && (state()["typing"] as? String ?? "") == typingBefore,
               "Mode \(navigation.mode.rawValue); button released \(Int(padCount("leftUp") - upsBefore))×; drift after exit \(fmt(drift)) pt; no keys leaked into the field: \((state()["typing"] as? String ?? "") == typingBefore).")
    }

    /// A09 and A11: Click from Off labels the fixture; a complete label activates exactly once.
    private func clickDirectEntry() async {
        await focusFixture()
        await ensureOff()
        let counter = state()["counter"] as? Int ?? 0
        let second = state()["second"] as? Int ?? 0
        let entered = ProcessInfo.processInfo.systemUptime
        clickEntryChord()
        let ready = await waitFor(2) { self.navigation.router.click?.hasSnapshot == true }
        let labelMs = (ProcessInfo.processInfo.systemUptime - entered) * 1000
        let session = navigation.router.click
        let names = session?.targets.map(\.name) ?? []
        let wanted = ["Increment", "Second action", "Name", "Typing area", "Moving target", "Remember me"]
        let found = wanted.filter { names.contains($0) }
        let hasDisabled = names.contains("Disabled action")
        record("L10", ["A09"], "The Click shortcut starts Click directly and labels the fixture window",
               ready && navigation.mode == .click && found.count == wanted.count && !hasDisabled && visibleOverlayCount() > 0,
               "\(names.count) targets in \(fmt(labelMs)) ms (discovery \(fmt(navigation.lastDiscovery?.milliseconds ?? -1)) ms); found \(found.count)/\(wanted.count) expected; disabled button excluded: \(!hasDisabled).",
               ["firstLabelsMs": labelMs, "discoveryMs": navigation.lastDiscovery?.milliseconds ?? -1, "targets": Double(names.count)])

        guard let session, let index = session.targets.firstIndex(where: { $0.name == "Increment" }) else {
            record("L11", ["A11"], "Typing a complete label activates once", false, "No Increment target was labelled.")
            return
        }
        type(session.labels[index])
        await wait(500)
        let newCounter = state()["counter"] as? Int ?? 0
        record("L11", ["A11"], "Typing a complete label activates exactly that target once",
               newCounter == counter + 1 && (state()["second"] as? Int ?? 0) == second && navigation.mode == .off,
               "Increment pressed \(newCounter - counter)×; other button \((state()["second"] as? Int ?? 0) - second)×; mode afterwards \(navigation.mode.rawValue) (one-shot); method: \(navigation.lastActivation?.outcome ?? "none").")
    }

    /// A13: search for a field, activate it, and type into it right away.
    private func searchField() async {
        await focusFixture()
        await ensureOff()
        clickEntryChord()
        _ = await waitFor(2) { self.navigation.router.click?.hasSnapshot == true }
        tapKey(Key.slash, text: "/")
        type("name")
        await wait(150)
        let results = navigation.router.click?.visible.count ?? 0
        tapKey(Key.returnKey)
        await wait(400)
        type("zq")
        await wait(300)
        let name = state()["name"] as? String ?? ""
        record("L12", ["A13"], "Search “name”, press Return, then type into the field immediately",
               navigation.mode == .off && name.hasSuffix("zq"),
               "\(results) result(s); mode after Return \(navigation.mode.rawValue); Name field now ends with “\(name.suffix(2))”.")
    }

    /// A24: one Escape leaves Click mode from Search.
    private func escapeFromSearch() async {
        await focusFixture()
        await ensureOff()
        clickEntryChord()
        _ = await waitFor(2) { self.navigation.router.click?.hasSnapshot == true }
        tapKey(Key.slash, text: "/")
        type("x")
        await wait(100)
        let inSearch = navigation.router.click?.substate == .search
        tapKey(Key.escape)
        await wait(200)
        record("L13", ["A24"], "One Escape exits Click mode from Search",
               inSearch && navigation.mode == .off && visibleOverlayCount() == 0,
               "Was in search: \(inSearch); mode after one Escape: \(navigation.mode.rawValue); overlays left: \(visibleOverlayCount()).")
    }

    /// A12: a target that moved after labelling is not clicked; KeyNav refreshes instead.
    private func staleTarget() async {
        await focusFixture()
        await ensureOff()
        clickEntryChord()
        _ = await waitFor(2) { self.navigation.router.click?.hasSnapshot == true }
        guard let session = navigation.router.click, let index = session.targets.firstIndex(where: { $0.name == "Moving target" }) else {
            record("L14", ["A12"], "Moved target is not clicked", false, "Moving target was not labelled.")
            return
        }
        let moving = state()["moving"] as? Int ?? 0
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.keynav.fixture.move"), object: nil, deliverImmediately: true)
        await wait(400)
        type(session.labels[index])
        await wait(500)
        let movedOutcome = navigation.lastActivation?.outcome ?? "none"
        let stillClick = navigation.mode == .click
        let refreshed = await waitFor(1.5) { self.navigation.router.click?.snapshot ?? 0 > session.snapshot }

        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.keynav.fixture.remove"), object: nil, deliverImmediately: true)
        await wait(100)
        var removedOutcome = "not run"
        if let fresh = navigation.router.click, let freshIndex = fresh.targets.firstIndex(where: { $0.name == "Moving target" }) {
            type(fresh.labels[freshIndex])
            await wait(500)
            removedOutcome = navigation.lastActivation?.outcome ?? "none"
        }
        tapKey(Key.escape)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.keynav.fixture.restore"), object: nil, deliverImmediately: true)
        await wait(300)
        record("L14", ["A12"], "A target that moved or disappeared is not clicked; labels refresh",
               (state()["moving"] as? Int ?? 0) == moving && movedOutcome == "target changed" && stillClick && refreshed
                   && removedOutcome == "target changed",
               "Moving target pressed \((state()["moving"] as? Int ?? 0) - moving)×; after move: “\(movedOutcome)”, stayed in Click \(stillClick), refreshed \(refreshed); after removal: “\(removedOutcome)”.")
    }

    /// A10: Cursor → Click → Cursor keeps one owner and never leaves a drag held.
    private func switching() async {
        await focusFixture()
        await ensureOff()
        move(to: point(in: "pad", 0.5, 0.5))
        await wait(250)
        let upsBefore = padCount("leftUp")
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        modifier(Key.leftCommand, down: true)
        await wait(150)
        let dragging = leftButtonDown()
        clickEntryChord(extra: flags(Key.leftCommand))
        await wait(250)
        let clickMode = navigation.mode == .click
        let releasedOnSwitch = !leftButtonDown() && padCount("leftUp") == upsBefore + 1
        modifier(Key.leftCommand, down: false)
        await wait(100)
        _ = await waitFor(2) { self.navigation.router.click?.hasSnapshot == true }
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        await wait(150)
        record("L15", ["A10"], "Cursor → Click → Cursor: one owner, drag released, no stale labels",
               dragging && clickMode && releasedOnSwitch && navigation.mode == .cursor && navigation.router.click == nil && !leftButtonDown(),
               "Drag was down: \(dragging); switched to Click: \(clickMode); drag released before Click: \(releasedOnSwitch); back in Cursor: \(navigation.mode == .cursor); Click snapshot cleared: \(navigation.router.click == nil).")
        await ensureOff()
    }

    /// A25: with a separate exit, the entry only enters; the exit works only in its mode.
    private func separateExitOn() async {
        await focusFixture()
        await ensureOff()
        await clickField("typing")
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        _ = await tapModifier(Key.rightOption, until: { false }, timeout: 0.3)
        let stillOn = navigation.mode == .cursor
        tapKey(Key.escape)
        await wait(150)
        let off = navigation.mode == .off
        record("L16", ["A25"], "Separate exit on: entry is enter-only, Escape exits",
               stillOn && off, "After a second Right Option tap: \(stillOn ? "still on" : "turned off"); after Escape: \(navigation.mode.rawValue).")
    }

    /// A26: without a separate exit, the entry toggles; Escape belongs to the app; the other entry switches.
    private func separateExitOff() async {
        model.update("Self-test: Cursor exit uses the entry") { $0.cursorEntry.separateExit = false }
        await focusFixture()
        await ensureOff()
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        tapKey(Key.escape)
        await wait(150)
        let escapeIgnored = navigation.mode == .cursor
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .off })
        let toggledOff = navigation.mode == .off
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        clickEntryChord()
        await wait(250)
        let switched = navigation.mode == .click
        tapKey(Key.escape)
        await wait(150)
        model.update("Self-test: Cursor exit restored") { $0.cursorEntry.separateExit = true }
        record("L17", ["A26"], "Separate exit off: entry toggles, Escape is ordinary, the Click entry switches modes",
               escapeIgnored && toggledOff && switched,
               "Escape kept Cursor on: \(escapeIgnored); second tap turned it off: \(toggledOff); The Click shortcut switched to Click: \(switched).")
        await ensureOff()
    }

    /// A15: editing a Settings field while a mode is on edits the field and never moves the pointer.
    private func settingsEditing() async {
        await focusFixture()
        await ensureOff()
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        model.page = .click
        let settingsWindow = showSettings()
        await wait(900)
        guard let window = settingsWindow, let field = editableField(in: window.contentView) else {
            record("L18", ["A15"], "Settings fields work while a mode is on", false, "No editable field found in Settings.")
            await ensureOff()
            return
        }
        let original = field.stringValue
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        await wait(200)
        let before = pointer()
        type("ijk")
        await wait(300)
        let text = field.currentEditor()?.string ?? field.stringValue
        let moved = distance(before, pointer())
        let editing = navigation.editingSettings
        let modeKept = navigation.mode == .cursor
        field.stringValue = original
        window.makeFirstResponder(nil)
        await wait(200)
        record("L18", ["A15"], "Typing in a Settings field while Cursor mode is on edits the field only",
               text.hasSuffix("ijk") && moved < 1 && editing && modeKept,
               "Field ends with “\(text.suffix(3))”; pointer moved \(fmt(moved)) pt; paused for editing: \(editing); Cursor mode still selected: \(modeKept).")
        navigation.stopNavigation()
        window.orderOut(nil)
        await focusFixture()
    }

    /// A14: an inaccessible canvas gets an honest message, not fake labels.
    private func inaccessibleCanvas() async {
        await ensureOff()
        guard let canvas = await launch(arguments: ["--state", canvasStateURL.path, "--canvas"]) else {
            record("L19", ["A14"], "Inaccessible canvas", false, "Canvas fixture did not start.")
            return
        }
        self.canvas = canvas
        await activate(canvas)
        clickEntryChord()
        _ = await waitFor(2) { self.navigation.router.click?.hasSnapshot == true }
        let targets = navigation.router.click?.targets.count ?? -1
        let content = navigation.lastDiscovery?.contentTargets ?? -1
        let message = navigation.message ?? ""
        tapKey(Key.escape)
        await wait(150)
        record("L19", ["A14"], "Click on an inaccessible canvas says so and points to Cursor mode",
               content == 0 && message.contains("Cursor mode"),
               "Content targets: \(content) (window buttons labelled: \(targets)); message: “\(message)”.")
    }

    /// A19: switching apps during discovery stops Click; the old job cannot publish.
    private func focusChangeDuringDiscovery() async {
        await focusFixture()
        await ensureOff()
        clickEntryChord()
        // Switch apps mid-discovery by opening another fixture window (a launched app may take focus;
        // a background app asking to activate another is ignored by current macOS).
        let switcher = await launch(arguments: ["--state", outputDirectory.appendingPathComponent("switch-state.json").path, "--canvas"])
        await wait(600)
        let off = navigation.mode == .off
        let switched = NSWorkspace.shared.frontmostApplication?.processIdentifier == switcher?.processIdentifier
        record("L20", ["A19"], "Switching apps during discovery ends Click without publishing old labels",
               switched && off && navigation.router.click == nil && visibleOverlayCount() == 0,
               "Other app took focus: \(switched); mode \(navigation.mode.rawValue); snapshot \(navigation.router.click == nil ? "discarded" : "still present"); overlays \(visibleOverlayCount()).")
        switcher?.terminate()
        await focusFixture()
    }

    /// A20 (partial): the sleep/lock path releases a held drag and turns navigation off.
    private func forcedStopWhileDragging() async {
        await focusFixture()
        await ensureOff()
        move(to: point(in: "pad", 0.4, 0.4))
        await wait(250)
        _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        modifier(Key.leftCommand, down: true)
        await wait(150)
        let upsBefore = padCount("leftUp")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        await wait(250)
        let released = padCount("leftUp") == upsBefore + 1 && !leftButtonDown()
        modifier(Key.leftCommand, down: false)
        await wait(100)
        record("L21", ["A20"], "Sleep notification mid-drag releases the button and turns KeyNav off (simulated notification)",
               released && navigation.mode == .off,
               "Button released: \(released); mode \(navigation.mode.rawValue). Real sleep, lock, and permission revocation were not exercised by this test.")
    }

    /// Spec §12 stability: generated enter/switch/exit sequences leave nothing held.
    private func stability() async {
        await focusFixture()
        await ensureOff()
        move(to: center("pad"))
        await wait(200)
        var seed: UInt64 = 0x5EED
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        for _ in 0..<150 {
            switch next() % 5 {
            case 0: _ = await tapModifier(Key.rightOption, until: { false }, timeout: 0)
            case 1: clickEntryChord()
            case 2: modifier(Key.leftCommand, down: true); await wait(10); modifier(Key.leftCommand, down: false)
            case 3: key(Key.j, down: true, text: "j"); await wait(15); key(Key.j, down: false, text: "j")
            default: tapKey(Key.escape)
            }
            await wait(18)
        }
        tapKey(Key.escape)
        await wait(300)
        if navigation.mode != .off { tapKey(Key.escape); await wait(200) }
        record("L22", ["Stability"], "150 generated enter/switch/drag/exit steps leave nothing held",
               navigation.mode == .off && !leftButtonDown() && visibleOverlayCount() == 0 && navigation.router.cursor.held.isEmpty,
               "Mode \(navigation.mode.rawValue); left button down \(leftButtonDown()); overlays \(visibleOverlayCount()); held actions \(navigation.router.cursor.held.count).")
    }

    /// Spec §12 idle behaviour: no animation or polling loop while Off.
    private func idleCPU() async {
        await ensureOff()
        let start = cpuSeconds()
        let wall = Date()
        await wait(5000)
        let cpu = cpuSeconds() - start
        let percent = cpu / Date().timeIntervalSince(wall) * 100
        record("L23", ["Performance"], "Idle CPU while Off over 5 s",
               percent < 1.0, "KeyNav used \(fmt(cpu * 1000)) ms of CPU in 5 s (\(fmt(percent))%).", ["idleCPUPercent": percent])
    }

    // MARK: - Fixture helpers

    private func launchFixture() async -> Bool {
        guard let app = await launch(arguments: ["--state", stateURL.path]) else { return false }
        fixture = app
        return await waitFor(5) { FileManager.default.fileExists(atPath: self.stateURL.path) && !(self.state()["frames"] as? [String: Any] ?? [:]).isEmpty }
    }

    private func launch(arguments: [String]) async -> NSRunningApplication? {
        guard let fixtureURL else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let app = try? await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: configuration)
        await wait(800)
        return app
    }

    private func activate(_ app: NSRunningApplication) async {
        app.activate()
        // A background app's activation request can be ignored; Accessibility's frontmost attribute is honoured.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = await waitFor(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        await wait(150)
    }

    private func focusFixture() async {
        if let fixture { await activate(fixture) }
    }

    private func ensureOff() async {
        if navigation.mode != .off {
            navigation.stopNavigation()
            await wait(100)
        }
    }

    private func ensureCursor() async {
        if navigation.mode != .cursor {
            await focusFixture()
            _ = await tapModifier(Key.rightOption, until: { self.navigation.mode == .cursor })
        }
    }

    private func state() -> [String: Any] {
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func padCount(_ key: String) -> Double {
        (state()["pad"] as? [String: Double])?[key] ?? 0
    }

    private func frame(_ name: String) -> CGRect {
        guard let frames = state()["frames"] as? [String: [String: Double]], let f = frames[name] else { return .zero }
        return CGRect(x: f["x"] ?? 0, y: f["y"] ?? 0, width: f["width"] ?? 0, height: f["height"] ?? 0)
    }

    private func center(_ name: String) -> CGPoint { point(in: name, 0.5, 0.5) }

    private func point(in name: String, _ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        let f = frame(name)
        return CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
    }

    private func clickField(_ name: String) async {
        let p = center(name)
        move(to: p)
        await wait(100)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        await wait(200)
        // Put the caret at the end so typed text appends.
        key(Key.rightArrow, down: true, flags: .maskCommand)
        key(Key.rightArrow, down: false, flags: .maskCommand)
        await wait(80)
    }

    private func editableField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled, field.placeholderString != "Search settings" {
            return field
        }
        for subview in view.subviews {
            if let found = editableField(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Synthetic input

    private func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func move(to point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func key(_ code: UInt16, down: Bool, flags: CGEventFlags = [], text: String? = nil) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        if let text {
            var units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        event.post(tap: .cghidEventTap)
    }

    private func tapKey(_ code: UInt16, text: String? = nil) {
        key(code, down: true, text: text)
        key(code, down: false, text: text)
    }

    private func type(_ text: String) {
        for character in text {
            let lower = String(character).lowercased()
            guard let code = Key.printableCodes.first(where: { $0.value.count == 1 && $0.value.lowercased() == lower })?.key else { continue }
            tapKey(code, text: String(character))
        }
    }

    /// Posts the configured Click start shortcut.
    private func clickEntryChord(extra: CGEventFlags = []) {
        guard case let .key(code, modifiers) = navigation.config.clickEntry.gesture else { return }
        var mask: CGEventFlags = []
        if modifiers.contains(.command) { mask.insert(.maskCommand) }
        if modifiers.contains(.shift) { mask.insert(.maskShift) }
        if modifiers.contains(.control) { mask.insert(.maskControl) }
        if modifiers.contains(.option) { mask.insert(.maskAlternate) }
        chord(code, mask, extra: extra)
    }

    private func chord(_ code: UInt16, _ modifiers: CGEventFlags, extra: CGEventFlags = []) {
        key(code, down: true, flags: modifiers.union(extra))
        key(code, down: false, flags: modifiers.union(extra))
    }

    private static let deviceBits: [UInt16: UInt64] = [
        Key.leftControl: 0x1, Key.leftShift: 0x2, Key.rightShift: 0x4, Key.leftCommand: 0x8,
        Key.rightCommand: 0x10, Key.leftOption: 0x20, Key.rightOption: 0x40, Key.rightControl: 0x2000
    ]

    private func flags(_ code: UInt16) -> CGEventFlags {
        var flags: CGEventFlags = []
        switch Key.modifierFlag(for: code) {
        case .command: flags.insert(.maskCommand)
        case .option: flags.insert(.maskAlternate)
        case .shift: flags.insert(.maskShift)
        case .control: flags.insert(.maskControl)
        default: break
        }
        return CGEventFlags(rawValue: flags.rawValue | (Self.deviceBits[code] ?? 0))
    }

    private func modifier(_ code: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? flags(code) : []
        event.post(tap: .cghidEventTap)
    }

    private func tapModifier(_ code: UInt16, until condition: @escaping @MainActor () -> Bool, timeout: Double = 1) async -> Bool {
        modifier(code, down: true)
        await wait(50)
        modifier(code, down: false)
        return await waitFor(timeout, condition)
    }

    private func releaseAllModifiers() {
        for code in [Key.leftCommand, Key.rightCommand, Key.leftOption, Key.rightOption, Key.leftShift, Key.leftControl] {
            modifier(code, down: false)
        }
        if leftButtonDown() {
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: pointer(), mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    private func leftButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    private func visibleOverlayCount() -> Int {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) }.count
    }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func waitFor(_ seconds: Double, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await wait(10)
        }
        return condition()
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    // MARK: - Report

    private func record(_ id: String, _ acceptance: [String], _ title: String, _ passed: Bool, _ detail: String, _ metrics: [String: Double] = [:]) {
        checks.append(Check(id: id, acceptance: acceptance, title: title, passed: passed, detail: detail, metrics: metrics))
        print("\(passed ? "PASS" : "FAIL") \(id) \(title) — \(detail)")
    }

    private func writeReport(started: Date) {
        let report = navigation.readiness
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(checks) {
            try? data.write(to: outputDirectory.appendingPathComponent("selftest.json"))
        }
        var lines = [
            "# KeyNav live self-test",
            "",
            "- Date: \(started.formatted(.iso8601))",
            "- macOS: \(report.osVersion)",
            "- App: \(Bundle.main.bundlePath) (\(report.bundleIdentifier), \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
            "- Input: synthetic CGEvents posted at the HID event tap, routed through KeyNav’s real tap. Not a hardware test.",
            "- Result: \(checks.filter(\.passed).count) of \(checks.count) passed",
            "",
            "| ID | Acceptance | Check | Result | Evidence |",
            "|---|---|---|---|---|"
        ]
        for check in checks {
            lines.append("| \(check.id) | \(check.acceptance.joined(separator: ", ")) | \(check.title) | \(check.passed ? "PASS" : "FAIL") | \(check.detail.replacingOccurrences(of: "|", with: "/")) |")
        }
        try? lines.joined(separator: "\n").appending("\n").write(to: outputDirectory.appendingPathComponent("selftest.md"), atomically: true, encoding: .utf8)
    }
}
