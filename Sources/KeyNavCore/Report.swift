import Foundation

/// A report someone is writing, from inside Clicking or Scrolling, about labels or panes that look wrong.
///
/// One field: "What went wrong?" Return sends, even empty, and Escape cancels the report and leaves the mode.
/// A label code ("SK") or a pane number ("pane 2") in the text marks what it's about.
public struct ReportDraft: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case consumed
        case send
        case cancel
    }

    public let mode: InteractionMode
    public private(set) var text = ""
    /// The label, or pane number, the text mentions first; set when it's sent.
    public private(set) var marked = ""

    public static let limit = 300

    public init(mode: InteractionMode) {
        self.mode = mode
    }

    /// The key that opens a report: `?`.
    public static func opens(_ event: KeyEvent) -> Bool {
        event.kind == .down && !event.isRepeat && event.code == Key.slash && event.modifiers == [.shift]
    }

    /// `labels` are the labels on screen, to find one the text mentions.
    public mutating func handle(_ event: KeyEvent, labels: [String] = []) -> Decision {
        guard event.kind == .down else { return .consumed }
        switch event.code {
        case Key.escape:
            return .cancel
        case Key.returnKey:
            marked = mention(in: text, labels: labels)
            return .send
        case Key.delete:
            if event.modifiers.contains(.option) {
                // Option-Delete removes the last word, as in any text field.
                while text.last == " " { text.removeLast() }
                while let last = text.last, last != " " { text.removeLast() }
            } else if !text.isEmpty {
                text.removeLast()
            }
            return .consumed
        default:
            break
        }
        guard event.modifiers.isDisjoint(with: [.command, .control]), text.count < Self.limit else { return .consumed }
        let typed = event.character ?? Key.printableCodes[event.code].map { $0 == "Space" ? " " : $0.lowercased() }
        if let typed, typed.count == 1, let character = typed.first, !character.isNewline, !(character.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) {
            text.append(character)
        }
        return .consumed
    }

    /// The first label code, or pane number, a report's text names.
    func mention(in text: String, labels: [String]) -> String {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if mode == .scroll {
            return words.first { Int($0).map { (1...9).contains($0) } ?? false } ?? ""
        }
        let known = Set(labels.map { $0.uppercased() })
        return words.first { $0.count <= 3 && known.contains($0.uppercased()) }?.uppercased() ?? ""
    }
}
