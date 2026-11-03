import AppKit
import SwiftUI

private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
private let sidebarBackground = Color(white: 0.075)
private let hairline = Color.white.opacity(0.07)

/// ⌘-click on a session opens it next to the current one instead of replacing it.
private var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }

struct WindowView: View {
    @ObservedObject var model: WindowModel
    let chooseFolder: () -> Void

    var body: some View {
        Group {
            if model.app.setup == .ready {
                sessions
            } else {
                OnboardingView(model: model)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var sessions: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                Sidebar(model: model, chooseFolder: chooseFolder)
                    .frame(width: 250)
                    .background(sidebarBackground)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(hairline).frame(width: 1)
            }
            VStack(spacing: 0) {
                TopBar(model: model)
                TerminalArea(model: model)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.sidebarVisible)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        HStack(spacing: 6) {
            if !model.sidebarVisible {
                // Room for the window's traffic lights.
                Spacer().frame(width: 72)
                IconButton(symbol: "sidebar.left", help: "Seitenleiste einblenden (⌃⌘S)") { model.sidebarVisible = true }
            }
            Spacer(minLength: 8)
            VStack(spacing: 1) {
                Text(model.selected?.title ?? "Hive")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let cwd = model.selected?.cwd {
                    Text(cwd.abbreviatingHome)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            IconButton(symbol: "paperclip", help: "Dateien oder Bilder anhängen (⇧⌘A) – oder einfach ins Terminal ziehen") {
                model.selected?.view.chooseAttachments()
            }
            .disabled(model.selected == nil)
            if model.visibleIDs.count > 1 {
                IconButton(symbol: "rectangle", help: "Nur die aktive Session anzeigen") { model.unsplit() }
            }
            IconButton(symbol: "rectangle.split.2x1", help: "Neue Session daneben (⌘D)") { model.newSession(split: true) }
                .disabled(!model.canSplit)
                .opacity(model.canSplit ? 1 : 0.35)
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: "Immer im Vordergrund", active: model.pinned) {
                model.pinned.toggle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: WindowModel
    let chooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                IconButton(symbol: "sidebar.left", help: "Seitenleiste ausblenden (⌃⌘S)") { model.sidebarVisible = false }
            }
            .frame(height: 40)
            .padding(.horizontal, 10)
            .padding(.bottom, -10)

            HStack(spacing: 6) {
                NewSessionButton { model.newSession() }
                IconButton(symbol: "folder.badge.plus", help: "Neue Session in einem Ordner (⌘O)", boxed: true, action: chooseFolder)
            }
            .padding(.horizontal, 10)

            SearchField(text: $model.query)
                .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !model.tabs.isEmpty {
                        SectionLabel("Dieses Fenster", count: model.tabs.count)
                        ForEach(model.tabs) { tab in
                            TabRow(model: model, tab: tab)
                        }
                    }

                    let others = model.otherWindowTabs
                    if !others.isEmpty {
                        SectionLabel("Andere Fenster", count: others.count)
                        ForEach(others) { tab in
                            OtherWindowRow(model: model, tab: tab)
                        }
                    }

                    let external = model.app.external
                    if !external.isEmpty {
                        SectionLabel("Externe Terminals", count: external.count)
                        ForEach(external) { s in
                            Row(title: model.app.title(for: s),
                                subtitle: [s.cwd.abbreviatingHome, SessionStore.hostApp(of: s.pid)?.localizedName]
                                    .compactMap { $0 }.joined(separator: " · "),
                                dot: .green,
                                action: { SessionStore.focusHostApp(of: s.pid) })
                                .help("Zum Terminal wechseln, in dem diese Session läuft")
                        }
                    }

                    let past = model.filteredPast
                    if !past.isEmpty || !model.query.isEmpty {
                        SectionLabel("Verlauf", count: past.count)
                        if past.isEmpty {
                            Text("Keine Treffer")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        ForEach(past) { s in
                            Row(title: s.title,
                                subtitle: "\(s.cwd.abbreviatingHome) · \(s.modified.formatted(.relative(presentation: .named)))",
                                action: { model.resume(s, split: commandHeld) },
                                actions: (model.canSplit
                                    ? [RowAction(symbol: "rectangle.split.2x1", help: "Daneben öffnen") { model.resume(s, split: true) }]
                                    : []) + [RowAction(symbol: "xmark", help: "Aus dem Verlauf löschen (in den Papierkorb)") {
                                        withAnimation(.easeOut(duration: 0.18)) { model.app.deleteFromHistory(s) }
                                    }])
                                .help("Klick: fortsetzen · ⌘-Klick: daneben öffnen")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct TabRow: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TermTab

    var body: some View {
        let visible = model.visibleIDs.contains(tab.id)
        var actions: [RowAction] = []
        if model.canSplit && !visible && !tab.exited {
            actions.append(RowAction(symbol: "rectangle.split.2x1", help: "Daneben öffnen") { model.show(tab, split: true) })
        }
        actions.append(RowAction(symbol: "xmark", help: "Session beenden") { model.close(tab) })

        return Row(title: tab.title,
                   subtitle: tab.exited ? "Beendet · Klicken zum Fortsetzen" : tab.cwd.abbreviatingHome,
                   dot: tab.exited ? Color.gray : accent,
                   selected: tab.id == model.selectedID,
                   visible: visible,
                   action: { tab.exited ? model.restart(tab) : model.show(tab, split: commandHeld) },
                   actions: actions)
    }
}

private struct OtherWindowRow: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TermTab

    var body: some View {
        Row(title: tab.title,
            subtitle: tab.cwd.abbreviatingHome,
            dot: tab.exited ? Color.gray : accent.opacity(0.6),
            action: { model.reveal(tab) },
            actions: [RowAction(symbol: "arrow.down.right.and.arrow.up.left", help: "In dieses Fenster holen") { model.adopt(tab) }])
            .help("Klick: zum Fenster wechseln")
    }
}

// MARK: - Terminal area

private struct TerminalArea: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        let panes = model.visible
        if panes.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "sparkle")
                    .font(.system(size: 30))
                    .foregroundStyle(accent)
                Text("Keine offene Session")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button { model.newSession() } label: {
                    Text("Neue Session starten").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 1–2 panes side by side; 3–4 as a 2×2 grid.
            let rows = panes.count <= 2 ? [panes] : [Array(panes.prefix(2)), Array(panes.dropFirst(2))]
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(rows[r]) { tab in
                            Pane(tab: tab, focused: tab.id == model.selectedID, split: panes.count > 1,
                                 onFocus: { model.select(tab) }, onHide: { model.hidePane(tab) })
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

private struct Pane: View {
    @ObservedObject var tab: TermTab
    let focused: Bool
    let split: Bool
    let onFocus: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if split {
                HStack(spacing: 6) {
                    Circle().fill(tab.exited ? Color.gray : accent).frame(width: 6, height: 6)
                    Text(tab.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    IconButton(symbol: "xmark", help: "Aus der Ansicht nehmen (Session läuft weiter)", size: 9, action: onHide)
                }
                .foregroundStyle(focused ? .primary : .secondary)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 26)
                .contentShape(Rectangle())
                .onTapGesture(perform: onFocus)
            }
            TerminalHost(view: tab.view)
                .padding(.horizontal, split ? 8 : 0)
                .padding(.bottom, split ? 6 : 0)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(split ? 0.025 : 0)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(split && focused ? accent.opacity(0.55) : hairline.opacity(split ? 1 : 0), lineWidth: 1)
        )
        .opacity(split && !focused ? 0.82 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct TerminalHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - Building blocks

private struct RowAction: Identifiable {
    let symbol: String
    let help: String
    let perform: () -> Void
    var id: String { symbol }
}

private struct Row: View {
    let title: String
    let subtitle: String
    var dot: Color?
    var selected = false
    var visible = false
    let action: () -> Void
    var actions: [RowAction] = []
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle().fill(dot ?? Color.white.opacity(0.15)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : Color.white.opacity(0.85))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hover {
                HStack(spacing: 2) {
                    ForEach(actions) { a in
                        IconButton(symbol: a.symbol, help: a.help, size: 10, action: a.perform)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(selected ? 0.11 : visible ? 0.06 : hover ? 0.045 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct NewSessionButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                Text("Neue Session").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("⌘T").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.1 : 0.065)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField("Verlauf durchsuchen", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: "Suche leeren", size: 11) { text = "" }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045)))
    }
}

private struct SectionLabel: View {
    let text: String
    let count: Int
    init(_ text: String, count: Int) { self.text = text; self.count = count }

    var body: some View {
        HStack(spacing: 5) {
            Text(text.uppercased())
            Text("\(count)").foregroundStyle(.quaternary)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 12
    var active = false
    var boxed = false
    let action: () -> Void
    @State private var hover = false

    init(symbol: String, help: String, size: CGFloat = 12, active: Bool = false, boxed: Bool = false,
         action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.active = active
        self.boxed = boxed
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(active ? accent : hover ? .primary : .secondary)
                .frame(width: boxed ? 28 : size + 14, height: boxed ? 28 : size + 12)
                .background(
                    RoundedRectangle(cornerRadius: boxed ? 8 : 6)
                        .fill(Color.white.opacity(boxed ? (hover ? 0.1 : 0.065) : (hover ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
