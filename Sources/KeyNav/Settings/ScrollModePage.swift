import KeyNavCore
import SwiftUI

struct ScrollModePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            EntrySection(mode: .scroll)

            Section {
                NumberSlider(title: "Speed", detail: "How fast H J K L scroll once they get going.", unit: "pt/s",
                             range: 100...4000, step: 10, value: model.config.scrolling.maximumSpeed) { value in
                    model.update("Scroll speed \(Int(value)) pt/s") { $0.scrolling.maximumSpeed = value }
                }
            } footer: {
                Text("Shift with H J K L jumps most of a window. Tab moves to the next scroll area, or press its number.")
            }
        }
        .formStyle(.grouped)
    }
}
