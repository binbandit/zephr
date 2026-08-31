import AppKit
import ZephrCore

/// The focused-window border (§4.3): a rounded outline drawn by a
/// click-through overlay window — the clearest cue for where focus is while
/// learning. Config: the `focus-border*` keys in `[layout]`.
@MainActor
final class FocusBorderController {

    /// Appearance from the config. Assigning re-paints, so a hot reload
    /// takes effect on the border already on screen.
    var style = FocusBorderStyle.default {
        didSet {
            guard style != oldValue else { return }
            if !style.enabled { window.orderOut(nil) }
            applyStyle()
        }
    }

    /// Alpha the accent color is drawn at when the config names no color.
    /// At full strength an accent outline reads as window chrome rather than
    /// a focus hint; a configured color is drawn exactly as written, alpha
    /// and all. Not private — Settings seeds its color well from this so the
    /// two agree on what "accent" looks like.
    static let accentAlpha: CGFloat = 0.55

    /// The system's window corner radius. macOS 26 rounded windows
    /// considerably more than earlier releases, so the pre-Tahoe 10 pt
    /// outline visibly cut across the corner of every window it traced.
    private static var systemWindowCornerRadius: CGFloat {
        if #available(macOS 26, *) { 16 } else { 10 }
    }

    /// How far outside the window the stroke sits, so it never covers
    /// content. Derived from the width so a thicker border still clears the
    /// window by the same 1 pt instead of creeping inward over it; at the
    /// default 2 pt this is the 3 pt the border has always used.
    private var outset: CGFloat { style.width + 1 }

    /// The outline's radius has to exceed the window's by the outset or the
    /// curve stops being concentric with the window's own — the corners
    /// pinch in while the straight edges stay parallel. A configured radius
    /// is the outline's own, so `0` really is square.
    private var cornerRadius: CGFloat {
        style.cornerRadius ?? Self.systemWindowCornerRadius + outset
    }

    private var color: NSColor {
        guard let color = style.color else {
            return .controlAccentColor.withAlphaComponent(Self.accentAlpha)
        }
        // sRGB: that is what a hex literal means everywhere else it is typed.
        return NSColor(
            srgbRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }

    private let window: NSWindow
    private let borderView: NSView

    init() {
        borderView = NSView()
        borderView.wantsLayer = true
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
        // No `.fullScreenAuxiliary`: that is the explicit opt-in to being
        // drawn alongside a fullscreen window, and this overlay has no
        // business on a Space it does not own. It is not the whole story -
        // `.canJoinAllSpaces` reaches fullscreen Spaces on its own, and the
        // border has to keep that to survive an ordinary Space switch - so
        // the engine also refuses to draw over a display a fullscreen window
        // has taken (see `hasFullscreenWindow`). Removing the opt-in just
        // stops us asking for the thing we then have to work around.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = borderView

        applyStyle()
    }

    private func applyStyle() {
        borderView.layer?.borderWidth = style.width
        borderView.layer?.cornerRadius = cornerRadius
        borderView.layer?.borderColor = color.cgColor
    }

    /// `frame` is the focused window's frame in global CG coordinates
    /// (top-left origin); nil hides the border.
    func update(frame: CGRect?) {
        // §4.3 pause means paused: a layout settle (minimize, close) while
        // paused must not resurrect the border — the user paused precisely
        // to stop overlays (presentations, screen sharing).
        let paused = AppDelegate.shared?.appState.paused ?? false
        guard style.enabled, !paused, let frame else {
            window.orderOut(nil)
            return
        }
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else {
            return
        }
        let outlined = frame.insetBy(dx: -outset, dy: -outset)
        let cocoa = globalToCocoa(outlined, primaryDisplayHeight: primary.frame.height)

        // Re-resolved every time: `controlAccentColor` is dynamic, and a
        // layer stores the flattened CGColor it was handed, so the border
        // would otherwise keep whichever accent was current when the config
        // last changed.
        borderView.layer?.borderColor = color.cgColor
        window.setFrame(cocoa, display: true)
        window.orderFrontRegardless()
    }
}
