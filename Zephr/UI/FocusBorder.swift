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

    private let window: NSWindow
    private let borderView: NSView

    init() {
        borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.borderWidth = 2
        borderView.layer?.cornerRadius = 10
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
        guard enabled, let frame else {
            window.orderOut(nil)
            return
        }
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else {
            return
        }
        // Slightly outside the window so the stroke never covers content.
        let outset = frame.insetBy(dx: -3, dy: -3)
        let cocoa = globalToCocoa(outset, primaryDisplayHeight: primary.frame.height)

        borderView.layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(0.55).cgColor
        window.setFrame(cocoa, display: true)
        window.orderFrontRegardless()
    }
}
