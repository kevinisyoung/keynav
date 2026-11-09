import AppKit
import KeyNavSystem

/// Read-only compatibility probe: runs Click-mode discovery on running apps' focused windows.
/// Nothing is clicked, focused, or typed. Only counts and timings are recorded, never names or titles.
///
///   KeyNav --probe-apps <output.json> <bundle id> [<bundle id> …]
@MainActor
enum CompatibilityProbe {
    struct Row: Codable {
        var bundleID: String
        var version: String
        var running: Bool
        var foundWindow: Bool
        var targets: Int
        var milliseconds: Double
        var visitedNodes: Int
        var truncated: Bool
        var roles: [String: Int]
        var covered = 0
    }

    static func run(output: URL, bundleIDs: [String]) async {
        var rows: [Row] = []
        for bundleID in bundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                rows.append(Row(bundleID: bundleID, version: "", running: false, foundWindow: false, targets: 0,
                                milliseconds: 0, visitedNodes: 0, truncated: false, roles: [:]))
                continue
            }
            let version = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? ""
            let result = await AccessibilityTargets.discover(pid: app.processIdentifier, checkCovering: false)
            var roles: [String: Int] = [:]
            for target in result.targets { roles[target.role, default: 0] += 1 }
            rows.append(Row(bundleID: bundleID, version: version, running: true, foundWindow: result.foundWindow,
                            targets: result.targets.count, milliseconds: result.elapsed * 1000,
                            visitedNodes: result.visitedNodes, truncated: result.truncated, roles: roles,
                            covered: result.covered))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(rows).write(to: output)
    }
}
