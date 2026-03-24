import Foundation

enum RunMode: String, Codable, CaseIterable {
    case terminal = "terminal"
    case background = "background"

    var label: String {
        switch self {
        case .terminal: return "Open in Terminal"
        case .background: return "Run in Background"
        }
    }
}

struct Command: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var shellCommand: String
    var runMode: RunMode

    init(id: UUID = UUID(), name: String = "", shellCommand: String = "", runMode: RunMode = .terminal) {
        self.id = id
        self.name = name
        self.shellCommand = shellCommand
        self.runMode = runMode
    }
}
