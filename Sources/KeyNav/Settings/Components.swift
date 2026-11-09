import KeyNavCore
import KeyNavSystem
import SwiftUI

/// A System Settings–style icon tile.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension SettingsPage {
    var symbol: String {
        switch self {
        case .cursor: return "cursorarrow.motionlines"
        case .click: return "hand.point.up.left.fill"
        case .scroll: return "scroll.fill"
        case .general: return "gearshape.fill"
        case .license: return "key.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .cursor: return .indigo
        case .click: return .teal
        case .scroll: return .mint
        case .general: return .gray
        case .license: return .orange
        case .about: return .blue
        }
    }
}

extension InteractionMode {
    var title: String {
        switch self {
        case .off: return "Typing"
        case .cursor: return "Moving"
        case .click: return "Clicking"
        case .scroll: return "Scrolling"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "keyboard"
        case .cursor: return "cursorarrow.motionlines"
        case .click: return "hand.point.up.left.fill"
        case .scroll: return "scroll.fill"
        }
    }

    var tint: Color {
        switch self {
        case .off: return .secondary
        case .cursor: return .indigo
        case .click: return .teal
        case .scroll: return .mint
        }
    }
}

/// A row that the Settings search can jump to. The row flashes when it was the search result.
struct SearchAnchor: ViewModifier {
    @Environment(AppModel.self) private var model
    let id: String

    func body(content: Content) -> some View {
        content
            .id(id)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(model.highlightedSetting == id ? 0.16 : 0))
                    .padding(-6)
            )
            .animation(.easeInOut(duration: 0.3), value: model.highlightedSetting)
    }
}

extension View {
    func searchAnchor(_ id: String) -> some View {
        modifier(SearchAnchor(id: id))
    }
}

/// A slider with an editable numeric field and a unit, so every value has a keyboard path.
struct NumberSlider: View {
    let title: String
    let detail: String?
    let unit: String
    let range: ClosedRange<Double>
    var step: Double? = nil
    let value: Double
    let onChange: (Double) -> Void

    private var format: FloatingPointFormatStyle<Double> {
        range.upperBound <= 10 ? .number.precision(.fractionLength(0...2)) : .number.precision(.fractionLength(0))
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { onChange(clamp(rounded($0))) }), in: range)
                    .labelsHidden()
                    .frame(minWidth: 140, maxWidth: 320)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(value.formatted(format)) \(unit)")
                TextField(title, value: Binding(get: { value }, set: { onChange(clamp($0)) }), format: format)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
    private func rounded(_ v: Double) -> Double {
        if let step { return (v / step).rounded() * step }
        return range.upperBound <= 10 ? (v * 100).rounded() / 100 : v.rounded()
    }
}

/// A plain-language status line with a colored symbol; the meaning never depends on color alone.
struct StatusLine: View {
    let ok: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Inline problem list with optional resolution actions.
struct ProblemList: View {
    let problems: [String]

    var body: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One setting: a name, one line saying what it does, and its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        LabeledContent {
            control
        } label: {
            SettingLabel(title: title, detail: detail)
        }
    }
}

struct SettingLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A switch with a one-line explanation.
struct SettingToggle: View {
    @Environment(AppModel.self) private var model
    let title: String
    let detail: String
    let keyPath: WritableKeyPath<KeyNavConfig, Bool>

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.config[keyPath: keyPath] },
            set: { value in model.update("\(title) \(value ? "on" : "off")") { $0[keyPath: keyPath] = value } }
        )) {
            SettingLabel(title: title, detail: detail)
        }
    }
}
