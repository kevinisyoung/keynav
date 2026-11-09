import XCTest
@testable import KeyNavCore

private func press(_ code: UInt16, _ modifiers: Modifiers = [], _ character: String? = nil) -> KeyEvent {
    KeyEvent(kind: .down, code: code, modifiers: modifiers,
             typesCharacter: character != nil && modifiers.isDisjoint(with: [.command, .control, .option]),
             character: character)
}

private func keyUp(_ code: UInt16, _ modifiers: Modifiers = []) -> KeyEvent {
    KeyEvent(kind: .up, code: code, modifiers: modifiers)
}

private let origin = (x: 0.0, y: 0.0)

private func enterCursor(_ r: inout NavigationRouter) {
    _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
    _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
}

final class MigrationTests: XCTestCase {
    /// A schema-1 file written by the first build: no new keys, controls stored as an array.
    func testVersion1FileKeepsCustomValuesAndGainsDefaults() throws {
        let v1 = """
        {"schemaVersion":1,"cursorEntry":{"gesture":{"modifierTap":{"code":61}},"separateExit":true,
         "exit":{"key":{"code":53,"modifiers":0}}},
         "clickEntry":{"gesture":{"key":{"code":49,"modifiers":3}},"separateExit":false,
         "exit":{"key":{"code":53,"modifiers":0}}},
         "cursorBindings":[{"action":"moveUp","gesture":{"key":{"code":34,"modifiers":0}}}],
         "clickControls":["startSearch",{"key":{"code":44,"modifiers":0}}],
         "motion":{"initialSpeed":95,"maximumSpeed":1000,"rampSeconds":1,"precisionMultiplier":0.2,"boostMultiplier":2},
         "scrolling":{"maximumSpeed":900,"rampSeconds":0.6,"reverse":true},
         "confineToCurrentDisplay":false,"clickSearchFirst":true,"clickRequireReturn":false,
         "clickStaysActive":false,"clickAlphabet":"asdf","modifierTapMaxMilliseconds":250}
        """
        let store = ConfigStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        let config = try store.decode(Data(v1.utf8))
        XCTAssertEqual(config.schemaVersion, 2)
        XCTAssertEqual(config.motion.initialSpeed, 95)
        XCTAssertTrue(config.scrolling.reverse)
        XCTAssertTrue(config.clickSearchFirst)
        XCTAssertFalse(config.clickEntry.separateExit)
        XCTAssertEqual(config.clickAlphabet, "asdf")
        XCTAssertEqual(config.dragStyle, .hold, "new settings take defaults")
        XCTAssertTrue(config.cursorBindings.contains { $0.action == .help }, "help is added when its key is free")
        XCTAssertEqual(config.clickControls[.startSearch], .key(code: Key.slash, modifiers: []))
    }

    func testUnknownFutureSchemaIsRefused() throws {
        var config = KeyNavConfig()
        config.schemaVersion = 7
        let data = try JSONEncoder().encode(config)
        XCTAssertThrowsError(try ConfigStore(fileURL: URL(fileURLWithPath: "/dev/null")).decode(data))
    }

    func testEncodingIsHumanReadable() throws {
        let data = try ConfigStore(fileURL: URL(fileURLWithPath: "/dev/null")).encode(.default)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"startSearch\""))
        XCTAssertTrue(text.contains("\"schemaVersion\" : 2"))
    }

    func testBackupIsKeptOnSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))
        try store.save(.default)
        var changed = KeyNavConfig.default
        changed.motion = .fast
        try store.save(changed)
        let backup = try store.decode(Data(contentsOf: store.backupURL))
        XCTAssertEqual(backup.motion, .gentle)
        XCTAssertEqual(try store.load().motion, .fast)
    }
}

final class ValidationTests: XCTestCase {
    func testExitCannotAlsoBeACursorAction() {
        var config = KeyNavConfig.default
        config.cursorEntry.exit = .key(code: Key.e, modifiers: [])
        XCTAssertTrue(ConfigValidator.problems(in: config).contains { $0.contains("stops Moving") })
    }

    func testEntryCannotShadowAModeBinding() {
        var config = KeyNavConfig.default
        config.clickEntry.gesture = .key(code: Key.i, modifiers: [])
        XCTAssertFalse(ConfigValidator.problems(in: config).isEmpty)
    }

    /// A18: the same character in different, non-overlapping contexts is allowed.
    func testSameKeyInDifferentModesIsAllowed() {
        var config = KeyNavConfig.default
        config.clickControls[.refresh] = .key(code: Key.i, modifiers: [.command])
        config.cursorBindings.append(CursorBinding(action: .rightClick, gesture: .key(code: Key.i, modifiers: [.command])))
        XCTAssertTrue(ConfigValidator.problems(in: config).isEmpty)
    }

    func testPrintableExitAndSystemShortcutsAreWarnings() {
        var config = KeyNavConfig.default
        config.clickEntry.exit = .key(code: Key.q, modifiers: [])
        config.cursorEntry.gesture = .key(code: Key.space, modifiers: [.command])
        let warnings = ConfigValidator.warnings(in: config)
        XCTAssertTrue(warnings.contains { $0.contains("Spotlight") })
        XCTAssertTrue(warnings.contains { $0.contains("“Q”") })
        XCTAssertTrue(ConfigValidator.problems(in: config).isEmpty)
    }

    func testPrintableExitIsRemovedFromLabels() {
        var config = KeyNavConfig.default
        config.clickEntry.exit = .key(code: Key.q, modifiers: [])
        var r = NavigationRouter(config: config)
        _ = r.handle(.key(press(Key.space, [.command, .shift])), at: 0, pointer: origin)
        XCTAssertFalse(r.click!.alphabet.contains("q"))
    }

    func testPresetsAreConflictFree() {
        for preset in Presets.all {
            var config = KeyNavConfig.default
            config.cursorBindings = preset.cursorBindings
            XCTAssertEqual(ConfigValidator.problems(in: config), [], preset.name)
        }
    }

    func testPresetDiffListsOnlyChangedActions() {
        let changes = BindingChange.diff(from: Presets.standard.cursorBindings, to: Presets.vim.cursorBindings)
        XCTAssertEqual(Set(changes.map(\.action)), [.moveUp, .moveDown, .moveLeft], "L moves right in both presets")
    }
}

/// The defaults with drag bound to Left Command, as someone might set it.
private var commandDragConfig: KeyNavConfig {
    var config = KeyNavConfig.default
    config.cursorBindings.append(CursorBinding(action: .dragHold, gesture: .key(code: Key.leftCommand, modifiers: [])))
    return config
}

final class CursorFeatureTests: XCTestCase {
    func testStandardHasNoModifierDrag() {
        XCTAssertFalse(Presets.standard.cursorBindings.contains { $0.action == .dragHold })
    }

    func testToggleDragPicksUpAndDrops() {
        var e = CursorEngine(bindings: commandDragConfig.cursorBindings, dragStyle: .toggle)
        XCTAssertEqual(e.keyDown(press(Key.leftCommand), at: 0, pointer: origin).commands, [.press(.left)])
        XCTAssertEqual(e.keyUp(keyUp(Key.leftCommand)).commands, [])
        XCTAssertEqual(e.keyDown(press(Key.leftCommand), at: 1, pointer: origin).commands, [.release(.left)])
    }

    func testHelpTogglesAndHidesOnExit() {
        var r = NavigationRouter(config: .default)
        enterCursor(&r)
        _ = r.handle(.key(press(Key.slash, [.shift], "?")), at: 0.2, pointer: origin)
        XCTAssertTrue(r.helpVisible)
        _ = r.handle(.key(press(Key.escape)), at: 0.3, pointer: origin)
        XCTAssertFalse(r.helpVisible)
    }

    func testExitOnMouseOption() {
        var config = KeyNavConfig.default
        config.exitCursorOnMouse = true
        var r = NavigationRouter(config: config)
        enterCursor(&r)
        _ = r.handle(.pointerButton, at: 0.5, pointer: origin)
        XCTAssertEqual(r.mode, .off)
    }

    func testPhysicalMouseKeepsModeByDefault() {
        var r = NavigationRouter(config: .default)
        enterCursor(&r)
        _ = r.handle(.pointerButton, at: 0.5, pointer: origin)
        XCTAssertEqual(r.mode, .cursor)
    }

    func testMotionStopsWhileSuspended() {
        var r = NavigationRouter(config: .default)
        enterCursor(&r)
        _ = r.handle(.key(press(Key.l, [], "l")), at: 0.2, pointer: origin)
        XCTAssertTrue(r.cursorNeedsTicks)
        _ = r.handle(.suspendRouting(true), at: 0.3, pointer: origin)
        XCTAssertFalse(r.cursorNeedsTicks)
        XCTAssertTrue(r.tickCursor(dt: 0.1).isEmpty)
    }

    /// A03 (synthetic): typing the action letters while Off produces no effects at all.
    func testOffLettersProduceNoEffects() {
        var r = NavigationRouter(config: .default)
        for code in [Key.i, Key.j, Key.k, Key.l, Key.r, Key.e, Key.q, Key.w, Key.upArrow, Key.downArrow, Key.returnKey] {
            let d = r.handle(.key(press(code, [], "x")), at: 0, pointer: origin)
            let u = r.handle(.key(keyUp(code)), at: 0.01, pointer: origin)
            XCTAssertEqual(d, .passThrough)
            XCTAssertEqual(u, .passThrough)
        }
    }

    /// A05 (synthetic): Option held across another key, or held long, never enters.
    func testLongOptionHoldDoesNotEnter() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.6, pointer: origin)
        XCTAssertEqual(r.mode, .off)
    }

    func testMouseButtonDuringOptionCancelsTap() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.pointerButton, at: 0.05, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        XCTAssertEqual(r.mode, .off)
    }

    /// A25/A26 (synthetic): the other mode's entry switches regardless of the separate-exit setting.
    func testOtherEntrySwitchesWhenSeparateExitIsOff() {
        var config = KeyNavConfig.default
        config.cursorEntry.separateExit = false
        var r = NavigationRouter(config: config)
        enterCursor(&r)
        _ = r.handle(.key(press(Key.space, [.command, .shift])), at: 1, pointer: origin)
        XCTAssertEqual(r.mode, .click)
        // With separate exit off for Cursor, Escape is an ordinary key in Cursor mode.
        enterCursor(&r)
        XCTAssertFalse(r.handle(.key(press(Key.escape)), at: 3, pointer: origin).consumed)
        XCTAssertEqual(r.mode, .cursor)
    }

    func testManualToggleCanAlwaysTurnModeOff() {
        var r = NavigationRouter(config: .default)
        _ = r.requestMode(.cursor)
        _ = r.requestMode(.cursor)
        XCTAssertEqual(r.mode, .off)
    }
}

final class ClickFeatureTests: XCTestCase {
    private func targets(_ n: Int) -> [HintTarget] {
        (0..<n).map { HintTarget(name: "Item \($0)", role: "AXButton", frame: .init(x: 0, y: Double($0) * 20, width: 50, height: 16)) }
    }

    private func clickRouter(_ config: KeyNavConfig = .default) -> NavigationRouter {
        var r = NavigationRouter(config: config)
        _ = r.handle(.key(press(Key.space, [.command, .shift])), at: 0, pointer: origin)
        _ = r.handle(.targetsDiscovered(generation: r.generation, snapshot: 1, targets: targets(40)), at: 0.1, pointer: origin)
        return r
    }

    func testCycleActionChangesPendingActionWithoutTouchingLabels() {
        var r = clickRouter()
        _ = r.handle(.key(press(Key.period, [], ".")), at: 0.2, pointer: origin)
        XCTAssertEqual(r.click?.pendingAction, .rightClick)
        let label = r.click!.labels[3]
        var effects: [NavigationEffect] = []
        for c in label { effects += r.handle(.key(press(0, [], String(c))), at: 0.3, pointer: origin).effects }
        XCTAssertEqual(effects.last, .activate(index: 3, snapshot: 1, generation: r.generation, action: .rightClick))
    }

    func testRefreshDuringHalfTypedLabelKeepsCodes() {
        var r = clickRouter()
        let before = r.click!.labels
        _ = r.handle(.key(press(0, [], String(before[5].first!))), at: 0.2, pointer: origin)
        _ = r.handle(.targetsDiscovered(generation: r.generation, snapshot: 2, targets: targets(3)), at: 0.3, pointer: origin)
        XCTAssertEqual(r.click?.labels, before)
        XCTAssertEqual(r.click?.snapshot, 1)
    }

    func testArrowsInLabelsScrollAndRefresh() {
        var r = clickRouter()
        let d = r.handle(.key(press(Key.downArrow)), at: 0.2, pointer: origin)
        XCTAssertTrue(d.consumed)
        XCTAssertEqual(d.effects.first, .cursor(.scroll(dx: 0, dy: -120)))
        XCTAssertTrue(d.effects.contains(.discoverTargets(generation: r.generation)))
    }

    func testFailedActivationRequestsRefreshNotClick() {
        var r = clickRouter()
        let d = r.handle(.activationFinished(generation: r.generation, succeeded: false), at: 0.5, pointer: origin)
        XCTAssertEqual(d.effects, [.discoverTargets(generation: r.generation), .refreshOverlay])
        XCTAssertEqual(r.mode, .click)
    }

    func testSuccessfulActivationExitsByDefault() {
        var r = clickRouter()
        _ = r.handle(.activationFinished(generation: r.generation, succeeded: true), at: 0.5, pointer: origin)
        XCTAssertEqual(r.mode, .off)
    }

    func testStayActivePreference() {
        var config = KeyNavConfig.default
        config.clickStaysActive = true
        var r = clickRouter(config)
        _ = r.handle(.activationFinished(generation: r.generation, succeeded: true), at: 0.5, pointer: origin)
        XCTAssertEqual(r.mode, .click)
    }

    /// A19 (synthetic): an app switch during discovery stops Click; the late result is discarded.
    func testFocusChangeDiscardsLateDiscovery() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.space, [.command, .shift])), at: 0, pointer: origin)
        let generation = r.generation
        _ = r.handle(.focusChanged, at: 0.05, pointer: origin)
        XCTAssertEqual(r.mode, .off)
        XCTAssertEqual(r.handle(.targetsDiscovered(generation: generation, snapshot: 1, targets: targets(2)), at: 0.1, pointer: origin), .passThrough)
        XCTAssertNil(r.click)
    }

    /// A23 (synthetic): labels follow the produced character, so a non-US layout that types "a" on another key works.
    func testLabelsUseProducedCharacterNotKeyPosition() {
        var r = clickRouter()
        let label = r.click!.labels[0]
        var effects: [NavigationEffect] = []
        for c in label { effects += r.handle(.key(press(Key.q, [], String(c))), at: 0.3, pointer: origin).effects }
        XCTAssertEqual(effects.last, .activate(index: 0, snapshot: 1, generation: r.generation, action: .press))
    }

    func testSearchIsUnicodeAware() {
        XCTAssertEqual(TargetSearch.rank(query: "ÉCRAN", names: ["Écran partagé", "Other"]), [0])
    }

    func testSearchPerformanceFor1000Targets() {
        let names = (0..<1000).map { "Target number \($0) button" }
        let start = Date()
        for query in ["t", "ta", "tar", "targ", "target 9", "button 99"] {
            _ = TargetSearch.rank(query: query, names: names)
        }
        let perQueryMs = Date().timeIntervalSince(start) / 6 * 1000
        print("search-perf: \(String(format: "%.2f", perQueryMs)) ms per query over 1000 targets")
        XCTAssertLessThan(perQueryMs, 50)
    }
}

final class MouselessImportTests: XCTestCase {
    /// A small synthetic file in the Mouseless shape; it is not anyone's personal configuration.
    let sample = """
    behavior_configs:
    - base_move_speed: 5.0
      tap_threshold_ms: 250
    keymaps:
    - entries:
        exit free mode: Escape
        hold for drag: CommandLeft
        hold for speed decrease: A
        hold for speed increase:
        - S
        - D
        left mouse button: Enter
        execute mouse action: Space
        move up: I
        move left: J
        move down: K
        move right: L
        wheel right: /
        wheel up: ArrowUp
        cycle font: '3'
        show overlay: CommandLeft tap
        right click: null
      name: mac
    log_level: info
    """

    func testTranslatesByMeaningAndListsUnsupported() {
        let result = MouselessImport.translate(yaml: sample, base: .default)
        let table = BindingTable(result.proposed.cursorBindings.map { ($0.gesture, $0.action) })
        XCTAssertEqual(table.action(forKey: Key.slash, modifiers: []), .scrollRight)
        XCTAssertEqual(table.action(forKey: Key.space, modifiers: []), .leftClick)
        XCTAssertEqual(table.action(forKey: Key.d, modifiers: []), .boost)
        XCTAssertEqual(table.action(forKey: Key.leftCommand, modifiers: []), .dragHold)
        XCTAssertNil(table.action(forKey: Key.rightArrow, modifiers: []), "the file rebinds scroll right")
        XCTAssertTrue(result.rows.contains { $0.source == "cycle font" && $0.issue != nil })
        XCTAssertTrue(result.rows.contains { $0.source == "show overlay" && $0.issue != nil })
        XCTAssertTrue(result.rows.contains { $0.issue?.contains("frame") == true })
        XCTAssertEqual(result.problems, [])
    }

    func testKeyStrings() {
        XCTAssertEqual(MouselessImport.gesture(from: "OptionRight tap"), .modifierTap(code: Key.rightOption))
        XCTAssertEqual(MouselessImport.gesture(from: "shift+3"), .key(code: 20, modifiers: [.shift]))
        XCTAssertEqual(MouselessImport.gesture(from: "'3'"), .key(code: 20, modifiers: []))
        XCTAssertNil(MouselessImport.gesture(from: "Hyper"))
    }

    func testInvalidImportReportsProblemsWithoutApplying() {
        let conflicting = sample.replacingOccurrences(of: "move up: I", with: "move up: L")
        let result = MouselessImport.translate(yaml: conflicting, base: .default)
        XCTAssertFalse(result.problems.isEmpty)
    }
}

final class ExitWhileHoldingTests: XCTestCase {
    /// A08 (synthetic): Escape exits while Left Command is held for a drag, and the button is released first.
    func testEscapeExitsWhileDragModifierIsHeld() {
        var r = NavigationRouter(config: commandDragConfig)
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.leftCommand)), at: 0.2, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.l, modifiers: [.command], typesCharacter: false, character: "l")), at: 0.25, pointer: (0, 0))
        let exit = r.handle(.key(KeyEvent(kind: .down, code: Key.escape, modifiers: [.command])), at: 0.3, pointer: (0, 0))
        XCTAssertEqual(r.mode, .off)
        XCTAssertEqual(exit.effects.first, .cursor(.release(.left)))
        // The held keys' releases stay consumed, so nothing leaks into the app.
        XCTAssertTrue(r.handle(.key(KeyEvent(kind: .up, code: Key.l)), at: 0.4, pointer: (0, 0)).consumed)
        XCTAssertTrue(r.handle(.key(KeyEvent(kind: .up, code: Key.leftCommand)), at: 0.5, pointer: (0, 0)).consumed)
    }
}

final class LiveFindingsTests: XCTestCase {
    /// Found by the live self-test: releasing a consumed Left Command must not leave the tap recognizer stuck.
    func testRightOptionTapWorksAfterDragModifierRelease() {
        var r = NavigationRouter(config: commandDragConfig)
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.leftCommand)), at: 0.2, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.space, modifiers: [.command, .shift])), at: 0.3, pointer: (0, 0))
        XCTAssertEqual(r.mode, .click)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.leftCommand)), at: 0.4, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 1, pointer: (0, 0))
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 1.1, pointer: (0, 0))
        XCTAssertEqual(r.mode, .cursor)
    }

    /// Found by the live self-test: a failed activation must let the refreshed snapshot replace the labels.
    func testFailedActivationAllowsRefresh() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.space, modifiers: [.command, .shift])), at: 0, pointer: (0, 0))
        let targets = (0..<3).map { HintTarget(name: "B\($0)", role: "AXButton", frame: .init(x: 0, y: Double($0) * 30, width: 40, height: 20)) }
        _ = r.handle(.targetsDiscovered(generation: r.generation, snapshot: 1, targets: targets), at: 0.1, pointer: (0, 0))
        for c in r.click!.labels[1] {
            _ = r.handle(.key(KeyEvent(kind: .down, code: 0, typesCharacter: true, character: String(c))), at: 0.2, pointer: (0, 0))
        }
        _ = r.handle(.activationFinished(generation: r.generation, succeeded: false), at: 0.3, pointer: (0, 0))
        _ = r.handle(.targetsDiscovered(generation: r.generation, snapshot: 2, targets: Array(targets.prefix(2))), at: 0.5, pointer: (0, 0))
        XCTAssertEqual(r.click?.snapshot, 2)
        XCTAssertEqual(r.click?.targets.count, 2)
    }
}

final class MouselessPresetTests: XCTestCase {
    /// A preset may carry a Clicking start; Mouseless's does not.
    func testPresetClickEntryIsAppliedOnlyWhenPresent() {
        XCTAssertNil(Presets.mouseless.clickEntry)
        var config = KeyNavConfig.default
        config.clickEntry.gesture = .key(code: Key.returnKey, modifiers: [.control, .command])
        XCTAssertEqual(config.clickEntry.gesture.displayName, "Control Command Return")
        XCTAssertEqual(ConfigValidator.problems(in: config), [])
    }
}

/// Requests from side-by-side use with Homerow.
final class SpaceHoldAndLabelTimeoutTests: XCTestCase {
    private func targets(_ n: Int) -> [HintTarget] {
        (0..<n).map { HintTarget(name: "Item \($0)", role: "AXButton", frame: .init(x: 0, y: Double($0) * 20, width: 50, height: 16)) }
    }

    func testHoldingSpaceKeepsTheButtonDownUntilRelease() {
        var r = NavigationRouter(config: .default)
        enterCursor(&r)
        let down = r.handle(.key(press(Key.space, [], " ")), at: 1, pointer: origin)
        XCTAssertEqual(down.effects.first, .cursor(.buttonDown(.left, clickCount: 1)))
        // Moving while Space is held does not release it.
        _ = r.handle(.key(press(Key.l, [], "l")), at: 1.1, pointer: origin)
        let moved = r.tickCursor(dt: 0.05)
        XCTAssertFalse(moved.isEmpty)
        XCTAssertTrue(r.handle(.key(KeyEvent(kind: .down, code: Key.space, isRepeat: true)), at: 1.2, pointer: origin).consumed)
        _ = r.handle(.key(keyUp(Key.l)), at: 1.3, pointer: origin)
        let up = r.handle(.key(keyUp(Key.space)), at: 1.4, pointer: origin)
        XCTAssertEqual(up.effects.first, .cursor(.buttonUp(.left, clickCount: 1)))
    }

    func testSpaceReleasedWithAModifierStillReleasesTheButton() {
        var e = CursorEngine(bindings: Presets.standard.cursorBindings)
        _ = e.keyDown(press(Key.space, [], " "), at: 0, pointer: origin)
        XCTAssertEqual(e.keyUp(keyUp(Key.space, [.shift])).commands, [.buttonUp(.left, clickCount: 1)])
    }

    func testExitingWhileSpaceIsHeldReleasesTheButton() {
        var r = NavigationRouter(config: .default)
        enterCursor(&r)
        _ = r.handle(.key(press(Key.space, [], " ")), at: 1, pointer: origin)
        let exit = r.handle(.forceOff, at: 1.5, pointer: origin)
        XCTAssertEqual(exit.effects.first, .cursor(.buttonUp(.left, clickCount: 1)))
    }

    private func clickRouter() -> NavigationRouter {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.space, [.command, .shift])), at: 0, pointer: origin)
        _ = r.handle(.targetsDiscovered(generation: r.generation, snapshot: 1, targets: targets(40)), at: 0.1, pointer: origin)
        return r
    }

    func testHalfTypedLabelResetsAfterThreeSeconds() {
        var r = clickRouter()
        let first = String(r.click!.labels[5].first!)
        _ = r.handle(.key(press(0, [], first)), at: 1, pointer: origin)
        XCTAssertEqual(r.typedLabelDeadline, 1 + NavigationRouter.typedLabelTimeout)
        // Too early: nothing happens.
        XCTAssertEqual(r.handle(.typedLabelTimeout, at: 2, pointer: origin), .passThrough)
        XCTAssertEqual(r.click?.typedPrefix, first)
        let d = r.handle(.typedLabelTimeout, at: 4.01, pointer: origin)
        XCTAssertEqual(d.effects, [.refreshOverlay])
        XCTAssertEqual(r.click?.typedPrefix, "")
        XCTAssertNil(r.typedLabelDeadline)
        XCTAssertEqual(r.mode, .click)
    }

    func testLetterAfterTheDeadlineStartsAFreshLabel() {
        var r = clickRouter()
        let label = r.click!.labels[7]
        _ = r.handle(.key(press(0, [], String(label.first!))), at: 1, pointer: origin)
        // The timer has not fired yet, but the next letter arrives late: it starts over instead of finishing a code.
        let late = r.handle(.key(press(0, [], String(label.last!))), at: 5, pointer: origin)
        XCTAssertFalse(late.effects.contains { if case .activate = $0 { return true } else { return false } })
        // With 40 targets no label starts with that second letter, so it is ignored and nothing stays typed.
        XCTAssertEqual(r.click?.typedPrefix, "")
    }

    func testEachLetterExtendsTheDeadline() {
        var r = clickRouter()
        let first = String(r.click!.labels[0].first!)
        _ = r.handle(.key(press(0, [], first)), at: 1, pointer: origin)
        _ = r.handle(.key(press(Key.delete)), at: 2, pointer: origin)
        XCTAssertNil(r.typedLabelDeadline)
        _ = r.handle(.key(press(0, [], first)), at: 2.5, pointer: origin)
        XCTAssertEqual(r.typedLabelDeadline, 5.5)
    }

    func testMenuBarAndDockSettingsDefaultOnAndRoundTrip() throws {
        XCTAssertTrue(KeyNavConfig.default.clickLabelsMenuBar)
        XCTAssertTrue(KeyNavConfig.default.clickLabelsDock)
        var config = KeyNavConfig.default
        config.clickLabelsDock = false
        let decoded = try JSONDecoder().decode(KeyNavConfig.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(decoded.clickLabelsDock)
        XCTAssertTrue(decoded.clickLabelsMenuBar)
    }
}

/// Live finding: the tick timer stops on release, so the ramp must restart without a further tick.
final class RampResetTests: XCTestCase {
    func testReleaseRestartsTheRampWithoutAnotherTick() {
        var e = CursorEngine(bindings: Presets.standard.cursorBindings)
        _ = e.keyDown(press(Key.l, [], "l"), at: 0, pointer: origin)
        for _ in 0..<60 { _ = e.tick(dt: 1.0 / 60) }
        XCTAssertGreaterThan(e.currentMoveSpeed(), 1000)
        _ = e.keyUp(keyUp(Key.l))
        // No tick here: the service stops ticking when nothing is held.
        _ = e.keyDown(press(Key.j, [], "j"), at: 2, pointer: origin)
        XCTAssertEqual(e.currentMoveSpeed(), MotionProfile.gentle.initialSpeed, accuracy: 0.001)
    }

    func testChangingDirectionWhileHeldKeepsSpeed() {
        var e = CursorEngine(bindings: Presets.standard.cursorBindings)
        _ = e.keyDown(press(Key.l, [], "l"), at: 0, pointer: origin)
        for _ in 0..<60 { _ = e.tick(dt: 1.0 / 60) }
        _ = e.keyDown(press(Key.k, [], "k"), at: 1, pointer: origin)
        _ = e.keyUp(keyUp(Key.l))
        XCTAssertGreaterThan(e.currentMoveSpeed(), 1000)
    }
}

/// Live finding: with a Settings text field focused, the start shortcut did nothing.
final class EntriesWhileEditingTests: XCTestCase {
    func testStartShortcutWorksInATextFieldButLettersStayThere() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.suspendRouting(true), at: 0, pointer: origin)
        _ = r.handle(.allowEntriesWhileSuspended(true), at: 0, pointer: origin)
        enterCursor(&r)
        XCTAssertEqual(r.mode, .cursor)
        XCTAssertFalse(r.handle(.key(press(Key.i, [], "i")), at: 1, pointer: origin).consumed)
        XCTAssertTrue(r.handle(.key(press(Key.escape)), at: 1.1, pointer: origin).consumed)
        XCTAssertEqual(r.mode, .off)
    }

    func testRecorderStillGetsEveryKey() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.suspendRouting(true), at: 0, pointer: origin)
        enterCursor(&r)
        XCTAssertEqual(r.mode, .off)
    }
}

/// Scroll mode, after Homerow's keys: Control Command J, H J K L, Shift to jump. It scrolls what is under the pointer.
final class ScrollModeTests: XCTestCase {
    private let window = HintTarget.Frame(x: 300, y: 100, width: 800, height: 600)

    private func scrollRouter(pointer: (x: Double, y: Double) = (500, 300)) -> NavigationRouter {
        var r = NavigationRouter(config: .default)
        let start = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: pointer)
        XCTAssertTrue(start.effects.contains(.findScrollWindow(generation: r.generation)))
        _ = r.handle(.scrollWindowFound(generation: r.generation, frame: window), at: 0.1, pointer: pointer)
        return r
    }

    func testPointerOverTheWindowStillMovesToTheMiddle() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (500, 300))
        let found = r.handle(.scrollWindowFound(generation: r.generation, frame: window), at: 0.1, pointer: (500, 300))
        XCTAssertEqual(found.effects, [.parkPointer(x: 700, y: 400)])
    }

    func testPointerElsewhereMovesToTheMiddleOfTheWindow() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (50, 900))
        let found = r.handle(.scrollWindowFound(generation: r.generation, frame: window), at: 0.1, pointer: (50, 900))
        XCTAssertEqual(found.effects, [.parkPointer(x: 700, y: 400)])
    }

    private func node(_ role: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScrollNode {
        ScrollNode(role: role, frame: HintTarget.Frame(x: x, y: y, width: width, height: height))
    }

    private func park(click: [ScrollNode] = [], focus: [ScrollNode] = [], areas: [HintTarget.Frame] = []) -> [NavigationEffect] {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (500, 300))
        return r.handle(.scrollWindowFound(generation: r.generation, frame: window, clickChain: click, focusChain: focus,
                                           areas: areas), at: 0.1, pointer: (500, 300)).effects
    }

    func testANativeClickGoesToItsScrollArea() {
        let click = [node("AXRow", 300, 300, 200, 20), node("AXOutline", 300, 100, 200, 900), node("AXScrollArea", 300, 100, 200, 600)]
        XCTAssertEqual(park(click: click), [.parkPointer(x: 400, y: 400)])
    }

    func testAToolbarClickInAWebAppIsNoPane() {
        // Claude's View options: the button's row is short and everything above it is the whole window.
        let click = [node("AXButton", 1050, 110, 30, 30), node("AXGroup", 300, 100, 800, 50),
                     node("AXGroup", 300, 100, 800, 600), node("AXWebArea", 300, 130, 800, 570), node("AXScrollArea", 300, 130, 800, 570)]
        XCTAssertEqual(park(click: click), [.parkPointer(x: 700, y: 400)])
    }

    func testAToolbarClickGoesToTheColumnItHeads() {
        // Notion's peek: the button's header sits on top of the peek's column.
        let click = [node("AXButton", 1050, 110, 30, 30), node("AXGroup", 700, 100, 400, 50), node("AXGroup", 700, 100, 400, 600),
                     node("AXGroup", 300, 100, 800, 600), node("AXWebArea", 300, 100, 800, 600)]
        XCTAssertEqual(park(click: click, areas: [HintTarget.Frame(x: 700, y: 100, width: 400, height: 600)]),
                       [.parkPointer(x: 900, y: 400)])
    }

    func testAWebClickGoesToTheOutermostPane() {
        // A web sidebar: the list inside it is tall too, but the whole sidebar is the pane.
        let click = [node("AXLink", 300, 300, 200, 30), node("AXGroup", 300, 250, 200, 300), node("AXGroup", 300, 100, 200, 600),
                     node("AXGroup", 300, 100, 800, 600), node("AXWebArea", 300, 100, 800, 600)]
        XCTAssertEqual(park(click: click, areas: [HintTarget.Frame(x: 300, y: 100, width: 200, height: 600)]),
                       [.parkPointer(x: 400, y: 400)])
    }

    func testABlockThatDoesNotScrollOnItsOwnIsNoPane() {
        // Google's AI Overview: tall and wide, but part of the page, which scrolls as a whole.
        let click = [node("AXStaticText", 400, 500, 300, 20), node("AXGroup", 350, 400, 600, 300),
                     node("AXGroup", 300, 100, 800, 600), node("AXWebArea", 300, 100, 800, 600)]
        XCTAssertEqual(park(click: click), [.parkPointer(x: 700, y: 400)])
    }

    func testAPageInsideANativePaneUsesThePane() {
        // Mail: the message is a web page inside the message pane's scroll area.
        let click = [node("AXLink", 800, 300, 80, 20), node("AXWebArea", 700, 100, 400, 600), node("AXScrollArea", 700, 100, 400, 600)]
        XCTAssertEqual(park(click: click), [.parkPointer(x: 900, y: 400)])
    }

    func testFocusDecidesWhenTheClickWasNotInAPane() {
        let click = [node("AXButton", 1050, 110, 30, 30), node("AXToolbar", 300, 100, 800, 50)]
        let focus = [node("AXTextArea", 500, 100, 600, 1200), node("AXScrollArea", 500, 100, 600, 600)]
        XCTAssertEqual(park(click: click, focus: focus), [.parkPointer(x: 800, y: 400)])
    }

    func testScrollingPicksUpWhereItLastScrolled() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (500, 300))
        let sidebar = [node("AXOutline", 300, 100, 200, 900), node("AXScrollArea", 300, 100, 200, 600)]
        let found = r.handle(.scrollWindowFound(generation: r.generation, frame: window, clickChain: sidebar,
                                                resume: ScrollPoint(x: 350, y: 650)), at: 0.1, pointer: (500, 300))
        XCTAssertEqual(found.effects, [.parkPointer(x: 350, y: 650)])
        XCTAssertEqual(r.scroll?.window, HintTarget.Frame(x: 300, y: 100, width: 200, height: 600), "a jump covers the sidebar")
    }

    func testNumbersJumpToScrollAreas() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (500, 300))
        let sidebar = HintTarget.Frame(x: 300, y: 100, width: 200, height: 600)
        let content = HintTarget.Frame(x: 500, y: 100, width: 600, height: 600)
        _ = r.handle(.scrollWindowFound(generation: r.generation, frame: window, areas: [content, sidebar]), at: 0.1, pointer: (500, 300))
        let second = r.handle(.key(press(Key.digits[1], [], "2")), at: 1, pointer: (500, 300))
        XCTAssertTrue(second.consumed)
        XCTAssertEqual(second.effects, [.parkPointer(x: 800, y: 400)])
        XCTAssertEqual(r.scroll?.areaIndex, 1)
        let missing = r.handle(.key(press(Key.digits[4], [], "5")), at: 2, pointer: (800, 400))
        XCTAssertTrue(missing.consumed)
        XCTAssertEqual(missing.effects, [])
    }

    func testASectionOfAColumnIsNoStopOfItsOwn() {
        // Slack: the sidebar, a list inside it, and the message list; the channel pane around the messages.
        let sidebar = HintTarget.Frame(x: 300, y: 100, width: 200, height: 600)
        let section = HintTarget.Frame(x: 300, y: 100, width: 200, height: 250)
        let channel = HintTarget.Frame(x: 500, y: 100, width: 600, height: 600)
        let messages = HintTarget.Frame(x: 500, y: 150, width: 600, height: 500)
        XCTAssertEqual(ScrollSession.tabStops([sidebar, section, channel, messages], in: window), [sidebar, messages])
    }

    func testTheMouseMovesTheCurrentArea() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (500, 300))
        let sidebar = HintTarget.Frame(x: 300, y: 100, width: 200, height: 600)
        let content = HintTarget.Frame(x: 500, y: 100, width: 600, height: 600)
        _ = r.handle(.scrollWindowFound(generation: r.generation, frame: window, areas: [content, sidebar]), at: 0.1, pointer: (500, 300))
        _ = r.handle(.externalPointerMoved, at: 1, pointer: (350, 400))
        XCTAssertEqual(r.scroll?.areaIndex, 0)
        XCTAssertEqual(r.scroll?.outlined, sidebar)
        _ = r.handle(.externalPointerMoved, at: 2, pointer: (50, 50))
        XCTAssertEqual(r.scroll?.outlined, sidebar, "outside every area, the last one stays outlined")
    }

    func testAClickOutsideEveryAreaKeepsTheWindow() {
        // Messages: the transcript fills the window, so only the conversation list is an area.
        let list = HintTarget.Frame(x: 300, y: 100, width: 300, height: 600)
        let click = [node("AXGroup", 700, 500, 300, 100), node("AXGroup", 300, 100, 800, 600)]
        XCTAssertEqual(park(click: click, areas: [list]), [.parkPointer(x: 700, y: 400)])
    }

    func testAListAtTheBottomOfItsPaneIsPartOfIt() {
        // Gmail: the list ends where the pane around it ends, under the AI Overview; the pane is what scrolls.
        let pane = HintTarget.Frame(x: 300, y: 200, width: 800, height: 500)
        let list = HintTarget.Frame(x: 300, y: 320, width: 798, height: 380)
        XCTAssertEqual(ScrollSession.tabStops([pane, list], in: window), [pane])
    }

    func testTheOutlineMovesOnlyWhenItsPaneChanges() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (500, 300))
        let list = HintTarget.Frame(x: 300, y: 300, width: 800, height: 400)
        _ = r.handle(.scrollWindowFound(generation: r.generation, frame: window, areas: [list]), at: 0.1, pointer: (700, 500))
        _ = r.handle(.externalPointerMoved, at: 1, pointer: (700, 500))
        XCTAssertEqual(r.scroll?.outlined, list)
        let pane = HintTarget.Frame(x: 300, y: 200, width: 800, height: 500)
        _ = r.handle(.scrollAreasMoved(generation: r.generation, areas: [pane, list]), at: 2, pointer: (700, 500))
        XCTAssertEqual(r.scroll?.outlined, pane, "scrolling showed the pane around the list")
        _ = r.handle(.scrollAreasMoved(generation: r.generation, areas: []), at: 3, pointer: (700, 500))
        XCTAssertNil(r.scroll?.outlined, "no stale outline once no area is there")
    }

    func testWithNoPaneTheLargestScrollAreaWins() {
        let sidebar = HintTarget.Frame(x: 300, y: 100, width: 200, height: 600)
        let content = HintTarget.Frame(x: 500, y: 100, width: 600, height: 600)
        XCTAssertEqual(park(areas: [sidebar, content]), [.parkPointer(x: 800, y: 400)])
    }

    func testAScrollAreaAsBigAsTheWindowSaysNothing() {
        // A long page: clipped to the window it is the whole window, so the middle of the window it is.
        XCTAssertEqual(park(focus: [node("AXScrollArea", 300, 100, 800, 5000)]), [.parkPointer(x: 700, y: 400)])
    }

    func testTabMovesBetweenScrollAreas() {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(press(Key.j, [.command, .shift])), at: 0, pointer: (500, 300))
        let sidebar = HintTarget.Frame(x: 300, y: 100, width: 200, height: 600)
        let content = HintTarget.Frame(x: 500, y: 100, width: 600, height: 600)
        // The page around both panes is covered by them, so it is no stop of its own.
        _ = r.handle(.scrollWindowFound(generation: r.generation, frame: window,
                                        clickChain: [node("AXScrollArea", 300, 100, 200, 600)],
                                        areas: [window, content, sidebar]), at: 0.1, pointer: (500, 300))
        let next = r.handle(.key(press(Key.tab, [])), at: 1, pointer: (400, 300))
        XCTAssertTrue(next.consumed)
        XCTAssertEqual(next.effects, [.parkPointer(x: 800, y: 400)])
        let wrapped = r.handle(.key(press(Key.tab, [])), at: 2, pointer: (800, 400))
        XCTAssertEqual(wrapped.effects, [.parkPointer(x: 400, y: 400)])
        let back = r.handle(.key(press(Key.tab, [.shift])), at: 3, pointer: (400, 400))
        XCTAssertEqual(back.effects, [.parkPointer(x: 800, y: 400)])
    }


    func testHoldingJScrollsDownUntilRelease() {
        var r = scrollRouter()
        XCTAssertTrue(r.handle(.key(press(Key.j, [], "j")), at: 1, pointer: (500, 300)).consumed)
        XCTAssertTrue(r.cursorNeedsTicks)
        guard case let .cursor(.scroll(_, dy)) = r.tickCursor(dt: 0.05).first else { return XCTFail("no scroll") }
        XCTAssertLessThan(dy, 0)
        _ = r.handle(.key(keyUp(Key.j)), at: 1.2, pointer: (500, 300))
        XCTAssertFalse(r.cursorNeedsTicks)
    }

    func testShiftKJumpsMostOfTheWindowUp() {
        var r = scrollRouter()
        _ = r.handle(.key(press(Key.k, [.shift], "K")), at: 1, pointer: (500, 300))
        var total = 0.0
        for _ in 0..<30 {
            for case let .cursor(.scroll(_, dy)) in r.tickCursor(dt: 1.0 / 60) { total += dy }
        }
        XCTAssertEqual(total, 600 * 0.8, accuracy: 1)
        XCTAssertFalse(r.cursorNeedsTicks)
    }

    func testLettersDoNotTypeAndEscapeExits() {
        var r = scrollRouter()
        XCTAssertTrue(r.handle(.key(press(Key.q, [], "q")), at: 1, pointer: (0, 0)).consumed)
        XCTAssertFalse(r.handle(.key(press(Key.c, [.command], "c")), at: 1, pointer: (0, 0)).consumed)
        _ = r.handle(.key(press(Key.escape)), at: 2, pointer: (0, 0))
        XCTAssertEqual(r.mode, .off)
        XCTAssertNil(r.scroll)
    }

    func testOtherModeShortcutsSwitchFromScroll() {
        var r = scrollRouter()
        _ = r.handle(.key(press(Key.space, [.command, .shift])), at: 1, pointer: (0, 0))
        XCTAssertEqual(r.mode, .click)
        XCTAssertNil(r.scroll)
    }

    func testThreeModesCannotShareAStartShortcut() {
        var config = KeyNavConfig.default
        config.scrollEntry.gesture = config.clickEntry.gesture
        XCTAssertTrue(ConfigValidator.problems(in: config).contains { $0.contains("Scrolling") })
    }
}
