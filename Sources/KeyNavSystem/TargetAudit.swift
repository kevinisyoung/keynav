import ApplicationServices
import Foundation
import KeyNavCore

/// Troubleshooting: checks Click mode's labels against an app's focused window without clicking anything.
/// For every label, whether the point it clicks hits that control; and the pressable controls left unlabelled.
public enum TargetAudit {
    public static func run(pid: pid_t) async -> String {
        var result = await AccessibilityTargets.discover(pid: pid, checkCovering: false)
        for _ in 0..<2 where result.treeWasAsleep {
            try? await Task.sleep(for: .milliseconds(1200))
            result = await AccessibilityTargets.discover(pid: pid, checkCovering: false)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let areas = await AccessibilityTargets.scrollContext(pid: pid, clickedAt: nil).areas
        let scrollMilliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        let text = await Task.detached(priority: .userInitiated) { report(pid: pid, result: result) }.value
        return text + "scroll context \(scrollMilliseconds) ms\n" + areas.map { "SCROLL AREA (\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height)))" }
            .joined(separator: "\n") + "\n"
    }

    private static func report(pid: pid_t, result: DiscoveryResult) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var lines = ["scope \(result.scope), targets \(result.targets.count), visited \(result.visitedNodes), "
                     + "truncated \(result.truncated), \(Int(result.elapsed * 1000)) ms"]
        var labelled: [AXUIElement] = []
        var misses = 0
        for (target, box) in zip(result.targets, result.elements) {
            labelled.append(box.element)
            lines.append("LABEL \(target.role) \"\(target.name.prefix(40))\" \(describe(target.frame))")
            // Menu bar, status icon, and Dock labels belong to other processes.
            var owner: pid_t = 0
            guard AXUIElementGetPid(box.element, &owner) == .success, owner == pid, target.role != "AXMenuBarItem" else {
                continue
            }
            let point = ClickPoint.of(target.frame.rect).point
            // Chromium answers a hit test from what it last tested and tests again in the background: ask twice.
            var hit: AXUIElement?
            _ = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
            Thread.sleep(forTimeInterval: 0.03)
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit else {
                continue
            }
            if !AccessibilityTargets.isSelfOrDescendant(hit, of: box.element) {
                misses += 1
                let hitRole = AccessibilityTargets.role(of: hit) ?? "?"
                let hitName = AccessibilityTargets.accessibleName(hit, role: hitRole).prefix(30)
                let relation = AccessibilityTargets.isSelfOrDescendant(box.element, of: hit) ? "its ancestor" : "unrelated"
                let hitFrame = AccessibilityTargets.frame(of: hit).map(describe) ?? "?"
                lines.append("MISS \(target.role) \"\(target.name.prefix(40))\" \(describe(target.frame)) "
                             + "clicks \(relation) \(hitRole) \"\(hitName)\" \(hitFrame)")
                let better = AccessibilityTargets.reachablePoint(box, preferred: point)
                lines.append(better == point ? "  no reachable point" : "  pointer goes to (\(Int(better.x)),\(Int(better.y)))")
            }
        }
        lines.append("\(misses) labels click something else")
        if let window = AccessibilityTargets.windowOf(app), let windowFrame = AccessibilityTargets.frame(of: window) {
            var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
            var visited = 0
            var unlabelled = 0
            while let (element, depth, covered) = stack.popLast(), visited < 6_000 {
                visited += 1
                AXUIElementSetMessagingTimeout(element, 0.25)
                let isTarget = labelled.contains { CFEqual($0, element) }
                let elementRole = AccessibilityTargets.role(of: element) ?? ""
                if !isTarget, !covered, let elementFrame = AccessibilityTargets.frame(of: element),
                   elementFrame.width >= 4, elementFrame.height >= 4,
                   elementFrame.rect.intersects(windowFrame.rect),
                   AccessibilityTargets.actionNames(element).contains(kAXPressAction) {
                    unlabelled += 1
                    let name = AccessibilityTargets.accessibleName(element, role: elementRole).prefix(40)
                    lines.append("UNLABELLED \(elementRole) \"\(name)\" \(describe(elementFrame))")
                }
                guard depth < 60 else { continue }
                for child in (AccessibilityTargets.childrenOf(element) ?? []).reversed() {
                    stack.append((child, depth + 1, covered || isTarget))
                }
            }
            lines.append("\(unlabelled) pressable controls without a label")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ frame: HintTarget.Frame) -> String {
        "(\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height)))"
    }
}
