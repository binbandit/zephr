import AppKit
import SwiftUI
import ZephrCore

/// Chord hints shown in the UI must reflect the active key preset (§4.2) —
/// ⌃⌥ by default, ⌘⌥ under i3, bare ⌥ under aerospace, none under vim
/// (leader-only). Derived from the config because `HotkeyService` keeps its
/// `chordMods` private; a read-only accessor there would let this follow
/// per-key rebinding later.
@MainActor
enum ChordHints {
    /// Modifiers the active preset uses for direct chords; nil when the
    /// preset has none (vim is leader-only). One table, so the strip, the
    /// palette and the menu can never disagree about what is bound.
    private static var modifiers: (control: Bool, option: Bool, command: Bool)? {
        switch AppDelegate.shared?.configService.current.keyPreset {
        case "i3": (control: false, option: true, command: true)
        case "aerospace": (control: false, option: true, command: false)
        case "vim": nil
        default: (control: true, option: true, command: false)
        }
    }

    /// A chord in Apple's canonical modifier order, ⌃⌥⇧⌘ — so the i3 preset
    /// renders `⌥⇧⌘H`, not `⌘⌥⇧H`. Rendering the whole chord here rather
    /// than handing out a prefix to concatenate is what keeps ⇧ in the right
    /// place when ⌘ is part of the preset.
    static func chord(_ key: String, shift: Bool = false) -> String? {
        guard let mods = modifiers else { return nil }
        var out = ""
        if mods.control { out += "⌃" }
        if mods.option { out += "⌥" }
        if shift { out += "⇧" }
        if mods.command { out += "⌘" }
        return out + key
    }

    /// Display prefix for an unshifted chord, e.g. "⌃⌥".
    static var prefix: String? { chord("") }

    /// Menu-item shortcut modifiers matching the active chords; nil = no
    /// chord equivalents exist (vim preset).
    static var menuModifiers: EventModifiers? {
        guard let mods = modifiers else { return nil }
        var out: EventModifiers = []
        if mods.control { out.insert(.control) }
        if mods.option { out.insert(.option) }
        if mods.command { out.insert(.command) }
        return out
    }
}

/// The which-key command strip (§4.2): a translucent HUD that appears
/// bottom-center the moment the leader is pressed, showing what every key
/// does. `?` expands it into the full cheat sheet.
@MainActor
final class CommandStripController {

    @Observable
    final class StripModel {
        var mode: HotkeyService.LayerState = .inactive
        var expanded = false
        var hint: String?
    }

    func showHint(_ text: String) {
        model.hint = text
        if model.mode != .inactive { present() }
    }

    private let panel: NSPanel
    private let model = StripModel()

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // Purely informational — it must never swallow clicks meant for the
        // windows underneath (§4.2).
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CommandStripView(model: model))
    }

    func update(state: HotkeyService.LayerState) {
        model.mode = state
        if state == .inactive {
            model.expanded = false
            model.hint = nil
            panel.orderOut(nil)
            return
        }
        present()
    }

    func toggleHelp() {
        guard model.mode != .inactive else { return }
        model.expanded.toggle()
        present()
    }

    private func present() {
        guard let hosting = panel.contentView as? NSHostingView<CommandStripView> else { return }
        hosting.layout()
        let size = hosting.fittingSize
        let screen = AppDelegate.shared?.engine.focusedScreen
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 28
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

// MARK: - SwiftUI content

struct CommandStripView: View {
    @Bindable var model: CommandStripController.StripModel

    var body: some View {
        VStack(spacing: 6) {
            if let hint = model.hint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
            if model.mode == .resize {
                resizeStrip
            } else if model.expanded {
                cheatSheet
            } else {
                strip
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .padding(6)
        .fixedSize()
    }

    private var strip: some View {
        HStack(spacing: 16) {
            group("Focus", keys: [("h j k l", nil)])
            group("Move", keys: [("⇧HJKL", nil)])
            group("Spaces", keys: [("1–9", nil), ("⇧1–9", "send")])
            group("Window", keys: [("t", "float"), ("m", "monocle"), ("s v", "split")])
            group("Layout", keys: [("␣", "cycle"), ("r", "resize"), ("=", "balance")])
            group("Rescue", keys: [("w", nil)])
            group("Help", keys: [("?", nil)])
        }
    }

    private var resizeStrip: some View {
        HStack(spacing: 16) {
            Text("RESIZE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
            group("Bigger", keys: [("l  j", nil)])
            group("Smaller", keys: [("h  k", nil)])
            group("Fine", keys: [("⇧ + key", nil)])
            group("Back", keys: [("esc", nil)])
        }
    }

    private var cheatSheet: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow { sheetItem("h j k l / arrows", "Focus window"); sheetItem("t", "Toggle float") }
            GridRow { sheetItem("⇧ H J K L", "Move window"); sheetItem("m", "Monocle") }
            GridRow { sheetItem("1–9", "Go to workspace"); sheetItem("s / v", "Split right / down") }
            GridRow { sheetItem("⇧ 1–9", "Send to workspace"); sheetItem("space", "Tiles ↔ accordion") }
            GridRow { sheetItem("r", "Resize: l/j bigger, h/k smaller"); sheetItem("=", "Balance sizes") }
            GridRow { sheetItem("q", "Close window"); sheetItem("p", "Palette") }
            GridRow { sheetItem("tab", "Next display"); sheetItem("w", "Rescue all windows") }
            GridRow { sheetItem("⇧ tab", "Send window to next display"); sheetItem("d", "Send workspace to display") }
            GridRow { sheetItem("⇧ D", "Pause this display only"); sheetItem("", "") }
            GridRow { sheetItem("g", "Group with next"); sheetItem("⇧ G", "Ungroup everything") }
            GridRow { sheetItem("o", "Row ↔ column"); sheetItem("", "") }
            GridRow {
                sheetItem("esc / leader", "Close layer")
                // §4.2: the hint tracks the active preset; vim has no chords.
                if let prefix = ChordHints.prefix {
                    sheetItem("\(prefix) …", "Same, without leader")
                }
            }
        }
    }

    private func sheetItem(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            keycap(key)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func group(_ title: String, keys: [(String, String?)]) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(keys.enumerated()), id: \.offset) { _, item in
                keycap(item.0)
                if let hint = item.1 {
                    Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            )
    }
}
