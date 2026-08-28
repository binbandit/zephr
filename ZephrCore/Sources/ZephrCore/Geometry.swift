import Foundation
import CoreGraphics

// All geometry in ZephrCore uses the CoreGraphics/Accessibility coordinate space:
// origin at the top-left of the primary display, y increasing downward.
// AppKit's bottom-left NSScreen coordinates must be converted at the boundary
// (see `cocoaToGlobal`).

public enum Orientation: String, Sendable, Codable, Equatable {
    case horizontal   // children laid out left → right
    case vertical     // children laid out top → bottom

    public var flipped: Orientation {
        self == .horizontal ? .vertical : .horizontal
    }
}

public enum Direction: String, Sendable, Codable, CaseIterable {
    case left, down, up, right

    public var orientation: Orientation {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// Whether the direction points toward higher child indices
    /// (right in a horizontal container, down in a vertical one).
    public var isForward: Bool {
        switch self {
        case .right, .down: true
        case .left, .up: false
        }
    }

    public var opposite: Direction {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}

public enum ContainerLayout: String, Sendable, Codable {
    case tiles
    case accordion

    public var cycled: ContainerLayout {
        self == .tiles ? .accordion : .tiles
    }
}

public struct WindowID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public var description: String { "w\(raw)" }
}

public struct DisplayID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
    public var description: String { "display\(raw)" }
}

extension CGRect {
    public func length(along orientation: Orientation) -> CGFloat {
        orientation == .horizontal ? width : height
    }

    public var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    /// The orientation of this rect's longer edge — a landscape rect splits horizontally.
    public var longerEdgeOrientation: Orientation {
        width >= height ? .horizontal : .vertical
    }

    /// Every component is a real number. `CGRect.null` (+infinity origin) and
    /// `.infinite` are not, and neither is anything derived from them — the
    /// solver refuses to lay out into such a rect, because `roundedToPixels`
    /// would produce NaN frames and a NaN frame written to AX puts a window
    /// where no rescue can reach it (§4.4, invariant 1).
    public var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }

    public func insetBy(gap: CGFloat) -> CGRect {
        guard gap > 0, width > gap * 2, height > gap * 2 else { return self }
        return insetBy(dx: gap, dy: gap)
    }

    public func roundedToPixels() -> CGRect {
        let x = origin.x.rounded()
        let y = origin.y.rounded()
        return CGRect(x: x, y: y, width: (maxX.rounded() - x), height: (maxY.rounded() - y))
    }

    public func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    /// Clamps this rect so that it lies within `bounds` (shrinking if necessary).
    public func clamped(into bounds: CGRect) -> CGRect {
        var r = self
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
        return r
    }
}

/// Converts an AppKit (bottom-left origin, y-up) rect to the global CG
/// (top-left origin, y-down) space, given the height of the primary display
/// in Cocoa coordinates. Pure so it can be unit-tested without AppKit.
public func cocoaToGlobal(_ rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
    CGRect(
        x: rect.origin.x,
        y: primaryDisplayHeight - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}

/// Inverse of `cocoaToGlobal` (the transform is an involution).
public func globalToCocoa(_ rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
    cocoaToGlobal(rect, primaryDisplayHeight: primaryDisplayHeight)
}
