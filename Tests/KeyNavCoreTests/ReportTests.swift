import XCTest
@testable import KeyNavCore

private let origin = (x: 0.0, y: 0.0)

private func down(_ code: UInt16, _ modifiers: Modifiers = [], _ character: String? = nil) -> KeyEvent {
    KeyEvent(kind: .down, code: code, modifiers: modifiers, character: character)
}

private let question = down(Key.slash, [.shift], "?")

private func type(_ text: String, into draft: inout ReportDraft, labels: [String] = []) {
    for character in text { _ = draft.handle(down(0, [], String(character)), labels: labels) }
}

final class ReportTests: XCTestCase {
    private func clicking() -> NavigationRouter {
        var r = NavigationRouter(config: .default)
        _ = r.handle(.key(down(Key.space, [.command, .shift])), at: 0, pointer: origin)
        let targets = (0..<80).map { HintTarget(name: "\($0)", role: "AXButton", frame: .init(x: Double($0) * 20, y: 0, width: 10, height: 10)) }
        _ = r.handle(.targetsDiscovered(generation: r.generation, snapshot: 1, targets: targets), at: 0.1, pointer: origin)
        return r
    }

    func testReturnSendsEvenEmpty() {
        var r = clicking()
        XCTAssertTrue(r.handle(.key(question), at: 1, pointer: origin).consumed)
        XCTAssertEqual(r.report?.mode, .click)
        let sent = r.handle(.key(down(Key.returnKey)), at: 1.1, pointer: origin)
        XCTAssertTrue(sent.effects.contains(.sendReport(ReportDraft(mode: .click))))
        XCTAssertNil(r.report)
    }

    func testTypedTextIsKeptAndALabelItNamesIsMarked() {
        var draft = ReportDraft(mode: .click)
        type("sk Clicks the wrong one!", into: &draft, labels: ["SK", "SL"])
        XCTAssertEqual(draft.text, "sk Clicks the wrong one!")
        XCTAssertEqual(draft.handle(down(Key.returnKey), labels: ["SK", "SL"]), .send)
        XCTAssertEqual(draft.marked, "SK")
    }

    func testDeleteAndOptionDelete() {
        var draft = ReportDraft(mode: .click)
        type("the wrong one", into: &draft)
        _ = draft.handle(down(Key.delete))
        XCTAssertEqual(draft.text, "the wrong on")
        _ = draft.handle(down(Key.delete, [.option]))
        XCTAssertEqual(draft.text, "the wrong ")
    }

    func testAPaneNumberInTheTextIsMarked() {
        var draft = ReportDraft(mode: .scroll)
        type("pane 2 is wrong", into: &draft)
        _ = draft.handle(down(Key.returnKey))
        XCTAssertEqual(draft.marked, "2")
    }

    func testEscapeCancelsTheReportAndLeavesTheMode() {
        var r = clicking()
        _ = r.handle(.key(question), at: 1, pointer: origin)
        _ = r.handle(.key(down(Key.escape)), at: 1.1, pointer: origin)
        XCTAssertNil(r.report)
        XCTAssertEqual(r.mode, .off)
    }

    func testCommandChordsPassThroughForScreenshots() {
        var r = clicking()
        _ = r.handle(.key(question), at: 1, pointer: origin)
        _ = r.handle(.key(down(21, [.command, .shift], "4")), at: 1.1, pointer: origin)
        XCTAssertEqual(r.report?.text, "")
    }
}
