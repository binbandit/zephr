import AppKit
import SwiftUI
import ZephrCore

/// The palette (§4.2): one fuzzy-searchable surface over windows,
/// workspaces, and every command — deterministic app switching by name,
/// window search across workspaces, and the discoverability escape hatch.
@MainActor
final class PaletteController {

    enum Entry: Identifiable {
        case window(WindowID, title: String, app: String, workspace: Int?, icon: NSImage?)
        case workspace(Int)
        case command(Command, keys: String)

        var id: String {
            switch self {
            case .window(let id, _, _, _, _): "w\(id.raw)"
            case .workspace(let n): "s\(n)"
            case .command(let c, _): "c\(c.label)"
            }
        }

        var searchText: String {
            switch self {
            case .window(_, let title, let app, _, _): "\(app) \(title)"
            case .workspace(let n): "workspace \(n)"
            case .command(let c, _): c.label
            }
        }
    }

    @Observable
    final class Model {
        var query = "" {
            didSet { refilter() }
        }
        var selection = 0
        var results: [Entry] = []
        fileprivate var all: [Entry] = []
        fileprivate var commit: ((Entry) -> Void)?
        fileprivate var dismiss: (() -> Void)?

        fileprivate func refilter() {
            let q = query.trimmingCharacters(in: .whitespaces)
            if q.isEmpty {
                results = all
            } else {
                results = all
                    .compactMap { entry in fuzzyScore(q, entry.searchText).map { (entry, $0) } }
                    .sorted { $0.1 > $1.1 }
                    .map(\.0)
            }
            selection = 0
        }
    }

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: NSPanel
    private let windowDelegate = CallbackWindowDelegate()
    private let model = Model()
    private weak var engine: TilingEngine?

    var isVisible: Bool { panel.isVisible }

    init(engine: TilingEngine) {
        self.engine = engine
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PaletteView(model: model))

        // §4.2 cites Spotlight/Raycast behaviour: losing key (⌘Tab, a click
        // elsewhere) dismisses — the panel must never linger over every app.
        windowDelegate.onResignKey = { [weak self] in self?.hide() }
        panel.delegate = windowDelegate

        model.commit = { [weak self] entry in self?.commit(entry) }
        model.dismiss = { [weak self] in self?.hide() }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        guard let engine else { return }
        model.all = Self.catalog(engine: engine)
        model.query = ""   // didSet refilters against the fresh catalog

        let screen = engine.focusedScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: 560, height: 380)
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2 + visible.height * 0.12,
                width: size.width, height: size.height
            ),
            display: true
        )
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func commit(_ entry: Entry) {
        hide()
        guard let engine else { return }
        switch entry {
        case .window(let id, _, _, _, _):
            engine.focusManagedWindow(id)
        case .workspace(let n):
            engine.perform(.goToWorkspace(n))
        case .command(let command, _):
            engine.perform(command)
        }
    }

    private static func catalog(engine: TilingEngine) -> [Entry] {
        var entries: [Entry] = engine.paletteWindows().map {
            .window($0.id, title: $0.title, app: $0.app, workspace: $0.workspace, icon: $0.icon)
        }
        for n in 1...9 {
            entries.append(.workspace(n))
        }
        // §4.2: chord hints follow the active key preset; vim (no chords)
        // falls back to the leader-layer keys.
        func chord(_ key: String, shift: Bool = false, orLeader leader: String) -> String {
            ChordHints.chord(key, shift: shift) ?? leader
        }
        let commands: [(Command, String)] = [
            (.toggleFloat, chord("T", orLeader: "leader t")),
            (.toggleMonocle, chord("M", orLeader: "leader m")),
            (.balance, "leader ="),
            (.cycleLayout, "leader ␣"), (.rescueWindows, "leader w"),
            (.focusNextDisplay, chord("`", orLeader: "leader ⇥")),
            (.closeWindow, chord("Q", orLeader: "leader q")),
            (.toggleWorkspaceFloatMode, ""), (.togglePause, ""),
            (.splitPreselect(.horizontal), "leader s"), (.splitPreselect(.vertical), "leader v"),
            (.focus(.left), chord("H", orLeader: "leader h")),
            (.focus(.down), chord("J", orLeader: "leader j")),
            (.focus(.up), chord("K", orLeader: "leader k")),
            (.focus(.right), chord("L", orLeader: "leader l")),
            (.move(.left), chord("H", shift: true, orLeader: "leader ⇧h")),
            (.move(.down), chord("J", shift: true, orLeader: "leader ⇧j")),
            (.move(.up), chord("K", shift: true, orLeader: "leader ⇧k")),
            (.move(.right), chord("L", shift: true, orLeader: "leader ⇧l")),
        ]
        entries.append(contentsOf: commands.map { .command($0.0, keys: $0.1) })
        return entries
    }
}

/// Subsequence fuzzy match; higher is better, nil means no match.
/// Word-start and adjacency score highest; spread is penalized.
func fuzzyScore(_ query: String, _ candidate: String) -> Int? {
    let q = Array(query.lowercased())
    let c = Array(candidate.lowercased())
    guard !q.isEmpty else { return 0 }
    var score = 0
    var qi = 0
    var lastMatch = -2
    for (i, char) in c.enumerated() {
        guard qi < q.count, char == q[qi] else { continue }
        score += 1
        if i == 0 || c[i - 1] == " " { score += 8 }          // word start
        if i == lastMatch + 1 { score += 5 }                 // adjacency
        score -= min(i - lastMatch - 1, 10) / 2              // spread penalty
        lastMatch = i
        qi += 1
    }
    return qi == q.count ? score : nil
}

// MARK: - SwiftUI content

private struct PaletteView: View {
    @Bindable var model: PaletteController.Model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Windows, workspaces, commands…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .light))
                .padding(14)
                .focused($focused)
                .onAppear { focused = true }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) { commit(); return .handled }
                .onKeyPress(.escape) { model.dismiss?(); return .handled }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == model.selection)
                                .id(index)
                                .onTapGesture {
                                    model.selection = index
                                    commit()
                                }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, new in
                    proxy.scrollTo(new)
                }
            }
        }
        .frame(width: 560, height: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private func move(_ delta: Int) {
        guard !model.results.isEmpty else { return }
        model.selection = min(max(0, model.selection + delta), model.results.count - 1)
    }

    private func commit() {
        guard model.results.indices.contains(model.selection) else { return }
        model.commit?(model.results[model.selection])
    }

    @ViewBuilder
    private func row(_ entry: PaletteController.Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch entry {
            case .window(_, let title, let app, let workspace, let icon):
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "macwindow").frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? app : title).lineLimit(1)
                    Text(app).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(workspace.map(String.init) ?? "⛶")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .help(workspace == nil ? "Native fullscreen" : "Workspace")
            case .workspace(let n):
                Image(systemName: "rectangle.3.group").frame(width: 22)
                Text("Go to workspace \(n)")
                Spacer()
            case .command(let command, let keys):
                Image(systemName: "command").frame(width: 22)
                Text(command.label)
                Spacer()
                Text(keys)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }
}
