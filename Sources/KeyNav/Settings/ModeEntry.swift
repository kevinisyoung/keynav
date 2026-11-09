import KeyNavCore
import KeyNavSystem
import SwiftUI

/// Shown only when the running app cannot take the keyboard.
struct AccessCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let secure = model.navigation.readiness.secureInputActive
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title(secure)
                Spacer(minLength: 12)
                if !secure { buttons }
            }
            VStack(alignment: .leading, spacing: 12) {
                title(secure)
                if !secure { HStack { buttons } }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.3)))
        .searchAnchor("diagnostics.readiness")
    }

    private func title(_ secure: Bool) -> some View {
        Label {
            Text(secure ? "\(model.navigation.readiness.secureInputApp ?? "Another app") has a password field active"
                        : "KeyNav needs Accessibility access")
                .font(.headline)
                .fixedSize()
        } icon: {
            Image(systemName: secure ? "lock.fill" : "hand.raised.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Open Settings") { Permissions.openAccessibilitySettings() }
            .buttonStyle(.borderedProminent)
        Button("Check Again") { model.navigation.recheckReadiness() }
    }
}

/// The top of each mode's page: the keys that start and stop it, then a looping picture of what it does.
struct EntrySection: View {
    @Environment(AppModel.self) private var model
    let mode: InteractionMode

    private var entry: EntryConfig {
        model.config.entry(for: mode) ?? KeyNavConfig.default.cursorEntry
    }

    private var defaultEntry: EntryConfig {
        KeyNavConfig.default.entry(for: mode) ?? KeyNavConfig.default.cursorEntry
    }

    private func change(_ summary: String, _ edit: @escaping (inout EntryConfig) -> Void) -> [String] {
        model.update(summary) { config in
            var updated = entry
            edit(&updated)
            config.setEntry(updated, for: mode)
        }
    }

    /// Up, left, down, right, and click keys as the person has them bound, for the Cursor preview.
    private var previewKeys: ModePreview.Keys {
        func key(_ action: CursorAction, _ fallback: String) -> String {
            guard let gesture = model.config.cursorBindings.first(where: { $0.action == action })?.gesture else { return fallback }
            let name = gesture.displayName
            return name.count <= 2 || name == "Space" ? name : (name == "Return" ? "↩" : String(name.prefix(1)))
        }
        return ModePreview.Keys(up: key(.moveUp, "I"), left: key(.moveLeft, "J"), down: key(.moveDown, "K"),
                                right: key(.moveRight, "L"), click: key(.leftClick, "Space"))
    }

    var body: some View {
        Section {
            if model.needsAccess {
                AccessCard()
            }
            LabeledContent {
                ShortcutField(
                    title: "\(mode.title) start",
                    gesture: entry.gesture,
                    kind: .entry,
                    defaultGesture: defaultEntry.gesture,
                    prominent: true,
                    onSave: { gesture in
                        guard let gesture else { return [] }
                        return change("\(mode.title) starts with \(gesture.displayName)") { $0.gesture = gesture }
                    }
                )
            } label: {
                Text("Start").font(.title3.weight(.semibold))
            }
            LabeledContent {
                if entry.separateExit {
                    ShortcutField(
                        title: "\(mode.title) stop",
                        gesture: entry.exit,
                        kind: .exit,
                        defaultGesture: defaultEntry.exit,
                        prominent: true,
                        onSave: { gesture in
                            guard let gesture else { return [] }
                            return change("\(mode.title) stops with \(gesture.displayName)") { $0.exit = gesture }
                        }
                    )
                } else {
                    Text("Same shortcut again").foregroundStyle(.secondary)
                }
            } label: {
                Text("Stop").font(.title3.weight(.semibold))
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mode == .click {
                // Real labels in the current letters and size.
                LabelsPreview(alphabet: LabelGenerator.usableAlphabet(model.config.clickAlphabet, reserved: []),
                              search: false, appearance: model.config.appearance)
            } else {
                ModePreview(mode: mode, keys: previewKeys)
                    .frame(height: 92)
            }
        }
        .searchAnchor(mode == .scroll ? "scroll.entry" : mode == .click ? "click.entry" : "cursor.entry")
    }

    private var warnings: [String] {
        let name = mode.name
        return ConfigValidator.warnings(in: model.config).filter { $0.contains(entry.gesture.displayName) || $0.contains(name) }
    }
}

/// A small looping picture of what the mode does, instead of a paragraph about it.
struct ModePreview: View {
    struct Keys {
        var up = "I", left = "J", down = "K", right = "L", click = "Space"
    }

    let mode: InteractionMode
    var keys = Keys()
    /// A fixed moment of the loop instead of the clock, for still renders.
    var time: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || time != nil)) { timeline in
            let t = time ?? (reduceMotion ? 0.5 : timeline.date.timeIntervalSinceReferenceDate)
            Canvas { context, size in
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10),
                             with: .color(mode.tint.opacity(0.07)))
                switch mode {
                case .cursor: drawCursor(context, size, t)
                case .scroll: drawScroll(context, size, t)
                default: drawClick(context, size, t)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The pointer travels a loop (right, down, left, up), easing in like the real ramp, then clicks.
    /// The key doing the work lights up on a small keyboard beside it.
    private func drawCursor(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        let cycle = 5.0
        let local = t.truncatingRemainder(dividingBy: cycle)
        let cap: CGFloat = 22
        let gap: CGFloat = 3
        let clickWidth: CGFloat = 40
        let pad: CGFloat = 14
        let keyboardWidth = cap * 3 + gap * 2 + gap * 2 + clickWidth
        let keyboardOrigin = CGPoint(x: size.width - pad - keyboardWidth, y: (size.height - (cap * 2 + gap)) / 2)

        // Pointer loop inside the space left of the keyboard.
        let area = CGRect(x: pad + 6, y: size.height * 0.22, width: max(keyboardOrigin.x - pad - 30, 40), height: size.height * 0.5)
        let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                       CGPoint(x: area.maxX, y: area.maxY), CGPoint(x: area.minX, y: area.maxY)]
        let segment = min(Int(local), 4)
        let pressed: String?
        var p: CGPoint
        if segment < 4 {
            let a = corners[segment]
            let b = corners[(segment + 1) % 4]
            let f = smoothRamp(min((local - Double(segment)) / 0.85, 1), duration: 1)
            p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            pressed = local - Double(segment) < 0.85 ? [keys.right, keys.down, keys.left, keys.up][segment] : nil
        } else {
            p = corners[0]
            pressed = local - 4 < 0.35 ? keys.click : nil
        }

        // Click ripple.
        if segment == 4 {
            let r = 4 + (local - 4) * 22
            let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(mode.tint.opacity(max(0.6 - (local - 4) * 0.6, 0))), lineWidth: 2)
        }
        context.draw(Image(systemName: "cursorarrow").resizable(), in: CGRect(x: p.x - 2, y: p.y - 2, width: 13, height: 18))

        func keycap(_ label: String, _ rect: CGRect) {
            let down = label == pressed
            let body = rect.offsetBy(dx: 0, dy: down ? 1 : 0)
            if !down {
                context.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 1.5), cornerRadius: 5), with: .color(.black.opacity(0.12)))
            }
            context.fill(Path(roundedRect: body, cornerRadius: 5),
                         with: .color(down ? mode.tint : Color(nsColor: .controlBackgroundColor)))
            context.stroke(Path(roundedRect: body, cornerRadius: 5),
                           with: .color(down ? mode.tint : Color.secondary.opacity(0.35)), lineWidth: 0.75)
            context.draw(Text(label).font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(down ? Color.white : Color.primary.opacity(0.75)),
                         at: CGPoint(x: body.midX, y: body.midY))
        }
        let o = keyboardOrigin
        keycap(keys.up, CGRect(x: o.x + cap + gap, y: o.y, width: cap, height: cap))
        keycap(keys.left, CGRect(x: o.x, y: o.y + cap + gap, width: cap, height: cap))
        keycap(keys.down, CGRect(x: o.x + cap + gap, y: o.y + cap + gap, width: cap, height: cap))
        keycap(keys.right, CGRect(x: o.x + (cap + gap) * 2, y: o.y + cap + gap, width: cap, height: cap))
        keycap(keys.click, CGRect(x: o.x + cap * 3 + gap * 4, y: o.y + cap + gap, width: clickWidth, height: cap))
    }

    /// A table pans under a small dot: H then L scroll it sideways, J then K up and down.
    private func drawScroll(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        let step = 1.2
        let local = t.truncatingRemainder(dividingBy: step * 4)
        let segment = Int(local / step)
        let held = local - Double(segment) * step
        // Each key is held for 1 s, then a short rest before the next.
        let f = CGFloat(smoothRamp(min(held, 1), duration: 1))
        let pressed: String? = held < 1 ? ["H", "L", "J", "K"][segment] : nil
        let reach: CGFloat = 30
        // Starts scrolled right, so H has somewhere to go.
        let offset: CGPoint
        switch segment {
        case 0: offset = CGPoint(x: reach * (1 - f), y: 0)
        case 1: offset = CGPoint(x: reach * f, y: 0)
        case 2: offset = CGPoint(x: reach, y: reach * f)
        default: offset = CGPoint(x: reach, y: reach * (1 - f))
        }

        let cap: CGFloat = 22
        let gap: CGFloat = 3
        let split: CGFloat = 8
        let pad: CGFloat = 14
        let keysWidth = cap * 4 + gap + split * 2
        let pane = CGRect(x: pad, y: 10, width: size.width - pad * 2 - keysWidth - 28, height: size.height - 20)
        context.fill(Path(roundedRect: pane, cornerRadius: 6), with: .color(Color(nsColor: .controlBackgroundColor)))
        var cells = context
        cells.clip(to: Path(roundedRect: pane, cornerRadius: 6))
        let columns = Int((pane.width + reach) / 60) + 2
        for row in 0..<11 {
            let y = pane.minY + 8 + CGFloat(row) * 11 - offset.y
            for column in 0..<columns {
                let x = pane.minX + 8 + CGFloat(column) * 60 - offset.x
                let width: CGFloat = (row + column) % 3 == 0 ? 26 : 42
                cells.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: 5), cornerRadius: 2.5),
                           with: .color(Color.secondary.opacity(row == 0 ? 0.35 : 0.22)))
            }
        }
        context.stroke(Path(roundedRect: pane, cornerRadius: 6), with: .color(Color.secondary.opacity(0.3)), lineWidth: 0.75)
        let dot = CGRect(x: pane.midX + pane.width * 0.15 - 4, y: pane.midY - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: dot), with: .color(.white))
        context.fill(Path(ellipseIn: dot.insetBy(dx: 1, dy: 1)), with: .color(.blue))
        func keycap(_ label: String, _ rect: CGRect) {
            let down = label == pressed
            let body = rect.offsetBy(dx: 0, dy: down ? 1 : 0)
            if !down {
                context.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 1.5), cornerRadius: 5), with: .color(.black.opacity(0.12)))
            }
            context.fill(Path(roundedRect: body, cornerRadius: 5), with: .color(down ? mode.tint : Color(nsColor: .controlBackgroundColor)))
            context.stroke(Path(roundedRect: body, cornerRadius: 5),
                           with: .color(down ? mode.tint : Color.secondary.opacity(0.35)), lineWidth: 0.75)
            context.draw(Text(label).font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(down ? Color.white : Color.primary.opacity(0.75)),
                         at: CGPoint(x: body.midX, y: body.midY))
        }
        // H, then J K together, then L: a little apart, the way the site shows them.
        var x = size.width - pad - keysWidth
        let y = (size.height - cap) / 2
        for (label, after) in [("H", split), ("J", gap), ("K", split), ("L", 0)] {
            keycap(label, CGRect(x: x, y: y, width: cap, height: cap))
            x += cap + after
        }
    }

    /// Buttons get short labels; typing one lights that button up.
    private func drawClick(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        let phase = t.truncatingRemainder(dividingBy: 3) / 3
        let labels = ["A", "S", "D"]
        let gap = size.width * 0.05
        let width = (size.width * 0.8 - gap * 2) / 3
        for (index, label) in labels.enumerated() {
            let x = size.width * 0.1 + CGFloat(index) * (width + gap)
            let rect = CGRect(x: x, y: size.height * 0.2, width: width, height: 28)
            let chosen = index == 1 && phase > 0.6
            context.fill(Path(roundedRect: rect, cornerRadius: 6),
                         with: .color(chosen ? mode.tint.opacity(0.5) : Color.secondary.opacity(0.18)))
            guard phase > 0.15, phase < 0.62 else { continue }
            let typed = index == 1 && phase > 0.45
            let tip = CGPoint(x: rect.midX, y: rect.maxY - 3)
            let chip = CGRect(x: tip.x - 9, y: tip.y, width: 18, height: 21)
            let shape = CalloutShape(tail: 4, radius: 3).path(in: chip)
            context.fill(shape, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.98, blue: 0.77), Color(red: 0.99, green: 0.88, blue: 0.28)]),
                                                      startPoint: CGPoint(x: chip.midX, y: chip.minY), endPoint: CGPoint(x: chip.midX, y: chip.maxY)))
            context.stroke(shape, with: .color(Color(white: 0.4)), lineWidth: typed ? 1.5 : 0.75)
            context.draw(Text(label).font(.system(size: 10, weight: .heavy)).foregroundStyle(.black.opacity(typed ? 0.3 : 1)),
                         at: CGPoint(x: chip.midX, y: chip.minY + 12.5))
        }
    }
}
