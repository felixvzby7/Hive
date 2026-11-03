import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// Global hotkey via Carbon, which does not need Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let handler: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            Unmanaged<HotKey>.fromOpaque(ctx!).takeUnretainedValue().handler()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4E434C44), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

/// One Hive window with its own sessions, like a Chrome window with its own tabs.
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let model: WindowModel
    private let onClose: (SessionWindowController) -> Void

    init(app: AppModel, cascadeFrom previous: NSWindow?, onClose: @escaping (SessionWindowController) -> Void) {
        model = WindowModel(app: app)
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Hive"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 640, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)

        window.delegate = self
        model.window = window
        window.contentView = NSHostingView(rootView: WindowView(model: model) { [weak self] in self?.chooseFolder() })

        if let previous {
            // New windows step down-right from the current one, like Chrome.
            window.setFrame(previous.frame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 28, y: previous.frame.maxY - 28))
        } else if !window.setFrameUsingName("HiveWindow") {
            // Very first window: drop down right under the notch.
            let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - 490, y: screen.visibleFrame.maxY - 8))
        }

        // Clicking into a pane makes it the focused one.
        window.publisher(for: \.firstResponder).sink { [weak self] responder in
            guard let view = responder as? NSView else { return }
            self?.model.didFocus(view: view)
        }.store(in: &model.subscriptions)

        model.$pinned.sink { [weak window] pinned in
            window?.level = pinned ? .floating : .normal
        }.store(in: &model.subscriptions)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        window.alphaValue = 0
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        // Until Claude Code is installed and signed in, the window shows the welcome/setup screen instead.
        if model.tabs.isEmpty && model.app.setup == .ready { model.newSession() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = model.runningTabs.count
        guard running > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "Fenster mit 1 laufenden Session schließen?" : "Fenster mit \(running) laufenden Sessions schließen?"
        alert.informativeText = "Die Sessions werden beendet. Du kannst sie jederzeit über den Verlauf fortsetzen."
        alert.addButton(withTitle: "Schließen")
        alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn { sender.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // The next "first" window reopens where this one was.
        window?.saveFrame(usingName: "HiveWindow")
        model.closeAll()
        onClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.focusTerminal()
    }

    func chooseFolder() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.prompt = "Session starten"
        picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        picker.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                if response == .OK, let url = picker.url {
                    self?.model.newSession(in: url.path)
                } else {
                    self?.model.focusTerminal()
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let app = AppModel()
    private var controllers: [SessionWindowController] = []
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Hive")
        statusItem.button?.toolTip = "Hive – Claude Terminal App (⌃⌥Space)"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // ⌃⌥Space
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }

        newWindow()
    }

    // MARK: Windows

    /// The window menu commands act on: the key window, else the frontmost of ours.
    private var current: SessionWindowController? {
        controllers.first { $0.window?.isKeyWindow == true }
            ?? controllers.first { $0.window?.isMainWindow == true }
            ?? NSApp.orderedWindows.lazy.compactMap { w in self.controllers.first { $0.window === w } }.first
    }

    @discardableResult
    private func newWindow() -> SessionWindowController {
        let controller = SessionWindowController(app: app, cascadeFrom: current?.window) { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.app.unregister(closed.model)
        }
        controllers.append(controller)
        app.register(controller.model)
        controller.present()
        return controller
    }

    /// Runs `body` on the current window, opening one first if there is none.
    private func withCurrent(_ body: (SessionWindowController) -> Void) {
        if let c = current {
            NSApp.activate()
            c.window?.makeKeyAndOrderFront(nil)
            body(c)
        } else {
            body(newWindow())
        }
    }

    private func toggle() {
        if NSApp.isActive, controllers.contains(where: { $0.window?.isKeyWindow == true }) {
            NSApp.hide(nil)
        } else if controllers.isEmpty {
            newWindow()
        } else {
            NSApp.unhide(nil)
            NSApp.activate()
            controllers.forEach { $0.window?.deminiaturize(nil) }
            current?.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Dock click: bring windows back, or open a new one if none is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let minimized = controllers.first(where: { $0.window?.isMiniaturized == true }) {
                minimized.window?.deminiaturize(nil)
            } else {
                newWindow()
            }
        }
        return false
    }

    /// Right-click on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Neues Fenster", #selector(newWindowAction)))
        menu.addItem(item("Neue Session in Ordner …", #selector(newSessionInFolder)))
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = controllers.reduce(0) { $0 + $1.model.runningTabs.count }
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Hive beenden?"
        alert.informativeText = "\(running) laufende Session\(running == 1 ? "" : "s") werden beendet. Du kannst sie über den Verlauf fortsetzen."
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.model.closeAll() }
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("Über Hive", #selector(showAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Beim Anmelden starten", #selector(toggleLogin)))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hive ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Andere ausblenden", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hive beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let file = NSMenu(title: "Ablage")
        file.addItem(item("Neues Fenster", #selector(newWindowAction), "n"))
        file.addItem(item("Neue Session", #selector(newSession), "t"))
        file.addItem(item("Neue Session daneben", #selector(newSplitSession), "d"))
        file.addItem(item("Neue Session in Ordner …", #selector(newSessionInFolder), "o"))
        file.addItem(item("Datei anhängen …", #selector(attachFiles), "a", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Session beenden", #selector(closeSession), "w"))
        file.addItem(item("Fenster schließen", #selector(closeWindow), "w", [.command, .shift]))
        main.addItem(withTitle: "Ablage", action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Bearbeiten", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "Darstellung")
        view.addItem(item("Seitenleiste ein-/ausblenden", #selector(toggleSidebar), "s", [.command, .control]))
        view.addItem(item("Nur aktive Session anzeigen", #selector(unsplit), "\r", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(withTitle: "Vollbild", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "Darstellung", action: nil, keyEquivalent: "").submenu = view

        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoomen", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(item("Immer im Vordergrund", #selector(togglePin)))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Alle nach vorne bringen", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Fenster", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleLogin):
            menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        case #selector(togglePin):
            menuItem.state = current?.model.pinned == true ? .on : .off
            return current != nil
        case #selector(attachFiles):
            return current?.model.selected != nil
        case #selector(closeSession), #selector(closeWindow), #selector(toggleSidebar), #selector(unsplit):
            return current != nil
        default:
            break
        }
        return true
    }

    @objc private func statusClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return toggle() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Öffnen / Ausblenden  (⌃⌥Space)", action: #selector(toggleAction), keyEquivalent: "").target = self
        menu.addItem(item("Neues Fenster", #selector(newWindowAction)))
        menu.addItem(.separator())
        let login = item("Beim Anmelden starten", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hive beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleAction() { toggle() }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Hive",
            .credits: NSAttributedString(
                string: "Claude Terminal App\nMehrere Claude Code-Sessions nebeneinander.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }
    @objc private func newWindowAction() { newWindow() }
    @objc private func newSession() { withCurrent { $0.model.newSession() } }
    @objc private func newSplitSession() { withCurrent { $0.model.newSession(split: true) } }
    @objc private func newSessionInFolder() { withCurrent { $0.chooseFolder() } }
    @objc private func attachFiles() { current?.model.selected?.view.chooseAttachments() }
    @objc private func toggleSidebar() { current?.model.sidebarVisible.toggle() }
    @objc private func unsplit() { current?.model.unsplit() }
    @objc private func togglePin() { current?.model.pinned.toggle() }
    @objc private func closeWindow() { current?.window?.performClose(nil) }

    @objc private func closeSession() {
        guard let c = current else { return }
        if let tab = c.model.selected {
            c.model.close(tab)
        } else {
            c.window?.performClose(nil)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
