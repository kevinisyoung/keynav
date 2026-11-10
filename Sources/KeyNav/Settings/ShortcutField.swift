import AppKit
import KeyNavCore
import KeyNavSystem
import SwiftUI

typealias KNGesture = KeyNavCore.Gesture

/// What a recorder accepts. Recording never triggers the action being recorded.
enum RecorderKind {
    /// Starts a mode: a lone modifier tap (such as Right Option) or a key with modifiers.
    case entry
    /// Leaves a mode. Escape records itself here; use Cancel to stop recording.
    case exit
    /// Works inside a mode: plain keys are fine; a lone modifier records as a hold.
    case action

    var hint: String {
        switch self {
        case .entry: return "Tap a single modifier such as Right Option, or press a key with modifiers. It saves when you let go."
        case .exit: return "Press the key that should leave the mode. It saves when you let go, and Escape records Escape here."
        case .action: return "Plain keys work here, and a modifier alone binds as a hold. It saves when you let go."
        }
    }
}

/// An inline shortcut recorder: shows the current key; click (or press Space) to record, and it saves as soon as
/// every key is let go. Escape, or Cancel, stops without saving.
struct ShortcutField: View {
    let title: String
    let gesture: KNGesture?
    let kind: RecorderKind
    var defaultGesture: KNGesture? = nil
    var allowsClear = false
    var placeholder = "None"
    /// Larger keycaps, for a mode's start and stop keys.
    var prominent = false
    /// Saves the gesture (nil clears it). Returns blocking problems; empty means saved.
    let onSave: (KNGesture?) -> [String]
    /// Resolves a conflict by taking the key from the other action.
    var onReplace: ((KNGesture) -> [String])? = nil

    @State private var recording = false
    @State private var pending: KNGesture?
    @State private var problems: [String] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if recording {
                    recorderPill
                    Button("Cancel") { stopRecording() }
                        .controlSize(.small)
                } else {
                    Button { startRecording() } label: {
                        KeyCaps(text: gesture?.displayName ?? placeholder, placeholder: gesture == nil, large: prominent)
                    }
                    .buttonStyle(.plain)
                    .help("Change \(title)")
                    .accessibilityLabel("\(title): \(gesture?.displayName ?? "none"). Change")
                    if let defaultGesture, gesture != defaultGesture {
                        Button { problems = onSave(defaultGesture) } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Restore default: \(defaultGesture.displayName)")
                        .accessibilityLabel("Restore default for \(title)")
                    }
                    if allowsClear, gesture != nil {
                        Button { problems = onSave(nil) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this key")
                        .accessibilityLabel("Remove \(gesture?.displayName ?? "") from \(title)")
                    }
                }
            }
            if recording {
                Text(kind.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !problems.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Keep existing") {
                            problems = []
                            stopRecording()
                        }
                        .keyboardShortcut(.cancelAction)
                        if let onReplace, let pending {
                            Button("Replace") {
                                problems = onReplace(pending)
                                if problems.isEmpty { stopRecording() }
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        Button("Choose another key") {
                            problems = []
                            pending = nil
                            recording = true
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var recorderPill: some View {
        ZStack {
            KeyCaptureRepresentable(kind: kind, onGesture: { pending = $0 }, onRelease: save, onCancel: { stopRecording() })
                .frame(width: 1, height: 1)
                .opacity(0.01)
            Text(pending?.displayName ?? "Press keys…")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(pending == nil ? .secondary : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(minWidth: 120)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording \(title). \(pending?.displayName ?? "No key yet")")
    }

    private func startRecording() {
        pending = nil
        problems = []
        recording = true
    }

    private func stopRecording() {
        recording = false
        pending = nil
    }

    private func save(_ gesture: KNGesture) {
        pending = gesture
        problems = onSave(gesture)
        if problems.isEmpty { stopRecording() } else { recording = false }
    }
}

/// Key names drawn as keycaps, with plain words rather than a wall of glyphs.
struct KeyCaps: View {
    let text: String
    var placeholder = false
    var large = false

    var body: some View {
        Text(text)
            .font(.system(large ? .title3 : .body, design: .rounded).weight(large ? .semibold : .medium))
            .foregroundStyle(placeholder ? .secondary : .primary)
            .padding(.horizontal, large ? 12 : 9)
            .padding(.vertical, large ? 5 : 3)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
            .contentShape(Rectangle())
    }
}

/// Captures one gesture. While focused, KeyNav's own navigation pauses (`SuspendsNavigation`).
struct KeyCaptureRepresentable: NSViewRepresentable {
    let kind: RecorderKind
    let onGesture: (KNGesture) -> Void
    /// Every key is up again after a gesture: it's the one to keep.
    let onRelease: (KNGesture) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        update(view)
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        update(view)
    }

    private func update(_ view: CaptureView) {
        view.kind = kind
        view.onGesture = onGesture
        view.onRelease = onRelease
        view.onCancel = onCancel
    }

    final class CaptureView: NSView, SuspendsNavigation {
        var kind: RecorderKind = .action
        var onGesture: ((KNGesture) -> Void)?
        var onRelease: ((KNGesture) -> Void)?
        var onCancel: (() -> Void)?
        private var modifierCandidate: UInt16?
        /// The gesture pressed and not yet let go.
        private var held: KNGesture?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Capture Command chords before menus see them.
            guard window?.firstResponder === self, event.type == .keyDown else { return false }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            modifierCandidate = nil
            if event.keyCode == Key.escape, kind != .exit, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                onCancel?()
                return
            }
            guard !event.isARepeat else { return }
            let gesture = KNGesture.key(code: event.keyCode, modifiers: Self.modifiers(event.modifierFlags))
            held = gesture
            onGesture?(gesture)
        }

        // macOS sends no key-up for a key pressed with Command, so a chord also finishes when its modifiers are let go.
        override func keyUp(with event: NSEvent) {
            if Self.modifierCount(event.modifierFlags) == 0 { finish() }
        }

        private func finish() {
            guard let gesture = held else { return }
            held = nil
            onRelease?(gesture)
        }

        override func flagsChanged(with event: NSEvent) {
            let code = event.keyCode
            guard Key.modifierKeys.contains(code) else { return }
            if Self.isDown(code, flags: event.modifierFlags) {
                modifierCandidate = Self.modifierCount(event.modifierFlags) == 1 ? code : nil
            } else if modifierCandidate == code {
                modifierCandidate = nil
                held = kind == .entry ? .modifierTap(code: code) : .key(code: code, modifiers: [])
                onGesture?(held!)
                finish()
            } else if Self.modifierCount(event.modifierFlags) == 0 {
                finish()
            }
        }

        static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
            var result: Modifiers = []
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.control) { result.insert(.control) }
            return result
        }

        static func modifierCount(_ flags: NSEvent.ModifierFlags) -> Int {
            [flags.contains(.command), flags.contains(.shift), flags.contains(.option), flags.contains(.control)]
                .filter { $0 }.count
        }

        /// Device-dependent bits distinguish left and right modifiers.
        static func isDown(_ code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
            let raw = UInt64(flags.rawValue)
            switch code {
            case Key.leftCommand: return raw & 0x08 != 0
            case Key.rightCommand: return raw & 0x10 != 0
            case Key.leftShift: return raw & 0x02 != 0
            case Key.rightShift: return raw & 0x04 != 0
            case Key.leftOption: return raw & 0x20 != 0
            case Key.rightOption: return raw & 0x40 != 0
            case Key.leftControl: return raw & 0x01 != 0
            case Key.rightControl: return raw & 0x2000 != 0
            case Key.capsLock: return flags.contains(.capsLock)
            default: return flags.contains(.function)
            }
        }
    }
}
