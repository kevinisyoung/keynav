import AppKit
import KeyNavCore
import KeyNavSystem
import SwiftUI

struct ClickModePage: View {
    @Environment(AppModel.self) private var model
    @State private var alphabetDraft = ""
    @State private var alphabetProblems: [String] = []

    var body: some View {
        Form {
            EntrySection(mode: .click)

            Section {
                SettingToggle(title: "Confirm with Return", detail: "Type a label, then press Return to click it.",
                              keyPath: \.clickRequireReturn)
                SettingToggle(title: "Stay on after clicking", detail: "Keep labels up for the next click until you press Escape.",
                              keyPath: \.clickStaysActive)
                Toggle(isOn: Binding(
                    get: { model.config.clickLabelsMenuBar || model.config.clickLabelsDock },
                    set: { value in
                        model.update(value ? "Menu bar and Dock labelled" : "Menu bar and Dock not labelled") {
                            $0.clickLabelsMenuBar = value
                            $0.clickLabelsDock = value
                        }
                    }
                )) {
                    SettingLabel(title: "Label the menu bar and Dock", detail: "Menus, status icons and Dock items get labels too.")
                }
            }

            Section {
                SettingRow(title: "Label size", detail: "How big labels are on screen.") {
                    Picker("Label size", selection: Binding(
                        get: { model.config.appearance.hintSize },
                        set: { value in model.update("Label size \(value.rawValue)") { $0.appearance.hintSize = value } }
                    )) {
                        ForEach(AppearanceSettings.Size.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingRow(title: "Label letters", detail: "The letters labels are made from, easiest first.") {
                    TextField("Letters", text: $alphabetDraft)
                        .labelsHidden()
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(saveAlphabet)
                }
                ProblemList(problems: alphabetProblems)
            }
        }
        .formStyle(.grouped)
        .onAppear { alphabetDraft = model.config.clickAlphabet }
    }

    private func saveAlphabet() {
        alphabetProblems = model.update("Label letters updated") { $0.clickAlphabet = alphabetDraft.lowercased() }
    }
}

/// A miniature window with real labels from the current letters and appearance.
struct LabelsPreview: View {
    let alphabet: [Character]
    let search: Bool
    let appearance: AppearanceSettings

    private let buttons = ["Back", "Share", "Save", "Name", "Cancel", "Done"]

    var body: some View {
        let labels = LabelGenerator.labels(count: buttons.count, alphabet: alphabet)
        VStack(alignment: .leading, spacing: 12) {
            if search {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("sa").fontWeight(.medium)
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 14)
                    Spacer()
                    Text("2 results").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 28) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, title in
                    let matched = !search || title.lowercased().contains("sa")
                    Text(title)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottom) {
                            if matched, labels.indices.contains(index) {
                                LabelChipPreview(label: search ? "\(buttons.prefix(index + 1).filter { $0.lowercased().contains("sa") }.count)" : labels[index],
                                                 typed: 0, scale: appearance.hintSize.scale, opacity: appearance.hintOpacity)
                                    // Hang below the button with the arrow tip just inside its bottom edge.
                                    .offset(y: 19 * appearance.hintSize.scale - 3)
                            }
                        }
                        .opacity(matched ? 1 : 0.35)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 30)
        .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

/// The Click label as drawn on screen: a yellow pill whose arrow tip marks the exact click point.
struct LabelChipPreview: View {
    let label: String
    let typed: Int
    let scale: Double
    let opacity: Double

    static let gradient = LinearGradient(
        colors: [Color(red: 255 / 255, green: 247 / 255, blue: 180 / 255),
                 Color(red: 250 / 255, green: 241 / 255, blue: 146 / 255),
                 Color(red: 252 / 255, green: 227 / 255, blue: 106 / 255)],
        startPoint: .top, endPoint: .bottom)

    var body: some View {
        let text = Text(String(label.prefix(typed)).uppercased()).foregroundStyle(.black.opacity(0.3))
            + Text(String(label.dropFirst(typed)).uppercased()).foregroundStyle(.black)
        text
            .font(.system(size: 10 * scale, weight: .heavy))
            .kerning(0.3 * scale)
            .padding(.horizontal, 4.25 * scale)
            .frame(minWidth: 17 * scale, minHeight: 15.5 * scale)
            .padding(.top, 3.5 * scale)
            .background(CalloutShape(tail: 3.5 * scale, radius: 4 * scale).fill(Self.gradient).opacity(opacity))
            .overlay(CalloutShape(tail: 3.5 * scale, radius: 4 * scale).stroke(Color.black.opacity(0.6), lineWidth: 1))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Rounded rectangle with a centred upward arrow, the shape of a Click label hanging below its control.
struct CalloutShape: Shape {
    let tail: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // One continuous outline, so the stroke does not cross the arrow's base.
        let body = CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        let half = tail * 0.8
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.midX - half, y: body.minY))
        path.addLine(to: CGPoint(x: body.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: body.midX + half, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

struct AppIconView: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "app.dashed").frame(width: 24, height: 24)
        }
    }
}
