import AppKit
import ZephrCore

/// Highlight shown over the half of a tiled window a drag would drop into
/// (§4.3 drop targets).
@MainActor
final class DropZoneOverlay {

    /// Pulled in from the half-tile it represents, so it reads as the space
    /// the window will occupy rather than a slab laid over the neighbour it
    /// is butted against.
    private static let inset: CGFloat = 6
    /// Matches the window corners it is previewing (see `FocusBorder`).
    private static let cornerRadius: CGFloat = 12
    private static let duration: TimeInterval = 0.12

    private let window: NSWindow
    private let view: NSView
    private var showing = false

    init() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.cornerRadius
        // macOS corners are squircles; a circular arc next to a real window
        // reads as subtly wrong even when the radius matches.
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1.5
        // Set once. These were being reassigned on every mouse-move, which
        // is a layer property write per event for a colour that never
        // changes.
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor

        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = view
        window.alphaValue = 0
    }

    func update(frame: CGRect?) {
        guard let frame,
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else {
            hide()
            return
        }
        // Only inset when there is room; a narrow zone would invert.
        let padded = frame.width > Self.inset * 4 && frame.height > Self.inset * 4
            ? frame.insetBy(dx: Self.inset, dy: Self.inset)
            : frame
        let target = globalToCocoa(padded, primaryDisplayHeight: primary.frame.height)

        guard showing else {
            // First appearance: place it before fading in, or it slides in
            // from wherever the previous drag left it.
            showing = true
            window.setFrame(target, display: false)
            window.orderFrontRegardless()
            animate { self.window.animator().alphaValue = 1 }
            return
        }
        // Between zones: glide. Snapping from one half-tile to another was
        // the single thing that made this feel broken rather than deliberate.
        animate {
            self.window.animator().setFrame(target, display: true)
        }
    }

    private func hide() {
        guard showing else { return }
        showing = false
        let window = self.window
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: {
            // A drag that starts again mid-fade will have set alpha back to
            // 1; only actually withdraw the window if the fade finished.
            MainActor.assumeIsolated {
                if window.alphaValue == 0 { window.orderOut(nil) }
            }
        })
    }

    private func animate(_ body: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            body()
        }
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
