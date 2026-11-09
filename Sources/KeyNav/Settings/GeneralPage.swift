import AppKit
import KeyNavCore
import KeyNavSystem
import ServiceManagement
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

struct GeneralPage: View {
    @Environment(AppModel.self) private var model
    @State private var loginError: String?
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var importReview: ImportReview?
    @State private var showReset = false
    @State private var checksForUpdates = Updates.controller?.updater.automaticallyChecksForUpdates ?? false

    var body: some View {
        Form {
            if model.needsAccess {
                Section { AccessCard() }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { value in
                        loginError = model.setLaunchAtLogin(value)
                        loginStatus = model.launchAtLoginStatus
                    }
                )) {
                    SettingLabel(title: "Open at login", detail: "Start KeyNav when you log in to your Mac.")
                }
                if loginStatus == .requiresApproval {
                    Label("Approve KeyNav in System Settings › Login Items", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                SettingToggle(title: "Show in menu bar", detail: "An icon that shows which mode is on.", keyPath: \.showMenuBarIcon)
                if let updates = Updates.controller {
                    Toggle(isOn: Binding(
                        get: { checksForUpdates },
                        set: { checksForUpdates = $0; updates.updater.automaticallyChecksForUpdates = $0 }
                    )) {
                        SettingLabel(title: "Check for updates automatically", detail: "KeyNav looks for a new version once a day.")
                    }
                    HStack {
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updates.checkForUpdates(nil) }
                    }
                }
            }
            .onAppear { loginStatus = model.launchAtLoginStatus }

            Section {
                ForEach(model.config.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        AppIconView(bundleID: bundleID)
                        Text(appName(bundleID))
                        Spacer()
                        Button {
                            model.update("KeyNav turned back on in \(appName(bundleID))") { $0.excludedBundleIDs.removeAll { $0 == bundleID } }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Turn KeyNav back on here")
                    }
                }
                Menu("Add App…") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                            guard let id = app.bundleIdentifier else { return }
                            model.update("KeyNav turned off in \(app.localizedName ?? id)") { $0.excludedBundleIDs.append(id) }
                        }
                    }
                }
                .fixedSize()
            } header: {
                Text("Turned off in")
            } footer: {
                Text("In these apps KeyNav stays out of the way, and its shortcuts reach the app.")
            }

            Section {
                HStack {
                    Menu("Import") {
                        Button("KeyNav Settings…", action: importSettings)
                        Button("Mouseless Keys…", action: importMouseless)
                    }
                    .fixedSize()
                    Button("Export…", action: exportSettings)
                    Spacer()
                    Button("Reset…") { showReset = true }
                }
            }

            if let note = model.storageNote {
                Section {
                    Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $importReview) { review in
            ImportReviewSheet(review: review) { importReview = nil }
        }
        .sheet(isPresented: $showReset) {
            ResetSheet { showReset = false }
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !model.config.excludedBundleIDs.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KeyNav Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportData().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = (try? Data(contentsOf: url)) ?? Data()
        switch model.previewImport(data) {
        case let .success(config):
            importReview = ImportReview(title: "Import \(url.lastPathComponent)", proposed: config, rows: [], problems: [])
        case let .failure(error):
            importReview = ImportReview(title: "Import \(url.lastPathComponent)", proposed: nil, rows: [], problems: [error.description])
        }
    }

    private func importMouseless() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Mouseless config.yaml. KeyNav only reads it."
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText, .plainText, .data]
        let usual = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mouseless/configs", isDirectory: true)
        if FileManager.default.fileExists(atPath: usual.path) { panel.directoryURL = usual }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importReview = ImportReview(title: "Mouseless import", proposed: nil, rows: [], problems: ["The file could not be read as text. Nothing was changed."])
            return
        }
        let result = MouselessImport.translate(yaml: text, base: model.config)
        importReview = ImportReview(title: "Import from Mouseless", proposed: result.proposed, rows: result.rows, problems: result.problems)
    }
}

struct ImportReview: Identifiable {
    let id = UUID()
    let title: String
    let proposed: KeyNavConfig?
    let rows: [MouselessImport.Row]
    let problems: [String]
}

/// Nothing is applied until the person reviews the proposal. Invalid input never partially applies.
struct ImportReviewSheet: View {
    @Environment(AppModel.self) private var model
    let review: ImportReview
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.title).font(.title3.weight(.semibold))
            if !review.rows.isEmpty {
                Table(review.rows) {
                    TableColumn("Mouseless command") { Text($0.source) }
                    TableColumn("Key") { Text($0.sourceBinding).foregroundStyle(.secondary) }
                    TableColumn("KeyNav") { Text($0.proposal) }
                    TableColumn("Note") { row in
                        Text(row.issue ?? "").foregroundStyle(row.issue == nil ? Color.secondary : Color.orange)
                            .help(row.issue ?? "")
                    }
                }
                .frame(minHeight: 220)
            }
            if let proposed = review.proposed {
                let changes = BindingChange.diff(from: model.config.cursorBindings, to: proposed.cursorBindings)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(changes.count) Cursor action\(changes.count == 1 ? "" : "s") change.").font(.callout.weight(.medium))
                    if proposed.cursorEntry != model.config.cursorEntry {
                        Text("Cursor start: \(proposed.cursorEntry.gesture.displayName); exit: \(proposed.cursorEntry.separateExit ? proposed.cursorEntry.exit.displayName : "same key")").font(.callout)
                    }
                    if proposed.clickEntry != model.config.clickEntry {
                        Text("Label-click start: \(proposed.clickEntry.gesture.displayName)").font(.callout)
                    }
                    if proposed.motion != model.config.motion {
                        Text("Pointer speed changes to \(proposed.motion.presetName ?? "custom values").").font(.callout)
                    }
                    Text("Your current settings are kept as a backup, and Undo is available.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !review.problems.isEmpty {
                Text("This cannot be applied. Nothing was changed.").font(.callout.weight(.semibold)).foregroundStyle(.red)
                ProblemList(problems: review.problems)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let proposed = review.proposed {
                        model.commit(proposed, review.rows.isEmpty ? "Settings imported" : "Mouseless keys imported")
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(review.proposed == nil || !review.problems.isEmpty)
            }
        }
        .padding(22)
        .frame(width: review.rows.isEmpty ? 480 : 760)
    }
}

struct ResetSheet: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var scope = Scope.cursor

    enum Scope: String, CaseIterable {
        case cursor = "Cursor keys and speed"
        case click = "Label-click settings"
        case everything = "Everything"
    }

    var body: some View {
        let proposed = resetConfig()
        let changes = BindingChange.diff(from: model.config.cursorBindings, to: proposed.cursorBindings)
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset Settings").font(.title3.weight(.semibold))
            Picker("Reset", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            VStack(alignment: .leading, spacing: 4) {
                if proposed == model.config {
                    Text("These settings already use the defaults.").foregroundStyle(.secondary)
                } else {
                    if !changes.isEmpty { Text("\(changes.count) Cursor action\(changes.count == 1 ? "" : "s") return to default keys.") }
                    if proposed.motion != model.config.motion { Text("Pointer speed returns to Gentle.") }
                    if proposed.clickAlphabet != model.config.clickAlphabet || proposed.clickControls != model.config.clickControls {
                        Text("Label-click labels and keys return to the defaults.")
                    }
                    if proposed.cursorEntry != model.config.cursorEntry || proposed.clickEntry != model.config.clickEntry {
                        Text("Start and exit shortcuts return to Right Option tap, Command Shift Space, and Command Shift J, with Escape to exit.")
                    }
                    if proposed.excludedBundleIDs != model.config.excludedBundleIDs { Text("Every app is allowed again.") }
                }
            }
            .font(.callout)
            HStack {
                Text("Undo is available afterwards.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Reset", role: .destructive) {
                    model.commit(proposed, "\(scope.rawValue) reset to defaults")
                    close()
                }
                .disabled(proposed == model.config)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func resetConfig() -> KeyNavConfig {
        let defaults = KeyNavConfig.default
        var config = model.config
        switch scope {
        case .cursor:
            config.cursorBindings = defaults.cursorBindings
            config.motion = defaults.motion
            config.scrolling = defaults.scrolling
            config.dragStyle = defaults.dragStyle
            config.profileName = defaults.profileName
        case .click:
            config.clickControls = defaults.clickControls
            config.clickAlphabet = defaults.clickAlphabet
            config.clickSearchFirst = defaults.clickSearchFirst
            config.clickRequireReturn = defaults.clickRequireReturn
            config.clickStaysActive = defaults.clickStaysActive
            config.clickPointerFallback = defaults.clickPointerFallback
            config.clickLabelsMenuBar = defaults.clickLabelsMenuBar
            config.clickLabelsDock = defaults.clickLabelsDock
        case .everything:
            config = defaults
        }
        return config
    }
}

struct AboutPage: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let navigation = model.navigation
        let report = navigation.readiness
        let allowed = !model.needsAccess || (report.accessibilityTrusted && navigation.tapInstalled)
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KeyNav").font(.title2.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                StatusLine(ok: allowed, title: "Keyboard access",
                           detail: allowed
                               ? "Allowed. KeyNav can read shortcuts and find controls."
                               : "Not allowed yet. Turn on KeyNav in Privacy & Security › Accessibility.")
                if report.secureInputActive && !model.assumesAccessForSnapshots {
                    StatusLine(ok: false, title: "Secure input is on",
                               detail: "\(report.secureInputApp ?? "Another app") has a password field active, so KeyNav waits until it closes. If no password field is open there, quit and reopen \(report.secureInputApp ?? "that app").")
                }
                HStack {
                    if !allowed {
                        Button("Open Privacy & Security") { Permissions.openAccessibilitySettings() }
                        Button("Check Again") { navigation.recheckReadiness() }
                    }
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostic Report") {
                        copyReport()
                        copied = true
                    }
                }
            } footer: {
                Text("The report lists recent events and versions. It never includes what you type or what is on screen.")
            }
        }
        .formStyle(.grouped)
    }

    private func copyReport() {
        let navigation = model.navigation
        let report = navigation.readiness
        var lines = [
            "KeyNav \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")",
            "macOS: \(report.osVersion)",
            "Accessibility: \(report.accessibilityTrusted), tap installed: \(navigation.tapInstalled), secure input: \(report.secureInputActive)",
            "Mode: \(navigation.mode.rawValue), profile: \(model.config.profileName), schema: \(model.config.schemaVersion)"
        ]
        if let stats = navigation.lastDiscovery {
            lines.append("Last discovery: \(stats.targets) targets, \(Int(stats.milliseconds)) ms, \(stats.visitedNodes) nodes, truncated: \(stats.truncated)")
        }
        lines += navigation.log.suffix(20).map { "\($0.date.formatted(.dateTime.hour().minute().second())) \($0.text)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
