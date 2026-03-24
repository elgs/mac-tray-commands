import Foundation
import Combine

final class CommandStore: ObservableObject {
    @Published var commands: [Command] = []

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacTrayCommands", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("commands.json")
    }()

    init() {
        load()
        if commands.isEmpty {
            commands = [
                Command(name: "Example: List Desktop", shellCommand: "ls ~/Desktop", runMode: .terminal)
            ]
            save()
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Command].self, from: data)
        else { return }
        commands = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        try? data.write(to: fileURL, options: .atomic)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .commandsDidChange, object: nil)
        }
    }

    func add(_ command: Command) {
        commands.append(command)
        save()
    }

    func remove(at offsets: IndexSet) {
        commands.remove(atOffsets: offsets)
        save()
    }

    func update(_ command: Command) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[index] = command
        save()
    }
}

extension Notification.Name {
    static let commandsDidChange = Notification.Name("commandsDidChange")
}
