import Foundation

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case conflicts([String])
    case unreadable(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(version):
            return "This file uses settings version \(version), which this KeyNav cannot read."
        case let .conflicts(messages):
            return messages.joined(separator: "\n")
        case let .unreadable(detail):
            return "The file is not a KeyNav settings file (\(detail))."
        }
    }
}

public enum ConfigValidator {
    /// Shortcuts macOS commonly reserves. Matching one is a warning that needs confirmation, not a hard error,
    /// because people may have turned the system shortcut off. KeyNav cannot know other apps' hotkeys.
    public static let knownSystemShortcuts: [Gesture: String] = [
        .key(code: Key.space, modifiers: [.command]): "Spotlight",
        .key(code: Key.space, modifiers: [.control]): "Select the previous input source",
        .key(code: Key.space, modifiers: [.control, .option]): "Select the next input source",
        .key(code: Key.space, modifiers: [.command, .option]): "Finder search window",
        .key(code: Key.tab, modifiers: [.command]): "App switcher",
        .key(code: 20, modifiers: [.command, .shift]): "Screenshot",
        .key(code: 21, modifiers: [.command, .shift]): "Screenshot selection",
        .key(code: 23, modifiers: [.command, .shift]): "Screenshot toolbar",
        .key(code: Key.q, modifiers: [.command]): "Quit app",
        .key(code: Key.w, modifiers: [.command]): "Close window",
        .key(code: Key.escape, modifiers: [.command, .option]): "Force Quit"
    ]

    /// Blocking problems. An empty list means the configuration is safe to apply.
    public static func problems(in config: KeyNavConfig) -> [String] {
        var problems: [String] = []
        let cursorTable = BindingTable(config.cursorBindings.map { ($0.gesture, $0.action) })
        for conflict in cursorTable.conflicts {
            problems.append("\(conflict.gesture.displayName) is assigned to both “\(conflict.first.title)” and “\(conflict.second.title)” in Moving.")
        }
        var controlOwners: [Gesture: ClickControl] = [:]
        for control in ClickControl.allCases {
            guard let gesture = config.clickControls[control] else { continue }
            if let other = controlOwners[gesture] {
                problems.append("\(gesture.displayName) is assigned to both “\(other.title)” and “\(control.title)” in Clicking.")
            }
            controlOwners[gesture] = control
        }
        let entries = config.entries
        for (index, first) in entries.enumerated() {
            for second in entries.dropFirst(index + 1) where first.entry.gesture == second.entry.gesture {
                problems.append("\(first.mode.name) and \(second.mode.name) cannot start with the same shortcut.")
            }
        }
        for (name, entry) in entries.map({ ($0.mode.name, $0.entry) }) where entry.separateExit {
            if entry.exit == entry.gesture {
                problems.append("\(name)’s stop key must differ from its start shortcut.")
            }
        }
        if config.cursorEntry.separateExit, let action = cursorTable[config.cursorEntry.exit] {
            problems.append("\(config.cursorEntry.exit.displayName) stops Moving, so it cannot also be “\(action.title)”.")
        }
        if config.clickEntry.separateExit, let control = controlOwners[config.clickEntry.exit] {
            problems.append("\(config.clickEntry.exit.displayName) stops Clicking, so it cannot also be “\(control.title)”.")
        }
        // Entries are checked before mode keys, so a binding equal to an entry would never run.
        for entry in entries.map(\.entry.gesture) {
            if let action = cursorTable[entry] {
                problems.append("\(entry.displayName) starts a mode, so it cannot also be “\(action.title)”.")
            }
            if let control = controlOwners[entry] {
                problems.append("\(entry.displayName) starts a mode, so it cannot also be “\(control.title)”.")
            }
        }
        let usable = LabelGenerator.usableAlphabet(config.clickAlphabet, reserved: [])
        if usable.count < 2 {
            problems.append("Labels need at least two different letters.")
        }
        if config.motion.maximumSpeed < config.motion.initialSpeed {
            problems.append("Top speed must be at least the starting speed.")
        }
        return problems
    }

    /// Non-blocking notes the Settings UI shows before saving.
    public static func warnings(in config: KeyNavConfig) -> [String] {
        var warnings: [String] = []
        for (name, entry) in config.entries.map({ ($0.mode.name, $0.entry) }) {
            if let system = knownSystemShortcuts[entry.gesture] {
                warnings.append("\(entry.gesture.displayName) may already be used by macOS for \(system). KeyNav will take it first.")
            }
            if entry.separateExit, case let .key(code, modifiers) = entry.exit, modifiers.isEmpty,
               let text = Key.printableCodes[code], text.count == 1 {
                warnings.append("“\(text)” stops \(name), so it cannot be typed in Clicking search or used in labels.")
            }
        }
        return warnings
    }
}

/// Atomic, versioned JSON persistence with a last-known-good backup.
public struct ConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: ~/Library/Application Support/KeyNav/config.json
    public static func defaultStore() throws -> ConfigStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("KeyNav", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
    }

    public var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("config.previous.json")
    }

    /// Missing file means first run: defaults. A broken file throws; the caller keeps the file untouched.
    public func load() throws -> KeyNavConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }
        return try decode(Data(contentsOf: fileURL))
    }

    /// Decodes and migrates. Never returns a configuration with blocking problems.
    public func decode(_ data: Data) throws -> KeyNavConfig {
        var config: KeyNavConfig
        do {
            config = try JSONDecoder().decode(KeyNavConfig.self, from: data)
        } catch {
            throw ConfigError.unreadable(String(describing: error).prefix(160).description)
        }
        guard (1...KeyNavConfig.currentSchemaVersion).contains(config.schemaVersion) else {
            throw ConfigError.unsupportedSchema(config.schemaVersion)
        }
        config = Self.migrate(config)
        let problems = ConfigValidator.problems(in: config)
        guard problems.isEmpty else { throw ConfigError.conflicts(problems) }
        return config
    }

    /// Version 1 → 2: new settings take their defaults (done by the tolerant decoder);
    /// the help binding is added only when its key is free, so no existing binding changes.
    static func migrate(_ old: KeyNavConfig) -> KeyNavConfig {
        var config = old
        if config.schemaVersion < 2 {
            let help = Gesture.key(code: Key.slash, modifiers: [.shift])
            if !config.cursorBindings.contains(where: { $0.gesture == help || $0.action == .help }) {
                config.cursorBindings.append(CursorBinding(action: .help, gesture: help))
            }
            config.schemaVersion = 2
        }
        return config
    }

    public func encode(_ config: KeyNavConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    /// Validates first, then writes atomically. The previous file is kept as the last-known-good backup.
    public func save(_ config: KeyNavConfig) throws {
        let problems = ConfigValidator.problems(in: config)
        guard problems.isEmpty else { throw ConfigError.conflicts(problems) }
        let data = try encode(config)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }
}
