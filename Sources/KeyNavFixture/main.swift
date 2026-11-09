import AppKit

// KeyNav Fixture: a controllable window for live tests. It records what it receives into a JSON state file,
// so tests check real outcomes (a button was pressed once, text arrived, a drag happened) instead of mocks.
//
//   KeyNavFixture --state /path/state.json [--canvas]
//
// Distributed notifications move or remove the "Moving target" button to create stale targets on purpose.

let arguments = CommandLine.arguments
func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
let statePath = argument(after: "--state")
let canvasOnly = arguments.contains("--canvas")

@MainActor
final class Recorder {
    static let shared = Recorder()
    var counter = 0
    var second = 0
    var moving = 0
    var checkbox = false
    var pad: [String: Double] = ["leftDown": 0, "leftUp": 0, "rightDown": 0, "otherDown": 0, "maxClickCount": 0, "dragDistance": 0]
    var scrollY = 0.0
    var scrollX = 0.0
    weak var window: NSWindow?
    var views: [String: NSView] = [:]
    var fields: [String: NSTextField] = [:]

    func frame(of view: NSView) -> [String: Double] {
        guard let window = view.window else { return [:] }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return ["x": rect.minX, "y": primary - rect.maxY, "width": rect.width, "height": rect.height]
    }

    func write() {
        guard let statePath else { return }
        var frames: [String: [String: Double]] = [:]
        for (name, view) in views { frames[name] = frame(of: view) }
        let state: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "canvas": canvasOnly,
            "counter": counter, "second": second, "moving": moving, "checkbox": checkbox,
            "name": fields["name"]?.stringValue ?? "",
            "typing": fields["typing"]?.stringValue ?? "",
            "pad": pad, "scrollY": scrollY, "scrollX": scrollX,
            "frames": frames,
            "active": NSApp.isActive
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }
}

final class PointerPad: NSView {
    private var lastDrag: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemIndigo.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSString(string: "Pointer pad").draw(at: NSPoint(x: 8, y: 8), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            let r = Recorder.shared
            r.pad["leftDown", default: 0] += 1
            r.pad["maxClickCount"] = max(r.pad["maxClickCount"] ?? 0, Double(event.clickCount))
            lastDrag = event.locationInWindow
            r.write()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            if let last = lastDrag {
                let d = hypot(event.locationInWindow.x - last.x, event.locationInWindow.y - last.y)
                Recorder.shared.pad["dragDistance", default: 0] += d
            }
            lastDrag = event.locationInWindow
            Recorder.shared.write()
        }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            Recorder.shared.pad["leftUp", default: 0] += 1
            lastDrag = nil
            Recorder.shared.write()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            Recorder.shared.pad["rightDown", default: 0] += 1
            Recorder.shared.write()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            Recorder.shared.pad["otherDown", default: 0] += 1
            Recorder.shared.write()
        }
    }
}

/// A canvas with no accessible children, like a game or drawing surface.
final class Canvas: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor.systemPink.setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 60, width: 120, height: 120)).fill()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 240, y: 90, width: 160, height: 90)).fill()
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var movingButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let primary = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 760, height: 560)
        let offset: CGFloat = canvasOnly ? 220 : 120
        let frame = NSRect(x: primary.minX + offset, y: primary.maxY - size.height - offset, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = canvasOnly ? "KeyNav Fixture Canvas" : "KeyNav Fixture"
        window.isReleasedWhenClosed = false
        Recorder.shared.window = window

        if canvasOnly {
            window.contentView = Canvas(frame: NSRect(origin: .zero, size: size))
        } else {
            buildControls(in: size)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(moveTarget), name: Notification.Name("local.keynav.fixture.move"), object: nil)
        center.addObserver(self, selector: #selector(removeTarget), name: Notification.Name("local.keynav.fixture.remove"), object: nil)
        center.addObserver(self, selector: #selector(restoreTarget), name: Notification.Name("local.keynav.fixture.restore"), object: nil)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { Recorder.shared.write() }
        }
        Recorder.shared.write()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildControls(in size: NSSize) {
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        let r = Recorder.shared

        func button(_ title: String, _ x: CGFloat, _ y: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: x, y: y, width: 150, height: 30)
            b.bezelStyle = .rounded
            content.addSubview(b)
            return b
        }
        r.views["increment"] = button("Increment", 20, 500, #selector(increment))
        r.views["second"] = button("Second action", 180, 500, #selector(secondAction))
        let disabled = button("Disabled action", 340, 500, #selector(secondAction))
        disabled.isEnabled = false
        let check = NSButton(checkboxWithTitle: "Remember me", target: self, action: #selector(toggleCheck))
        check.frame = NSRect(x: 510, y: 504, width: 160, height: 24)
        content.addSubview(check)

        let name = NSTextField(frame: NSRect(x: 20, y: 450, width: 300, height: 26))
        name.placeholderString = "Name"
        name.setAccessibilityLabel("Name")
        content.addSubview(name)
        r.fields["name"] = name
        r.views["name"] = name

        let typing = NSTextField(frame: NSRect(x: 340, y: 450, width: 380, height: 26))
        typing.placeholderString = "Typing area"
        typing.setAccessibilityLabel("Typing area")
        content.addSubview(typing)
        r.fields["typing"] = typing
        r.views["typing"] = typing

        let moving = button("Moving target", 20, 400, #selector(movingAction))
        movingButton = moving
        r.views["moving"] = moving

        let pad = PointerPad(frame: NSRect(x: 20, y: 40, width: 360, height: 320))
        content.addSubview(pad)
        r.views["pad"] = pad

        let scroll = NSScrollView(frame: NSRect(x: 400, y: 40, width: 320, height: 320))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 3000))
        for i in 0..<60 {
            let label = NSTextField(labelWithString: "Row \(i)")
            label.frame = NSRect(x: 10, y: CGFloat(i) * 50, width: 120, height: 20)
            document.addSubview(label)
        }
        scroll.documentView = document
        document.scroll(NSPoint(x: 0, y: 3000 - 320))
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Distance scrolled down from the top, in points.
                Recorder.shared.scrollY = 3000 - 320 - scroll.contentView.bounds.origin.y
                Recorder.shared.scrollX = scroll.contentView.bounds.origin.x
                Recorder.shared.write()
            }
        }
        content.addSubview(scroll)
        r.views["scroll"] = scroll
    }

    @objc func increment() { Recorder.shared.counter += 1; Recorder.shared.write() }
    @objc func secondAction() { Recorder.shared.second += 1; Recorder.shared.write() }
    @objc func movingAction() { Recorder.shared.moving += 1; Recorder.shared.write() }
    @objc func toggleCheck(_ sender: NSButton) { Recorder.shared.checkbox = sender.state == .on; Recorder.shared.write() }

    @objc func moveTarget() {
        movingButton?.frame.origin.x += 160
        Recorder.shared.write()
    }

    @objc func removeTarget() {
        movingButton?.removeFromSuperview()
        Recorder.shared.write()
    }

    @objc func restoreTarget() {
        movingButton?.frame.origin.x = 20
        if let movingButton, movingButton.superview == nil { window.contentView?.addSubview(movingButton) }
        Recorder.shared.write()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
