import AppKit
import ApplicationServices
import Foundation
import KeyNavCore

/// A report about Clicking's labels or Scrolling's panes, sent to keynav.app when someone asks.
///
/// It holds no screenshot: only what's needed to draw the scene again as a wireframe. Every position is in global
/// points (top-left origin), rects as [x, y, w, h]. Without names it carries no text from the screen at all:
/// roles and positions only. The person's own note goes with it either way.
enum ProblemReport {
    static var endpoint: URL {
        if let custom = UserDefaults.standard.string(forKey: "KeyNavReportURL"), let url = URL(string: custom) { return url }
        return URL(string: "https://keynav.app/api/report")!
    }

    struct ClickScene: Sendable {
        var targets: [HintTarget]
        var labels: [String]
        var elements: [AXElementBox]
        var drawn: [String: (body: CGRect, tip: CGPoint)]
        var stats: NavigationService.DiscoveryStats?
        /// Label size: it moves where labels sit and where they click.
        var scale: Double = 1
    }

    struct ScrollScene: Sendable {
        var window: HintTarget.Frame?
        var areas: [HintTarget.Frame]
        var outlined: HintTarget.Frame?
        var areaIndex: Int?
        var lastClick: CGPoint?
    }

    /// The parts every report shares.
    @MainActor
    static func base(_ draft: ReportDraft, pid: pid_t, window: HintTarget.Frame?, pointer: CGPoint) -> [String: Any] {
        let app = NSRunningApplication(processIdentifier: pid)
        let appBundle = app?.bundleURL.flatMap(Bundle.init(url:))
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let top = ScreenSpace.primaryHeight
        var report: [String: Any] = [
            "v": 1,
            "mode": draft.mode == .scroll ? "scroll" : "click",
            "level": "layout",
            "app": [
                "bundle": app?.bundleIdentifier ?? "?",
                "version": appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            ],
            "keynav": [
                "version": info["CFBundleShortVersionString"] as? String ?? "dev",
                "build": Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                "store": info["KeyNavStoreBuild"] as? Bool == true
            ],
            "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "displays": NSScreen.screens.map { screen in
                ["frame": rect(CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                                      width: screen.frame.width, height: screen.frame.height)),
                 "scale": screen.backingScaleFactor] as [String: Any]
            },
            "pointer": point(pointer),
            "note": draft.text
        ]
        if let window { report["window"] = rect(window.rect) }
        if draft.mode == .scroll {
            report["marked"] = Int(draft.marked).map { $0 as Any } ?? NSNull()
        } else {
            report["marked"] = draft.marked.isEmpty ? NSNull() : draft.marked
        }
        return report
    }

    /// Each label: its control, where the label was drawn, where it clicks, and what a click there would hit.
    static func click(_ scene: ClickScene, pid: pid_t, names: Bool) async -> Data {
        await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            var targets: [[String: Any]] = []
            for (index, target) in scene.targets.enumerated() {
                let label = scene.labels.indices.contains(index) ? scene.labels[index] : ""
                let drawn = scene.drawn[label]
                let box = scene.elements.indices.contains(index) ? scene.elements[index] : nil
                let clickPoint = drawn?.tip ?? ClickPoint.of(target.frame.rect, scale: scene.scale).point
                var entry: [String: Any] = [
                    "label": label.uppercased(), "role": target.role,
                    "frame": rect(target.frame.rect), "point": point(clickPoint),
                    "chip": drawn.map { rect($0.body) } ?? NSNull()
                ]
                if names { entry["name"] = target.name }
                // Where a pointer click really goes, when that isn't the control's own frame (a link's title).
                if let clickFrame = box?.clickFrame {
                    entry["clickFrame"] = rect(clickFrame.rect)
                    entry["clickPoint"] = point(ClickPoint.of(clickFrame.rect, scale: scene.scale).point)
                }
                if let box {
                    if let action = box.pressAction { entry["action"] = action }
                    entry["actions"] = box.actions
                }
                // The menu bar answers hit tests as its own process, so a hit test can't check it.
                if scene.elements.indices.contains(index), target.role != "AXMenuBarItem" {
                    entry["hit"] = hit(at: clickPoint, expecting: scene.elements[index].element, app: app, pid: pid) ?? NSNull()
                }
                targets.append(entry)
            }
            var result: [String: Any] = ["targets": targets]
            if let stats = scene.stats {
                result["scope"] = stats.scope
                result["visited"] = stats.visitedNodes
                result["truncated"] = stats.truncated
                result["ms"] = Int(stats.milliseconds)
            }
            result["unlabelled"] = unlabelled(app: app, labelled: scene.elements.map(\.element), names: names)
            result["tree"] = tree(app: app, labels: Array(zip(scene.elements.map(\.element), scene.labels)), names: names)
            return json(result)
        }.value
    }

    /// The settings that change where labels go and what gets one.
    static func settings(_ config: KeyNavConfig) -> [String: Any] {
        [
            "labelSize": config.appearance.hintSize.rawValue,
            "labelScale": config.appearance.hintSize.scale,
            "alphabet": config.clickAlphabet,
            "labelMenuBar": config.clickLabelsMenuBar,
            "labelDock": config.clickLabelsDock,
            "requireReturn": config.clickRequireReturn,
            "searchFirst": config.clickSearchFirst,
            "pointerFallback": config.clickPointerFallback
        ]
    }

    /// The panes on screen, and how a fresh scan of the window decides them.
    static func scroll(_ scene: ScrollScene, pid: pid_t, names: Bool) async -> Data {
        let trace = await AccessibilityTargets.scrollTrace(pid: pid)
        let context = await AccessibilityTargets.scrollContext(pid: pid, clickedAt: scene.lastClick, areas: false)
        let treeData = await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            return json(tree(app: app, labels: [], names: names))
        }.value
        let chain = { (nodes: [ScrollNode]) in nodes.map { ["role": $0.role, "frame": rect($0.frame.rect)] as [String: Any] } }
        return json([
            "areas": scene.areas.map { rect($0.rect) },
            "outlined": scene.outlined.map { rect($0.rect) } ?? NSNull(),
            "areaIndex": scene.areaIndex ?? NSNull(),
            "scan": [
                "areas": trace.areas.map { rect($0.rect) }
            ],
            "scrollAreas": trace.scrollAreas.map { rect($0.rect) },
            "candidates": trace.candidates.map { candidate in
                [
                    "rect": rect(candidate.rect),
                    "page": candidate.page.map(rect) ?? NSNull(),
                    "pane": candidate.pane.map { rect($0.rect) } ?? NSNull(),
                    "scrolls": candidate.scrolls,
                    "role": candidate.role ?? NSNull(),
                    "top": candidate.top.map { Double($0) } ?? NSNull(),
                    "bottom": candidate.bottom.map { Double($0) } ?? NSNull(),
                    "evidence": candidate.evidence.map(rect) ?? NSNull(),
                    "kept": candidate.dropped == nil,
                    "reason": candidate.dropped ?? NSNull()
                ] as [String: Any]
            },
            "rejected": trace.rejected.map { block in
                ["rect": rect(block.rect), "page": block.page.map(rect) ?? NSNull(), "role": block.role ?? NSNull(),
                 "reason": block.dropped ?? NSNull()] as [String: Any]
            },
            "pageSlivers": trace.pageSlivers.map { ["page": rect($0.page), "count": $0.count] as [String: Any] },
            "visited": trace.visited,
            "timedOut": trace.timedOut,
            "ms": Int(trace.milliseconds),
            "clickChain": chain(context.clickChain),
            "focusChain": chain(context.focusChain),
            "tree": (try? JSONSerialization.jsonObject(with: treeData)) ?? NSNull()
        ])
    }

    /// Puts the scene's parts into the report: `sections` maps a key ("click", "scroll") to its JSON.
    static func assemble(_ base: Data, _ sections: [String: Data]) -> Data? {
        guard var report = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return nil }
        for (key, data) in sections { report[key] = try? JSONSerialization.jsonObject(with: data) }
        return try? JSONSerialization.data(withJSONObject: report)
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    /// Sends a report. Nil when it arrived, otherwise why not, in a few words.
    static func send(_ body: Data?) async -> String? {
        guard let body else { return "it couldn't be written" }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        request.setValue("KeyNav/\(version)", forHTTPHeaderField: "User-Agent")
        // Raw DEFLATE: the window's tree makes a report a few hundred KB of JSON, which compresses about tenfold.
        if let packed = try? (body as NSData).compressed(using: .zlib) as Data {
            request.httpBody = packed
            request.setValue("deflate-raw", forHTTPHeaderField: "X-KeyNav-Encoding")
        } else {
            request.httpBody = body
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return nil
            case 429: return "too many reports today"
            default: return "keynav.app answered \(status)"
            }
        } catch {
            return "no connection"
        }
    }

    // MARK: - Helpers

    private static func rect(_ r: CGRect) -> [Double] {
        [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 }
    }

    private static func point(_ p: CGPoint) -> [Double] {
        [p.x, p.y].map { (Double($0) * 10).rounded() / 10 }
    }

    /// What a click at `spot` would land on, and how it relates to the labelled control.
    private static func hit(at spot: CGPoint, expecting element: AXUIElement, app: AXUIElement, pid: pid_t) -> [String: Any]? {
        var owner: pid_t = 0
        // Menu bar, status icon, and Dock labels belong to other processes.
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        var found: AXUIElement?
        // Chromium answers a hit test from what it last tested and tests again in the background: ask twice.
        _ = AXUIElementCopyElementAtPosition(app, Float(spot.x), Float(spot.y), &found)
        guard AXUIElementCopyElementAtPosition(app, Float(spot.x), Float(spot.y), &found) == .success, let found else { return nil }
        let ok = AccessibilityTargets.isSelfOrDescendant(found, of: element)
        let relation = ok ? "self" : AccessibilityTargets.isSelfOrDescendant(element, of: found) ? "ancestor" : "unrelated"
        var result: [String: Any] = ["ok": ok, "relation": relation, "role": AccessibilityTargets.role(of: found) ?? "?"]
        if let frame = AccessibilityTargets.frame(of: found) { result["frame"] = rect(frame.rect) }
        return result
    }

    /// The focused window's Accessibility tree, stripped down: for each element its parent's index, role, subrole,
    /// frame, actions, and whether it's disabled; its name only with names on; and the label it got, if any.
    /// Enough to see the whole scene, and later to run the labelling and pane scan against it again.
    static func tree(app: AXUIElement, labels: [(AXUIElement, String)], names: Bool,
                     maxNodes: Int = 4_000, seconds: Double = 2.5) -> [String: Any] {
        guard let window = AccessibilityTargets.windowOf(app) else { return [:] }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var nodes: [[String: Any]] = []
        var queue: [(AXUIElement, Int)] = [(window, -1)]
        var head = 0
        while head < queue.count, nodes.count < maxNodes, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, parent) = queue[head]
            head += 1
            let role = AccessibilityTargets.role(of: element) ?? "?"
            var node: [String: Any] = ["p": parent, "r": role]
            if let subrole = attribute(element, kAXSubroleAttribute) as? String { node["s"] = subrole }
            if let frame = AccessibilityTargets.frame(of: element) { node["f"] = rect(frame.rect) }
            let actions = AccessibilityTargets.actionNames(element)
            if !actions.isEmpty { node["a"] = actions.map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 } }
            if attribute(element, kAXEnabledAttribute) as? Bool == false { node["e"] = false }
            if names {
                let name = AccessibilityTargets.accessibleName(element, role: role)
                if !name.isEmpty { node["n"] = String(name.prefix(80)) }
            }
            if let label = labels.first(where: { CFEqual($0.0, element) })?.1 { node["t"] = label.uppercased() }
            let index = nodes.count
            nodes.append(node)
            for child in AccessibilityTargets.childrenOf(element) ?? [] { queue.append((child, index)) }
        }
        return ["nodes": nodes, "complete": head >= queue.count]
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Pressable controls in the focused window that got no label.
    private static func unlabelled(app: AXUIElement, labelled: [AXUIElement], names: Bool) -> [[String: Any]] {
        guard let window = AccessibilityTargets.windowOf(app), let windowFrame = AccessibilityTargets.frame(of: window) else { return [] }
        var found: [[String: Any]] = []
        var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while let (element, depth, covered) = stack.popLast(), visited < 6_000, found.count < 300,
              ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            let isTarget = labelled.contains { CFEqual($0, element) }
            let role = AccessibilityTargets.role(of: element) ?? ""
            if !isTarget, !covered, let frame = AccessibilityTargets.frame(of: element),
               frame.width >= 4, frame.height >= 4, frame.rect.intersects(windowFrame.rect),
               AccessibilityTargets.actionNames(element).contains(kAXPressAction) {
                var entry: [String: Any] = ["role": role, "frame": rect(frame.rect)]
                if names { entry["name"] = AccessibilityTargets.accessibleName(element, role: role) }
                found.append(entry)
            }
            guard depth < 60 else { continue }
            for child in (AccessibilityTargets.childrenOf(element) ?? []).reversed() {
                stack.append((child, depth + 1, covered || isTarget))
            }
        }
        return found
    }
}

/// Troubleshooting: the report Clicking or Scrolling would send for an app's focused window, without the labels or
/// outline on screen. Labels have no drawn position here; their click point stands in.
public enum ReportProbe {
    @MainActor
    public static func run(pid: pid_t, mode: InteractionMode, names: Bool, send: Bool) async -> (json: Data, problem: String?) {
        let draft = ReportDraft(mode: mode)
        var sections: [String: Data] = [:]
        var window: HintTarget.Frame?
        if mode == .scroll {
            let context = await AccessibilityTargets.scrollContext(pid: pid, clickedAt: nil)
            window = context.window
            let scene = ProblemReport.ScrollScene(window: context.window, areas: context.areas, outlined: nil, areaIndex: nil, lastClick: nil)
            sections["scroll"] = await ProblemReport.scroll(scene, pid: pid, names: names)
        } else {
            let result = await AccessibilityTargets.discover(pid: pid)
            window = result.windowFrame.map { HintTarget.Frame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
            let labels = LabelGenerator.labels(count: result.targets.count, alphabet: Array(KeyNavConfig.defaultAlphabet))
            let scene = ProblemReport.ClickScene(targets: result.targets, labels: labels, elements: result.elements, drawn: [:],
                                                 stats: .init(targets: result.targets.count, milliseconds: result.elapsed * 1000,
                                                              visitedNodes: result.visitedNodes, truncated: result.truncated,
                                                              scope: result.scope, contentTargets: result.contentTargets))
            sections["click"] = await ProblemReport.click(scene, pid: pid, names: names)
        }
        var fields = ProblemReport.base(draft, pid: pid, window: window, pointer: .zero)
        fields["settings"] = ProblemReport.settings(.default)
        let base = ProblemReport.json(fields)
        let json = ProblemReport.assemble(base, sections) ?? Data()
        return (json, send ? await ProblemReport.send(json) : nil)
    }
}
