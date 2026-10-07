import AppKit
import Combine
import Foundation
import os

/// Lifecycle of a click-to-update install. `failed` keeps the offer standing
/// so the user can try again, or fall back to `brew upgrade`.
enum UpdateState: Equatable {
    case idle
    case downloading(Double)  // fraction 0...1
    case installing
    case failed(String)
}

/// Keeping the app current: a quiet look at the published cask a minute
/// after launch and about once a day after that, and the click that installs
/// what it found.
///
/// An automatic check is allowed to fail silently and a clicked one is not.
/// Nobody asked for the daily check, so a flaky network or a captive portal
/// must never produce a dialog — the check just doesn't find anything that
/// time. A click on "Check for Updates…" is a question, and a question that
/// goes unanswered is a broken menu item, so that path reports every outcome.
final class Updater: ObservableObject {
    /// What a clicked check has to say for itself.
    enum CheckOutcome: Equatable {
        case available(AvailableUpdate)
        case upToDate
        /// A newer release exists, but it needs this macOS major version or
        /// later and the Mac runs something older. The installed version stays.
        case needsNewerMacOS(update: String, macOS: String)
        case failed
    }

    /// nil = no update; otherwise the newer release advertised by the cask,
    /// carrying everything `installUpdate` needs to fetch and verify the DMG.
    @Published private(set) var updateAvailable: AvailableUpdate?
    @Published private(set) var updateState: UpdateState = .idle
    /// True while a clicked check is in flight. Automatic checks never touch it.
    @Published private(set) var isChecking = false

    /// Called on the main thread when a click-to-update install fails, with
    /// the reason. `updateState` carries it too; this is for the one-time alert.
    var onInstallFailed: ((String) -> Void)?

    /// What this build calls itself — the left-hand side of every comparison.
    let currentVersion: String

    /// How long after launch the first automatic check runs. Not at launch
    /// itself: this is the least urgent thing happening then.
    static let firstCheckDelay: TimeInterval = 60
    /// About a day, ±2h. The jitter is the point: every copy launched by the
    /// same login wave would otherwise ask GitHub at the same second.
    static let dailyInterval: ClosedRange<TimeInterval> = (22 * 3600)...(26 * 3600)

    private var checkTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    /// Read with: log show --last 1h --predicate 'subsystem == "home.MacTrayCommands"'
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacTrayCommands",
                                    category: "update")

    init(currentVersion: String = AppVersion.current) {
        self.currentVersion = currentVersion
    }

    deinit {
        checkTimer?.invalidate()
        downloadTask?.cancel()
    }

    // MARK: - Scheduling

    /// Begin the rhythm: the first check `firstCheckDelay` from now, then one
    /// about every day. Idempotent — a second call is ignored.
    func startPeriodicChecks() {
        guard checkTimer == nil else { return }
        scheduleCheck(after: Self.firstCheckDelay)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        checkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.checkForUpdate(manual: false, completion: nil)
            self.scheduleCheck(after: .random(in: Self.dailyInterval))
        }
    }

    // MARK: - Checking

    /// The "Check for Updates…" click. Same fetch as the daily one; the
    /// difference is entirely in what it says afterwards. A second click
    /// while one is in flight is ignored. `completion` runs on the main thread.
    func checkForUpdateNow(completion: @escaping (CheckOutcome) -> Void) {
        guard !isChecking else { return }
        isChecking = true
        checkForUpdate(manual: true) { [weak self] outcome in
            self?.isChecking = false
            completion(outcome)
        }
    }

    private func checkForUpdate(manual: Bool, completion: ((CheckOutcome) -> Void)?) {
        // A clicked check must not be answered from the app's own URL cache:
        // the cask is served with a five minute lifetime, so a copy cached
        // just before a release would report "up to date" for that long.
        // The daily check keeps the default policy; its runs are a day apart.
        var request = URLRequest(url: UpdateCatalog.caskURL)
        request.timeoutInterval = 30
        if manual { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, (200...299).contains(status),
                  let data, let content = String(data: data, encoding: .utf8),
                  let update = UpdateCatalog.parseCask(content)
            else {
                let reason = error?.localizedDescription ?? "HTTP \(status) or an unreadable cask"
                Self.log.error("Update check failed: \(reason, privacy: .public)")
                DispatchQueue.main.async { completion?(.failed) }
                return
            }
            DispatchQueue.main.async { self.apply(update, completion: completion) }
        }
        task.resume()
    }

    private func apply(_ update: AvailableUpdate, completion: ((CheckOutcome) -> Void)?) {
        // Never move the offer out from under a running install: installUpdate
        // captured its own copy, but the menu's progress row keys off it.
        switch updateState {
        case .downloading, .installing:
            completion?(updateAvailable.map { .available($0) } ?? .upToDate)
            return
        case .idle, .failed:
            break
        }
        switch UpdateCatalog.offer(update, installed: currentVersion, running: SystemVersion.current) {
        case .available:
            if updateAvailable != update {
                updateAvailable = update
                // A failure recorded against an older offer says nothing about
                // this one; it survives only while the same update is retried.
                updateState = .idle
                Self.log.notice("Update available: \(self.currentVersion, privacy: .public) → \(update.version, privacy: .public)")
            }
            completion?(.available(update))
        case .needsNewerMacOS(let macOS):
            // Offering it would end in a refused install, so nothing is
            // offered and the installed version stays. `brew upgrade` makes
            // the same call from the same cask line.
            updateAvailable = nil
            updateState = .idle
            Self.log.notice("Update \(update.version, privacy: .public) needs macOS \(macOS, privacy: .public) or later (this Mac runs \(SystemVersion.current, privacy: .public)); staying on \(self.currentVersion, privacy: .public)")
            completion?(.needsNewerMacOS(update: update.version, macOS: macOS))
        case .upToDate:
            updateAvailable = nil
            updateState = .idle
            completion?(.upToDate)
        }
    }

    // MARK: - Installing

    /// Download the advertised DMG, verify it (SHA-256 from the cask, code
    /// signature, Team ID matching the running app, a minimum macOS this Mac
    /// meets), swap the app bundle in place, and relaunch. The relaunch goes
    /// through `NSApp.terminate`, the same quit path as a normal exit. A
    /// second call while one is running is ignored.
    func installUpdate() {
        switch updateState {
        case .downloading, .installing: return
        case .idle, .failed: break
        }
        guard let update = updateAvailable else { return }
        let appBundleURL = Bundle.main.bundleURL
        // The app run out of a build directory that isn't a bundle: there is
        // nothing to swap. Reachable, so it gets a sentence rather than a
        // dead menu item.
        guard appBundleURL.pathExtension == "app" else {
            fail(UpdateInstall.Failure("The app isn't running from an app bundle, so it can't replace itself."))
            return
        }

        updateState = .downloading(0)
        Self.log.notice("Update \(update.version, privacy: .public): downloading \(update.dmgURL.absoluteString, privacy: .public)")
        let task = URLSession.shared.downloadTask(with: update.dmgURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            // URLSession deletes tempURL when this handler returns — claim
            // the file synchronously, then do the slow verify/install work
            // off the session's queue.
            do {
                if let error { throw error }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw UpdateInstall.Failure("The download failed (HTTP \(http.statusCode)).")
                }
                guard let tempURL else { throw UpdateInstall.Failure("The download produced no file.") }
                let fm = FileManager.default
                let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("mac-tray-commands-update-\(ProcessInfo.processInfo.processIdentifier)")
                try? fm.removeItem(at: workDir)
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                let dmgURL = workDir.appendingPathComponent("MacTrayCommands.dmg")
                do {
                    try fm.moveItem(at: tempURL, to: dmgURL)
                } catch {
                    // The workDir name is PID-scoped, so a later run would
                    // never reclaim it — clean up before bailing.
                    try? fm.removeItem(at: workDir)
                    throw error
                }
                DispatchQueue.main.async { self.updateState = .installing }
                // Hashing, mounting and ditto are all blocking; none of it
                // belongs on the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { try? FileManager.default.removeItem(at: workDir) }
                    do {
                        try UpdateInstall.perform(dmg: dmgURL, expecting: update, into: appBundleURL)
                        // Hand off to a detached shell that waits for this
                        // process to exit, then opens the new copy.
                        try UpdateInstall.spawnRelauncher(appPath: appBundleURL.path)
                        Self.log.notice("Update \(update.version, privacy: .public) installed — relaunching")
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    } catch {
                        self.fail(error)
                    }
                }
            } catch {
                // A user-initiated cancel is not a failure — cancelUpdate
                // already reset the state; don't overwrite it with .failed.
                if (error as? URLError)?.code == .cancelled { return }
                self.fail(error)
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                // Quantize to whole percents: raw KVO fires per received
                // chunk, and every updateState write rebuilds the menu. The
                // `.downloading` guard also keeps a late event from
                // clobbering .installing/.failed.
                guard let self, case .downloading(let previous) = self.updateState,
                      Int(fraction * 100) != Int(previous * 100) else { return }
                self.updateState = .downloading(fraction)
            }
        }
        downloadTask = task
        task.resume()
    }

    /// Cancel an in-flight download. No-op outside `.downloading`: the
    /// install stage is short and swaps atomically, so it isn't cancellable.
    func cancelUpdate() {
        guard case .downloading = updateState else { return }
        downloadTask?.cancel()
        downloadTask = nil
        progressObservation = nil
        // The download completion handler maps the resulting
        // URLError.cancelled to a silent return; reset here too so the menu
        // reverts to the Update item instantly.
        updateState = .idle
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Self.log.error("Update failed: \(message, privacy: .public)")
        DispatchQueue.main.async {
            self.updateState = .failed(message)
            self.onInstallFailed?(message)
        }
    }
}
