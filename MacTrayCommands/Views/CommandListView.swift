import SwiftUI
import AppKit

struct CommandListView: View {
    @ObservedObject var store: CommandStore
    @Binding var selectedID: UUID?

    var body: some View {
        List(store.commands, selection: $selectedID) { command in
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .fontWeight(.medium)
                Text(command.shellCommand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 2)
            .tag(command.id)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: addCommand) {
                    Image(systemName: "plus")
                }
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                }
                .disabled(selectedID == nil)

                Spacer()

                Button(action: exportCommands) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export commands")
                Button(action: importCommands) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import commands")
            }
        }
    }

    private func addCommand() {
        let new = Command(name: "New Command", shellCommand: "", runMode: .terminal)
        store.add(new)
        DispatchQueue.main.async {
            selectedID = new.id
        }
    }

    private func exportCommands() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "commands.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store.commands) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importCommands() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode([Command].self, from: data)
        else {
            let alert = NSAlert()
            alert.messageText = "Invalid file"
            alert.informativeText = "The file is not a valid commands JSON file."
            alert.runModal()
            return
        }
        // Assign new IDs to avoid duplicates
        for var command in imported {
            command.id = UUID()
            store.add(command)
        }
        selectedID = store.commands.last?.id
    }

    private func removeSelected() {
        guard let id = selectedID,
              let index = store.commands.firstIndex(where: { $0.id == id })
        else { return }
        let previousIndex = index > 0 ? index - 1 : (store.commands.count > 1 ? 1 : nil)
        let nextSelectedID = previousIndex.map { store.commands[$0].id }
        store.remove(at: IndexSet(integer: index))
        selectedID = nextSelectedID
    }
}
