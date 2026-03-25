import SwiftUI
import AppKit

struct CommandListView: View {
    @ObservedObject var store: CommandStore
    @Binding var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
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

            Divider()

            HStack(spacing: 0) {
                bottomButton(action: addCommand, systemImage: "plus")
                bottomButton(action: removeSelected, systemImage: "minus")
                    .disabled(selectedID == nil)

                Divider().frame(height: 16)

                bottomButton(action: moveUp, systemImage: "chevron.up")
                    .disabled(!canMoveUp)
                bottomButton(action: moveDown, systemImage: "chevron.down")
                    .disabled(!canMoveDown)

                Spacer()

                bottomButton(action: exportCommands, systemImage: "square.and.arrow.up")
                    .help("Export commands")
                bottomButton(action: importCommands, systemImage: "square.and.arrow.down")
                    .help("Import commands")
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
        }
    }

    private func bottomButton(action: @escaping () -> Void, systemImage: String) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
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

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return store.commands.firstIndex(where: { $0.id == id })
    }

    private var canMoveUp: Bool {
        guard let index = selectedIndex else { return false }
        return index > 0
    }

    private var canMoveDown: Bool {
        guard let index = selectedIndex else { return false }
        return index < store.commands.count - 1
    }

    private func moveUp() {
        guard let index = selectedIndex, index > 0 else { return }
        store.move(from: index, to: index - 1)
    }

    private func moveDown() {
        guard let index = selectedIndex, index < store.commands.count - 1 else { return }
        store.move(from: index, to: index + 1)
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
