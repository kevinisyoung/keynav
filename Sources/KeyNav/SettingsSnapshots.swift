import AppKit
import KeyNavCore
import KeyNavSystem
import SwiftUI

/// Shows each Settings page in a real window so an external tool can capture exactly that window.
///
///   KeyNav --snapshot-settings <directory>
///
/// For every page and variant the app writes `<directory>/request` containing "<windowNumber> <name>",
/// then waits until `<directory>/<name>.png` exists (written by `scripts/capture_settings.sh` with
/// `screencapture -l`). Only KeyNav's own window is captured; a throwaway settings file is used.
@MainActor
enum SettingsSnapshots {
    static func run(in directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("keynav-snapshot-\(UUID().uuidString).json"))
        // No event tap: a second keyboard listener would act on the person's keys alongside the running KeyNav.
        let model = AppModel(store: store)
        model.assumesAccessForSnapshots = true

        let variants: [(name: String, appearance: NSAppearance.Name, size: NSSize)] = [
            ("light", .aqua, NSSize(width: 940, height: 680)),
            ("dark", .darkAqua, NSSize(width: 940, height: 680)),
            ("narrow", .aqua, NSSize(width: 720, height: 540))
        ]
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 940, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "KeyNav"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsWindowView().environment(model))
        // Drawn behind everything and never activated, so capturing does not interrupt whoever is using the Mac.

        for variant in variants {
            NSApp.appearance = NSAppearance(named: variant.appearance)
            window.setContentSize(variant.size)
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                              y: screen.visibleFrame.midY - window.frame.height / 2))
            }
            for page in SettingsPage.allCases {
                model.page = page
                window.orderBack(nil)
                try? await Task.sleep(for: .milliseconds(900))
                let slug = page.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
                let name = "settings-\(slug)-\(variant.name)"
                let output = directory.appendingPathComponent("\(name).png")
                try? "\(window.windowNumber) \(name)".write(to: directory.appendingPathComponent("request"), atomically: true, encoding: .utf8)
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: output.path), Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("request"))
        window.close()
        try? FileManager.default.removeItem(at: store.fileURL)
    }
}
