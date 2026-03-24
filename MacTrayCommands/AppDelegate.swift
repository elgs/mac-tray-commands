import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    let store = CommandStore()
    private var settingsWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "MacTrayCommands")
            button.image?.isTemplate = true
        }

        buildMenu()
        setupMainMenu()
        registerGlobalHotKey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(buildMenu),
            name: .commandsDidChange,
            object: nil
        )
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
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
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

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mac Tray Commands",
            .applicationVersion: version,
            .version: build,
        ])
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacTrayCommands — Settings"
            let controller = NSHostingController(rootView: SettingsView(store: store))
            controller.preferredContentSize = NSSize(width: 900, height: 650)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 900, height: 650))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
