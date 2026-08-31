import AppKit
import ZephrCore

/// The focused-window border (§4.3): a 2 pt accent-colored rounded outline
/// drawn by a click-through overlay window — the clearest cue for where
/// focus is while learning. Config: `[layout] focus-border`.
@MainActor
final class FocusBorderController {

    var enabled = true {
        didSet { if !enabled { window.orderOut(nil) } }
    }

    /// The system's window corner radius. macOS 26 rounded windows
    /// considerably more than earlier releases, so the pre-Tahoe 10 pt
    /// outline visibly cut across the corner of every window it traced.
    private static var systemWindowCornerRadius: CGFloat {
        if #available(macOS 26, *) { 16 } else { 10 }
    }

    /// How far outside the window the stroke sits, so it never covers
    /// content. The outline's radius has to grow by the same amount or the
    /// curve stops being concentric with the window's own — the corners
    /// pinch in while the straight edges stay parallel.
    private static let outset: CGFloat = 3

    private let window: NSWindow
    private let borderView: NSView

    init() {
        borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.borderWidth = 2
        borderView.layer?.cornerRadius = Self.systemWindowCornerRadius + Self.outset
        // macOS window corners are squircles, not circular arcs.
        borderView.layer?.cornerCurve = .continuous
        borderView.layer?.backgroundColor = NSColor.clear.cgColor

        window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = borderView
    }

    /// `frame` is the focused window's frame in global CG coordinates
    /// (top-left origin); nil hides the border.
    func update(frame: CGRect?) {
        // §4.3 pause means paused: a layout settle (minimize, close) while
        // paused must not resurrect the border — the user paused precisely
        // to stop overlays (presentations, screen sharing).
        let paused = AppDelegate.shared?.appState.paused ?? false
        guard enabled, !paused, let frame else {
            window.orderOut(nil)
            return
        }
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else {
            return
        }
        let outlined = frame.insetBy(dx: -Self.outset, dy: -Self.outset)
        let cocoa = globalToCocoa(outlined, primaryDisplayHeight: primary.frame.height)

        borderView.layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(0.55).cgColor
        window.setFrame(cocoa, display: true)
        window.orderFrontRegardless()
    }
}
