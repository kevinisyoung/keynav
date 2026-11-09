import AppKit
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import IOKit

/// What the current binary can actually do, measured by probes rather than remembered settings.
public struct PermissionReport: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var executablePath: String
    public var osVersion: String
    /// `AXIsProcessTrusted()`: the Accessibility grant for this process identity.
    public var accessibilityTrusted: Bool
    /// `CGPreflightListenEventAccess()`: the Input Monitoring grant, where macOS reports one.
    public var listenEventAccess: Bool
    /// Whether an active (filtering) keyboard event tap could be created. This is the real capability probe.
    public var activeTapCreatable: Bool
    /// Whether secure event input is on. While it is, keystrokes may not reach taps.
    public var secureInputActive: Bool
    /// The app that turned secure input on, when macOS says.
    public var secureInputApp: String? = nil

    public var status: ReadinessStatus {
        if secureInputActive { return .restricted }
        if activeTapCreatable { return .ready }
        if !accessibilityTrusted { return .needsAccess }
        return .unavailable
    }
}

public enum ReadinessStatus: String, Codable, Sendable {
    case ready = "Ready"
    case needsAccess = "Needs access"
    case restricted = "Restricted by macOS"
    case unavailable = "Unavailable"
}

public enum Permissions {
    public static func report() -> PermissionReport {
        let bundle = Bundle.main
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return PermissionReport(
            bundleIdentifier: bundle.bundleIdentifier ?? "(no bundle identifier: running a raw executable)",
            executablePath: bundle.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "",
            osVersion: version,
            accessibilityTrusted: AXIsProcessTrusted(),
            listenEventAccess: CGPreflightListenEventAccess(),
            activeTapCreatable: probeActiveTap(),
            secureInputActive: IsSecureEventInputEnabled(),
            secureInputApp: IsSecureEventInputEnabled() ? secureInputApp() : nil
        )
    }

    /// The app holding secure input (a focused password field, or one an app forgot to release), from the login
    /// session's record in the I/O Registry.
    public static func secureInputApp() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 {
                return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
            }
        }
        return nil
    }

    /// Why KeyNav is off while secure input is on, naming the app when known.
    public static func secureInputReason() -> String {
        if let app = secureInputApp() { return "\(app) has a password field active, so KeyNav stays off until it closes." }
        return "A password field is active in another app, so KeyNav stays off until it closes."
    }

    /// Creates and immediately destroys an active keyboard tap. Nothing is delivered to it.
    static func probeActiveTap() -> Bool {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
    }

    /// Shows the system prompt for Accessibility. The result is not a grant; the caller must re-probe.
    @discardableResult
    public static func requestAccessibilityPrompt() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public static func requestListenAccessPrompt() -> Bool {
        CGRequestListenEventAccess()
    }

    @MainActor
    public static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @MainActor
    public static func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    @MainActor
    private static func openPrivacyPane(_ anchor: String) {
        // The anchor is stable across recent releases; if it stops working, the diagnostics page shows written steps.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
