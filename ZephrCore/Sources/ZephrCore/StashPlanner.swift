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

        // Candidate origins, best first: below, right, left.
        var candidates: [CGRect] = []

        // South: top sliver row remains at the display's bottom edge.
        candidates.append(CGRect(
            x: min(max(windowFrame.origin.x, displayFrame.minX), displayFrame.maxX - size.width),
            y: displayFrame.maxY - sliver,
            width: size.width, height: size.height
        ))
        // East: left sliver column remains at the display's right edge.
        candidates.append(CGRect(
            x: displayFrame.maxX - sliver,
            y: min(max(windowFrame.origin.y, displayFrame.minY), max(displayFrame.minY, displayFrame.maxY - size.height)),
            width: size.width, height: size.height
        ))
        // West: right sliver column remains at the display's left edge.
        candidates.append(CGRect(
            x: displayFrame.minX - size.width + sliver,
            y: min(max(windowFrame.origin.y, displayFrame.minY), max(displayFrame.minY, displayFrame.maxY - size.height)),
            width: size.width, height: size.height
        ))

        for candidate in candidates {
            let offScreenPart = candidate.subtracting(displayFrame)
            let collides = others.contains { other in
                other.intersects(offScreenPart)
            }
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

    /// Bounding box of the part of `self` outside `other` — good enough for
    /// the stash collision check where candidates hang off one edge.
    func subtracting(_ other: CGRect) -> CGRect {
        guard intersects(other) else { return self }
        let inter = intersection(other)
        // The candidate sticks out past exactly one edge of the display.
        if maxX > other.maxX {
            return CGRect(x: other.maxX, y: minY, width: maxX - other.maxX, height: height)
        }
        if minX < other.minX {
            return CGRect(x: minX, y: minY, width: other.minX - minX, height: height)
        }
        if maxY > other.maxY {
            return CGRect(x: minX, y: other.maxY, width: width, height: maxY - other.maxY)
        }
        if minY < other.minY {
            return CGRect(x: minX, y: minY, width: width, height: other.minY - minY)
        }
        _ = inter
        return .zero
    }
}
