import AppKit
import KeyNavCore
import KeyNavSystem
import Observation
import ServiceManagement

/// Settings pages, in sidebar order.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case click = "Clicking"
    case scroll = "Scrolling"
    case cursor = "Moving"
    case general = "General"
    case license = "License"
    case about = "About"

    var id: String { rawValue }
}

/// The app's single source of configuration. Every change is validated, saved atomically, applied, and undoable.
@Observable
@MainActor
final class AppModel {
    private(set) var config: KeyNavConfig
    let navigation: NavigationService
    let licensing = Licensing()
    private(set) var storageNote: String?
    /// The most recent saved change, shown with an Undo button.
    private(set) var lastChange: String?
    private var undoStack: [KeyNavConfig] = []
    private let store: ConfigStore?

    var page: SettingsPage = .click
    /// Screenshots of Settings show the ready state; the capture run has no keyboard access of its own.
    var assumesAccessForSnapshots = false

    /// KeyNav cannot take the keyboard right now (no access, or a password field is protecting it).
    var needsAccess: Bool {
        !assumesAccessForSnapshots && (!navigation.tapInstalled || navigation.readiness.secureInputActive)
    }
    /// A setting the search jumped to; the matching row highlights briefly.
    var highlightedSetting: String?

    init(store: ConfigStore? = try? ConfigStore.defaultStore()) {
        var loaded = KeyNavConfig.default
        var note: String?
        if let store {
            do {
                loaded = try store.load()
            } catch {
                // The file is left untouched so nothing is lost; defaults run until the person decides.
                note = "Saved settings could not be read, so defaults are in use. The file was not changed. \(error)"
            }
        } else {
            note = "Application Support is unavailable; changes will not be saved."
        }
        self.store = store
        self.config = loaded
        self.storageNote = note
        self.navigation = NavigationService(config: loaded)
        navigation.mayStart = { [licensing] in
            licensing.refresh()
            return licensing.status.allowsUse
        }
    }

    var settingsFileURL: URL? { store?.fileURL }

    /// Validates and applies a complete configuration. Returns blocking problems and changes nothing if any exist.
    @discardableResult
    func commit(_ newConfig: KeyNavConfig, _ description: String) -> [String] {
        guard newConfig != config else { return [] }
        let problems = ConfigValidator.problems(in: newConfig)
        guard problems.isEmpty else { return problems }
        do {
            try store?.save(newConfig)
        } catch {
            storageNote = "Settings could not be written: \(error)"
            return ["Settings could not be saved: \(error.localizedDescription)"]
        }
        undoStack.append(config)
        if undoStack.count > 30 { undoStack.removeFirst() }
        config = newConfig
        lastChange = description
        navigation.apply(config: newConfig)
        return []
    }

    /// Convenience for a single edit.
    @discardableResult
    func update(_ description: String, _ change: (inout KeyNavConfig) -> Void) -> [String] {
        var next = config
        change(&next)
        return commit(next, description)
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        try? store?.save(previous)
        config = previous
        lastChange = nil
        navigation.apply(config: previous)
    }

    func dismissChange() {
        lastChange = nil
    }

    // MARK: - Import and export

    func exportData() throws -> Data {
        try (store ?? ConfigStore(fileURL: URL(fileURLWithPath: "/dev/null"))).encode(config)
    }

    /// Reads a KeyNav settings file without applying it.
    func previewImport(_ data: Data) -> Result<KeyNavConfig, ConfigError> {
        do {
            return .success(try ConfigStore(fileURL: URL(fileURLWithPath: "/dev/null")).decode(data))
        } catch let error as ConfigError {
            return .failure(error)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    // MARK: - Launch at login

    var launchAtLoginStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Returns an error message when macOS refuses.
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "macOS did not change the login item: \(error.localizedDescription)"
        }
    }
}
