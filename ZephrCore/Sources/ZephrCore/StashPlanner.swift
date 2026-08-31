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

        // Pick the candidate that spills least onto a neighbouring display,
        // rather than the first that spills not at all.
        //
        // Rejecting on *any* overlap and falling back to a corner inside the
        // display made the common bad case far worse than it needed to be: a
        // display flanked on both sides has no clean corner, so a candidate
        // leaking a single point was discarded in favour of a fallback that
        // left the window almost entirely visible. Ranking keeps the
        // one-point answer. Order breaks ties, so the preferred corners
        // still win when nothing spills — which is the usual case.
        //
        // Testing the whole candidate rather than one edge also catches a
        // window that protrudes past two edges at once, e.g. one wider than
        // the display and hanging below it.
        func spill(_ candidate: CGRect) -> CGFloat {
            others.reduce(0) { $0 + candidate.intersection($1).area }
        }
        var best = candidates[0]
        var bestSpill = spill(best)
        for candidate in candidates.dropFirst() where bestSpill > 0 {
            let value = spill(candidate)
            if value < bestSpill {
                best = candidate
                bestSpill = value
            }
        }
        return best
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
