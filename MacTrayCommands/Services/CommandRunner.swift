import Foundation

final class CommandRunner {

    /// Opens command in Terminal.app via osascript. The window stays open naturally
    /// after the command finishes since `do script` leaves the shell session alive.
    static func runInTerminal(shellCommand: String) {
        // Write command to a temp file to avoid AppleScript escaping issues
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sh")
        try? shellCommand.write(to: tempFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tempFile.path)

        let appleScript = """
        tell application "Terminal"
            activate
            do script "/bin/zsh -l '\(tempFile.path)'; rm -f '\(tempFile.path)'"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        try? process.run()
    }

    /// Runs command silently via /bin/zsh with no visible window.
    static func runInBackground(shellCommand: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-l", "-c", shellCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
