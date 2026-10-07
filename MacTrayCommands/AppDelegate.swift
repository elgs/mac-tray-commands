import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    let store = CommandStore()
    let updater = Updater()
    private var settingsWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var updaterObserver: AnyCancellable?
    /// Re-renders the icon when the menu bar flips light/dark. Needed
    /// because the update badge forces non-template rendering (a colored
    /// dot cannot survive template recoloring), so the glyph color must
    /// track the appearance manually instead of letting the system tint it.
    private var appearanceObservation: NSKeyValueObservation?
    private var lastIconHasUpdate: Bool?
    private var lastIconDark = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()

        buildMenu()
        setupMainMenu()
        registerGlobalHotKey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(buildMenu),
            name: .commandsDidChange,
            object: nil
        )

        // The menu lists the pending update and the install's progress, and
        // the icon carries the badge dot; both follow the updater's state.
        updaterObserver = updater.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenuBarIcon()
                self?.buildMenu()
            }
        }
        updater.onInstallFailed = { [weak self] message in
            self?.presentInstallFailure(message)
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateMenuBarIcon() }
        }
        updater.startPeriodicChecks()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D544321), id: 1)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRef = ref

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            guard let appDelegate = NSApp.delegate as? AppDelegate else { return noErr }
            appDelegate.statusItem.button?.performClick(nil)
            return noErr
        }, 1, &eventSpec, nil, nil)
    }

    // MARK: - Menu bar icon

    /// True when the menu bar around the status item renders dark. Read from
    /// the button (not NSApp) so wallpaper-tinted menu bars resolve correctly.
    private var menuBarIsDark: Bool {
        statusItem?.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let hasUpdate = updater.updateAvailable != nil
        let dark = menuBarIsDark

        // Hover text for the one state the icon can only signal with the
        // wordless badge dot. Assign only on a real change: every assignment
        // re-installs the tooltip, which restarts the hover delay.
        let toolTip = updater.updateAvailable.map {
            "Mac Tray Commands \($0.version) is available. Open the menu to update."
        }
        if button.toolTip != toolTip {
            button.toolTip = toolTip
        }

        // Every @Published change lands here (download progress included);
        // skip the NSImage rebuild when nothing the icon renders has changed.
        if hasUpdate == lastIconHasUpdate, dark == lastIconDark { return }
        lastIconHasUpdate = hasUpdate
        lastIconDark = dark
        button.image = Self.renderMenuBarIcon(hasUpdate: hasUpdate, darkMenuBar: dark)
    }

    /// Pure icon renderer: the terminal glyph, with a small blue badge dot
    /// over its top-right corner while an update is pending.
    ///
    /// Template rendering only survives while the icon is monochrome: the
    /// system recolors template images from their alpha alone, which would
    /// erase the badge's blue. That variant renders non-template, picking the
    /// glyph color from `darkMenuBar` manually. Both variants share one
    /// canvas, so the status item never changes width and the glyph never
    /// shifts when the badge comes and goes.
    static func renderMenuBarIcon(hasUpdate: Bool, darkMenuBar: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Mac Tray Commands") ?? NSImage()
        let glyph = symbol.size  // 19×14 at the menu bar's default symbol size
        let pad = NSSize(width: 1, height: 2)  // room for the badge to overhang the corner
        let image = NSImage(size: NSSize(width: glyph.width + pad.width * 2,
                                         height: glyph.height + pad.height * 2))
        image.lockFocus()
        let glyphRect = NSRect(origin: NSPoint(x: pad.width, y: pad.height), size: glyph)
        symbol.draw(in: glyphRect)
        if hasUpdate, let ctx = NSGraphicsContext.current {
            // The template symbol draws black; give it the menu bar's color.
            (darkMenuBar ? NSColor.white : NSColor.black).setFill()
            glyphRect.fill(using: .sourceAtop)
            // The badge: a blue dot over the top-right corner, separated from
            // the glyph by a knocked-out ring so it reads crisply over the
            // outline and over any menu bar background.
            let center = NSPoint(x: glyphRect.maxX - 2, y: glyphRect.maxY - 2)
            let ringR: CGFloat = 4.3
            let dotR: CGFloat = 3
            ctx.compositingOperation = .destinationOut
            NSColor.black.setFill()  // only the alpha matters for the punch-out
            NSBezierPath(ovalIn: NSRect(x: center.x - ringR, y: center.y - ringR,
                                        width: ringR * 2, height: ringR * 2)).fill()
            ctx.compositingOperation = .sourceOver
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR,
                                        width: dotR * 2, height: dotR * 2)).fill()
        }
        image.unlockFocus()
        image.isTemplate = !hasUpdate
        return image
    }

    /// The menu's "Update to …" glyph: `arrow.up.circle.fill` in the badge's
    /// blue — one color for "update" everywhere. Pre-rendered rather than a
    /// template symbol, which the menu would tint to the label color.
    private static let updateMenuImage: NSImage = {
        let symbol = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil) ?? NSImage()
        let rect = NSRect(origin: .zero, size: symbol.size)
        let image = NSImage(size: rect.size)
        image.lockFocus()
        symbol.draw(in: rect)
        NSColor.systemBlue.setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }()

    // MARK: - Menu

    @objc func buildMenu() {
        let menu = NSMenu()

        if store.commands.isEmpty {
            let empty = NSMenuItem(title: "No commands — open Settings", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (i, command) in store.commands.enumerated() {
                let item = NSMenuItem(title: "\(i). \(command.name)", action: #selector(runCommand(_:)), keyEquivalent: "")
                item.representedObject = command
                item.toolTip = command.shellCommand
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let shortcutHint = NSMenuItem(title: "Shortcut: ⌃⌥L", action: nil, keyEquivalent: "")
        shortcutHint.isEnabled = false
        menu.addItem(shortcutHint)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ""))
        for item in updateMenuItems() {
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// The update rows: a check while nothing is pending, the install item
    /// once a newer release is known, and its progress while it runs. The
    /// menu is rebuilt on every updater change, so an open menu shows the
    /// state as of when it opened and the next open shows the latest.
    private func updateMenuItems() -> [NSMenuItem] {
        guard let update = updater.updateAvailable else {
            if updater.isChecking {
                let item = NSMenuItem(title: "Checking for Updates…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                return [item]
            }
            let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            item.toolTip = "Check the Homebrew tap for a newer version now. The app also checks automatically about once a day."
            return [item]
        }
        switch updater.updateState {
        case .downloading(let fraction):
            let progress = NSMenuItem(title: "Downloading \(update.version)… \(Int((fraction * 100).rounded()))%",
                                      action: nil, keyEquivalent: "")
            progress.isEnabled = false
            let cancel = NSMenuItem(title: "Cancel Download", action: #selector(cancelUpdate), keyEquivalent: "")
            cancel.toolTip = "Stop the download. The Update item returns and nothing is changed."
            return [progress, cancel]
        case .installing:
            let item = NSMenuItem(title: "Installing \(update.version)…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        case .idle, .failed:
            let item = NSMenuItem(title: "Update to \(update.version)…", action: #selector(installUpdate), keyEquivalent: "")
            item.image = Self.updateMenuImage
            // macOS 27 hides menu item images unless an item asks for its own.
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
            if case .failed(let message) = updater.updateState {
                item.toolTip = "The last attempt failed: \(message)\n\nClick to try again, or run: \(UpdateCatalog.brewUpgradeCommand)"
            } else {
                item.toolTip = "Download \(update.version), verify it, install it, and relaunch. Currently on \(updater.currentVersion)."
            }
            return [item]
        }
    }

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command else { return }
        switch command.runMode {
        case .terminal:
            CommandRunner.runInTerminal(shellCommand: command.shellCommand)
        case .background:
            CommandRunner.runInBackground(shellCommand: command.shellCommand)
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Failed to toggle launch at login: \(error)")
        }
        buildMenu()
    }

    // MARK: - Updates

    @objc func checkForUpdates() {
        updater.checkForUpdateNow { [weak self] outcome in
            self?.presentCheckOutcome(outcome)
        }
    }

    @objc func installUpdate() {
        updater.installUpdate()
    }

    @objc func cancelUpdate() {
        updater.cancelUpdate()
    }

    /// A clicked check owes the user an answer; the alert is it. An update
    /// found this way can be installed right from the alert, or later from
    /// the menu, where the badge dot and the Update item now wait.
    private func presentCheckOutcome(_ outcome: Updater.CheckOutcome) {
        let alert = NSAlert()
        switch outcome {
        case .available(let update):
            alert.messageText = "Mac Tray Commands \(update.version) is available."
            alert.informativeText = "You have \(updater.currentVersion). The app will download the update, check that it is signed by the same developer, replace itself, and relaunch."
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Later")
            presentFromRunLoop(alert) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.updater.installUpdate()
                }
            }
            return
        case .upToDate:
            alert.messageText = "You're up to date."
            alert.informativeText = "Mac Tray Commands \(updater.currentVersion) is the latest version."
        case .needsNewerMacOS(let version, let macOS):
            alert.messageText = "Mac Tray Commands \(version) needs macOS \(macOS) or later."
            alert.informativeText = "This Mac runs macOS \(SystemVersion.current). Version \(updater.currentVersion) stays installed."
        case .failed:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates."
            alert.informativeText = "Check your connection and try again, or run: \(UpdateCatalog.brewUpgradeCommand)"
        }
        alert.addButton(withTitle: "OK")
        presentFromRunLoop(alert)
    }

    private func presentInstallFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The update couldn't be installed."
        alert.informativeText = "\(message)\n\nYou can try again from the menu, or run: \(UpdateCatalog.brewUpgradeCommand)"
        alert.addButton(withTitle: "OK")
        presentFromRunLoop(alert)
    }

    /// Run an alert from the run loop itself rather than from inside a
    /// dispatch block. The updater hands its results to the main queue, and
    /// a modal session started inside one of those blocks cannot drain that
    /// queue (the drain is not re-entrant), so the icon and menu updates the
    /// same result queued would wait behind the alert: the badge dot would
    /// appear only once "X is available" was dismissed. Default mode only,
    /// so an alert never opens over a menu that is still tracking.
    private func presentFromRunLoop(_ alert: NSAlert,
                                    then handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        RunLoop.main.perform {
            // The app isn't active when a menu item is clicked; bring it
            // forward or the alert opens behind everything.
            NSApp.activate(ignoringOtherApps: true)
            handler?(alert.runModal())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: - Windows

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mac Tray Commands",
            .applicationVersion: version,
            .version: build,
        ])
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            // .fullSizeContentView lets the SwiftUI content extend under the unified
            // title bar. NavigationSplitView assumes this on macOS 26+ and draws its
            // per-column title bar backgrounds there; without it they land 52pt below
            // the real title bar and cover the top of the detail view.
            let titleBarHeight: CGFloat = 52
            let contentSize = NSSize(width: 900, height: 650 + titleBarHeight)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MacTrayCommands — Settings"
            let controller = NSHostingController(rootView: SettingsView(store: store))
            window.contentViewController = controller
            window.setContentSize(contentSize)
            window.contentMinSize = NSSize(width: 560, height: 380)
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
