import Foundation
import CoreGraphics

/// The desired on-screen state for one window, produced by a solve.
public struct Placement: Equatable, Sendable {
    public enum Layer: Equatable, Sendable {
        case tiled
        case floating
    }
    public var frame: CGRect
    public var layer: Layer
}

/// Result of solving one workspace into a rect.
public struct PlacementSet: Sendable {
    public var placements: [WindowID: Placement] = [:]
    /// Windows to raise above their app siblings, bottom-to-top. The focused
    /// window and floats come last.
    public var raiseOrder: [WindowID] = []
    public var focused: WindowID?
}

/// Pure layout solver: workspace tree → concrete pixel frames.
/// Handles tiles/accordion containers, monocle, gaps, and per-tile minimum
/// sizes with clamp-and-redistribute (degrading a container to accordion when
/// minimums cannot be met, per §6.2).
public enum Solver {

    public static func solve(workspace: Workspace, in workspaceRect: CGRect, config: LayoutConfig = .default) -> PlacementSet {
        var result = PlacementSet()
        let rect = workspaceRect.insetBy(gap: config.outerGap)

        if !workspace.root.children.isEmpty {
            solveNode(workspace.root, rect: rect, config: config, into: &result)
        }

        // Monocle: focused tiled window takes the whole workspace rect.
        if workspace.monocle,
           let focused = workspace.focusedWindow,
           result.placements[focused]?.layer == .tiled {
            result.placements[focused]?.frame = rect.roundedToPixels()
        }

        // Floating windows sit above tiles, in stacking order, clamped on-screen.
        for id in workspace.floatingOrder {
            guard let frame = workspace.floating[id] else { continue }
            result.placements[id] = Placement(frame: frame.clamped(into: workspaceRect).roundedToPixels(), layer: .floating)
            result.raiseOrder.append(id)
        }

        result.focused = workspace.focusedWindow
        if let f = workspace.focusedWindow, workspace.contains(f) {
            result.raiseOrder.removeAll { $0 == f }
            result.raiseOrder.append(f)
        }

        // Remember solved frames for split-orientation and float heuristics.
        workspace.lastSolvedFrames = result.placements.mapValues(\.frame)
        return result
    }

    private static func solveNode(_ node: TreeNode, rect: CGRect, config: LayoutConfig, into result: inout PlacementSet) {
        if let id = node.windowID {
            result.placements[id] = Placement(frame: rect.roundedToPixels(), layer: .tiled)
            return
        }
        guard !node.children.isEmpty else { return }
        if node.children.count == 1 {
            solveNode(node.children[0], rect: rect, config: config, into: &result)
            return
        }

        switch node.layout {
        case .tiles:
            solveTiles(node, rect: rect, config: config, into: &result)
        case .accordion:
            solveAccordion(node, rect: rect, config: config, into: &result)
        }
    }

    private static func solveTiles(_ node: TreeNode, rect: CGRect, config: LayoutConfig, into result: inout PlacementSet) {
        let axis = node.orientation
        let n = node.children.count
        let gapTotal = config.innerGap * CGFloat(n - 1)
        let available = rect.length(along: axis) - gapTotal

        let minLength = axis == .horizontal ? config.minTileSize.width : config.minTileSize.height
        guard available > 0 else {
            // Degenerate space: fall back to accordion behavior.
            solveAccordion(node, rect: rect, config: config, into: &result)
            return
        }
        if minLength * CGFloat(n) > available {
            // Minimums can't be satisfied: degrade this container (§6.2).
            solveAccordion(node, rect: rect, config: config, into: &result)
            return
        }

        // Proportional lengths with clamp-and-redistribute for minimums.
        var lengths = node.children.map { $0.ratio * available }
        for _ in 0..<n {
            var deficit: CGFloat = 0
            var headroom: CGFloat = 0
            for (i, len) in lengths.enumerated() {
                if len < minLength {
                    deficit += minLength - len
                    lengths[i] = minLength
                } else {
                    headroom += len - minLength
                }
            }
            if deficit <= 0.01 || headroom <= 0 { break }
            for (i, len) in lengths.enumerated() where len > minLength {
                lengths[i] = len - deficit * ((len - minLength) / headroom)
            }
        }

        var cursor = axis == .horizontal ? rect.minX : rect.minY
        for (i, child) in node.children.enumerated() {
            let start = cursor
            let end = start + lengths[i]
            let childRect: CGRect = axis == .horizontal
                ? CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
                : CGRect(x: rect.minX, y: start, width: rect.width, height: end - start)
            solveNode(child, rect: childRect, config: config, into: &result)
            cursor = end + config.innerGap
        }
    }

    /// Accordion: the active child gets nearly everything; each other sibling
    /// keeps a `accordionPadding`-wide sliver stacked at the edges in order.
    private static func solveAccordion(_ node: TreeNode, rect: CGRect, config: LayoutConfig, into result: inout PlacementSet) {
        let axis = node.orientation
        let n = node.children.count
        let focusedIdx = min(max(0, node.lastFocusedIndex), n - 1)

        // Shrink padding if the rect is too small to fit all slivers.
        var padding = config.accordionPadding
        let total = rect.length(along: axis)
        if padding * CGFloat(n - 1) > total * 0.5 {
            padding = max(2, (total * 0.5) / CGFloat(max(1, n - 1)))
        }

        let origin = axis == .horizontal ? rect.minX : rect.minY
        for (i, child) in node.children.enumerated() {
            let start: CGFloat
            let length: CGFloat
            if i < focusedIdx {
                start = origin + CGFloat(i) * padding
                length = padding
            } else if i == focusedIdx {
                start = origin + CGFloat(i) * padding
                length = total - padding * CGFloat(n - 1)
            } else {
                start = origin + total - padding * CGFloat(n - i)
                length = padding
            }
            let childRect: CGRect = axis == .horizontal
                ? CGRect(x: start, y: rect.minY, width: length, height: rect.height)
                : CGRect(x: rect.minX, y: start, width: rect.width, height: length)
            solveNode(child, rect: childRect, config: config, into: &result)
        }

        // Active child of an accordion should sit above its collapsed siblings.
        if let active = node.children[focusedIdx].descendToLeaf()?.windowID {
            result.raiseOrder.append(active)
        }
    }
}
