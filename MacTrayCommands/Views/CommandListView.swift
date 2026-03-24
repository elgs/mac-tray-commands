import SwiftUI

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
