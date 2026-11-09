import AppKit
import Foundation
import KeyNavCore
import Security

/// Where KeyNav is sold, on Polar.
enum Store {
    /// The product's checkout link (Products › Checkout Links).
    static let checkoutURL = URL(string: "https://buy.polar.sh/polar_cl_EeQnbseQRNTZW8EFdLd1EZZPaN6WUKbxVuW0J0d5gXP")!
    /// Where buyers find their key and free up a Mac.
    static let portalURL = URL(string: "https://polar.sh/keynav/portal")!
    /// The Polar organization, and the license-key benefit; a key for anything else is refused.
    static let organizationID = "8be57bc9-de0f-45dd-a63d-2498ea780371"
    static let benefitID = "28a3ae6f-00fa-499c-92e1-58d487c96817"
    static let price = "$39"
}

/// The free trial and the license, kept in KeyNav's Application Support folder. The only network calls KeyNav makes,
/// besides checking keynav.app for updates, are the two
/// here, to Polar, when the person activates or deactivates a license.
@Observable
@MainActor
final class Licensing {
    private(set) var status: LicenseStatus
    /// The activated license, shown masked.
    private(set) var license: License?

    struct License: Codable, Equatable {
        var key: String
        var instanceID: String

        var masked: String { key.count > 8 ? "\(key.prefix(4))…\(key.suffix(4))" : key }
    }

    init() {
        let firstLaunch = SavedState.read(Self.trialAccount).flatMap { Double(String(decoding: $0, as: UTF8.self)) }
            .map(Date.init(timeIntervalSince1970:)) ?? Self.startTrial()
        let saved = SavedState.read(Self.licenseAccount).flatMap { try? JSONDecoder().decode(License.self, from: $0) }
        self.firstLaunch = firstLaunch
        self.license = saved
        self.status = Trial.status(firstLaunch: firstLaunch, now: Date(), licensed: saved != nil || Self.selfBuilt)
    }

    private let firstLaunch: Date
    /// A build someone made from the source for themselves, which is free to use and has no trial. Only the builds
    /// sold at keynav.app carry KeyNavStoreBuild (scripts/build_app.sh).
    static let selfBuilt = Bundle.main.object(forInfoDictionaryKey: "KeyNavStoreBuild") as? Bool != true
    private static let trialAccount = "trial-start"
    private static let licenseAccount = "license"

    private static func startTrial() -> Date {
        let now = Date()
        SavedState.write(Data(String(now.timeIntervalSince1970).utf8), account: trialAccount)
        return now
    }

    /// Recomputes the trial's days left; called when Settings opens and when a mode starts.
    func refresh() {
        status = Trial.status(firstLaunch: firstLaunch, now: Date(), licensed: license != nil || Self.selfBuilt)
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }

    /// Activates `key` on this Mac with Polar.
    func activate(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.message("Paste the license key from your receipt email.") }
        let name = Host.current().localizedName ?? "Mac"
        let reply = try await Self.post("activate", ["key": key, "organization_id": Store.organizationID, "label": name])
        guard let instanceID = reply["id"] as? String, let licenseKey = reply["license_key"] as? [String: Any] else {
            throw Failure.message(Self.reason(reply) ?? "That key could not be activated.")
        }
        guard licenseKey["benefit_id"] as? String == Store.benefitID else {
            _ = try? await Self.post("deactivate", ["key": key, "organization_id": Store.organizationID, "activation_id": instanceID])
            throw Failure.message("That key is for a different product.")
        }
        let activated = License(key: key, instanceID: instanceID)
        SavedState.write(try JSONEncoder().encode(activated), account: Self.licenseAccount)
        license = activated
        refresh()
    }

    /// Frees this Mac's activation so the license can be used on another one.
    func deactivate() async throws {
        guard let license else { return }
        let reply = try await Self.post("deactivate", ["key": license.key, "organization_id": Store.organizationID,
                                                       "activation_id": license.instanceID])
        // Polar answers 204 with no body when the activation is gone; a missing one is already free.
        if let error = reply["error"] as? String, error != "ResourceNotFound" {
            throw Failure.message(Self.reason(reply) ?? "This Mac could not be deactivated.")
        }
        SavedState.delete(account: Self.licenseAccount)
        self.license = nil
        refresh()
    }

    private static func post(_ endpoint: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        request.timeoutInterval = 20
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.message("Polar could not be reached. Check your connection and try again.")
        }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.message("Polar sent an unexpected reply. Try again in a moment.")
        }
        return object
    }

    /// A readable reason from a Polar error reply.
    private static func reason(_ reply: [String: Any]) -> String? {
        switch reply["error"] as? String {
        case "ResourceNotFound": "That key wasn't found. Check it against your receipt email."
        case "NotPermitted": "That key is already active on three Macs. Deactivate one from Polar's customer portal first."
        case let error?: (reply["detail"] as? String) ?? error
        case nil: nil
        }
    }
}

/// Small files in ~/Library/Application Support/KeyNav, one per account. Not the Keychain: macOS asks for the
/// login password whenever a differently signed build reads a Keychain item, and that prompt looks suspicious.
private enum SavedState {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KeyNav")
    }

    static func read(_ account: String) -> Data? {
        if let data = try? Data(contentsOf: folder.appendingPathComponent(account)) { return data }
        // 0.2.5 kept these in the Keychain: carried over once, and only if macOS hands them over without asking
        // for a password (it asks when the item was written by a differently signed build).
        let service = (Bundle.main.bundleIdentifier ?? "local.keynav.KeyNav") + ".license"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        // The login keychain's own access prompt ignores the query's options; this turns it off for the read.
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        write(data, account: account)
        return data
    }

    static func write(_ data: Data, account: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(account), options: .atomic)
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(account))
    }
}
