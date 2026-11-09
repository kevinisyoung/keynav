import KeyNavCore
import SwiftUI

struct LicensePage: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let licensing = model.licensing
        Form {
            Section {
                switch licensing.status {
                case let .trial(daysLeft):
                    StatusLine(ok: true, title: "Free trial",
                               detail: "\(daysLeft) \(daysLeft == 1 ? "day" : "days") left. Everything works until then.")
                case .trialEnded:
                    StatusLine(ok: false, title: "Your free trial has ended",
                               detail: "Buy KeyNav to keep using Clicking, Scrolling, and Moving.")
                case .licensed where licensing.license == nil:
                    StatusLine(ok: true, title: "Built from source",
                               detail: "Free for your own use. Buying KeyNav at keynav.app supports it.")
                case .licensed:
                    StatusLine(ok: true, title: "Licensed",
                               detail: licensing.license?.masked ?? "")
                }
            }

            if licensing.status != .licensed {
                Section {
                    Button("Buy KeyNav for \(Store.price)") { NSWorkspace.shared.open(Store.checkoutURL) }
                        .buttonStyle(.borderedProminent)
                } footer: {
                    Text("One payment, every future update included. Your license key arrives by email.")
                }

                Section {
                    HStack {
                        TextField("License key", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(activate)
                        Button("Activate", action: activate)
                            .disabled(working || key.isEmpty)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Link("Find your key or free up a Mac", destination: Store.portalURL)
                        .font(.callout)
                } footer: {
                    Text("Activating checks the key with Polar once. After that KeyNav never goes online.")
                }
            } else if licensing.license != nil {
                Section {
                    HStack {
                        Spacer()
                        Button("Deactivate This Mac") {
                            run { try await model.licensing.deactivate() }
                        }
                        .disabled(working)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Frees this Mac's activation so you can use your license on another one.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { licensing.refresh() }
    }

    private func activate() {
        let entered = key
        run {
            try await model.licensing.activate(entered)
            key = ""
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
