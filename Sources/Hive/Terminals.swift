import AppKit
import Combine
import SwiftTerm
import SwiftUI

/// One embedded terminal, usually running `claude`.
final class TermTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let view: ClaudeTerminalView
    let cwd: String
    @Published var sessionId: String?
    @Published var title: String
    @Published var exited = false
    @Published var exitCode: Int32?
    /// Called on the main thread when the process has ended.
    var onExit: (() -> Void)?

    convenience init(cwd: String, resume: HistorySession?) {
        let claude = ClaudeSetup.shellQuote(ClaudeSetup.executable)
        self.init(cwd: cwd,
                  title: resume?.title ?? "Neue Session",
                  sessionId: resume?.id,
                  command: resume.map { "exec \(claude) --resume \($0.id)" } ?? "exec \(claude)")
    }

    /// Runs `command` in the user's login shell, e.g. claude itself or the installer during setup.
    init(cwd: String, title: String, sessionId: String? = nil, command: String) {
        self.cwd = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        self.sessionId = sessionId
        self.title = title
        view = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        super.init()

        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.caretColor = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        // Many layouts (German, French, …) need Option for @ [ ] { } | ~, so it must not act as Meta.
        view.optionAsMetaKey = false

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Lets scripts (e.g. build.sh) know they run inside Hive.
        env["HIVE"] = "1"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // A login + interactive shell picks up the user's PATH (~/.local/bin) like a normal terminal would.
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-i", "-c", command],
            environment: env.map { "\($0.key)=\($0.value)" },
            currentDirectory: self.cwd
        )
    }

    var pid: pid_t { view.process?.shellPid ?? 0 }

    func terminate() {
        if !exited { view.terminate() }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.exitCode = exitCode
            self.exited = true
            self.onExit?()
        }
    }
}

/// State shared by all windows: which claude sessions run where, and the history on disk.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var windows: [WindowModel] = []
    @Published private(set) var running: [RunningSession] = []
    @Published private(set) var history: [HistorySession] = []
    @Published private(set) var setup: SetupState = .checking

    private var timer: Timer?

    init() {
        recheckSetup()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    var allTabs: [TermTab] { windows.flatMap(\.tabs) }

    /// Checks whether Claude Code is installed and signed in; once it is, empty windows get their first session.
    func recheckSetup() {
        Task {
            let state = await ClaudeSetup.check()
            setup = state
            if state == .ready {
                for w in windows {
                    w.setupTab = nil
                    if w.tabs.isEmpty { w.newSession() }
                }
            }
        }
    }

    func register(_ window: WindowModel) { windows.append(window) }
    func unregister(_ window: WindowModel) { windows.removeAll { $0 === window } }

    func window(owning tab: TermTab) -> WindowModel? {
        windows.first { $0.tabs.contains { $0 === tab } }
    }

    func title(for running: RunningSession) -> String {
        history.first { $0.id == running.sessionId }?.title ?? "Session \(running.sessionId.prefix(8))"
    }

    /// Claude sessions running in some other terminal app (not in any of our windows).
    var external: [RunningSession] {
        let own = Set(allTabs.map(\.pid))
        return running.filter { !own.contains($0.pid) }
    }

    /// Past sessions that are not running anywhere right now.
    var past: [HistorySession] {
        let busy = Set(running.map(\.sessionId)).union(allTabs.compactMap(\.sessionId))
        return history.filter { !busy.contains($0.id) }
    }

    func deleteFromHistory(_ session: HistorySession) {
        SessionStore.trash(sessionId: session.id)
        history.removeAll { $0.id == session.id }
    }

    func refresh() {
        // Only publish real changes, so the windows don't redraw every two seconds.
        let newRunning = SessionStore.running()
        if newRunning != running { running = newRunning }
        let newHistory = SessionStore.history(limit: 60)
        if newHistory != history { history = newHistory }
        for tab in allTabs {
            if let match = running.first(where: { $0.pid == tab.pid }), tab.sessionId != match.sessionId {
                tab.sessionId = match.sessionId
            }
            if let id = tab.sessionId, let h = history.first(where: { $0.id == id }), tab.title != h.title {
                tab.title = h.title
            }
        }
        for w in windows { w.window?.title = w.selected?.title ?? "Hive" }
    }
}

/// One window: its own sessions (tabs) and which of them are shown side by side.
@MainActor
final class WindowModel: ObservableObject {
    unowned let app: AppModel
    weak var window: NSWindow?

    @Published var tabs: [TermTab] = []
    /// The pane that has keyboard focus.
    @Published var selectedID: UUID?
    /// Tabs shown side by side in the terminal area (at most `maxPanes`), in display order.
    @Published var visibleIDs: [UUID] = []
    @Published var pinned = false
    @Published var sidebarVisible = true
    @Published var query = ""
    /// Terminal running the installer or login while Claude Code is being set up.
    @Published var setupTab: TermTab?
    var subscriptions = Set<AnyCancellable>()

    static let maxPanes = 4

    init(app: AppModel) {
        self.app = app
        // Re-render when shared state changes (other windows' tabs, running sessions, history).
        app.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var selected: TermTab? { tabs.first { $0.id == selectedID } }
    var visible: [TermTab] { visibleIDs.compactMap { id in tabs.first { $0.id == id } } }
    var canSplit: Bool { visibleIDs.count < Self.maxPanes }
    var runningTabs: [TermTab] { tabs.filter { !$0.exited } }

    var otherWindowTabs: [TermTab] {
        app.windows.filter { $0 !== self }.flatMap(\.tabs)
    }

    var filteredPast: [HistorySession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return app.past }
        return app.past.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.cwd.localizedCaseInsensitiveContains(q) }
    }

    /// Runs a setup step (install or login) visibly in a terminal, then checks the setup again.
    func runSetupStep(title: String, command: String) {
        setupTab?.terminate()
        let tab = TermTab(cwd: NSHomeDirectory(), title: title, command: command)
        tab.onExit = { [weak self] in self?.app.recheckSetup() }
        setupTab = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.window?.makeFirstResponder(tab.view)
        }
    }

    /// `split: true` opens the session in an extra pane next to the current ones instead of replacing the focused pane.
    func newSession(in cwd: String = NSHomeDirectory(), split: Bool = false) {
        open(TermTab(cwd: cwd, resume: nil), split: split)
    }

    func resume(_ session: HistorySession, split: Bool = false) {
        if let tab = app.allTabs.first(where: { $0.sessionId == session.id }) {
            reveal(tab, split: split)
        } else {
            open(TermTab(cwd: session.cwd, resume: session), split: split)
        }
    }

    /// Shows a tab wherever it lives: in this window, or by bringing its window to the front.
    func reveal(_ tab: TermTab, split: Bool = false) {
        if let owner = app.window(owning: tab), owner !== self {
            owner.show(tab)
            owner.window?.makeKeyAndOrderFront(nil)
        } else {
            show(tab, split: split)
        }
    }

    /// Moves a session from another window into this one (like dragging a tab between Chrome windows).
    func adopt(_ tab: TermTab, split: Bool = false) {
        guard let owner = app.window(owning: tab), owner !== self else { return }
        owner.detach(tab)
        open(tab, split: split)
    }

    /// Shows a tab: focuses it if already visible, otherwise puts it into the focused pane (or a new one).
    func show(_ tab: TermTab, split: Bool = false) {
        if !visibleIDs.contains(tab.id) {
            if split && canSplit {
                visibleIDs.append(tab.id)
            } else if let i = visibleIDs.firstIndex(where: { $0 == selectedID }) {
                visibleIDs[i] = tab.id
            } else if visibleIDs.isEmpty {
                visibleIDs = [tab.id]
            } else {
                visibleIDs[visibleIDs.count - 1] = tab.id
            }
        }
        select(tab)
    }

    func select(_ tab: TermTab) {
        selectedID = tab.id
        window?.title = tab.title
        focusTerminal()
    }

    /// Called when the user clicks into a terminal, so the focused pane follows the mouse.
    func didFocus(view: NSView) {
        if let tab = tabs.first(where: { $0.view === view }), tab.id != selectedID {
            selectedID = tab.id
            window?.title = tab.title
        }
    }

    /// Removes a pane from the split view; the session keeps running in the sidebar.
    func hidePane(_ tab: TermTab) {
        visibleIDs.removeAll { $0 == tab.id }
        if selectedID == tab.id { selectedID = visibleIDs.last }
        focusTerminal()
    }

    /// Shows only the focused session again.
    func unsplit() {
        if let id = selectedID { visibleIDs = [id] }
        focusTerminal()
    }

    func close(_ tab: TermTab) {
        tab.terminate()
        detach(tab)
    }

    /// Restarts a session whose claude process has exited, resuming its conversation if known.
    func restart(_ tab: TermTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let resume = tab.sessionId.map { HistorySession(id: $0, title: tab.title, cwd: tab.cwd, modified: Date()) }
        let fresh = TermTab(cwd: tab.cwd, resume: resume)
        tabs[index] = fresh
        if let v = visibleIDs.firstIndex(of: tab.id) { visibleIDs[v] = fresh.id } else { show(fresh) }
        select(fresh)
    }

    func closeAll() {
        setupTab?.terminate()
        setupTab = nil
        tabs.forEach { $0.terminate() }
        tabs.removeAll()
        visibleIDs.removeAll()
        selectedID = nil
    }

    private func detach(_ tab: TermTab) {
        tabs.removeAll { $0 === tab }
        visibleIDs.removeAll { $0 == tab.id }
        if visibleIDs.isEmpty, let last = tabs.last { visibleIDs = [last.id] }
        if selectedID == tab.id || selectedID == nil { selectedID = visibleIDs.last }
        focusTerminal()
    }

    func focusTerminal() {
        // Slight delay: a pane that was just added is only attached to the window after the next layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let view = self.selected?.view, view.window === self.window else { return }
            self.window?.makeFirstResponder(view)
        }
    }

    private func open(_ tab: TermTab, split: Bool) {
        tabs.append(tab)
        show(tab, split: split)
    }
}
