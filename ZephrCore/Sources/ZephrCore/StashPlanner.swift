import Foundation
import CoreGraphics

/// Computes off-screen stash positions for inactive-workspace windows.
///
/// Requirement (§4.4): works for *any* display arrangement with no user
/// homework. For each display we find an edge that borders empty virtual
/// space — no other display there — and park windows just past it, keeping a
/// 1‑point sliver on the owning display (macOS will not reliably keep a
/// window alive fully off-screen, and never above a display's top edge, so
/// "north" is never used).
public enum StashPlanner {

    public static let sliver: CGFloat = 1

    /// The frame a window should occupy while stashed. `displayFrame` is the
    /// full frame of the window's display; `allDisplays` the full arrangement
    /// (global CG coordinates).
    public static func stashFrame(
        for windowFrame: CGRect,
        on displayFrame: CGRect,
        allDisplays: [CGRect]
    ) -> CGRect {
        let others = allDisplays.filter { $0 != displayFrame }
        let size = windowFrame.size

        // Corners, not edges. Pushing a window straight down leaves a
        // full-width strip of it across the bottom of the screen: macOS
        // clamps how far below a display a window may sit — it keeps the
        // title bar reachable — so "one point past the bottom edge" is not
        // past it at all, and the request lands tens of points short.
        //
        // Horizontal displacement has no such clamp, so a corner works.
        // The window goes mostly off to the side *and* down; even if the
        // vertical part is clamped back, all that can show is a
        // sliver-wide column at the very edge. (Same conclusion AeroSpace
        // reached: it hides into the bottom-left or bottom-right corner.)
        var candidates: [CGRect] = []

        // South-east: only the top-left sliver stays on the display, and
        // the body hangs off to the right.
        candidates.append(CGRect(
            x: displayFrame.maxX - sliver,
            y: displayFrame.maxY - sliver,
            width: size.width, height: size.height
        ))
        // South-west: mirrored, body hanging off to the left.
        candidates.append(CGRect(
            x: displayFrame.minX + sliver - size.width,
            y: displayFrame.maxY - sliver,
            width: size.width, height: size.height
        ))
        // Due east / west, for arrangements where both bottom corners
        // border another display but a side is still free.
        candidates.append(CGRect(
            x: displayFrame.maxX - sliver,
            y: min(max(windowFrame.origin.y, displayFrame.minY), max(displayFrame.minY, displayFrame.maxY - size.height)),
            width: size.width, height: size.height
        ))
        candidates.append(CGRect(
            x: displayFrame.minX + sliver - size.width,
            y: min(max(windowFrame.origin.y, displayFrame.minY), max(displayFrame.minY, displayFrame.maxY - size.height)),
            width: size.width, height: size.height
        ))

        for candidate in candidates {
            // Displays are disjoint and the visible sliver lies inside the
            // owning display, so any overlap with another display is an
            // off-screen collision. Testing the candidate directly also
            // catches windows that protrude past *two* edges (e.g. wider
            // than the display and hanging below), which a single-edge
            // protrusion check misses.
            let collides = others.contains { $0.intersects(candidate) }
            if !collides { return candidate }
        }

        // Fully surrounded display (rare): pile at the bottom-right corner
        // with a small visible chunk; the app-hide hybrid removes most of it.
        return CGRect(
            x: displayFrame.maxX - 8,
            y: displayFrame.maxY - 8,
            width: size.width, height: size.height
        )
    }

    /// Whether a frame looks stashed relative to its display (used by crash
    /// recovery to decide which windows need restoring).
    public static func looksStashed(_ frame: CGRect, displays: [CGRect]) -> Bool {
        let visibleArea = displays.reduce(CGFloat(0)) { area, d in
            area + frame.intersection(d).area
        }
        return visibleArea < frame.area * 0.05
    }
}

extension CGRect {
    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}
