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

    /// Narrowest strip we will place. With flush tiling (`gaps = 0`) there is
    /// no gap to sit in, so a strip must overlap content slightly or mouse
    /// split-resize (§4.3) would not exist at all for that config — but it
    /// stays at 4 pt rather than the engine's 8 pt clamp, halving how much
    /// content it can swallow.
    private static let minimumStripWidth: CGFloat = 4

    func update(boundaries: [Boundary]) {
        guard !dragActive else { return } // never rebuild under a live drag
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return }

        // §4.3 pause means paused: a layout settle while paused must not
        // resurrect the click-eating strips (presentations, screen sharing).
        let paused = AppDelegate.shared?.appState.paused ?? false

        // The engine clamps strips to an 8 pt minimum and re-centres them,
        // so with small gaps they would overlap window content and eat its
        // clicks (scrollbars, sidebar dividers). Never widen past the true
        // gap; skip seams too thin to grab at all.
        let gap = CGFloat(AppDelegate.shared?.configService.current.layout.innerGap ?? 8)

        // Floating windows sit above the strips' seams — a strip covering
        // one would swallow its clicks. Use `lastAppliedFrame` (where the
        // window actually is) rather than `lastVisibleFrame` (where it was
        // last seen on screen): a float parked on an inactive workspace is
        // stashed off-screen, and matching on its remembered on-screen frame
        // would kill strips in that region of the *active* workspace.
        let floatingFrames: [CGRect] = AppDelegate.shared?.engine.windows.values
            .filter { $0.floating && !$0.minimized && !$0.fullscreen }
            .compactMap { $0.lastAppliedFrame ?? $0.lastVisibleFrame } ?? []

        var wanted: [Boundary] = []
        if !paused {
            let width = max(gap, Self.minimumStripWidth)
            for boundary in boundaries {
                var rect = boundary.rect
                if boundary.direction.orientation == .horizontal {
                    let mid = rect.midX
                    rect.size.width = min(rect.width, width)
                    rect.origin.x = mid - rect.width / 2
                } else {
                    let mid = rect.midY
                    rect.size.height = min(rect.height, width)
                    rect.origin.y = mid - rect.height / 2
                }
                guard !floatingFrames.contains(where: { $0.intersects(rect) }) else { continue }
                wanted.append(Boundary(window: boundary.window, direction: boundary.direction, rect: rect))
            }
        }

        // Reuse strip windows across settles: rebuilding every settle churns
        // one NSWindow per boundary and risks deallocating a window whose
        // view is mid-event-dispatch.
        while strips.count > wanted.count {
            strips.removeLast().orderOut(nil)
        }
        for (index, boundary) in wanted.enumerated() {
            let window: NSWindow
            let view: GapStripView
            if index < strips.count, let existing = strips[index].contentView as? GapStripView {
                window = strips[index]
                view = existing
            } else {
                view = GapStripView(boundary: boundary)
                window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.ignoresMouseEvents = false
                window.acceptsMouseMovedEvents = true
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                window.contentView = view
                strips.append(window)
            }
            view.boundary = boundary
            view.onDrag = { [weak self] delta in
                self?.dragActive = true
                self?.onDrag?(boundary.window, boundary.direction, delta)
            }
            view.onDragEnded = { [weak self] in
                self?.dragActive = false
                self?.onDragEnded?()
            }
            window.setFrame(globalToCocoa(boundary.rect, primaryDisplayHeight: primary.frame.height), display: false)
            window.invalidateCursorRects(for: view)
            window.orderFrontRegardless()
        }
    }

    func clear() {
        update(boundaries: [])
    }
}

private final class GapStripView: NSView {
    var boundary: GapResizeController.Boundary
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
