import ApplicationServices
import AppKit
import Foundation
import KeyNavCore

/// Wraps an AXUIElement so it can cross the discovery task boundary. Only the main actor acts on it.
public struct AXElementBox: @unchecked Sendable {
    public let element: AXUIElement
    public let role: String
    public let frame: HintTarget.Frame
    public let actions: [String]
    /// A named action to perform instead of a press: a notification's Close, or `hover`.
    public var pressAction: String? = nil
    /// Where a pointer click lands when that isn't the element's own frame (a link's title).
    public var clickFrame: HintTarget.Frame? = nil

    /// Not an Accessibility action: KeyNav moves the pointer over the element so its hover controls appear.
    public static let hover = "KeyNav.hover"
}

public struct DiscoveryResult: Sendable {
    public var targets: [HintTarget]
    public var elements: [AXElementBox]
    public var truncated: Bool
    public var elapsed: Double
    public var visitedNodes: Int
    /// Whether the app exposed a window at all. False usually means no Accessibility tree for it.
    public var foundWindow: Bool
    public var scope: String
    /// Targets other than the window's own close, minimise, zoom, and full-screen buttons.
    /// Menu bar, status icon, and Dock targets are not counted either.
    public var contentTargets: Int = 0
    /// Frame of the focused window, used to tell a full-screen window.
    public var windowFrame: CGRect?
    /// Whether the focused window can be full screen: it says so, or it is a standard window. Finder's desktop
    /// fills the display without being either.
    public var windowCanBeFullScreen = false
    /// Window targets left out because a notification or another app's window covers them.
    public var covered = 0
    /// This read first asked a Chromium or Electron app for its full tree, which it builds in the background:
    /// the result may hold only part of the page, so read again shortly.
    public var treeWasAsleep = false

    /// Drops window targets whose centre lies under one of `covers`.
    mutating func removeCovered(by covers: [CGRect]) {
        guard !covers.isEmpty else { return }
        let keep = targets.indices.filter { index in
            let center = CGPoint(x: targets[index].frame.center.x, y: targets[index].frame.center.y)
            return !covers.contains { $0.contains(center) }
        }
        guard keep.count != targets.count else { return }
        covered = targets.count - keep.count
        let chrome = targets.count - contentTargets
        targets = keep.map { targets[$0] }
        elements = keep.map { elements[$0] }
        contentTargets = max(targets.count - chrome, 0)
    }

    /// Adds menu bar, status icon, and Dock targets, keeping the label order stable.
    mutating func append(_ extra: [(HintTarget, AXElementBox)]) {
        guard !extra.isEmpty else { return }
        var all = Array(zip(targets, elements)) + extra
        AccessibilityTargets.sortForLabels(&all)
        targets = all.map(\.0)
        elements = all.map(\.1)
    }
}

/// Per-index result slots written from `concurrentPerform`. Each index is written once by one thread.
private final class UncheckedResults: @unchecked Sendable {
    private var slots: [[(HintTarget, AXElementBox)]]
    private let lock = NSLock()
    init(count: Int) { slots = Array(repeating: [], count: count) }
    func set(_ index: Int, _ value: [(HintTarget, AXElementBox)]) {
        lock.lock()
        slots[index] = value
        lock.unlock()
    }
    var all: [(HintTarget, AXElementBox)] { slots.flatMap { $0 } }
}

/// Apps already asked for their full Accessibility tree.
private final class AwakenedApps: @unchecked Sendable {
    private var pids = Set<pid_t>()
    private let lock = NSLock()
    /// True the first time `pid` is seen.
    func insert(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.insert(pid).inserted
    }
}

/// Bounded Accessibility traversal of one application's focused window (or its frontmost sheet).
///
/// Every AX call has a messaging timeout; traversal stops on node, depth, target, or time budgets; it never
/// runs on the event-tap callback. A stalled app yields a truncated or empty result, not a hang.
/// Occlusion by other windows is not detectable from AX alone, so targets are clipped only to their
/// window and scroll areas.
public enum AccessibilityTargets {
    private static let awakened = AwakenedApps()
    private static let enhanced = AwakenedApps()

    public static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXTextField", "AXTextArea", "AXComboBox", "AXDisclosureTriangle",
        "AXSearchField", "AXSecureTextField", "AXTab", "AXSlider", "AXIncrementor", "AXColorWell", "AXDockItem",
        // List, table, and sidebar rows: chosen by selecting them.
        "AXRow"
    ]
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
    static let menuOpeningRoles: Set<String> = ["AXMenuBarItem", "AXMenuButton", "AXPopUpButton", "AXDockItem"]
    static let windowChromeSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    /// Roles that are a control only when pressable: a web page's clickable div, a map pin, a section heading.
    static let clickableRoles: Set<String> = ["AXGroup", "AXGenericElement", "AXImage", "AXCell", "AXHeading", "AXLayoutItem"]
    static let contentRoles: Set<String> = ["AXSplitGroup", "AXScrollArea", "AXGroup", "AXTabGroup", "AXWebArea", "AXList",
                                             "AXTable", "AXOutline", "AXBrowser", "AXLayoutArea"]
    static let clippingRoles: Set<String> = ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXWebArea", "AXGroup"]

    public struct Budget: Sendable {
        public var maxNodes = 8_000
        public var maxDepth = 60
        public var maxTargets = 400
        public var seconds: Double = 0.8
        public init() {}
    }

    /// What besides the focused window gets labels.
    public struct Extras: Sendable {
        /// The app's own menus and the status icons on the right of the menu bar.
        public var menuBar = true
        public var dock = true
        public init(menuBar: Bool = true, dock: Bool = true) {
            self.menuBar = menuBar
            self.dock = dock
        }
    }

    /// Runs discovery off the main actor.
    /// `checkCovering` drops targets under other windows; the read-only probe turns it off for apps in the background.
    public static func discover(pid: pid_t, budget: Budget = Budget(), extras: Extras = Extras(),
                                checkCovering: Bool = true) async -> DiscoveryResult {
        let displays = DisplayGeometry.activeBounds()
        let menuBarShown = extras.menuBar && !menuBarAutoHides
        let dockPID = extras.dock && !dockAutoHides
            ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            : nil
        // Status icons belong to many apps; each owns its own extras menu bar.
        let statusApps = menuBarShown
            ? NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }
                .map { StatusApp(pid: $0.processIdentifier, name: $0.localizedName) }
            : []
        let notificationPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .first?.processIdentifier
        let work: @Sendable () -> DiscoveryResult = {
            let started = ProcessInfo.processInfo.systemUptime
            var result = discoverSynchronously(pid: pid, budget: budget, displays: displays)
            // Controls hidden under a notification or another app's window would be pressed behind it: drop them,
            // and label the notification instead.
            let notifications = notificationPID.map { notificationTargets(pid: $0, displays: displays) } ?? []
            if checkCovering { result.removeCovered(by: notifications.map(\.0.frame.rect) + windowsAbove(pid: pid)) }
            result.append(notifications)
            let window = result.windowFrame
            // A full-screen window hides the menu bar and the Dock.
            let fullScreen = result.windowCanBeFullScreen
                && window.map { frame in displays.contains { $0.equalTo(frame) } } == true
            guard !fullScreen else { return result }
            var extra: [(HintTarget, AXElementBox)] = []
            if menuBarShown {
                extra += menuBarTargets(pid: pid, displays: displays)
                extra += statusTargets(apps: statusApps, displays: displays)
            }
            if let dockPID {
                extra += dockTargets(pid: dockPID, displays: displays)
            }
            result.append(extra)
            result.elapsed = ProcessInfo.processInfo.systemUptime - started
            return result
        }
        // Requests to KeyNav's own windows are answered in-process, on the calling thread, by AppKit and SwiftUI,
        // which must only run on the main thread. Other apps answer from their own process, so read them off it.
        if pid == getpid() {
            return await MainActor.run { work() }
        }
        return await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// An app other than the frontmost one whose window has the keyboard: a panel that takes keys without
    /// activating its app (Raycast, Spotlight, Alfred, 1Password's Quick Access). Nil when the frontmost app has it.
    public static func keyboardPanelApp() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        guard let app = elementAttribute(systemWide, kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pid != getpid(),
              pid != NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(app, 0.2)
        return elementAttribute(app, kAXFocusedWindowAttribute) != nil ? pid : nil
    }

    /// Whether "Automatically hide and show the menu bar" is on.
    static var menuBarAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool ?? false
    }

    static var dockAutoHides: Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
    }

    // MARK: - Scroll mode

    /// What Scroll mode needs to choose where to scroll: the focused window, the ancestry (innermost first) of
    /// the control under the person's last click and of the focused control, and every scroll area to Tab between.
    public struct ScrollContext: Sendable {
        public var window: HintTarget.Frame?
        public var clickChain: [ScrollNode] = []
        public var focusChain: [ScrollNode] = []
        public var areas: [HintTarget.Frame] = []
        /// This read first asked a browser for its tree, which it builds in the background.
        public var treeWasAsleep = false
    }

    /// Reads `ScrollContext` for `pid`. `click` counts only if it lies in the focused window. Without `areas`, it
    /// returns at once with the window and the two ancestries; `scrollAreas(pid:)` then reads the panes.
    public static func scrollContext(pid: pid_t, clickedAt click: CGPoint?, areas readAreas: Bool = true) async -> ScrollContext {
        let work: @Sendable () -> ScrollContext = {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            // Scrolling may be the first thing to ask a browser for its tree; give it a moment to build.
            let asleep = wakeTree(app, pid: pid)
            if asleep, readAreas { Thread.sleep(forTimeInterval: 0.3) }
            guard let window = windowOf(app), let windowFrame = frame(of: window) else { return ScrollContext() }
            var context = ScrollContext(window: windowFrame)
            if let click, windowFrame.contains((click.x, click.y)) {
                var element: AXUIElement?
                AXUIElementCopyElementAtPosition(app, Float(click.x), Float(click.y), &element)
                context.clickChain = ancestry(of: element)
            }
            context.focusChain = ancestry(of: elementAttribute(app, kAXFocusedUIElementAttribute))
            context.treeWasAsleep = asleep
            if readAreas { context.areas = scrollAreas(in: window, frame: windowFrame) }
            return context
        }
        if pid == getpid() { return await MainActor.run { work() } }
        return await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// The focused window's scroll areas, after giving a browser that was just woken a moment to build its tree.
    public static func scrollAreas(pid: pid_t, afterWaking: Bool) async -> [HintTarget.Frame] {
        let work: @Sendable () -> [HintTarget.Frame] = {
            if afterWaking { Thread.sleep(forTimeInterval: 0.3) }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let window = windowOf(app), let windowFrame = frame(of: window) else { return [] }
            // This read runs after the dot and outline are already up, so it can take longer than the quick one; a
            // scan cut short by a slow app finds no panes.
            return scrollAreas(in: window, frame: windowFrame, seconds: 1.5)
        }
        if pid == getpid() { return await MainActor.run { work() } }
        return await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// A spot near `point` where the pointer hovers nothing that reacts: no link, button, or control, and nothing
    /// with a tooltip. Tries rings of nearby spots, nearest first; `point` itself if none is quiet.
    public static func quietPoint(pid: pid_t, near point: CGPoint) async -> CGPoint {
        let work: @Sendable () -> CGPoint = {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            let offsets: [(Double, Double)] = [(0, 0), (0, -40), (0, 40), (-60, 0), (60, 0), (-60, -40), (60, -40),
                                               (-60, 40), (60, 40), (0, -80), (0, 80), (-120, 0), (120, 0)]
            for (dx, dy) in offsets {
                let candidate = CGPoint(x: point.x + dx, y: point.y + dy)
                var element: AXUIElement?
                guard AXUIElementCopyElementAtPosition(app, Float(candidate.x), Float(candidate.y), &element) == .success
                else { continue }
                if isQuiet(element) { return candidate }
            }
            return point
        }
        // KeyNav's own window answers in-process and only on the main thread; asking it from another thread while
        // the main thread waits on Accessibility froze KeyNav (Scrolling started over its own Settings).
        if pid == getpid() { return await MainActor.run { work() } }
        return await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// Whether hovering `element` is harmless: neither it nor its near ancestors is a control or has a tooltip.
    private static func isQuiet(_ element: AXUIElement?) -> Bool {
        var current = element
        for _ in 0..<4 {
            guard let node = current, let nodeRole = role(of: node) else { return true }
            if ["AXWindow", "AXScrollArea", "AXWebArea"].contains(nodeRole) { return true }
            if actionableRoles.contains(nodeRole) || nodeRole == "AXImage" { return false }
            if let help = stringAttribute(node, kAXHelpAttribute), !help.isEmpty { return false }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return true
    }

    /// `element` and its ancestors up to (not including) the window, innermost first.
    private static func ancestry(of element: AXUIElement?) -> [ScrollNode] {
        var nodes: [ScrollNode] = []
        var current = element
        while let node = current, nodes.count < 60 {
            guard let nodeRole = role(of: node), nodeRole != "AXWindow", nodeRole != "AXApplication" else { break }
            if let rect = frame(of: node) { nodes.append(ScrollNode(role: nodeRole, frame: rect)) }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return nodes
    }

    /// Every scroll area in a window: lists, sidebars, text views, pages. Web apps rarely mark their panes as
    /// scrollable, so inside a page anything shaped like a pane counts too (Slack's channel list and messages,
    /// Notion's page and peek); Scroll mode drops the containers its panes already cover.
    /// A block that might scroll on its own: a web page's pane, a plain group an iPad app on the Mac scrolls in,
    /// or a group as big as the window (Messages' conversation reports the whole window). It does once something
    /// inside it shows content scrolled out of it, which the same pass reads anyway.
    private struct ScrollCandidate {
        let rect: CGRect
        /// The page it sits in, if any.
        let page: CGRect?
        let pane: HintTarget.Frame?
        let top: CGFloat?
        let bottom: CGFloat?
        var scrolls = false
    }

    private static func scrollAreas(in window: AXUIElement, frame windowFrame: HintTarget.Frame,
                                    maxNodes: Int = 3_000, seconds: Double = 0.6) -> [HintTarget.Frame] {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var areas: [HintTarget.Frame] = []
        var candidates: [ScrollCandidate] = []
        /// Pages that scroll as a whole (X, Google): content below the fold is squeezed into slivers at the page's
        /// bottom edge. Blocks inside such a page move with it rather than scrolling on their own.
        var pageSlivers: [(page: CGRect, count: Int)] = []
        var hasPage = false
        var visited = 0
        var stack: [(AXUIElement, CGRect?, [Int])] = [(window, nil, [])]
        while let (element, page, within) = stack.popLast(), visited < maxNodes,
              ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            let elementRole = role(of: element)
            let rect = frame(of: element)
            var inside = within
            if let rect {
                for index in within where !candidates[index].scrolls && shows(rect.rect, scrolledOutOf: candidates[index]) {
                    candidates[index].scrolls = true
                }
                // Only the bottom edge counts: a pane under a header (Claude's chat) leaves what scrolled up at the
                // page's top, and screen reader hints hide there too. Text and links count, not the empty layout
                // groups apps also leave there; X squeezes them to no height at all. A pane with its own top that
                // runs to the page's bottom (Claude's file preview) leaves its overflow there too; that's the pane
                // scrolling, not the page.
                if let page, rect.height <= 1, rect.width >= 40, abs(rect.y - page.maxY) <= 1,
                   ["AXStaticText", "AXLink", "AXButton", "AXImage", "AXHeading"].contains(elementRole ?? ""),
                   !within.contains(where: { candidates[$0].pane != nil && candidates[$0].top != nil }) {
                    if let index = pageSlivers.firstIndex(where: { $0.page == page }) { pageSlivers[index].count += 1 }
                    else { pageSlivers.append((page, 1)) }
                }
                if elementRole == "AXScrollArea", rect.width >= 200, rect.height >= 200 {
                    areas.append(rect)
                } else if page != nil || elementRole == "AXGroup", let bounds = page ?? Optional(windowFrame.rect),
                          bounds.insetBy(dx: -1, dy: -1).contains(rect.rect) {
                    let pane = ScrollSession.paneShaped(rect, in: windowFrame)
                    let windowSized = page == nil && elementRole == "AXGroup"
                        && rect.width * rect.height >= windowFrame.width * windowFrame.height * 0.85
                    if pane != nil || windowSized {
                        // Content at the page's own edge means the page is what scrolls, so only the block's
                        // other edges count; a window-sized group counts its own.
                        let top = windowSized || rect.y > bounds.minY + 1 ? CGFloat(rect.y) : nil
                        let bottom = windowSized || rect.y + rect.height < bounds.maxY - 1 ? CGFloat(rect.y + rect.height) : nil
                        if top != nil || bottom != nil {
                            candidates.append(ScrollCandidate(rect: rect.rect, page: page, pane: pane, top: top, bottom: bottom))
                            inside.append(candidates.count - 1)
                        }
                    }
                }
            }
            // A list's rows, and anything scrolled out of sight, hold no pane: skip them, as Finder's long lists
            // would otherwise take most of the time.
            if page == nil, ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXRow"].contains(elementRole ?? "") { continue }
            if let rect, rect.width > 0, rect.height > 0, !rect.rect.intersects(windowFrame.rect) { continue }
            if elementRole == "AXWebArea" { hasPage = true }
            let childPage = page ?? (elementRole == "AXWebArea" ? rect?.rect : nil)
            for child in (childrenOf(element) ?? []).reversed() { stack.append((child, childPage, inside)) }
        }
        let scrollingPages = pageSlivers.filter { $0.count >= 3 }.map(\.page)
        areas += candidates.compactMap { $0.scrolls && !($0.page.map(scrollingPages.contains) ?? false) ? $0.pane : nil }
        // What a window-sized group shows is what the panes beside it leave: Messages' conversation, right of the
        // list. A web app's window wrappers are such groups too; its panes are found in the page instead.
        for group in candidates where group.scrolls && group.pane == nil && !hasPage {
            var shown = group.rect
            for area in areas.map(\.rect) where area.height >= shown.height * 0.7 && area.intersects(shown) {
                if area.minX - shown.minX < 20 {
                    shown = CGRect(x: area.maxX, y: shown.minY, width: shown.maxX - area.maxX, height: shown.height)
                } else if shown.maxX - area.maxX < 20 {
                    shown.size.width = area.minX - shown.minX
                }
            }
            if shown.width >= 200, shown != group.rect {
                areas.append(HintTarget.Frame(x: shown.minX, y: shown.minY, width: shown.width, height: shown.height))
            }
        }
        return areas
    }

    /// Whether `inner` is content scrolled out of `block`: it reaches past one of the block's edges (Claude's chat,
    /// Messages), or Chromium squeezed it into a sliver at that edge (Slack, Chrome). A block that only sits in a
    /// scrolling page (Google's AI Overview) holds all its content.
    private static func shows(_ inner: CGRect, scrolledOutOf block: ScrollCandidate) -> Bool {
        guard inner.width > 0, inner.height > 0 else { return false }
        if inner.height <= 1, block.top.map({ abs(inner.minY - $0) <= 1 }) == true
            || block.bottom.map({ abs(inner.minY - $0) <= 1 }) == true { return true }
        return block.top.map { inner.minY < $0 - 8 } == true || block.bottom.map { inner.maxY > $0 + 8 } == true
    }

    // MARK: - Covering windows and notifications

    /// Frames of ordinary windows of other apps stacked above `pid`'s frontmost window. Floating overlays
    /// (higher layers) are skipped: many are transparent and cover nothing visible.
    static func windowsAbove(pid: pid_t) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var above: [CGRect] = []
        for window in list {
            let owner = window[kCGWindowOwnerPID as String] as? pid_t
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if owner == pid { return above }
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            if owner != getpid(), alpha > 0.1,
               let bounds = window[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds) {
                above.append(rect)
            }
        }
        return []
    }

    /// Notification banners and alerts on screen. Each opens its notification when pressed.
    static func notificationTargets(pid: pid_t, displays: [CGRect]) -> [(HintTarget, AXElementBox)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var found: [(HintTarget, AXElementBox)] = []
        var stack = (elementsAttribute(app, kAXWindowsAttribute) ?? []).map { ($0, 0) }
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 300 {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.15)
            let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
            if subrole.hasPrefix("AXNotificationCenter"), let frame = frame(of: element),
               isVisible(frame.rect, clip: frame.rect, displays: displays) {
                let actions = actionNames(element)
                if actions.contains(kAXPressAction) {
                    let elementRole = role(of: element) ?? "AXGroup"
                    let name = accessibleName(element, role: elementRole)
                    found.append((HintTarget(name: name.isEmpty ? "Notification" : name, role: elementRole, frame: frame),
                                  AXElementBox(element: element, role: elementRole, frame: frame, actions: actions)))
                    // Its close button only appears on hover, at the top-left corner; label that corner too.
                    if let close = actions.first(where: { $0.hasPrefix("Name:Close\n") || $0.hasPrefix("Name:Clear") }) {
                        let corner = HintTarget.Frame(x: frame.x - 8, y: frame.y - 8, width: 20, height: 20)
                        found.append((HintTarget(name: "Close \(name.isEmpty ? "notification" : name)", role: "AXButton",
                                                 frame: corner),
                                      AXElementBox(element: element, role: elementRole, frame: frame, actions: actions,
                                                   pressAction: close)))
                    }
                    continue
                }
            }
            // The stack's own controls: Clear and Show Less.
            if role(of: element) == "AXButton", let frame = frame(of: element),
               isVisible(frame.rect, clip: frame.rect, displays: displays) {
                let actions = actionNames(element)
                let name = accessibleName(element, role: "AXButton")
                if actions.contains(kAXPressAction), !name.isEmpty {
                    found.append((HintTarget(name: name, role: "AXButton", frame: frame),
                                  AXElementBox(element: element, role: "AXButton", frame: frame, actions: actions)))
                }
                continue
            }
            guard depth < 8 else { continue }
            for child in childrenOf(element) ?? [] { stack.append((child, depth + 1)) }
        }
        return found
    }

    // MARK: - Menu bar, status icons, and Dock

    /// The frontmost app's menus, Apple menu first.
    static func menuBarTargets(pid: pid_t, displays: [CGRect]) -> [(HintTarget, AXElementBox)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar = elementAttribute(app, kAXMenuBarAttribute) else { return [] }
        return barItems(childrenOf(bar) ?? [], fallbackName: nil, displays: displays)
    }

    /// Status icons from every app's extras menu bar. Each app gets a short timeout so a stuck app costs little.
    struct StatusApp: Sendable {
        let pid: pid_t
        let name: String?
    }

    static func statusTargets(apps: [StatusApp], displays: [CGRect]) -> [(HintTarget, AXElementBox)] {
        let results = UncheckedResults(count: apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let app = AXUIElementCreateApplication(apps[index].pid)
            AXUIElementSetMessagingTimeout(app, 0.08)
            guard let bar = elementAttribute(app, "AXExtrasMenuBar") else { return }
            AXUIElementSetMessagingTimeout(bar, 0.08)
            // Icons that don't fit beside the notch stay in the list one point above the screen; they can't be seen.
            let shown = barItems(childrenOf(bar) ?? [], fallbackName: apps[index].name, displays: displays).filter { item in
                displays.contains { $0.contains(CGPoint(x: item.0.frame.x + item.0.frame.width / 2, y: item.0.frame.y)) }
            }
            results.set(index, shown)
        }
        return results.all
    }

    /// Items in the Dock's list: apps, folders, and the Trash.
    static func dockTargets(pid: pid_t, displays: [CGRect]) -> [(HintTarget, AXElementBox)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let lists = (childrenOf(app) ?? []).filter { role(of: $0) == "AXList" }
        return lists.flatMap { list in
            barItems((childrenOf(list) ?? []).filter { stringAttribute($0, kAXSubroleAttribute) != "AXSeparatorDockItem" },
                     fallbackName: nil, displays: displays)
        }
    }

    private static func barItems(_ items: [AXUIElement], fallbackName: String?, displays: [CGRect]) -> [(HintTarget, AXElementBox)] {
        items.compactMap { element in
            AXUIElementSetMessagingTimeout(element, 0.25)
            let elementRole = role(of: element) ?? ""
            guard actionableRoles.contains(elementRole), let frame = frame(of: element),
                  isVisible(frame.rect, clip: frame.rect, displays: displays),
                  boolAttribute(element, kAXEnabledAttribute) ?? true else { return nil }
            var name = accessibleName(element, role: elementRole)
            if name.isEmpty { name = fallbackName ?? "" }
            guard !name.isEmpty else { return nil }
            return (HintTarget(name: name, role: elementRole, frame: frame),
                    AXElementBox(element: element, role: elementRole, frame: frame, actions: actionNames(element)))
        }
    }

    static func discoverSynchronously(pid: pid_t, budget: Budget, displays: [CGRect]) -> DiscoveryResult {
        let started = ProcessInfo.processInfo.systemUptime
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium and Electron build their full tree only when asked; this is an ordinary AX attribute.
        // Other apps don't support it, so the first successful request is the one that wakes the tree.
        let asleep = wakeTree(app, pid: pid)

        guard let window = windowOf(app) else {
            return DiscoveryResult(targets: [], elements: [], truncated: false, elapsed: 0, visitedNodes: 0,
                                   foundWindow: false, scope: "no window")
        }
        // An open sheet is modal: label it instead of the inactive controls behind it.
        var root = window
        var scope = "focused window"
        if let sheet = childrenOf(window)?.first(where: { role(of: $0) == "AXSheet" }) {
            root = sheet
            scope = "sheet"
        }
        // An open popover (Calendar's event details) closes on a click outside it: label it alone.
        if scope == "focused window", let popover = firstDescendant(of: window, role: "AXPopover", depth: 2) {
            root = popover
            scope = "popover"
        }
        // An open menu (a context menu, a pop-up button's list) takes the keyboard: label its items instead.
        if let menu = (childrenOf(app) ?? []).last(where: { role(of: $0) == "AXMenu" }) {
            root = menu
            scope = "menu"
        }
        guard let rootFrame = frame(of: root) else {
            return DiscoveryResult(targets: [], elements: [], truncated: false, elapsed: 0, visitedNodes: 0,
                                   foundWindow: true, scope: scope)
        }
        let rootRect = rootFrame.rect

        struct Item {
            let element: AXUIElement
            let depth: Int
            let clip: CGRect
            let targetAncestorFrame: CGRect?
            /// Whether that labelled ancestor is a row.
            var inRow = false
            /// The nearest pressable group above, in `hosts`.
            var host: Int? = nil
        }
        /// Pressable groups (a Slack message) whose controls only appear on hover: their buttons are in the tree
        /// with no width until the pointer is over them.
        struct HoverHost {
            let element: AXUIElement
            let frame: HintTarget.Frame
            let name: String
            var revealsControls = false
        }
        var hosts: [HoverHost] = []
        /// Pressable groups outside any target, with their hover host if they are one: a web page's clickable cards,
        /// rows, and list items (a div with a click handler), which Chrome marks pressable in its full tree.
        var clickableGroups: [(element: AXUIElement, frame: HintTarget.Frame, host: Int?)] = []

        var found: [(HintTarget, AXElementBox)] = []
        var chrome = 0
        var seen = Set<String>()
        var visited = 0
        var truncated = false
        var stack = [Item(element: root, depth: 0, clip: rootRect, targetAncestorFrame: nil)]

        while let item = stack.popLast() {
            if visited >= budget.maxNodes || found.count >= budget.maxTargets
                || ProcessInfo.processInfo.systemUptime - started > budget.seconds {
                truncated = true
                break
            }
            visited += 1
            let element = item.element
            AXUIElementSetMessagingTimeout(element, 0.25)

            let elementRole = role(of: element) ?? ""
            let elementFrame = frame(of: element)
            var clip = item.clip
            var targetAncestor = item.targetAncestorFrame
            var inRow = item.inRow
            var host = item.host

            // Slack's message list reports a 1 by 2 point frame around messages it lays out in full; a container
            // that small clips nothing it could really hold.
            if let elementFrame, clippingRoles.contains(elementRole), elementRole != "AXGroup",
               elementFrame.width >= 20, elementFrame.height >= 20 {
                clip = clip.intersection(elementFrame.rect)
            }

            // Mac Catalyst apps (Messages) expose tappable cells as pressable text. Every text there is pressable,
            // timestamps included, so only text big enough to be a cell counts.
            let pressableText = elementRole == "AXStaticText"
                && elementFrame.map { $0.width >= 30 && $0.height >= 30 } == true
                && actionNames(element).contains(kAXPressAction)
            // A custom toggle hides its real checkbox as a speck inside the label people click: show the label's frame.
            let speck = ["AXCheckBox", "AXRadioButton"].contains(elementRole)
                && elementFrame.map { $0.width < 4 || $0.height < 4 } == true
            let shownFrame = speck ? elementAttribute(element, kAXParentAttribute).flatMap { frame(of: $0) }
                .flatMap { parent in parent.width <= 400 && parent.height <= 60 ? parent : nil } : elementFrame
            // A closed pop-up button keeps its menu's items in the tree as slivers.
            let sliver = elementRole == "AXMenuItem" && elementFrame.map { $0.height < 10 } == true
            if actionableRoles.contains(elementRole) || pressableText, !sliver, let elementFrame, let shownFrame,
               isVisible(shownFrame.rect, clip: clip, displays: displays) {
                let enabled = boolAttribute(element, kAXEnabledAttribute) ?? true
                var name = accessibleName(element, role: elementRole)
                if name.isEmpty, elementRole == "AXButton" || elementRole == "AXLink" {
                    name = stringAttribute(element, kAXRoleDescriptionAttribute) ?? ""
                }
                if name.isEmpty, elementRole == "AXRow" {
                    name = firstText(in: element) ?? ""
                }
                // Unnamed but pressable (Maps' sidebar rows, Calendar's calendar checkboxes): still a control,
                // named by its kind.
                if name.isEmpty, pressableText || actionNames(element).contains(kAXPressAction) {
                    name = stringAttribute(element, kAXRoleDescriptionAttribute) ?? "Item"
                }
                // A child that covers exactly the same area as a labelled parent would be a redundant label.
                var redundant = targetAncestor.map { $0.equalTo(elementFrame.rect) } ?? false
                // A row's name field (Finder's file names) is part of the row, which already has a label; selecting
                // the row and pressing Return edits it where the app allows.
                if item.inRow, textRoles.contains(elementRole) { redundant = true }
                if enabled, !redundant, !name.isEmpty || textRoles.contains(elementRole) {
                    let key = "\(elementRole)|\(name)|\(Int(elementFrame.x))|\(Int(elementFrame.y))"
                    if !seen.contains(key) {
                        seen.insert(key)
                        let label = name.isEmpty ? roleDescription(elementRole) : name
                        // Half scrolled out of view: label and click the part that shows.
                        let shown = shownFrame.rect.intersection(clip)
                        let clipped = shown.width < shownFrame.width - 1 || shown.height < shownFrame.height - 1
                        let hitFrame = elementRole == "AXLink" ? linkHitFrame(element, frame: elementFrame)
                            : speck ? shownFrame
                            : clipped ? HintTarget.Frame(x: shown.minX, y: shown.minY, width: shown.width, height: shown.height)
                            : nil
                        let target = HintTarget(name: label, role: elementRole, frame: hitFrame ?? elementFrame)
                        found.append((target, AXElementBox(element: element, role: elementRole, frame: elementFrame,
                                                           actions: actionNames(element), clickFrame: hitFrame)))
                        if let subrole = stringAttribute(element, kAXSubroleAttribute), windowChromeSubroles.contains(subrole) {
                            chrome += 1
                        }
                        targetAncestor = elementFrame.rect
                        inRow = elementRole == "AXRow"
                    }
                }
            }

            if let elementFrame, let index = host, actionableRoles.contains(elementRole),
               elementFrame.width == 0 || elementFrame.height == 0 {
                hosts[index].revealsControls = true
            }
            if clickableRoles.contains(elementRole), let elementFrame, isVisible(elementFrame.rect, clip: clip, displays: displays),
               actionNames(element).contains(kAXPressAction) {
                var ownHost: Int?
                if elementRole == "AXGroup", elementFrame.height >= 20 {
                    hosts.append(HoverHost(element: element, frame: elementFrame, name: accessibleName(element, role: elementRole)))
                    host = hosts.count - 1
                    ownHost = host
                }
                if item.targetAncestorFrame == nil {
                    clickableGroups.append((element, elementFrame, ownHost))
                }
            }

            // Skip subtrees that are entirely clipped away or scrolled out of view: a long list's hidden rows, or a
            // long page's sections, would use up the budget before the controls after them (Finder's column headers,
            // Chrome's tab strip). A container with no size can still hold visible children, so it's kept.
            if clip.isEmpty { continue }
            if let elementFrame, elementFrame.width > 0, elementFrame.height > 0, item.depth > 0,
               !elementFrame.rect.intersects(clip) { continue }
            if item.depth >= budget.maxDepth {
                truncated = true
                continue
            }
            if var children = childrenOf(element) {
                // Read the window's toolbar and buttons before its content: a slow app (Notes) can use up the time
                // budget in a long list, and the toolbar matters more than its last rows.
                if item.depth == 0 {
                    let content = children.filter { contentRoles.contains(role(of: $0) ?? "") }
                    children = children.filter { !contentRoles.contains(role(of: $0) ?? "") } + content
                }
                for child in children.reversed() {
                    stack.append(Item(element: child, depth: item.depth + 1, clip: clip, targetAncestorFrame: targetAncestor,
                                      inRow: inRow, host: host))
                }
            }
        }

        // A clickable group that holds no other target is one control: label it. One that holds targets is a
        // container whose click handler serves them (React listens at its root), so its targets stand for it.
        let rootArea = rootRect.width * rootRect.height
        for group in clickableGroups where found.count < budget.maxTargets {
            let rect = group.frame.rect
            guard rect.width * rect.height <= rootArea * 0.4,
                  !found.contains(where: { rect.contains($0.0.frame.rect) || $0.0.frame.rect.contains(rect) }),
                  group.host.map({ !hosts[$0].revealsControls }) ?? true else { continue }
            let groupRole = role(of: group.element) ?? "AXGroup"
            let name = accessibleName(group.element, role: groupRole)
            let label = name.isEmpty ? firstText(in: group.element) ?? "" : name
            guard !label.isEmpty || (rect.width <= 80 && rect.height <= 80) else { continue }
            found.append((HintTarget(name: label.isEmpty ? "Button" : String(label.prefix(80)), role: groupRole, frame: group.frame),
                          AXElementBox(element: group.element, role: groupRole, frame: group.frame,
                                       actions: actionNames(group.element))))
        }

        // Each such group gets a label that hovers it, so its controls appear and are labelled in turn.
        // A group as big as the window (Spotify's whole page) isn't something people mean to hover.
        for host in hosts where host.revealsControls && found.count < budget.maxTargets
            && host.frame.width * host.frame.height <= rootArea * 0.4 {
            let name = String((host.name.isEmpty ? "Show actions" : host.name).prefix(80))
            found.append((HintTarget(name: name, role: "AXGroup", frame: host.frame),
                          AXElementBox(element: host.element, role: "AXGroup", frame: host.frame, actions: [],
                                       pressAction: AXElementBox.hover)))
        }

        dropSameSpot(&found)
        sortForLabels(&found)
        var result = DiscoveryResult(
            targets: found.map(\.0),
            elements: found.map(\.1),
            truncated: truncated,
            elapsed: ProcessInfo.processInfo.systemUptime - started,
            visitedNodes: visited,
            foundWindow: true,
            scope: scope,
            contentTargets: found.count - chrome
        )
        result.windowFrame = frame(of: window)?.rect
        result.windowCanBeFullScreen = boolAttribute(window, "AXFullScreen") == true
            || stringAttribute(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
        result.treeWasAsleep = asleep
        // Chrome and the browsers built on it (Arc, Brave, Edge) answer the request above with a reduced tree whose
        // links and buttons can't be pressed: pressing reports success and does nothing, so KeyNav would have to
        // click with the pointer, which misses whatever covers or pads the control. The mode VoiceOver asks for
        // gives them a press; ask once per app, then read again for the pressable tree.
        let links = found.filter { $0.1.role == "AXLink" }
        if links.count >= 2, !links.contains(where: { $0.1.actions.contains(kAXPressAction) }), enhanced.insert(pid) {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            result.treeWasAsleep = true
        }
        return result
    }

    /// Two targets on exactly the same spot are one control reached twice (Spotify's sidebar rows hold a button
    /// as big as the row, and its table lists each cell again under a column): one label, for the control itself
    /// rather than the row or group around it.
    static func dropSameSpot(_ found: inout [(HintTarget, AXElementBox)]) {
        let wrappers: Set<String> = ["AXRow", "AXCell", "AXGroup", "AXGenericElement", "AXLayoutItem"]
        func same(_ a: HintTarget.Frame, _ b: HintTarget.Frame) -> Bool {
            abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
        }
        var kept: [(HintTarget, AXElementBox)] = []
        for entry in found {
            if let index = kept.firstIndex(where: { same($0.1.frame, entry.1.frame) }) {
                if wrappers.contains(kept[index].1.role), !wrappers.contains(entry.1.role) { kept[index] = entry }
            } else {
                kept.append(entry)
            }
        }
        found = kept
    }

    /// Stable order: rows top-to-bottom, then left-to-right. Labels do not shuffle between refreshes.
    static func sortForLabels(_ found: inout [(HintTarget, AXElementBox)]) {
        found.sort { lhs, rhs in
            let a = lhs.0.frame
            let b = rhs.0.frame
            if abs(a.y - b.y) > 6 { return a.y < b.y }
            return a.x < b.x
        }
    }

    // MARK: - Validation and activation

    public enum Revalidation: Equatable, Sendable {
        case valid(HintTarget.Frame)
        case changed
    }

    /// The target must still exist, keep its role, and sit where it was labelled (within 3 points).
    public static func revalidate(_ box: AXElementBox) -> Revalidation {
        guard let current = frame(of: box.element), role(of: box.element) == box.role else { return .changed }
        guard abs(current.x - box.frame.x) < 3, abs(current.y - box.frame.y) < 3,
              abs(current.width - box.frame.width) < 3, abs(current.height - box.frame.height) < 3 else {
            return .changed
        }
        if boolAttribute(box.element, kAXEnabledAttribute) == false { return .changed }
        return .valid(current)
    }

    public enum SemanticOutcome: Equatable, Sendable {
        case pressed
        case focused
        case unsupported(String)
    }

    /// Performs the accessibility action for a revalidated target. Never moves the pointer.
    public static func performSemantic(_ box: AXElementBox, action: TargetAction) -> SemanticOutcome {
        switch action {
        case .press:
            if let named = box.pressAction, named != AXElementBox.hover {
                let result = AXUIElementPerformAction(box.element, named as CFString)
                return result == .success ? .pressed : .unsupported("\(named.prefix(20)) error \(result.rawValue)")
            }
            if textRoles.contains(box.role) {
                let result = AXUIElementSetAttributeValue(box.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return result == .success ? .focused : .unsupported("focus error \(result.rawValue)")
            }
            if box.role == "AXRow", !box.actions.contains(kAXPressAction) {
                let result = AXUIElementSetAttributeValue(box.element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                guard result == .success else { return .unsupported("select error \(result.rawValue)") }
                // Web rows that aren't selectable (Gmail's inbox) accept the change and ignore it; they open on a click.
                return boolAttribute(box.element, kAXSelectedAttribute) == true ? .pressed : .unsupported("row not selectable")
            }
            guard box.actions.contains(kAXPressAction) else { return .unsupported("no press action") }
            // Pressing a Chromium tree row only selects it; Slack's sidebar opens a conversation or app from
            // the clickable group that fills the row, so press that instead.
            let pressed = box.role == "AXRow" ? rowContent(box) ?? box.element : box.element
            let result = AXUIElementPerformAction(pressed, kAXPressAction as CFString)
            // Opening a menu keeps its owner busy until the menu closes, so the reply times out even though
            // the press worked. Falling back to the pointer here would click the menu closed again.
            if result == .cannotComplete, menuOpeningRoles.contains(box.role) { return .pressed }
            return result == .success ? .pressed : .unsupported("press error \(result.rawValue)")
        case .rightClick:
            guard box.actions.contains(kAXShowMenuAction) else { return .unsupported("no menu action") }
            let result = AXUIElementPerformAction(box.element, kAXShowMenuAction as CFString)
            return result == .success ? .pressed : .unsupported("menu error \(result.rawValue)")
        case .doubleClick, .movePointer:
            return .unsupported("needs the pointer")
        }
    }

    /// Where a link takes a click when its own box has blank space at the point KeyNav clicks: Google's results
    /// wrap a short title and the site's address in one link, so the box's bottom centre sits beside the title.
    /// The title (a heading) if there is one, else its largest piece of text or image; nil when the usual point hits.
    private static func linkHitFrame(_ link: AXUIElement, frame box: HintTarget.Frame) -> HintTarget.Frame? {
        var pieces: [(role: String, frame: HintTarget.Frame)] = []
        var stack = (childrenOf(link) ?? []).map { ($0, 0) }
        while let (element, depth) = stack.popLast(), pieces.count < 12 {
            let elementRole = role(of: element) ?? ""
            if ["AXHeading", "AXStaticText", "AXImage"].contains(elementRole), let piece = frame(of: element),
               piece.width > 0, piece.height > 0 {
                pieces.append((elementRole, piece))
            } else if depth < 3 {
                stack += (childrenOf(element) ?? []).map { ($0, depth + 1) }
            }
        }
        guard pieces.count > 1 else { return nil }
        let point = ClickPoint.of(box.rect).point
        if pieces.contains(where: { $0.frame.rect.insetBy(dx: -2, dy: -2).contains(point) }) { return nil }
        return pieces.first { $0.role == "AXHeading" }?.frame
            ?? pieces.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.frame
    }

    /// A point where a pointer click reaches `box`, by the app's own hit test: the middle of one of its pieces of
    /// text or images, else its middle, else `preferred` (a link that wraps onto two lines, a control partly under
    /// a banner). `preferred` when no point is confirmed. Arc's links can only be clicked this way.
    public static func reachablePoint(_ box: AXElementBox, preferred: CGPoint) -> CGPoint {
        var pid: pid_t = 0
        guard AXUIElementGetPid(box.element, &pid) == .success else { return preferred }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let rect = (frame(of: box.element) ?? box.frame).rect
        // The middle of its own text first: a link's box runs below its text, and the label's point near the
        // bottom edge can fall outside what a web page treats as the link (keynav.app's Buy, in Arc). Then its
        // centre, and the label's point last.
        var candidates: [CGPoint] = []
        var stack = (childrenOf(box.element) ?? []).map { ($0, 0) }
        while let (element, depth) = stack.popLast(), candidates.count < 8 {
            let elementRole = role(of: element) ?? ""
            if ["AXStaticText", "AXImage", "AXHeading"].contains(elementRole), let piece = frame(of: element)?.rect,
               piece.width >= 2, piece.height >= 2 {
                let middle = CGPoint(x: piece.midX, y: piece.midY)
                if rect.contains(middle) { candidates.append(middle) }
            } else if depth < 3, !actionableRoles.contains(elementRole) {
                // Text inside another control (an artist link in a song row) would click that control instead.
                stack += (childrenOf(element) ?? []).reversed().map { ($0, depth + 1) }
            }
        }
        candidates += [CGPoint(x: rect.midX, y: rect.midY), preferred]
        // Chromium answers a hit test from its last result and tests again in the background, so ask about every
        // point once before reading the answers.
        var hit: AXUIElement?
        for point in candidates { _ = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) }
        usleep(30_000)
        for point in candidates {
            hit = nil
            if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit,
               isSelfOrDescendant(hit, of: box.element) { return point }
        }
        return preferred
    }

    /// Apps can answer a hit test with a fresh object for the same control, so a role and frame match counts too.
    static func isSelfOrDescendant(_ element: AXUIElement, of ancestor: AXUIElement) -> Bool {
        let ancestorRole = role(of: ancestor)
        let ancestorFrame = frame(of: ancestor)
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return false }
            if CFEqual(node, ancestor) { return true }
            if let ancestorFrame, role(of: node) == ancestorRole, frame(of: node) == ancestorFrame { return true }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return false
    }

    /// A pressable child group covering most of a row, as web apps build their list items.
    private static func rowContent(_ box: AXElementBox) -> AXUIElement? {
        let row = box.frame.rect
        return elementsAttribute(box.element, kAXChildrenAttribute)?.first { child in
            guard role(of: child) == "AXGroup", actionNames(child).contains(kAXPressAction),
                  let frame = frame(of: child)?.rect else { return false }
            let overlap = frame.intersection(row)
            return overlap.width * overlap.height >= row.width * row.height * 0.7
        }
    }

    // MARK: - Troubleshooting

    /// An indented outline of the focused window's tree for investigating a missed control: role, subrole,
    /// frame, actions, and a shortened name. Text and secure field values are never read.
    public static func outline(pid: pid_t, maxNodes: Int = 4_000) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var roots = windowOf(app).map { [$0] } ?? []
        if roots.isEmpty, let all = elementsAttribute(app, kAXWindowsAttribute) { roots = all }
        guard !roots.isEmpty else { return "no window\n" }
        var lines: [String] = []
        var stack: [(AXUIElement, Int)] = roots.reversed().map { ($0, 0) }
        while let (element, depth) = stack.popLast(), lines.count < maxNodes {
            AXUIElementSetMessagingTimeout(element, 0.5)
            let elementRole = role(of: element) ?? "?"
            let subrole = stringAttribute(element, kAXSubroleAttribute).map { "/\($0)" } ?? ""
            let f = frame(of: element).map { "(\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height)))" } ?? "(no frame)"
            let actions = actionNames(element).filter { !$0.hasPrefix("AXScroll") }.joined(separator: ",")
            let name = String(accessibleName(element, role: elementRole).prefix(40))
            let enabled = boolAttribute(element, kAXEnabledAttribute) == false ? " disabled" : ""
            lines.append(String(repeating: "  ", count: depth) + "\(elementRole)\(subrole) \(f) [\(actions)]\(enabled) \"\(name)\"")
            for child in (childrenOf(element) ?? []).reversed() { stack.append((child, depth + 1)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Attribute helpers

    /// Chromium and Electron build their full tree only when asked; this is an ordinary AX attribute. Other apps
    /// don't support it, so the first successful request is the one that wakes the tree. Returns true then.
    static func wakeTree(_ app: AXUIElement, pid: pid_t) -> Bool {
        let firstRequest = awakened.insert(pid)
        var asleep = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
            && firstRequest
        // Apps built on the Chromium Embedded Framework (Spotify) ignore that and wake for the attribute VoiceOver
        // sets, even though they report an error. It changes other apps' behaviour, so only these get it.
        if firstRequest, !asleep, embedsChromium(pid) {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            asleep = true
        }
        return asleep
    }

    private static func embedsChromium(_ pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// The first element with `role` within `depth` levels below `element`, breadth first.
    static func firstDescendant(of element: AXUIElement, role wanted: String, depth: Int) -> AXUIElement? {
        var level = [element]
        for _ in 0..<depth {
            level = level.flatMap { childrenOf($0) ?? [] }
            if let match = level.first(where: { role(of: $0) == wanted }) { return match }
        }
        return nil
    }

    static func windowOf(_ app: AXUIElement) -> AXUIElement? {
        if let focused = elementAttribute(app, kAXFocusedWindowAttribute) { return focused }
        return elementAttribute(app, kAXMainWindowAttribute)
    }

    static func childrenOf(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    static func elementsAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    static func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute)
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Never reads the value of a text or secure field; their contents are not a search source.
    static func accessibleName(_ element: AXUIElement, role: String) -> String {
        let candidates = [
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute),
            stringAttribute(element, kAXPlaceholderValueAttribute),
            titleOfTitleElement(element),
            textRoles.contains(role) ? nil : stringAttribute(element, kAXValueAttribute),
            stringAttribute(element, kAXHelpAttribute)
        ]
        let name = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return name.map { String($0.prefix(120)) } ?? ""
    }

    /// The first piece of visible text inside a row, for naming it in search.
    static func firstText(in element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }
        for child in childrenOf(element) ?? [] {
            if role(of: child) == "AXStaticText",
               let text = (stringAttribute(child, kAXValueAttribute) ?? stringAttribute(child, kAXTitleAttribute))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return String(text.prefix(120))
            }
            if let text = firstText(in: child, depth: depth + 1) { return text }
        }
        return nil
    }

    static func titleOfTitleElement(_ element: AXUIElement) -> String? {
        guard let titleElement = elementAttribute(element, kAXTitleUIElementAttribute) else { return nil }
        return stringAttribute(titleElement, kAXValueAttribute) ?? stringAttribute(titleElement, kAXTitleAttribute)
    }

    static func roleDescription(_ role: String) -> String {
        switch role {
        case "AXTextField", "AXSearchField", "AXComboBox": return "Text field"
        case "AXSecureTextField": return "Password field"
        case "AXTextArea": return "Text area"
        default: return role.replacingOccurrences(of: "AX", with: "")
        }
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Global CoreGraphics frame from AXPosition and AXSize.
    static func frame(of element: AXUIElement) -> HintTarget.Frame? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return HintTarget.Frame(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    /// Visible when large enough, its centre lies inside the clip region, and it is on a display.
    static func isVisible(_ rect: CGRect, clip: CGRect, displays: [CGRect]) -> Bool {
        guard rect.width >= 4, rect.height >= 4 else { return false }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard clip.contains(center) else { return false }
        return displays.isEmpty || displays.contains { $0.contains(center) }
    }
}

extension HintTarget.Frame {
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
