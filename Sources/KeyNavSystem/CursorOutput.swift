import CoreGraphics
import Foundation
import KeyNavCore

/// Posts pointer, button, and scroll events. Every event carries `KeyNav.marker` so the tap ignores its own output.
@MainActor
public final class CursorOutput {
    public static let marker: Int64 = 0x4B4E_4156

    /// Whether the person's confine preference keeps the pointer on its current display.
    public var confineToCurrentDisplay = false

    private let source = CGEventSource(stateID: .combinedSessionState)
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private var buttonsDown: Set<MouseButton> = []

    public init() {}

    public var isLeftDown: Bool { buttonsDown.contains(.left) }

    public func location() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Executes one command. Returns false when the system refused to create or post the event.
    @discardableResult
    public func perform(_ command: CursorCommand) -> Bool {
        switch command {
        case let .move(dx, dy):
            return move(dx: dx, dy: dy)
        case let .scroll(dx, dy):
            return scroll(dx: dx, dy: dy)
        case let .press(button):
            buttonsDown.insert(button)
            return post(mouse: button, down: true, at: location(), clickCount: 1)
        case let .release(button):
            buttonsDown.remove(button)
            return post(mouse: button, down: false, at: location(), clickCount: 1)
        case let .buttonDown(button, count):
            buttonsDown.insert(button)
            return post(mouse: button, down: true, at: location(), clickCount: count)
        case let .buttonUp(button, count):
            buttonsDown.remove(button)
            return post(mouse: button, down: false, at: location(), clickCount: count)
        case let .click(button, count):
            let point = location()
            let down = post(mouse: button, down: true, at: point, clickCount: count)
            let up = post(mouse: button, down: false, at: point, clickCount: count)
            return down && up
        }
    }

    /// A move while a button is held is a drag of that button.
    private var moveType: (CGEventType, CGMouseButton) {
        if buttonsDown.contains(.left) { return (.leftMouseDragged, .left) }
        if buttonsDown.contains(.right) { return (.rightMouseDragged, .right) }
        if buttonsDown.contains(.middle) { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    /// Moves the pointer to an absolute global point (used for Click-mode pointer actions).
    @discardableResult
    public func move(to point: CGPoint) -> Bool {
        let (type, button) = moveType
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return false
        }
        tag(event)
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Moves the pointer one point and back, so the app under it updates its hover state for whatever has
    /// scrolled beneath it (a Notion table only scrolls sideways once hovered).
    public func refreshHover() {
        let point = location()
        move(to: CGPoint(x: point.x + 1, y: point.y))
        move(to: point)
    }

    /// Moves to `point` and clicks there. Only used on a target frame that was just revalidated.
    @discardableResult
    public func click(at point: CGPoint, button: MouseButton, count: Int) -> Bool {
        guard move(to: point) else { return false }
        var ok = true
        for index in 1...max(count, 1) {
            ok = post(mouse: button, down: true, at: point, clickCount: index) && ok
            ok = post(mouse: button, down: false, at: point, clickCount: index) && ok
        }
        return ok
    }

    /// Releases every button KeyNav pressed. Part of every stop path; safe to repeat.
    public func releaseAll() {
        for button in buttonsDown {
            _ = post(mouse: button, down: false, at: location(), clickCount: 1)
        }
        buttonsDown.removeAll()
        scrollRemainderX = 0
        scrollRemainderY = 0
    }

    private func move(dx: Double, dy: Double) -> Bool {
        let current = location()
        let target = CGPoint(x: current.x + dx, y: current.y + dy)
        let bounds = DisplayGeometry.activeBounds()
        let confined = confineToCurrentDisplay ? bounds.first(where: { $0.contains(current) }) : nil
        let clamped = DisplayGeometry.clamp(target, confinedTo: confined, bounds: bounds)
        let (type, button) = moveType
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: clamped, mouseButton: button) else {
            return false
        }
        tag(event)
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Scrolls the area at `point` without moving the pointer, when the system routes by event location.
    @discardableResult
    public func scroll(dx: Double, dy: Double, at point: CGPoint) -> Bool {
        scroll(dx: dx, dy: dy, location: point)
    }

    private func scroll(dx: Double, dy: Double, location: CGPoint? = nil) -> Bool {
        // Pixel deltas are integers; keep the fraction so slow scrolling is not lost.
        scrollRemainderX += dx
        scrollRemainderY += dy
        let wholeX = scrollRemainderX.rounded(.towardZero)
        let wholeY = scrollRemainderY.rounded(.towardZero)
        scrollRemainderX -= wholeX
        scrollRemainderY -= wholeY
        guard wholeX != 0 || wholeY != 0 else { return true }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(wholeY),
            wheel2: Int32(wholeX),
            wheel3: 0
        ) else {
            return false
        }
        if let location { event.location = location }
        tag(event)
        event.post(tap: .cghidEventTap)
        return true
    }

    private func post(mouse button: MouseButton, down: Bool, at point: CGPoint, clickCount: Int) -> Bool {
        let (type, cgButton) = Self.eventType(for: button, down: down)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else {
            return false
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        tag(event)
        event.post(tap: .cghidEventTap)
        return true
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
    }

    static func eventType(for button: MouseButton, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left: return (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: return (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: return (down ? .otherMouseDown : .otherMouseUp, .center)
        case .back: return (down ? .otherMouseDown : .otherMouseUp, CGMouseButton(rawValue: 3) ?? .center)
        case .forward: return (down ? .otherMouseDown : .otherMouseUp, CGMouseButton(rawValue: 4) ?? .center)
        }
    }
}
