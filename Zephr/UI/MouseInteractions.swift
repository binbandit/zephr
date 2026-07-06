import AppKit
import ZephrCore

/// Highlight shown over the half of a tiled window a drag would drop into
/// (§4.3 drop targets).
@MainActor
final class DropZoneOverlay {

    private let window: NSWindow
    private let view: NSView

    init() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = view
    }

    func update(frame: CGRect?) {
        guard let frame,
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else {
            window.orderOut(nil)
            return
        }
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        view.layer?.borderWidth = 2
        window.setFrame(globalToCocoa(frame, primaryDisplayHeight: primary.frame.height), display: true)
        window.orderFrontRegardless()
    }
}

/// Invisible strips over inner gaps: dragging one adjusts the split — the
/// "8 px invisible hit area" from §4.3. Strips are plain windows (no
/// polling); they're rebuilt whenever the layout settles.
@MainActor
final class GapResizeController {

    struct Boundary {
        let window: WindowID
        let direction: Direction   // which way the leading window's edge moves
        let rect: CGRect           // global CG
    }

    /// deltaPixels along the boundary axis (CG sign convention).
    var onDrag: ((WindowID, Direction, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var strips: [NSWindow] = []
    private(set) var dragActive = false

    func update(boundaries: [Boundary]) {
        guard !dragActive else { return } // never rebuild under a live drag
        for strip in strips { strip.orderOut(nil) }
        strips.removeAll()
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return }

        for boundary in boundaries {
            let view = GapStripView(boundary: boundary)
            view.onDrag = { [weak self] delta in
                self?.dragActive = true
                self?.onDrag?(boundary.window, boundary.direction, delta)
            }
            view.onDragEnded = { [weak self] in
                self?.dragActive = false
                self?.onDragEnded?()
            }
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = view
            window.setFrame(globalToCocoa(boundary.rect, primaryDisplayHeight: primary.frame.height), display: false)
            window.orderFrontRegardless()
            strips.append(window)
        }
    }

    func clear() {
        update(boundaries: [])
    }
}

private final class GapStripView: NSView {
    let boundary: GapResizeController.Boundary
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    init(boundary: GapResizeController.Boundary) {
        self.boundary = boundary
        super.init(frame: .zero)
        wantsLayer = true
        // Nearly invisible but still hit-testable.
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.01).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        let cursor: NSCursor = boundary.direction.orientation == .horizontal
            ? .resizeLeftRight
            : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDragged(with event: NSEvent) {
        // Cocoa deltaY is y-down, matching the CG space ZephrCore uses.
        let delta = boundary.direction.orientation == .horizontal ? event.deltaX : event.deltaY
        if abs(delta) > 0.1 { onDrag?(delta) }
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
