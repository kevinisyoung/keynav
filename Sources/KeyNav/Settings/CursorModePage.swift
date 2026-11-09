import KeyNavCore
import KeyNavSystem
import SwiftUI

struct CursorModePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            EntrySection(mode: .cursor)

            Section {
                ActionBindingRow(action: .leftClick)
                ActionBindingRow(action: .rightClick)
            } footer: {
                Text("I J K L move the pointer. Hold the click key to drag.")
            }

            Section {
                SettingRow(title: "Speed", detail: "How quickly the pointer picks up speed while a key is held.") {
                    Picker("Speed", selection: Binding(
                        get: { model.config.motion.presetName ?? "Custom" },
                        set: { name in
                            guard let preset = MotionProfile.presets.first(where: { $0.name == name }) else { return }
                            model.update("Speed: \(name)") { $0.motion = preset.profile }
                        }
                    )) {
                        ForEach(MotionProfile.presets.map(\.name), id: \.self) { Text($0).tag($0) }
                        if model.config.motion.presetName == nil { Text("Custom").tag("Custom") }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One action with its keys. Each key is its own recorder; aliases are separate chips.
struct ActionBindingRow: View {
    @Environment(AppModel.self) private var model
    let action: CursorAction

    var body: some View {
        let gestures = model.config.cursorBindings.filter { $0.action == action }.map(\.gesture)
        LabeledContent {
            HStack(spacing: 8) {
                ForEach(gestures, id: \.self) { gesture in
                    ShortcutField(
                        title: action.title,
                        gesture: gesture,
                        kind: .action,
                        allowsClear: true,
                        onSave: { replace(gesture, with: $0) },
                        onReplace: { newGesture in takeOver(newGesture, replacing: gesture) }
                    )
                }
                ShortcutField(
                    title: "another key for \(action.title)",
                    gesture: nil,
                    kind: .action,
                    placeholder: gestures.isEmpty ? "Add key" : "+",
                    onSave: { add($0) },
                    onReplace: { takeOver($0, replacing: nil) }
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                if action.isHold {
                    Text("while held").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func replace(_ old: KNGesture, with new: KNGesture?) -> [String] {
        model.update(new.map { "\(action.title): \($0.displayName)" } ?? "\(action.title): removed \(old.displayName)") { config in
            guard let index = config.cursorBindings.firstIndex(of: CursorBinding(action: action, gesture: old)) else { return }
            if let new {
                config.cursorBindings[index].gesture = new
            } else {
                config.cursorBindings.remove(at: index)
            }
        }
    }

    private func add(_ gesture: KNGesture?) -> [String] {
        guard let gesture else { return [] }
        return model.update("\(action.title): added \(gesture.displayName)") { config in
            config.cursorBindings.append(CursorBinding(action: action, gesture: gesture))
        }
    }

    /// Conflict resolution: the key moves from the other action to this one, in one undoable change.
    private func takeOver(_ gesture: KNGesture, replacing old: KNGesture?) -> [String] {
        model.update("\(gesture.displayName) moved to \(action.title)") { config in
            config.cursorBindings.removeAll { $0.gesture == gesture && $0.action != action }
            if let old, let index = config.cursorBindings.firstIndex(of: CursorBinding(action: action, gesture: old)) {
                config.cursorBindings[index].gesture = gesture
            } else {
                config.cursorBindings.append(CursorBinding(action: action, gesture: gesture))
            }
        }
    }
}
