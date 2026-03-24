import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: CommandStore
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            CommandListView(store: store, selectedID: $selectedID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            if let id = selectedID,
               let command = store.commands.first(where: { $0.id == id }) {
                CommandEditView(command: command) { updated in
                    store.update(updated)
                }
                .id(id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No Command Selected")
                        .font(.headline)
                    Text("Select a command from the list or add a new one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear {
            if selectedID == nil {
                selectedID = store.commands.first?.id
            }
        }
    }
}
