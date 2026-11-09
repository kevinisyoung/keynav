import Foundation

/// The state of one Scroll-mode session. Scrolling goes to whatever is under the pointer; the session only knows
/// the window in front (to place the pointer and size a jump) and which keys are held. Pure: time comes in
/// through `tick`, and the system layer moves the pointer and posts the scrolls.
///
/// Keys follow Homerow: H J K L scroll, and Shift with them jumps most of a window. Tab and Shift Tab move
/// between the window's scroll areas, and 1 to 9 jump to one by its number.
/// One element in the ancestry of a clicked or focused control: its Accessibility role and frame.
public struct ScrollNode: Equatable, Sendable {
    public var role: String
    public var frame: HintTarget.Frame

    public init(role: String, frame: HintTarget.Frame) {
        self.role = role
        self.frame = frame
    }
}

/// A point in global coordinates: where the pointer should go.
public struct ScrollPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScrollSession: Sendable {
    public enum Direction: Sendable {
        case up, down, left, right
    }

    public struct KeyResult: Equatable, Sendable {
        public var consumed: Bool
        public var commands: [CursorCommand] = []
        /// Where the pointer should go: the scroll area Tab moved to.
        public var park: ScrollPoint?
    }

    /// The window in front, once known; after moving to a scroll area, that area.
    public private(set) var window: HintTarget.Frame?
    /// The window's scroll areas in reading order, numbered from 1 on screen, and which one the pointer is in.
    public private(set) var areas: [HintTarget.Frame] = []
    public private(set) var areaIndex: Int?
    /// The pane outlined on screen as the one being scrolled; nil when that is just wherever the pointer is.
    public private(set) var outlined: HintTarget.Frame?
    /// The whole window in front, which `window` narrows to a pane.
    private var windowFrame: HintTarget.Frame?
    public var scrolling: ScrollProfile

    private var held: Set<Direction> = []
    private var heldCodes: [UInt16: Direction] = [:]
    private var elapsed = 0.0
    private var dashLeft = (dx: 0.0, dy: 0.0)
    private var dashSpeed = (dx: 0.0, dy: 0.0)

    /// How much of the window one jump covers, and how long it takes.
    static let dashFraction = 0.8
    static let dashSeconds = 0.16

    public init(scrolling: ScrollProfile = .standard) {
        self.scrolling = scrolling
    }

    /// Takes the window in front, the ancestry of the control last clicked (or scrolled) and of the focused
    /// control, the window's scroll areas, and the spot last scrolled at. Returns where the pointer should go:
    /// that spot, since it scrolled before; else the middle of the pane the click was in, else the one holding
    /// focus, else the largest scroll area, else the middle of the window. A jump then covers most of that pane.
    public mutating func setWindow(_ frame: HintTarget.Frame?, clickChain: [ScrollNode] = [],
                                   focusChain: [ScrollNode] = [], areas found: [HintTarget.Frame] = [],
                                   resume: (x: Double, y: Double)? = nil,
                                   pointer: (x: Double, y: Double)) -> (x: Double, y: Double)? {
        window = frame
        windowFrame = frame
        guard let frame else { return nil }
        areas = Self.tabStops(found, in: frame)
        // The largest area stands in for the pane only if the last click wasn't somewhere else (Messages' transcript
        // claims the whole window, so only its conversation list counts as an area).
        let clicked = clickChain.first?.frame.center
        let largest = areas.max { $0.width * $0.height < $1.width * $1.height }
            .flatMap { area in clicked.map { area.contains($0) } ?? true ? area : nil }
        let clickPane = Self.pane(in: clickChain, window: frame, webPanes: areas)
        if let pane = clickPane ?? Self.pane(in: focusChain, window: frame, webPanes: areas) ?? largest {
            window = pane
        }
        var park = window?.center ?? frame.center
        if let resume, frame.contains(resume) {
            window = clickPane ?? frame
            park = resume
        }
        // Tab continues from the area the pointer starts in.
        areaIndex = innermost(at: park)
        outlined = window == frame ? nil : window
        return park
    }

    /// The pane a control sits in, from its ancestry (innermost first), clipped to the window; nil when the
    /// control isn't in one, like a toolbar button.
    ///
    /// A native pane is the nearest scroll area. Web apps rarely mark theirs, so inside a page a pane is the
    /// outermost ancestor that is one of `webPanes`, the page's blocks found to scroll on their own (a sidebar, a
    /// column, a peek); a block that merely sits in a scrolling page (Google's AI Overview) is no pane. Scroll
    /// areas as big as the window say nothing about where the person is working.
    static func pane(in chain: [ScrollNode], window: HintTarget.Frame, webPanes: [HintTarget.Frame]) -> HintTarget.Frame? {
        let windowArea = window.width * window.height
        var webPane: HintTarget.Frame?
        for node in chain {
            switch node.role {
            case "AXWebArea":
                if let webPane { return webPane }
            case "AXScrollArea":
                if let visible = clip(node.frame, to: window, minimum: 80),
                   visible.width * visible.height < windowArea * 0.85 {
                    return visible
                }
            default:
                if let visible = paneShaped(node.frame, in: window), webPanes.contains(visible) { webPane = visible }
            }
        }
        return nil
    }

    /// The visible part of a web page element, if it is shaped like a pane: a column most of the window tall,
    /// reasonably wide, and short of the whole window (a sidebar, a message list). Cards, quoted posts, and
    /// widgets inside a page are smaller and scroll with it.
    public static func paneShaped(_ frame: HintTarget.Frame, in window: HintTarget.Frame) -> HintTarget.Frame? {
        guard let visible = clip(frame, to: window, minimum: 1),
              visible.height >= window.height * 0.7, visible.width >= 150,
              visible.width * visible.height < window.width * window.height * 0.85 else { return nil }
        return visible
    }

    /// The person moved the mouse to `point`: scrolling follows it, so the area under it becomes the current one.
    /// Outside every area the last one stays outlined.
    public mutating func pointerMoved(to point: (x: Double, y: Double)) {
        guard let index = innermost(at: point) else { return }
        areaIndex = index
        window = areas[index]
        outlined = areas[index]
    }

    /// The scroll areas read after Scroll started, or again after scrolling. A page's panes show themselves once
    /// content leaves their edge (Gmail's list, under the AI Overview), and an area that moved was part of what
    /// scrolled, so the outline goes to the area under the pointer now, or away if there is none.
    public mutating func areasMoved(_ found: [HintTarget.Frame], pointer point: (x: Double, y: Double)) {
        guard let windowFrame else { return }
        areas = Self.tabStops(found, in: windowFrame)
        if let index = innermost(at: point) {
            areaIndex = index
            window = areas[index]
            outlined = areas[index]
        } else {
            areaIndex = nil
            outlined = nil
            window = windowFrame
        }
    }

    /// The smallest area holding `point`: a pane rather than the column around it.
    private func innermost(at point: (x: Double, y: Double)) -> Int? {
        areas.indices.filter { areas[$0].contains(point) }.min { areas[$0].width * areas[$0].height < areas[$1].width * areas[$1].height }
    }

    /// Moves to the area at `index`, if there is one.
    private mutating func area(_ index: Int) -> ScrollPoint? {
        guard areas.indices.contains(index) else { return nil }
        areaIndex = index
        window = areas[index]
        outlined = areas[index]
        let center = areas[index].center
        return ScrollPoint(x: center.x, y: center.y)
    }

    /// Moves to the next scroll area (or the previous one), wrapping around.
    private mutating func nextArea(backward: Bool) -> ScrollPoint? {
        guard !areas.isEmpty else { return nil }
        let index: Int
        if let current = areaIndex {
            index = (current + (backward ? areas.count - 1 : 1)) % areas.count
        } else {
            index = backward ? areas.count - 1 : 0
        }
        return area(index)
    }

    /// The part of `area` inside `frame`, if at least `minimum` points each way.
    static func clip(_ area: HintTarget.Frame, to frame: HintTarget.Frame, minimum: Double) -> HintTarget.Frame? {
        let left = max(frame.x, area.x), top = max(frame.y, area.y)
        let right = min(frame.x + frame.width, area.x + area.width)
        let bottom = min(frame.y + frame.height, area.y + area.height)
        guard right - left >= minimum, bottom - top >= minimum else { return nil }
        return HintTarget.Frame(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The areas worth a Tab stop: on screen, not repeated, not a container whose panes already cover it (a web
    /// app's page around its sidebar and content), and not a section inside a column that is already a stop
    /// (one list within Slack's sidebar). Ordered left to right, then top to bottom.
    static func tabStops(_ found: [HintTarget.Frame], in frame: HintTarget.Frame) -> [HintTarget.Frame] {
        var visible: [HintTarget.Frame] = []
        for area in found.compactMap({ clip($0, to: frame, minimum: 80) }) {
            let repeated = visible.contains { abs($0.x - area.x) < 4 && abs($0.y - area.y) < 4
                && abs($0.width - area.width) < 4 && abs($0.height - area.height) < 4 }
            if !repeated { visible.append(area) }
        }
        // One column, read twice: a block that reaches the column's top or bottom is part of what the column
        // scrolls (a sidebar's first section, Gmail's list under the AI Overview), while one held between a header
        // and a footer is the part that scrolls (Slack's messages, between the channel name and the message box).
        var columns = visible
        for area in visible {
            for outer in visible where outer != area && outer.encloses(area) && abs(outer.width - area.width) < 8 {
                let sharesEdge = abs(outer.y - area.y) < 4 || abs(outer.y + outer.height - area.y - area.height) < 4
                columns.removeAll { $0 == (sharesEdge ? area : outer) }
            }
        }
        let stops = columns.filter { container in
            let inside = columns.filter { $0 != container && container.encloses($0) }
            let covered = inside.reduce(0) { $0 + $1.width * $1.height }
            return covered < container.width * container.height * 0.6
        }
        return stops.sorted { ($0.x / 40).rounded() != ($1.x / 40).rounded() ? $0.x < $1.x : $0.y < $1.y }
    }

    public var needsTicks: Bool {
        !held.isEmpty || dashLeft.dx != 0 || dashLeft.dy != 0
    }

    public mutating func keyDown(_ event: KeyEvent) -> KeyResult {
        let plain = event.modifiers.isDisjoint(with: [.command, .control, .option])
        if event.code == Key.tab, plain {
            return KeyResult(consumed: true, park: nextArea(backward: event.modifiers.contains(.shift)))
        }
        if let number = Key.digits.firstIndex(of: event.code), event.modifiers.isEmpty {
            return KeyResult(consumed: true, park: area(number))
        }
        if let direction = Self.direction(event.code), plain {
            if event.isRepeat { return KeyResult(consumed: true) }
            if event.modifiers.contains(.shift) {
                startDash(direction)
                return KeyResult(consumed: true)
            }
            if held.isEmpty { elapsed = 0 }
            held.insert(direction)
            heldCodes[event.code] = direction
            return KeyResult(consumed: true)
        }
        // Other typing keys are swallowed so they never type into the app underneath; shortcuts pass through.
        return KeyResult(consumed: event.typesCharacter && plain)
    }

    public mutating func keyUp(_ event: KeyEvent) -> KeyResult {
        // Released by key code, so Shift pressed or let go mid-scroll cannot strand a direction.
        guard let direction = heldCodes.removeValue(forKey: event.code) else {
            return KeyResult(consumed: Self.direction(event.code) != nil)
        }
        if !heldCodes.values.contains(direction) { held.remove(direction) }
        if held.isEmpty { elapsed = 0 }
        return KeyResult(consumed: true)
    }

    public mutating func tick(dt: Double) -> [CursorCommand] {
        guard dt > 0 else { return [] }
        var dx = 0.0
        var dy = 0.0
        if !held.isEmpty {
            elapsed += dt
            let speed = scrolling.maximumSpeed * (0.2 + 0.8 * smoothRamp(elapsed, duration: scrolling.rampSeconds)) * dt
            if held.contains(.up) { dy += speed }
            if held.contains(.down) { dy -= speed }
            if held.contains(.right) { dx += speed }
            if held.contains(.left) { dx -= speed }
        }
        dx += take(&dashLeft.dx, dashSpeed.dx * dt)
        dy += take(&dashLeft.dy, dashSpeed.dy * dt)
        guard dx != 0 || dy != 0 else { return [] }
        let sign = scrolling.reverse ? -1.0 : 1.0
        return [.scroll(dx: dx * sign, dy: dy * sign)]
    }

    /// Stops all scrolling.
    public mutating func reset() {
        held.removeAll()
        heldCodes.removeAll()
        elapsed = 0
        dashLeft = (0, 0)
    }

    // MARK: - Private

    private static func direction(_ code: UInt16) -> Direction? {
        switch code {
        case Key.h: return .left
        case Key.j: return .down
        case Key.k: return .up
        case Key.l: return .right
        default: return nil
        }
    }

    private mutating func startDash(_ direction: Direction) {
        let size = window ?? HintTarget.Frame(x: 0, y: 0, width: 800, height: 600)
        switch direction {
        case .up: dashLeft.dy += size.height * Self.dashFraction
        case .down: dashLeft.dy -= size.height * Self.dashFraction
        case .right: dashLeft.dx += size.width * Self.dashFraction
        case .left: dashLeft.dx -= size.width * Self.dashFraction
        }
        dashSpeed = (abs(dashLeft.dx) / Self.dashSeconds, abs(dashLeft.dy) / Self.dashSeconds)
    }

    /// Moves up to `amount` (always positive) of `remaining` toward zero and returns the signed part taken.
    private func take(_ remaining: inout Double, _ amount: Double) -> Double {
        guard remaining != 0 else { return 0 }
        let part = min(abs(remaining), max(amount, 1)) * (remaining > 0 ? 1 : -1)
        remaining -= part
        if abs(remaining) < 0.5 { remaining = 0 }
        return part
    }
}

extension HintTarget.Frame {
    public func contains(_ point: (x: Double, y: Double)) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }

    func encloses(_ other: HintTarget.Frame) -> Bool {
        other.x >= x - 1 && other.y >= y - 1 && other.x + other.width <= x + width + 1
            && other.y + other.height <= y + height + 1
    }
}
