import AppKit
import KeyNavCore
import KeyNavSystem
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let arguments: [String]
    private var model: AppModel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var launchedAsLoginItem = false
    /// Checks keynav.app for a newer version once a day, and on request from the menus and Settings.
    private var updater: SPUStandardUpdaterController? { Updates.controller }

    init(arguments: [String]) {
        self.arguments = arguments
    }

    private func argument(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One instance only: a second copy would install a competing event tap.
        let utilityRun = argument(after: "--snapshot-settings") != nil || arguments.contains("--probe-apps") || arguments.contains("--outline-app") || arguments.contains("--audit-app") || arguments.contains("--label-sample") || arguments.contains("--preview-frames") || arguments.contains("--self-scan")
        if let bundleIdentifier = Bundle.main.bundleIdentifier, !utilityRun {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0 != NSRunningApplication.current }
            if let existing = others.first {
                existing.activate()
                exit(0)
            }
        }
        // A login-item launch stays quiet: no window, no mode.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = argument(after: "--snapshot-settings") {
            Task { @MainActor in
                await SettingsSnapshots.run(in: URL(fileURLWithPath: directory))
                exit(0)
            }
            return
        }

        // KeyNav --self-scan <output.txt>: scans an off-screen Settings window the way Label-click labels KeyNav
        // itself, to check that reading KeyNav's own window is safe. Nothing is shown or pressed.
        if let output = argument(after: "--self-scan") {
            // A throwaway settings file, and no event tap: this run only reads its own window.
            let model = AppModel(store: ConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("keynav-self-scan-\(getpid()).json")))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 940, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: SettingsWindowView().environment(model))
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            window.makeMain()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                let result = await AccessibilityTargets.discover(pid: getpid(), extras: .init(menuBar: true, dock: false),
                                                                 checkCovering: false)
                let text = "found window \(result.foundWindow), visited \(result.visitedNodes), targets \(result.targets.count)\n"
                try? text.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // KeyNav --preview-frames <dir>: still frames of the mode previews, rendered offscreen.
        if let directory = argument(after: "--preview-frames") {
            for (mode, times) in [(InteractionMode.cursor, [0.4, 1.4, 2.5, 3.3, 4.15]), (.click, [1.6])] {
                for time in times {
                    for scheme in [ColorScheme.light, .dark] {
                        let renderer = ImageRenderer(content: ModePreview(mode: mode, time: time)
                            .frame(width: 400, height: 92).padding(12)
                            .background(scheme == .dark ? Color(white: 0.17) : Color.white)
                            .environment(\.colorScheme, scheme))
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(mode.rawValue)-\(time)-\(scheme == .dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
            exit(0)
        }
        // KeyNav --label-sample <output.png>: the Click label style, rendered offscreen.
        if let output = argument(after: "--label-sample") {
            try? LabelSample.png()?.write(to: URL(fileURLWithPath: output))
            exit(0)
        }
        // KeyNav --outline-app <output.txt> <bundle id>: the focused window's Accessibility tree, for a missed control.
        if let index = arguments.firstIndex(of: "--outline-app"), arguments.indices.contains(index + 2) {
            let output = URL(fileURLWithPath: arguments[index + 1])
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[index + 2]).first?.processIdentifier
            let text = pid.map { AccessibilityTargets.outline(pid: $0) } ?? "not running\n"
            try? text.write(to: output, atomically: true, encoding: .utf8)
            exit(0)
        }
        // KeyNav --audit-app <output.txt> <bundle id>: labels whose click lands elsewhere, and unlabelled controls.
        if let index = arguments.firstIndex(of: "--audit-app"), arguments.indices.contains(index + 2) {
            let output = URL(fileURLWithPath: arguments[index + 1])
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[index + 2]).first?.processIdentifier
            Task { @MainActor in
                let text = if let pid { await TargetAudit.run(pid: pid) } else { "not running\n" }
                try? text.write(to: output, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if let index = arguments.firstIndex(of: "--probe-apps"), arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: arguments[index + 1])
            let bundleIDs = Array(arguments[(index + 2)...])
            Task { @MainActor in
                await CompatibilityProbe.run(output: output, bundleIDs: bundleIDs)
                exit(0)
            }
            return
        }

        let selfTestDirectory = argument(after: "--self-test") ?? argument(after: "--demo-labels") ?? argument(after: "--scroll-check")
        // The self-test uses its own settings file so the person's settings are never touched.
        let model = selfTestDirectory.map { AppModel(store: ConfigStore(fileURL: URL(fileURLWithPath: $0).appendingPathComponent("selftest-config.json"))) }
            ?? AppModel()
        self.model = model
        quitCleanlyOnSIGTERM()
        model.navigation.start()
        model.navigation.onTrialEnded = { [weak self] in self?.showPage(.license) }
        updateStatusItem()
        observeMenuBarPreference()

        if let checkDirectory = argument(after: "--scroll-check") {
            let fixture = argument(after: "--fixture")
            Task { @MainActor in
                let passed = await LiveSelfTest(model: model, output: URL(fileURLWithPath: checkDirectory), fixturePath: fixture,
                                                showSettings: { nil }).scrollCheck()
                model.navigation.shutdown()
                exit(passed ? 0 : 1)
            }
            return
        }

        if let demoDirectory = argument(after: "--demo-labels") {
            let fixture = argument(after: "--fixture")
            Task { @MainActor in
                await LiveSelfTest(model: model, output: URL(fileURLWithPath: demoDirectory), fixturePath: fixture,
                                   showSettings: { nil }).demoLabels(seconds: 4)
                model.navigation.shutdown()
                exit(0)
            }
            return
        }

        if let selfTestDirectory {
            let fixture = argument(after: "--fixture")
            Task { @MainActor in
                let passed = await LiveSelfTest(model: model, output: URL(fileURLWithPath: selfTestDirectory),
                                                fixturePath: fixture, showSettings: { [weak self] in
                                                    self?.showSettings()
                                                    return self?.settingsWindow
                                                }).run()
                model.navigation.shutdown()
                exit(passed ? 0 : 1)
            }
            return
        }
        // Only a bundle that names its update feed checks for updates; a build run from the source tree doesn't.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            Updates.controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        if !launchedAsLoginItem {
            showSettings()
        }
    }

    /// A plain `kill` (or an installer replacing the app) quits the normal way, so held buttons are released and
    /// overlays and the hidden pointer are restored before exit.
    private var terminationSource: DispatchSourceSignal?

    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.navigation.shutdown()
    }

    /// Reopening from Finder, Spotlight, Raycast, or the Dock brings Settings forward. It never enters a mode.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addModeItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings)))
        return menu
    }

    // MARK: - Window

    @objc func showSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "KeyNav"
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 540)
            window.contentViewController = NSHostingController(rootView: SettingsWindowView().environment(model))
            window.setContentSize(NSSize(width: 940, height: 680))
            window.center()
            window.setFrameAutosaveName("KeyNavSettings")
            // Closing Settings takes KeyNav back out of the Dock and the app switcher.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        // The sidebar search field would otherwise take focus, and a focused text field pauses navigation.
        DispatchQueue.main.async { [weak self] in self?.settingsWindow?.makeFirstResponder(nil) }
    }

    func showPage(_ page: SettingsPage) {
        model?.page = page
        showSettings()
    }

    // MARK: - Commands

    @objc func enterCursor() { model?.navigation.setMode(.cursor) }
    @objc func enterClick() { model?.navigation.setMode(.click) }
    @objc func enterScroll() { model?.navigation.setMode(.scroll) }
    @objc func stopNavigation() { model?.navigation.stopNavigation() }
    @objc func showKeys() { showPage(.cursor) }

    @objc func openHelp() {
        if let url = URL(string: "https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac") {
            NSWorkspace.shared.open(url)
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = self
        return menuItem
    }

    private func addModeItems(to menu: NSMenu) {
        menu.addItem(item("Start Moving", #selector(enterCursor)))
        menu.addItem(item("Start Clicking", #selector(enterClick)))
        menu.addItem(item("Start Scrolling", #selector(enterScroll)))
        menu.addItem(item("Stop Navigation", #selector(stopNavigation), key: "."))
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About KeyNav", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide KeyNav", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit KeyNav", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu("KeyNav", appMenu))

        // Standard editing commands, so cut, copy, paste, and undo work in Settings fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu("Edit", edit))

        let navigation = NSMenu(title: "Navigation")
        addModeItems(to: navigation)
        main.addItem(submenu("Navigation", navigation))

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu("Window", window))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(item("Moving Keys", #selector(showKeys)))
        help.addItem(item("Accessibility Access Help", #selector(openHelp)))
        main.addItem(submenu("Help", help))
        NSApp.helpMenu = help
        return main
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - Optional menu bar icon

    private func observeMenuBarPreference() {
        withObservationTracking {
            _ = model?.config.showMenuBarIcon
            _ = model?.navigation.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeMenuBarPreference()
            }
        }
    }

    private func updateStatusItem() {
        guard let model else { return }
        guard model.config.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            newItem.menu = menu
            statusItem = newItem
        }
        let symbol: String
        switch model.navigation.mode {
        case .off: symbol = "keyboard"
        case .cursor: symbol = "cursorarrow.motionlines"
        case .click: symbol = "hand.point.up.left"
        case .scroll: symbol = "scroll"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "KeyNav: \(model.navigation.mode.rawValue)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state: String
        switch model?.navigation.mode ?? .off {
        case .off: state = "Typing"
        case .cursor: state = "Moving"
        case .click: state = "Clicking"
        case .scroll: state = "Scrolling"
        }
        let header = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        addModeItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(NSMenuItem(title: "Quit KeyNav", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    @objc func checkForUpdates() {
        updater?.checkForUpdates(nil)
    }
}

/// The updater, shared by the menus and Settings › General. Nil in builds run from the source tree.
@MainActor
enum Updates {
    static var controller: SPUStandardUpdaterController?
}
