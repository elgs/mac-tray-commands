import SwiftUI
import AppKit

struct CommandListView: View {
    @ObservedObject var store: CommandStore
    @Binding var selectedID: UUID?
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.commands) { command in
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
                .onMove(perform: onMove)
            }

            Divider()

            HStack(spacing: 0) {
                bottomButton(action: addCommand, systemImage: "plus")
                    .help("Add command")
                bottomButton(action: { showDeleteConfirmation = true }, systemImage: "minus")
                    .disabled(selectedID == nil)
                    .help("Delete command")
                bottomButton(action: duplicateSelected, systemImage: "plus.square.on.square")
                    .disabled(selectedID == nil)
                    .help("Duplicate command")

                Divider().frame(height: 16)

                bottomButton(action: moveUp, systemImage: "chevron.up")
                    .disabled(!canMoveUp)
                    .help("Move up")
                bottomButton(action: moveDown, systemImage: "chevron.down")
                    .disabled(!canMoveDown)
                    .help("Move down")

                Spacer()

                bottomButton(action: exportCommands, systemImage: "square.and.arrow.up")
                    .help("Export commands")
                bottomButton(action: importCommands, systemImage: "square.and.arrow.down")
                    .help("Import commands")
            }
            .padding(.horizontal, 4)
            .frame(height: 28)
        }
        .alert("Delete Command", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: removeSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let id = selectedID, let command = store.commands.first(where: { $0.id == id }) {
                Text("Are you sure you want to delete \"\(command.name)\"?")
            } else {
                Text("Are you sure you want to delete this command?")
            }
        }
    }

    private func bottomButton(action: @escaping () -> Void, systemImage: String) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
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

    private func onMove(from source: IndexSet, to destination: Int) {
        store.commands.move(fromOffsets: source, toOffset: destination)
        store.save()
    }

    private func duplicateSelected() {
        guard let id = selectedID,
              let command = store.commands.first(where: { $0.id == id })
        else { return }
        let copy = store.duplicate(command)
        DispatchQueue.main.async {
            selectedID = copy.id
        }
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
