import SwiftUI

struct CommandEditView: View {
    @State private var draft: Command
    let onSave: (Command) -> Void

    init(command: Command, onSave: @escaping (Command) -> Void) {
        _draft = State(initialValue: command)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").fontWeight(.medium)
                TextField("e.g. Deploy Staging", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command").fontWeight(.medium)
                ShellEditorWithLineNumbers(text: draft.shellCommand) { newText in
                        draft.shellCommand = newText
                    }
                    .frame(minHeight: 80, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Run Mode").fontWeight(.medium)
                Picker("", selection: $draft.runMode) {
                    ForEach(RunMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(draft.runMode == .terminal
                     ? "Opens Terminal.app and keeps the window open when the command finishes."
                     : "Runs via /bin/zsh in the background with no visible window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    switch draft.runMode {
                    case .terminal:
                        CommandRunner.runInTerminal(shellCommand: draft.shellCommand)
                    case .background:
                        CommandRunner.runInBackground(shellCommand: draft.shellCommand)
                    }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.shellCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .onChange(of: draft) { newValue in
            onSave(newValue)
        }
    }
}
