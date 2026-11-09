import XCTest
@testable import KeyNavCore

private func down(_ code: UInt16, _ modifiers: Modifiers = [], character: String? = nil, typesCharacter: Bool? = nil, repeats: Bool = false) -> KeyEvent {
    KeyEvent(kind: .down, code: code, modifiers: modifiers, isRepeat: repeats,
             typesCharacter: typesCharacter ?? (character != nil && modifiers.isDisjoint(with: [.command, .control, .option])),
             character: character)
}

private func up(_ code: UInt16, _ modifiers: Modifiers = []) -> KeyEvent {
    KeyEvent(kind: .up, code: code, modifiers: modifiers)
}

final class ModifierTapTests: XCTestCase {
    func testMissedReleaseDoesNotBreakLaterTaps() {
        var r = ModifierTapRecognizer(maxDuration: 0.25)
        // Command went down while the tap was off and its release never arrived.
        _ = r.modifierChanged(code: Key.leftCommand, down: true, at: 0)
        _ = r.modifierChanged(code: Key.rightOption, down: true, at: 5)
        XCTAssertEqual(r.modifierChanged(code: Key.rightOption, down: false, at: 5.1), Key.rightOption)
        // Right Option's own release missed: its next press still starts a fresh tap.
        _ = r.modifierChanged(code: Key.rightOption, down: true, at: 6)
        _ = r.modifierChanged(code: Key.rightOption, down: true, at: 8)
        XCTAssertEqual(r.modifierChanged(code: Key.rightOption, down: false, at: 8.1), Key.rightOption)
    }

    func testLoneRightOptionTapIsRecognized() {
        var r = ModifierTapRecognizer(maxDuration: 0.25)
        XCTAssertNil(r.modifierChanged(code: Key.rightOption, down: true, at: 0))
        XCTAssertEqual(r.modifierChanged(code: Key.rightOption, down: false, at: 0.1), Key.rightOption)
    }

    func testLongHoldIsNotATap() {
        var r = ModifierTapRecognizer(maxDuration: 0.25)
        _ = r.modifierChanged(code: Key.rightOption, down: true, at: 0)
        XCTAssertNil(r.modifierChanged(code: Key.rightOption, down: false, at: 0.4))
    }

    func testOtherKeyCancelsTap() {
        var r = ModifierTapRecognizer(maxDuration: 0.25)
        _ = r.modifierChanged(code: Key.rightOption, down: true, at: 0)
        r.otherInput()
        XCTAssertNil(r.modifierChanged(code: Key.rightOption, down: false, at: 0.1))
    }

    func testBothSidesHeldIsNotATap() {
        var r = ModifierTapRecognizer(maxDuration: 0.25)
        _ = r.modifierChanged(code: Key.leftOption, down: true, at: 0)
        _ = r.modifierChanged(code: Key.rightOption, down: true, at: 0.05)
        XCTAssertNil(r.modifierChanged(code: Key.rightOption, down: false, at: 0.1))
        XCTAssertNil(r.modifierChanged(code: Key.leftOption, down: false, at: 0.12))
    }

    func testLeftAndRightAreDistinct() {
        var r = ModifierTapRecognizer(maxDuration: 0.25)
        _ = r.modifierChanged(code: Key.leftOption, down: true, at: 0)
        XCTAssertEqual(r.modifierChanged(code: Key.leftOption, down: false, at: 0.1), Key.leftOption)
    }

    func testHeldBeforeCandidateInvalidatesAfterReleaseOfOther() {
        var r = ModifierTapRecognizer(maxDuration: 0.25)
        _ = r.modifierChanged(code: Key.leftCommand, down: true, at: 0)
        _ = r.modifierChanged(code: Key.rightOption, down: true, others: .command, at: 0.05)     // second modifier
        XCTAssertNil(r.modifierChanged(code: Key.rightOption, down: false, others: .command, at: 0.1))
        XCTAssertNil(r.modifierChanged(code: Key.leftCommand, down: false, at: 0.15))
        // A fresh, clean tap works afterwards.
        _ = r.modifierChanged(code: Key.rightOption, down: true, at: 1)
        XCTAssertEqual(r.modifierChanged(code: Key.rightOption, down: false, at: 1.1), Key.rightOption)
    }
}

final class BindingTests: XCTestCase {
    func testStandardPresetHasNoConflicts() {
        XCTAssertTrue(ConfigValidator.problems(in: .default).isEmpty)
    }

    func testDuplicateGestureInOneContextIsReported() {
        let table = BindingTable<CursorAction>([
            (.key(code: Key.i, modifiers: []), .moveUp),
            (.key(code: Key.i, modifiers: []), .scrollUp)
        ])
        XCTAssertEqual(table.conflicts.count, 1)
        XCTAssertEqual(table.conflicts.first?.first, .moveUp)
    }

    func testMouselessPresetMapsSlashToScrollRightAndSpaceToClick() {
        let table = BindingTable(Presets.mouseless.cursorBindings.map { ($0.gesture, $0.action) })
        XCTAssertEqual(table.action(forKey: Key.slash, modifiers: []), .scrollRight)
        XCTAssertEqual(table.action(forKey: Key.space, modifiers: []), .leftClick)
        XCTAssertEqual(table.action(forKey: Key.i, modifiers: []), .moveUp)
        XCTAssertTrue(table.conflicts.isEmpty)
    }

    func testConfigWithConflictingBindingsIsRejected() {
        var config = KeyNavConfig.default
        config.cursorBindings.append(CursorBinding(action: .rightClick, gesture: .key(code: Key.i, modifiers: [])))
        XCTAssertFalse(ConfigValidator.problems(in: config).isEmpty)
    }

    func testEntryAndExitCannotBeIdentical() {
        var config = KeyNavConfig.default
        config.cursorEntry = EntryConfig(gesture: .key(code: Key.escape, modifiers: []), separateExit: true)
        XCTAssertFalse(ConfigValidator.problems(in: config).isEmpty)
    }
}

final class CursorEngineTests: XCTestCase {
    private func engine() -> CursorEngine {
        CursorEngine(bindings: Presets.standard.cursorBindings, motion: .gentle)
    }

    private func pointer() -> (x: Double, y: Double) { (100, 100) }

    func testUnmatchedPrintableKeyIsConsumedButShortcutPasses() {
        var e = engine()
        XCTAssertTrue(e.keyDown(down(Key.z, character: "z"), at: 0, pointer: pointer()).consumed)
        XCTAssertFalse(e.keyDown(down(Key.z, [.command], character: "z"), at: 0, pointer: pointer()).consumed)
    }

    func testMoveOnlyWhileHeldAndStopsOnRelease() {
        var e = engine()
        _ = e.keyDown(down(Key.l, character: "l"), at: 0, pointer: pointer())
        let moving = e.tick(dt: 1.0 / 120)
        XCTAssertEqual(moving.count, 1)
        _ = e.keyUp(up(Key.l))
        XCTAssertTrue(e.tick(dt: 1.0 / 120).isEmpty)
    }

    func testDiagonalIsNormalized() {
        var e = engine()
        _ = e.keyDown(down(Key.l, character: "l"), at: 0, pointer: pointer())
        _ = e.keyDown(down(Key.k, character: "k"), at: 0, pointer: pointer())
        guard case let .move(dx, dy)? = e.tick(dt: 0.1).first else { return XCTFail("no move") }
        let length = (dx * dx + dy * dy).squareRoot()
        XCTAssertEqual(length, 0.1 * e.currentMoveSpeed(), accuracy: 1e-9)
    }

    func testOppositeDirectionsCancel() {
        var e = engine()
        _ = e.keyDown(down(Key.j, character: "j"), at: 0, pointer: pointer())
        _ = e.keyDown(down(Key.l, character: "l"), at: 0, pointer: pointer())
        XCTAssertTrue(e.tick(dt: 0.1).allSatisfy { if case let .move(dx, dy) = $0 { return dx == 0 && dy == 0 }; return false })
    }

    /// Displacement over a fixed interval must not depend on how the interval is sliced (60/120/144 Hz).
    func testDisplacementIsIndependentOfFrameRate() {
        func distance(frequency: Double, seconds: Double) -> Double {
            var e = CursorEngine(bindings: Presets.standard.cursorBindings, motion: .gentle)
            _ = e.keyDown(down(Key.l, character: "l"), at: 0, pointer: (0, 0))
            var total = 0.0
            let steps = Int((seconds * frequency).rounded())
            for _ in 0..<steps {
                for command in e.tick(dt: 1 / frequency) {
                    if case let .move(dx, _) = command { total += dx }
                }
            }
            return total
        }
        let at60 = distance(frequency: 60, seconds: 2)
        let at144 = distance(frequency: 144, seconds: 2)
        XCTAssertEqual(at60, at144, accuracy: at60 * 0.01)
    }

    func testRampStartsSlowAndReachesMaximum() {
        var e = engine()
        _ = e.keyDown(down(Key.l, character: "l"), at: 0, pointer: pointer())
        XCTAssertEqual(e.currentMoveSpeed(), 80, accuracy: 0.001)
        for _ in 0..<200 { _ = e.tick(dt: 1.0 / 120) }
        XCTAssertEqual(e.currentMoveSpeed(), 1100, accuracy: 0.001)
    }

    func testReleaseOfAllKeysRestartsRamp() {
        var e = engine()
        _ = e.keyDown(down(Key.l, character: "l"), at: 0, pointer: pointer())
        for _ in 0..<60 { _ = e.tick(dt: 1.0 / 60) }
        _ = e.keyUp(up(Key.l))
        _ = e.tick(dt: 0.1)
        _ = e.keyDown(down(Key.l, character: "l"), at: 2, pointer: pointer())
        XCTAssertEqual(e.currentMoveSpeed(), 80, accuracy: 0.001)
    }

    func testPrecisionAndBoostScaleSpeed() {
        var e = engine()
        _ = e.keyDown(down(Key.a, character: "a"), at: 0, pointer: pointer())
        XCTAssertEqual(e.currentMoveSpeed(), 80 * 0.2, accuracy: 0.001)
    }

    func testClickCountIncrementsWithinIntervalAndDistance() {
        var e = engine()
        let first = e.keyDown(down(Key.space, character: nil), at: 0, pointer: pointer()).commands
        let second = e.keyDown(down(Key.space), at: 0.2, pointer: pointer()).commands
        let third = e.keyDown(down(Key.space), at: 5, pointer: pointer()).commands
        XCTAssertEqual(first, [.buttonDown(.left, clickCount: 1)])
        // Still held: a second press of a held button does nothing.
        XCTAssertEqual(second, [])
        _ = e.keyUp(up(Key.space))
        XCTAssertEqual(e.keyDown(down(Key.space), at: 0.3, pointer: pointer()).commands, [.buttonDown(.left, clickCount: 2)])
        XCTAssertEqual(e.keyUp(up(Key.space)).commands, [.buttonUp(.left, clickCount: 2)])
        _ = third
    }

    func testDragHoldPressesAndReleasesLeftButton() {
        var e = CursorEngine(bindings: Presets.standard.cursorBindings
            + [CursorBinding(action: .dragHold, gesture: .key(code: Key.leftCommand, modifiers: []))])
        XCTAssertEqual(e.keyDown(down(Key.leftCommand, [], character: nil), at: 0, pointer: pointer()).commands, [.press(.left)])
        XCTAssertEqual(e.keyUp(up(Key.leftCommand)).commands, [.release(.left)])
    }

    func testResetReleasesDragAndClearsHeld() {
        var e = CursorEngine(bindings: Presets.standard.cursorBindings
            + [CursorBinding(action: .dragHold, gesture: .key(code: Key.leftCommand, modifiers: []))])
        _ = e.keyDown(down(Key.leftCommand, [], character: nil), at: 0, pointer: pointer())
        _ = e.keyDown(down(Key.l, character: "l"), at: 0, pointer: pointer())
        XCTAssertEqual(e.reset(), [.release(.left)])
        XCTAssertTrue(e.held.isEmpty)
        XCTAssertEqual(e.reset(), [])
    }

    func testScrollReverseNegatesDelta() {
        var e = CursorEngine(bindings: Presets.standard.cursorBindings, scrolling: ScrollProfile(maximumSpeed: 100, rampSeconds: 0.01, reverse: true))
        _ = e.keyDown(down(Key.upArrow), at: 0, pointer: pointer())
        guard case let .scroll(_, dy)? = e.tick(dt: 0.1).first else { return XCTFail("no scroll") }
        XCTAssertLessThan(dy, 0)
    }
}

final class LabelAndSearchTests: XCTestCase {
    func testLabelsArePrefixFreeAndUnique() {
        let labels = LabelGenerator.labels(count: 100, alphabet: Array("abcdefghij"))
        XCTAssertEqual(labels.count, 100)
        XCTAssertEqual(Set(labels).count, 100)
        XCTAssertTrue(Set(labels.map(\.count)).count == 1, "labels must share one length")
    }

    func testReservedKeysNeverAppearInLabels() {
        let alphabet = LabelGenerator.usableAlphabet("asdf/ghjk", reserved: ["g", "h"])
        XCTAssertEqual(alphabet, Array("asdfjk"))
    }

    func testSearchMatchesTokensCaseAndDiacriticInsensitive() {
        let names = ["Café Mocha", "Save As…", "Save", "Open Recent"]
        XCTAssertEqual(TargetSearch.rank(query: "cafe", names: names), [0])
        XCTAssertEqual(TargetSearch.rank(query: "SAVE", names: names), [2, 1])
        XCTAssertEqual(TargetSearch.rank(query: "zzz", names: names), [])
    }
}

final class ClickSessionTests: XCTestCase {
    private func targets(_ n: Int) -> [HintTarget] {
        (0..<n).map { HintTarget(name: "Button \($0)", role: "AXButton", frame: .init(x: 0, y: 0, width: 10, height: 10)) }
    }

    func testFullLabelActivatesOnce() {
        var s = ClickSession(alphabet: Array("abcd"))
        s.setTargets(targets(4), snapshot: 1)
        let label = s.labels[2]
        var activations: [Int] = []
        for character in label {
            if case let .activate(target, _) = s.handle(down(0, character: String(character)), controls: [:]) {
                activations.append(target)
            }
        }
        XCTAssertEqual(activations, [2])
    }

    func testSearchActivatesSelectedResult() {
        var s = ClickSession(alphabet: Array("abcd"))
        s.setTargets(targets(3), snapshot: 1)
        let controls: [Gesture: ClickControl] = [.key(code: Key.slash, modifiers: []): .startSearch,
                                                 .key(code: Key.returnKey, modifiers: []): .activateSelected]
        _ = s.handle(down(Key.slash, character: "/"), controls: controls)
        for character in "button 1" {
            _ = s.handle(down(0, character: String(character)), controls: controls)
        }
        XCTAssertEqual(s.visible, [1])
        XCTAssertEqual(s.handle(down(Key.returnKey), controls: controls), .activate(target: 1, action: .press))
    }

    func testBackspaceOnEmptySearchReturnsToLabels() {
        var s = ClickSession(alphabet: Array("ab"), searchFirst: true)
        s.setTargets(targets(2), snapshot: 1)
        XCTAssertEqual(s.substate, .search)
        _ = s.handle(down(Key.delete), controls: [.key(code: Key.delete, modifiers: []): .backspace])
        XCTAssertEqual(s.substate, .labels)
    }
}

final class NavigationRouterTests: XCTestCase {
    private func router(_ config: KeyNavConfig = .default) -> NavigationRouter {
        NavigationRouter(config: config)
    }

    private let origin = (x: 0.0, y: 0.0)

    /// Drag bound to Left Command, as someone might set it; the defaults have no modifier drag.
    private func commandDragRouter() -> NavigationRouter {
        var config = KeyNavConfig.default
        config.cursorBindings.append(CursorBinding(action: .dragHold, gesture: .key(code: Key.leftCommand, modifiers: [])))
        return NavigationRouter(config: config)
    }

    func testOffPassesEverythingThrough() {
        var r = router()
        for code in [Key.i, Key.j, Key.r, Key.e, Key.q, Key.w] {
            let decision = r.handle(.key(down(code, character: "x")), at: 0, pointer: origin)
            XCTAssertFalse(decision.consumed)
        }
    }

    func testRightOptionTapEntersCursorWithoutPointerEffects() {
        var r = router()
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        let decision = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        XCTAssertEqual(r.mode, .cursor)
        XCTAssertEqual(decision.effects, [.started(.cursor), .refreshOverlay])
        XCTAssertFalse(decision.effects.contains { if case .cursor = $0 { return true }; return false })
    }

    func testOptionLetterShortcutDoesNotEnter() {
        var r = router()
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.key(down(Key.a, [.option], character: nil, typesCharacter: false)), at: 0.05, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        XCTAssertEqual(r.mode, .off)
    }

    func testEnterOnlyEntryWithSeparateExitIgnoresRepeatEntry() {
        var r = router()
        _ = r.handle(.key(down(Key.space, [.command, .shift])), at: 0, pointer: origin)
        XCTAssertEqual(r.mode, .click)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.space, modifiers: [.command, .shift])), at: 0.01, pointer: origin)
        _ = r.handle(.key(down(Key.space, [.command, .shift])), at: 0.5, pointer: origin)
        XCTAssertEqual(r.mode, .click, "same entry gesture must not exit when a separate exit exists")
    }

    func testToggleEntryWhenSeparateExitDisabled() {
        var config = KeyNavConfig.default
        config.cursorEntry.separateExit = false
        var r = router(config)
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        XCTAssertEqual(r.mode, .cursor)
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 1, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 1.1, pointer: origin)
        XCTAssertEqual(r.mode, .off)
    }

    func testSwitchBetweenModesIsExclusiveAndReleasesDrag() {
        var r = commandDragRouter()
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        _ = r.handle(.key(down(Key.leftCommand)), at: 0.2, pointer: origin)
        let switching = r.handle(.key(down(Key.space, [.command, .shift])), at: 0.3, pointer: origin)
        XCTAssertTrue(switching.effects.contains(.cursor(.release(.left))))
        XCTAssertTrue(switching.effects.contains(.started(.click)))
        XCTAssertTrue(switching.effects.contains(.discoverTargets(generation: r.generation)))
        let releaseIndex = switching.effects.firstIndex(of: .cursor(.release(.left)))!
        let startIndex = switching.effects.firstIndex(of: .started(.click))!
        XCTAssertLessThan(releaseIndex, startIndex, "the drag must end before Click starts")
        XCTAssertEqual(r.mode, .click)
    }

    func testEscapeExitsClickFromSearchInOneKey() {
        var r = router()
        _ = r.handle(.key(down(Key.space, [.command, .shift])), at: 0, pointer: origin)
        _ = r.handle(.key(down(Key.slash, character: "/")), at: 0.1, pointer: origin)
        XCTAssertEqual(r.click?.substate, .search)
        let decision = r.handle(.key(down(Key.escape)), at: 0.2, pointer: origin)
        XCTAssertEqual(r.mode, .off)
        XCTAssertTrue(decision.consumed)
    }

    func testConsumedKeyReleaseStaysConsumedAfterExit() {
        var r = router()
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        _ = r.handle(.key(down(Key.escape)), at: 0.2, pointer: origin)
        XCTAssertEqual(r.mode, .off)
        XCTAssertTrue(r.handle(.key(up(Key.escape)), at: 0.25, pointer: origin).consumed)
    }

    func testSuspendReleasesHeldMotion() {
        var r = commandDragRouter()
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        _ = r.handle(.key(down(Key.leftCommand)), at: 0.2, pointer: origin)
        let decision = r.handle(.suspendRouting(true), at: 0.3, pointer: origin)
        XCTAssertEqual(decision.effects, [.cursor(.release(.left)), .refreshOverlay])
        XCTAssertEqual(r.mode, .cursor, "suspension keeps the selected mode")
        XCTAssertFalse(r.handle(.key(down(Key.i, character: "i")), at: 0.4, pointer: origin).consumed)
    }

    func testForceOffReleasesAndStops() {
        var r = commandDragRouter()
        _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: 0, pointer: origin)
        _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: 0.1, pointer: origin)
        _ = r.handle(.key(down(Key.leftCommand)), at: 0.2, pointer: origin)
        let decision = r.handle(.forceOff, at: 0.3, pointer: origin)
        XCTAssertEqual(decision.effects, [.cursor(.release(.left)), .stopped(.cursor)])
        XCTAssertEqual(r.mode, .off)
    }

    func testStaleActivationResultIsIgnored() {
        var r = router()
        _ = r.handle(.key(down(Key.space, [.command, .shift])), at: 0, pointer: origin)
        let stale = r.handle(.activationFinished(generation: 0, succeeded: true), at: 0.1, pointer: origin)
        XCTAssertEqual(stale, .passThrough)
        XCTAssertEqual(r.mode, .click)
    }

    func testStaleTargetsAreDiscarded() {
        var r = router()
        _ = r.handle(.key(down(Key.space, [.command, .shift])), at: 0, pointer: origin)
        let stale = HintTarget(name: "Old", role: "AXButton", frame: .init(x: 0, y: 0, width: 1, height: 1))
        _ = r.handle(.targetsDiscovered(generation: 0, snapshot: 1, targets: [stale]), at: 0.1, pointer: origin)
        XCTAssertEqual(r.click?.targets.count, 0)
    }

    func testClickActivationEmitsEffectWithCurrentGeneration() {
        var r = router()
        _ = r.handle(.key(down(Key.space, [.command, .shift])), at: 0, pointer: origin)
        let target = HintTarget(name: "OK", role: "AXButton", frame: .init(x: 0, y: 0, width: 1, height: 1))
        _ = r.handle(.targetsDiscovered(generation: r.generation, snapshot: 7, targets: [target]), at: 0.1, pointer: origin)
        let label = r.click!.labels[0]
        var effects: [NavigationEffect] = []
        for character in label {
            effects += r.handle(.key(down(0, character: String(character))), at: 0.2, pointer: origin).effects
        }
        XCTAssertEqual(effects, [.activate(index: 0, snapshot: 7, generation: r.generation, action: .press)])
    }

    func testMassEnterSwitchExitLeavesNoHeldState() {
        var r = router()
        var seed: UInt64 = 42
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        var t = 0.0
        for _ in 0..<1000 {
            let pick = next() % 4
            t += 0.3
            switch pick {
            case 0: _ = r.handle(.key(KeyEvent(kind: .down, code: Key.rightOption)), at: t, pointer: origin)
                    _ = r.handle(.key(KeyEvent(kind: .up, code: Key.rightOption)), at: t + 0.05, pointer: origin)
            case 1: _ = r.handle(.key(down(Key.space, [.command, .shift])), at: t, pointer: origin)
                    _ = r.handle(.key(KeyEvent(kind: .up, code: Key.space, modifiers: [.command, .shift])), at: t + 0.05, pointer: origin)
            case 2: _ = r.handle(.key(down(Key.leftCommand)), at: t, pointer: origin)
            default: _ = r.handle(.key(down(Key.escape)), at: t, pointer: origin)
                    _ = r.handle(.key(up(Key.escape)), at: t + 0.05, pointer: origin)
            }
        }
        _ = r.handle(.forceOff, at: t + 1, pointer: origin)
        XCTAssertEqual(r.mode, .off)
        XCTAssertTrue(r.cursor.held.isEmpty)
    }
}

final class ConfigStoreTests: XCTestCase {
    func testRoundTripAndAtomicSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))
        var config = KeyNavConfig.default
        config.motion.maximumSpeed = 900
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
    }

    func testUnsupportedSchemaIsRejected() throws {
        let store = ConfigStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        var config = KeyNavConfig.default
        config.schemaVersion = 99
        let data = try JSONEncoder().encode(config)
        XCTAssertThrowsError(try store.decode(data))
    }

    func testConflictingFileNeverPartiallyApplies() throws {
        let store = ConfigStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        var config = KeyNavConfig.default
        config.cursorBindings.append(CursorBinding(action: .rightClick, gesture: .key(code: Key.i, modifiers: [])))
        let data = try JSONEncoder().encode(config)
        XCTAssertThrowsError(try store.decode(data))
    }
}
