import AppKit
import SwiftUI
import ZephrCore

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
        let screen = NSScreen.main ?? NSScreen.screens.first
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
            group("Adjust 5%", keys: [("h j k l", nil)])
            group("Fine 1%", keys: [("⇧ + hjkl", nil)])
            group("Back", keys: [("esc", nil)])
        }
    }

    private var cheatSheet: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow { sheetItem("h j k l / arrows", "Focus window"); sheetItem("t", "Toggle float") }
            GridRow { sheetItem("⇧ H J K L", "Move window"); sheetItem("m", "Monocle") }
            GridRow { sheetItem("1–9", "Go to workspace"); sheetItem("s / v", "Split right / down") }
            GridRow { sheetItem("⇧ 1–9", "Send to workspace"); sheetItem("space", "Tiles ↔ accordion") }
            GridRow { sheetItem("r", "Resize mode"); sheetItem("=", "Balance sizes") }
            GridRow { sheetItem("q", "Close window"); sheetItem("p", "Palette") }
            GridRow { sheetItem("tab", "Next display"); sheetItem("w", "Rescue all windows") }
            GridRow { sheetItem("esc / leader", "Close layer"); sheetItem("⌃⌥ …", "Same, without leader") }
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
