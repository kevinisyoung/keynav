import AppKit
import Carbon.HIToolbox
import KeyNavCore
import SwiftUI

/// A nonactivating, click-through panel. It never takes focus from the target app and is never key.
@MainActor
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        // Overlays are not part of any app's accessibility content and must not be discovered as targets.
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Converts CoreGraphics global points (top-left origin) to AppKit screen points (bottom-left origin).
@MainActor
enum ScreenSpace {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func appKitRect(fromGlobal rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitPoint(fromGlobal point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func screen(containingGlobal point: CGPoint) -> NSScreen? {
        let p = appKitPoint(fromGlobal: point)
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}

// MARK: - SwiftUI overlay content

/// State shared by the small overlay views.
@MainActor
@Observable
final class OverlayModel {
    var badgeTitle = "Moving"
    var badgeDetail: String?
    var badgeDragging = false
    var badgeScale = 1.0

    var hudTitle = "Clicking"
    var hudApp = ""
    var hudLine = ""
    var hudQuery: String?
    var hudCount = 0
    var hudAction: String?
    var hudMessage: String?

    var helpRows: [(group: String, rows: [(action: String, keys: String)])] = []
    var helpEntry = ""
    var helpExit = ""
}

struct BadgeView: View {
    let model: OverlayModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.badgeDragging ? Color.orange : Color.green)
                .frame(width: 7 * model.badgeScale, height: 7 * model.badgeScale)
            Text(model.badgeTitle).fontWeight(.semibold)
            if let detail = model.badgeDetail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5 * model.badgeScale))
        .padding(.horizontal, 9 * model.badgeScale)
        .padding(.vertical, 4.5 * model.badgeScale)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

struct ClickHUDView: View {
    let model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.hudTitle)
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                Text(model.hudApp).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 12)
                if let action = model.hudAction {
                    Text(action)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                }
                Text("\(model.hudCount) targets").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let query = model.hudQuery {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(query.isEmpty ? "Type to search" : query)
                        .foregroundStyle(query.isEmpty ? .secondary : .primary)
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 14)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let message = model.hudMessage {
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.hudLine).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
    }
}

struct HelpView: View {
    let model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Moving keys").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("? hides this · \(model.helpExit) exits").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                ForEach(Array(model.helpRows.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.group.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(row.action).font(.system(size: 12)).frame(width: 110, alignment: .leading)
                                Text(row.keys).font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// Hosts a SwiftUI view in a click-through overlay panel sized to fit its content.
@MainActor
final class HostedOverlay<Content: View> {
    let panel: OverlayPanel
    private let host: NSHostingView<Content>

    init(_ content: Content) {
        host = NSHostingView(rootView: content)
        panel = OverlayPanel(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        panel.contentView = host
    }

    var size: NSSize { host.fittingSize }

    func show(at origin: NSPoint) {
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - Hint labels

/// Draws all labels of one screen in a single view: yellow callouts whose tail points at the control.
@MainActor
final class HintCanvas: NSView {
    struct Chip {
        var text: String
        var typed: Int
        /// The callout body, without its tail.
        var rect: NSRect
        /// Where the tail points (the control), in view coordinates.
        var anchor: NSPoint
        var selected: Bool
        /// The body had to move away from its control to avoid overlap; draw a connector instead of a tail.
        var offset: Bool
        /// The arrow points up: the label hangs below the control (the usual case).
        var tailUp: Bool
    }

    var chips: [Chip] = []
    var highlight: NSRect?
    var fontSize: CGFloat = 11
    var opacity: CGFloat = 1

    override var isFlipped: Bool { false }

    // Sampled from Homerow's labels: pale yellow at the top, warmer at the bottom, a translucent dark rim.
    static let gradientColors = [
        NSColor(srgbRed: 255 / 255, green: 247 / 255, blue: 180 / 255, alpha: 1),
        NSColor(srgbRed: 250 / 255, green: 241 / 255, blue: 146 / 255, alpha: 1),
        NSColor(srgbRed: 252 / 255, green: 227 / 255, blue: 106 / 255, alpha: 1)
    ]
    static let outline = NSColor(white: 0, alpha: 0.6)
    /// Arrow height and half-width, and corner radius, at the regular size.
    static let tailHeight: CGFloat = 3.5
    static let tailHalfWidth: CGFloat = 2.75
    static let cornerRadius: CGFloat = 4

    static func attributedLabel(_ text: String, typed: Int, fontSize: CGFloat) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text.uppercased(), attributes: [
            // Homerow's letters are a touch smaller than the label size, leaving more room around them.
            .font: NSFont.systemFont(ofSize: fontSize * 0.95, weight: .heavy),
            .foregroundColor: NSColor.black,
            .kern: 0.3 * fontSize / 10.5
        ])
        if typed > 0 {
            // Letters already typed fade, so the next one to press stands out.
            string.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.3),
                                range: NSRange(location: 0, length: min(typed, string.length)))
        }
        return string
    }

    /// Body size for a label at `fontSize`: 15.5 pt tall with about 4 pt each side at the regular 10.5 pt size.
    static func bodySize(_ text: String, fontSize: CGFloat) -> NSSize {
        let scale = fontSize / 10.5
        let textWidth = attributedLabel(text, typed: 0, fontSize: fontSize).size().width
        return NSSize(width: max(17 * scale, (textWidth + 8.5 * scale).rounded()), height: 15.5 * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let highlight {
            let path = NSBezierPath(roundedRect: highlight.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5)
            path.lineWidth = 2.5
            NSColor.systemBlue.setStroke()
            path.stroke()
        }
        let scale = fontSize / 10.5
        let gradient = NSGradient(colors: Self.gradientColors.map { $0.withAlphaComponent(opacity) },
                                  atLocations: [0, 0.5, 1], colorSpace: .sRGB)
        for chip in chips {
            let path = Self.callout(chip.rect, tail: chip.offset ? nil : chip.anchor, tailUp: chip.tailUp, scale: scale)
            gradient?.draw(in: path, angle: -90)
            path.lineWidth = chip.selected ? 2 : 1
            (chip.selected ? NSColor.black : Self.outline).setStroke()
            path.stroke()

            let text = Self.attributedLabel(chip.text, typed: chip.typed, fontSize: fontSize)
            let size = text.size()
            text.draw(at: NSPoint(x: (chip.rect.midX - size.width / 2).rounded(), y: chip.rect.midY - size.height / 2 + 0.25 * scale))
        }
    }

    /// A rounded rectangle with an optional small arrow on its edge, pointing straight at `tail`. When the body
    /// was nudged sideways, the arrow stays on the body at the point nearest the control.
    static func callout(_ body: NSRect, tail: NSPoint?, tailUp: Bool, scale: CGFloat) -> NSBezierPath {
        let r = cornerRadius * scale
        let half = tailHalfWidth * scale
        let path = NSBezierPath()
        let minX = body.minX, maxX = body.maxX, minY = body.minY, maxY = body.maxY
        let tipX = tail.map { min(max($0.x, minX + r + half), maxX - r - half) } ?? body.midX
        path.move(to: NSPoint(x: minX + r, y: maxY))
        if let tail, tailUp {
            path.line(to: NSPoint(x: tipX - half, y: maxY))
            path.line(to: NSPoint(x: tipX, y: tail.y))
            path.line(to: NSPoint(x: tipX + half, y: maxY))
        }
        path.line(to: NSPoint(x: maxX - r, y: maxY))
        path.curve(to: NSPoint(x: maxX, y: maxY - r), controlPoint1: NSPoint(x: maxX, y: maxY), controlPoint2: NSPoint(x: maxX, y: maxY))
        path.line(to: NSPoint(x: maxX, y: minY + r))
        path.curve(to: NSPoint(x: maxX - r, y: minY), controlPoint1: NSPoint(x: maxX, y: minY), controlPoint2: NSPoint(x: maxX, y: minY))
        if let tail, !tailUp {
            path.line(to: NSPoint(x: tipX + half, y: minY))
            path.line(to: NSPoint(x: tipX, y: tail.y))
            path.line(to: NSPoint(x: tipX - half, y: minY))
        }
        path.line(to: NSPoint(x: minX + r, y: minY))
        path.curve(to: NSPoint(x: minX, y: minY + r), controlPoint1: NSPoint(x: minX, y: minY), controlPoint2: NSPoint(x: minX, y: minY))
        path.line(to: NSPoint(x: minX, y: maxY - r))
        path.curve(to: NSPoint(x: minX + r, y: maxY), controlPoint1: NSPoint(x: minX, y: maxY), controlPoint2: NSPoint(x: minX, y: maxY))
        path.close()
        return path
    }
}

@MainActor
final class HintOverlay {
    private var panels: [OverlayPanel] = []

    struct Item {
        var label: String
        var typed: Int
        var frame: HintTarget.Frame
        var selected: Bool
    }

    func render(_ items: [Item], highlight: HintTarget.Frame?, appearance: AppearanceSettings) {
        ensurePanels()
        let fontSize = 10.5 * appearance.hintSize.scale
        for panel in panels {
            guard let canvas = panel.contentView as? HintCanvas else { continue }
            canvas.fontSize = fontSize
            canvas.opacity = min(max(appearance.hintOpacity, 0.6), 1)
            canvas.chips = layout(items, in: panel.frame, fontSize: fontSize)
            canvas.highlight = highlight.flatMap { frame in
                let rect = ScreenSpace.appKitRect(fromGlobal: frame.rect)
                return panel.frame.intersects(rect) ? rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY) : nil
            }
            canvas.needsDisplay = true
            panel.orderFrontRegardless()
        }
    }

    /// Each callout hangs just below its control, its arrow touching the click point, like Homerow's. At the
    /// bottom of a display (the Dock) the body stays on screen and overlaps the control. Overlapping callouts
    /// slide sideways into a row, keeping their arrows; only a crowded spot stacks a callout below without one.
    private func layout(_ items: [Item], in screenFrame: NSRect, fontSize: CGFloat) -> [HintCanvas.Chip] {
        let scale = fontSize / 10.5
        let tail = HintCanvas.tailHeight * scale
        let gap: CGFloat = 1
        var placed: [NSRect] = []
        var chips: [HintCanvas.Chip] = []
        let displays = DisplayGeometry.activeBounds()
        for item in items {
            let target = ScreenSpace.appKitRect(fromGlobal: item.frame.rect)
            guard screenFrame.intersects(target) else { continue }
            let size = HintCanvas.bodySize(item.label, fontSize: fontSize)
            // The tail tip is exactly where a pointer action on this target lands (ClickPoint).
            let click = ClickPoint.of(item.frame.rect, displays: displays, scale: scale)
            let tip = ScreenSpace.appKitPoint(fromGlobal: click.point)
            let anchor = NSPoint(x: tip.x - screenFrame.minX, y: tip.y - screenFrame.minY)
            var base = NSRect(x: (anchor.x - size.width / 2).rounded(), y: (anchor.y - tail - size.height).rounded(),
                              width: size.width, height: size.height)
            base.origin.x = min(max(base.minX, 1), screenFrame.width - size.width - 1)
            let free = { (candidate: NSRect) in !placed.contains { $0.insetBy(dx: -gap, dy: -gap).intersects(candidate) } }
            var chosen = base
            var arrow = true
            if !free(base) {
                let sideways = (1...4).flatMap { step -> [NSRect] in
                    let dx = CGFloat(step) * (size.width + gap)
                    return [base.offsetBy(dx: dx, dy: 0), base.offsetBy(dx: -dx, dy: 0)]
                }
                if let slid = sideways.first(where: free) {
                    chosen = slid
                } else {
                    chosen = (1...3).map { base.offsetBy(dx: 0, dy: -CGFloat($0) * (size.height + gap)) }.first(where: free) ?? base
                    arrow = chosen == base
                }
            }
            placed.append(chosen)
            chips.append(HintCanvas.Chip(text: item.label, typed: item.typed, rect: chosen, anchor: anchor,
                                         selected: item.selected, offset: !arrow, tailUp: true))
        }
        return chips
    }

    private func ensurePanels() {
        let frames = NSScreen.screens.map(\.frame)
        if panels.map(\.frame) == frames { return }
        clear()
        panels = frames.map { frame in
            let panel = OverlayPanel(frame: frame)
            panel.contentView = HintCanvas(frame: NSRect(origin: .zero, size: frame.size))
            return panel
        }
    }

    func clear() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

// MARK: - Search progress

/// A thin bar along the very bottom of the screen while Label-click mode searches a window for targets.
/// Progress is measured against the search's time budget; it completes when labels are ready.
@MainActor
final class ScanProgressBar {
    private let panel = OverlayPanel(frame: .zero)
    private let fill = NSView()
    private var timer: Timer?
    private var started = Date()
    private var budget: Double = 0.8
    private let height: CGFloat = 3

    init() {
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        track.addSubview(fill)
        panel.contentView = track
        panel.level = .statusBar
    }

    func start(on screen: NSScreen, budget: Double) {
        self.budget = budget
        started = Date()
        panel.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height), display: false)
        panel.alphaValue = 1
        setProgress(0.04)
        panel.orderFrontRegardless()
        timer?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setProgress(0.5)
            return
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Fills to the end, then fades away.
    func finish() {
        timer?.invalidate()
        timer = nil
        guard panel.isVisible else { return }
        setProgress(1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func advance() {
        // Eases toward 90% of the bar over the time budget; never claims completion early.
        let t = Date().timeIntervalSince(started) / max(budget, 0.1)
        setProgress(0.04 + 0.86 * (1 - exp(-3 * t)))
    }

    private func setProgress(_ value: Double) {
        guard let width = panel.contentView?.bounds.width else { return }
        fill.frame = NSRect(x: 0, y: 0, width: width * CGFloat(min(max(value, 0), 1)), height: height)
    }
}

// MARK: - Style check

public enum LabelSample {
    /// PNG of sample labels hanging below grey control boxes at 2x, for comparing the label style by eye.
    @MainActor
    public static func png(labels: [String] = ["AA", "AD", "AF", "SG", "SH", "AS", "G", "WW"]) -> Data? {
        let size = NSSize(width: 40 + CGFloat(labels.count) * 34, height: 60)
        let canvas = HintCanvas(frame: NSRect(origin: .zero, size: size))
        let scale: CGFloat = 1
        var chips: [HintCanvas.Chip] = []
        var x: CGFloat = 20
        for label in labels {
            let body = HintCanvas.bodySize(label, fontSize: 10.5)
            let anchor = NSPoint(x: x + 12, y: 40)
            chips.append(HintCanvas.Chip(text: label, typed: 0,
                                         rect: NSRect(x: (anchor.x - body.width / 2).rounded(), y: anchor.y - HintCanvas.tailHeight * scale - body.height,
                                                      width: body.width, height: body.height),
                                         anchor: anchor, selected: false, offset: false, tailUp: true))
            x += 34
        }
        canvas.chips = chips
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.7, alpha: 1).setFill()
        for chip in chips { NSRect(x: chip.anchor.x - 10, y: chip.anchor.y - 3, width: 20, height: 16).fill() }
        canvas.draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Pointer dot

/// While Scroll mode holds the pointer still, the arrow is hidden and this small dot marks where it rests.
@MainActor
final class PointerDot {
    private let size: CGFloat = 8
    private lazy var panel: OverlayPanel = {
        let panel = OverlayPanel(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = DotView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        return panel
    }()
    private var cursorHidden = false

    func show(atGlobal point: CGPoint) {
        let center = ScreenSpace.appKitPoint(fromGlobal: point)
        panel.setFrameOrigin(NSPoint(x: center.x - size / 2, y: center.y - size / 2))
        panel.orderFrontRegardless()
        if cursorHidden {
            // macOS shows a background app's hidden cursor again once the pointer moves, KeyNav's own moves
            // included (parking, the hover nudge): hide it once more, keeping one hide outstanding.
            CGDisplayShowCursor(CGMainDisplayID())
        } else {
            PointerVisibility.allowHidingInBackground()
            cursorHidden = true
        }
        CGDisplayHideCursor(CGMainDisplayID())
    }

    /// Brings the arrow back. Safe to call repeatedly.
    func hide() {
        panel.orderOut(nil)
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
    }

    private final class DotView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
            NSColor.white.setFill()
            ring.fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).fill()
        }
    }
}

/// After a label click the arrow would sit on the next label; it stays hidden until the mouse moves.
///
/// macOS shows a background app's hidden cursor again when the pointer moves (KeyNav's own click included) or
/// another app comes forward, so the hide is applied again just after the click and on every app switch.
@MainActor
final class PointerHider {
    private var hidden = false
    private var activation: NSObjectProtocol?

    func hide() {
        PointerVisibility.allowHidingInBackground()
        if hidden {
            reassert()
        } else {
            CGDisplayHideCursor(CGMainDisplayID())
            hidden = true
        }
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reassert() }
        }
        activation = activation ?? NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert() }
        }
    }

    /// Brings the arrow back. Safe to call repeatedly.
    func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    /// Hides it again while it should be hidden, keeping one hide outstanding.
    private func reassert() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        CGDisplayHideCursor(CGMainDisplayID())
    }
}

// MARK: - Scroll area outlines

/// Scroll mode's panes: the one being scrolled outlined in blue, and every Tab stop numbered so its number key
/// jumps there. Only the current pane is outlined; more outlines would clutter the window.
@MainActor
final class ScrollOutline {
    private var panels: [OverlayPanel] = []

    /// `areas` are the numbered stops (up to nine); `current` is the pane being scrolled, which may be one of them.
    /// `coversWindow` says `current` is the whole window rather than a pane. `fade` eases an outline that moved in at
    /// its new place, so a correction doesn't jump.
    func show(current: CGRect?, areas: [CGRect], currentIndex: Int?, coversWindow: Bool = false, fade: Bool = false) {
        var outlines = areas.prefix(9).enumerated().map { (rect: $1, number: $0 + 1, active: $0 == currentIndex) }
        // Another area's number would float over the content being scrolled; those stay hidden (their keys still work).
        if let current, !coversWindow {
            outlines.removeAll { !$0.active && current.contains(CGPoint(x: $0.rect.minX + 19, y: $0.rect.minY + 19)) }
        }
        if currentIndex == nil, let current { outlines.append((current, 0, true)) }
        while panels.count < outlines.count {
            let panel = OverlayPanel(frame: .zero)
            panel.contentView = OutlineView()
            panels.append(panel)
        }
        for (panel, outline) in zip(panels, outlines) {
            guard let view = panel.contentView as? OutlineView else { continue }
            view.number = outline.number
            view.active = outline.active
            let frame = ScreenSpace.appKitRect(fromGlobal: outline.rect)
            // An outline already showing in place stays as it is; only a new or moved one fades in.
            // A first outline shows at once; one that moves from where it was fades in at its new place.
            let moved = panel.isVisible && panel.frame != frame
            panel.setFrame(frame, display: true)
            view.needsDisplay = true
            if moved || !fade || !panel.isVisible { panel.alphaValue = fade && moved ? 0 : 1 }
            panel.orderFrontRegardless()
            if fade && moved {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 1
                }
            }
        }
        for panel in panels.dropFirst(outlines.count) { panel.orderOut(nil) }
    }

    func hide() {
        for panel in panels { panel.orderOut(nil) }
    }

    private final class OutlineView: NSView {
        /// 0 for a pane without a number.
        var number = 0
        var active = false

        override func draw(_ dirtyRect: NSRect) {
            let blue = NSColor.systemBlue
            if active {
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
                path.lineWidth = 2
                blue.withAlphaComponent(0.45).setStroke()
                path.stroke()
            }
            guard number > 0 else { return }
            let badge = NSRect(x: 8, y: bounds.maxY - 30, width: 22, height: 22)
            blue.withAlphaComponent(active ? 1 : 0.7).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
            let text = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }
    }
}

/// macOS hides the pointer only for the app in front unless the connection opts in to hiding it from the
/// background. The switch is a private CoreGraphics property, looked up at run time; without it the arrow
/// simply stays visible next to the dot.
enum PointerVisibility {
    nonisolated(unsafe) private static var enabled = false

    static func allowHidingInBackground() {
        guard !enabled else { return }
        enabled = true
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        _ = unsafeBitCast(setSymbol, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

// MARK: - Keys behind a password field

/// While a password field holds Secure Input, macOS hides keys from the event tap but still delivers them to the
/// key window. This invisible panel becomes key without activating KeyNav (the app in front stays in front), so a
/// mode can read its keys; when it closes, the keyboard goes back to the field.
@MainActor
final class KeyCatcher {
    private let handle: (CGEventType, CGEvent) -> Void
    private lazy var panel: CatcherPanel = {
        let panel = CatcherPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityElement(false)
        let view = CatcherView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.handle = { [weak self] event in self?.forward(event) }
        panel.contentView = view
        return panel
    }()

    init(handle: @escaping (CGEventType, CGEvent) -> Void) {
        self.handle = handle
    }

    var isActive: Bool { panel.isVisible }

    func begin() {
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(panel.contentView)
    }

    func end() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func forward(_ event: NSEvent) {
        // Once the field lets go, the tap sees keys again and has already handled this one.
        guard IsSecureEventInputEnabled(), let cgEvent = event.cgEvent else { return }
        switch event.type {
        case .keyDown: handle(.keyDown, cgEvent)
        case .keyUp: handle(.keyUp, cgEvent)
        case .flagsChanged: handle(.flagsChanged, cgEvent)
        default: break
        }
    }

    private final class CatcherPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private final class CatcherView: NSView {
        var handle: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { handle?(event) }
        override func keyUp(with event: NSEvent) { handle?(event) }
        override func flagsChanged(with event: NSEvent) { handle?(event) }
        // Shortcuts like Command Shift J come through here first; take them so nothing beeps.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handle?(event)
            return true
        }
    }
}
