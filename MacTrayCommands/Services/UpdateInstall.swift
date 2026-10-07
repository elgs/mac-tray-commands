import CryptoKit
import Foundation

/// Turning a downloaded DMG into the app bundle that is running.
///
/// Everything here is a step that can leave the disk worse than it found it,
/// so the order is the contract: nothing is copied until the bytes match the
/// hash the cask published, nothing is swapped until the new bundle carries
/// an intact signature from the same team as the running one and can open on
/// this macOS, and the swap itself is atomic wherever the filesystem can be
/// (APFS can). The one path with a gap — the two-rename fallback — rolls
/// back, and says so loudly if even that fails, because at that point the
/// hidden copies are the only intact bits left.
enum UpdateInstall {
    /// Anything that stopped an install, phrased for the alert that shows it.
    struct Failure: LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The two-rename fallback failed AND the rollback failed — no bundle sits
    /// at the live path any more. Distinguished from `Failure` so the caller
    /// knows to leave the staged and outgoing copies on disk: deleting them
    /// while cleaning up would turn a recoverable mess into a lost app.
    struct UnrecoverableSwap: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - The install

    /// Verify `dmg` against the cask and put the app inside it where
    /// `appBundleURL` is. Blocking: run it off the main thread.
    ///
    /// On return the new bundle is live, de-quarantined, and ready to be
    /// opened by the relauncher. On a throw the live bundle is untouched and
    /// nothing hidden is left behind — except after `UnrecoverableSwap`,
    /// which is exactly the case where the leftovers matter.
    static func perform(dmg: URL, expecting update: AvailableUpdate, into appBundleURL: URL) throws {
        // 1. The bytes must be the bytes release.sh hashed into the cask.
        //    This is what makes the download trustworthy at all, so it comes
        //    before anything is mounted or copied.
        let digest = try sha256OfFile(at: dmg)
        guard digest == update.sha256 else {
            throw Failure("The download doesn't match the published release — its checksum is different.")
        }

        // 2. Mount, and find the app inside.
        let mountPoint = try attachDMG(at: dmg)
        defer { detachDMG(mountPoint) }
        let newApp = try locateApp(named: appBundleURL.lastPathComponent, in: mountPoint)

        // 3. Signed, intact, and by the same team as the running app.
        try verifyCodeSignature(newApp: newApp, currentApp: appBundleURL)

        // 4. Able to open on this Mac. The cask's macOS requirement already
        //    keeps such a release from being offered, but only for release
        //    names this build knows; the bundle's own declared minimum is the
        //    authority. Without this, the swap below would replace a working
        //    app with one macOS refuses to launch.
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure("Couldn't read the new version's Info.plist.")
        }
        if let blocker = UpdateCatalog.launchBlocker(
            minimumSystemVersion: info["LSMinimumSystemVersion"] as? String,
            running: SystemVersion.current) {
            throw Failure(blocker)
        }

        // 5. Stage a copy next to the destination — same volume, so the swap
        //    below is a rename and not a copy — then exchange the two paths.
        let fm = FileManager.default
        let name = appBundleURL.lastPathComponent
        let destination = appBundleURL.deletingLastPathComponent()
        let staged = destination.appendingPathComponent(".\(name).update-staged")
        let old = destination.appendingPathComponent(".\(name).update-old")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        do {
            // ditto, not FileManager.copyItem: it preserves the signature,
            // the extended attributes and the permission bits exactly, and a
            // bundle copied any other way stops verifying.
            try runChecked("/usr/bin/ditto", [newApp.path, staged.path],
                           failure: "Couldn't stage the new version in \(destination.path).")
            try swapIntoPlace(staged: staged, live: appBundleURL, old: old)
        } catch {
            // A hidden bundle must not outlive a failed install — unless the
            // rollback is what failed, when it is the only copy left.
            if !(error is UnrecoverableSwap) { try? fm.removeItem(at: staged) }
            throw error
        }

        // 6. The bundle is verified; drop any quarantine flag the download
        //    attached, so the relaunch doesn't stall behind a Gatekeeper
        //    first-open dialog.
        _ = runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appBundleURL.path])
    }

    /// Exchange `staged` and `live` atomically where the filesystem supports
    /// it, falling back to two renames through `old`.
    ///
    /// `renamex_np(RENAME_SWAP)` means the app is never missing from disk: at
    /// every instant one of the two bundles is at `live`. The fallback has an
    /// unavoidable sub-millisecond gap, and a rollback failure there is
    /// surfaced rather than swallowed — a silent one leaves a Mac with no app
    /// and no explanation.
    static func swapIntoPlace(staged: URL, live: URL, old: URL) throws {
        let fm = FileManager.default
        if renamex_np(staged.path, live.path, UInt32(RENAME_SWAP)) == 0 {
            // `staged` now holds the outgoing bundle. The running executable's
            // inode stays alive unlinked-but-open, so removing it is safe.
            try? fm.removeItem(at: staged)
            return
        }
        try fm.moveItem(at: live, to: old)
        do {
            try fm.moveItem(at: staged, to: live)
        } catch {
            do {
                try fm.moveItem(at: old, to: live)  // roll back
            } catch let rollbackError {
                throw UnrecoverableSwap(message:
                    "The update failed while replacing the app, and putting the old one back failed too ("
                    + rollbackError.localizedDescription + "). Rename " + old.lastPathComponent
                    + " in " + live.deletingLastPathComponent().path + " back to " + live.lastPathComponent
                    + ", or reinstall with: brew reinstall --cask mac-tray-commands")
            }
            throw error
        }
        try? fm.removeItem(at: old)
    }

    // MARK: - Relaunching

    /// The shell the relauncher runs: wait for this process to go, give the
    /// process table a beat to settle, then open the new copy. The path is
    /// single-quoted with embedded apostrophes escaped, so an install under
    /// `/Users/O'Neill/Applications` cannot end the string early.
    static func relauncherScript(pid: Int32, appPath: String) -> String {
        let quoted = appPath.replacingOccurrences(of: "'", with: "'\\''")
        return "while kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/bin/sleep 0.3; /usr/bin/open '\(quoted)'"
    }

    /// Hand off to a detached shell that waits on this PID. It survives our
    /// exit — children are reparented to launchd, not killed with the parent.
    static func spawnRelauncher(appPath: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", relauncherScript(
            pid: ProcessInfo.processInfo.processIdentifier, appPath: appPath)]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
    }

    // MARK: - Pieces

    /// Stream-hash a file (the DMG is small today, but don't assume).
    static func sha256OfFile(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure("Couldn't read the downloaded file.")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mount an image read-only and answer its mount point.
    static func attachDMG(at dmg: URL) throws -> URL {
        let result = runProcess("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard result.status == 0 else {
            throw Failure("Couldn't open the downloaded disk image.")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw Failure("Couldn't find the mounted volume of the downloaded disk image.")
        }
        return URL(fileURLWithPath: mountPoint)
    }

    static func detachDMG(_ mountPoint: URL) {
        // A just-finished copy can leave the volume transiently busy.
        let result = runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
        if result.status != 0 {
            _ = runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        }
    }

    /// The app inside a mounted image. By name first — the DMG holds
    /// `MacTrayCommands.app` beside an `/Applications` symlink — then any
    /// `.app` in it, so a renamed bundle still installs rather than failing
    /// at the last step of a download the user already waited for.
    static func locateApp(named name: String, in mountPoint: URL) throws -> URL {
        let exact = mountPoint.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        if let other = contents.sorted().first(where: { $0.hasSuffix(".app") }) {
            return mountPoint.appendingPathComponent(other)
        }
        throw Failure("There is no app in the update image.")
    }

    /// The signature gate: an intact signature, and the same Team ID as the
    /// bundle being replaced.
    static func verifyCodeSignature(newApp: URL, currentApp: URL) throws {
        try runChecked("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path],
                       failure: "The new version failed code-signature verification.")
        let newTeam = try teamIdentifier(of: newApp)
        let currentTeam = try teamIdentifier(of: currentApp)
        guard newTeam == currentTeam else {
            throw Failure("The new version is signed by a different team (\(newTeam), expected \(currentTeam)).")
        }
    }

    /// The Team ID out of `codesign -dvv` (which writes to stderr). Ad-hoc and
    /// unsigned bundles report `TeamIdentifier=not set`, which the
    /// uppercase-and-digits capture below deliberately fails to match — an
    /// unsigned build must never pass for ours.
    static func teamIdentifier(of bundle: URL) throws -> String {
        let result = runProcess("/usr/bin/codesign", ["-dvv", bundle.path])
        guard result.status == 0 else {
            throw Failure("\(bundle.lastPathComponent) has no readable code signature.")
        }
        let text = String(decoding: result.stderr, as: UTF8.self)
        guard let team = UpdateCatalog.firstCapture(#"TeamIdentifier=([A-Z0-9]{10})"#, in: text) else {
            throw Failure("\(bundle.lastPathComponent) has no Team ID — it is unsigned or ad-hoc signed.")
        }
        return team
    }

    // MARK: - Running tools

    /// Run a tool to completion, capturing output. Both pipes are drained to
    /// EOF at the same time, before waiting: a child that fills one pipe
    /// (64 KB) while the parent still waits on the other blocks forever, and
    /// so would the parent.
    @discardableResult
    static func runProcess(_ launchPath: String,
                           _ arguments: [String]) -> (status: Int32, stdout: Data, stderr: Data) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return (-1, Data(), Data())
        }
        var stderr = Data()
        let stderrDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDrained.signal()
        }
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.wait()
        task.waitUntilExit()
        return (task.terminationStatus, stdout, stderr)
    }

    static func runChecked(_ launchPath: String, _ arguments: [String], failure: String) throws {
        let result = runProcess(launchPath, arguments)
        guard result.status == 0 else {
            let detail = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(detail.isEmpty ? failure : "\(failure) \(detail)")
        }
    }
}
