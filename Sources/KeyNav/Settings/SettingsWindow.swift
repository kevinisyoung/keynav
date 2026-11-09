import KeyNavCore
import KeyNavSystem
import SwiftUI

struct SettingsWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
                Section {
                    sidebarRow(.click)
                    sidebarRow(.scroll)
                    sidebarRow(.cursor)
                }
                Section {
                    sidebarRow(.general)
                    sidebarRow(.license)
                    sidebarRow(.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            VStack(spacing: 0) {
                page(for: model.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ChangeBanner()
            }
            // The window keeps the app's name, so app and window switchers show "KeyNav"; the page is the subtitle.
            .navigationTitle("KeyNav")
            .navigationSubtitle(model.page.rawValue)
        }
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        Label {
            Text(page.rawValue)
        } icon: {
            IconTile(symbol: page.symbol, color: page.color)
        }
        .tag(page)
    }

    @ViewBuilder
    private func page(for page: SettingsPage) -> some View {
        switch page {
        case .click: ClickModePage()
        case .scroll: ScrollModePage()
        case .cursor: CursorModePage()
        case .general: GeneralPage()
        case .license: LicensePage()
        case .about: AboutPage()
        }
    }
}

/// Compact, persistent access to both modes from every page.
/// Shows the last saved change with Undo, so live edits are always reversible.
struct ChangeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let change = model.lastChange {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(change).lineLimit(1)
                Spacer()
                if model.canUndo {
                    Button("Undo") { model.undo() }
                }
                Button {
                    model.dismissChange()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .task(id: change) {
                try? await Task.sleep(for: .seconds(8))
                if model.lastChange == change { model.dismissChange() }
            }
        }
    }
}
