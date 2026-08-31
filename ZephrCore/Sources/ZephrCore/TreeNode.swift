import Foundation
import CoreGraphics

/// A node in a workspace's i3-style layout tree. Leaves are windows; interior
/// nodes are containers with an orientation and a layout. Reference semantics
/// with parent pointers keep the frequent walk-up operations (focus, move,
/// resize) simple; `Workspace.validate()` checks the structural invariants and
/// is exercised heavily by the property tests.
public final class TreeNode {
    public enum Kind: Equatable {
        case container
        case window(WindowID)
    }

    public private(set) var kind: Kind
    public internal(set) var orientation: Orientation
    public internal(set) var layout: ContainerLayout
    public internal(set) var children: [TreeNode]
    /// This node's share of its parent along the parent's orientation. The
    /// shares of a container's children always sum to ~1.
    public internal(set) var ratio: CGFloat
    public internal(set) weak var parent: TreeNode?
    /// Index of the most recently focused child; used to descend during
    /// directional focus and as the expanded child of an accordion.
    public internal(set) var lastFocusedIndex: Int = 0

    public var windowID: WindowID? {
        if case .window(let id) = kind { return id }
        return nil
    }

    public var isContainer: Bool { kind == .container }
    public var isWindow: Bool { !isContainer }

    /// Points this leaf at a different window without moving it. Backs
    /// `Workspace.replace` - see there for why a tab group needs it.
    func retarget(to id: WindowID) {
        guard case .window = kind else { return }
        kind = .window(id)
    }

    init(window id: WindowID) {
        self.kind = .window(id)
        self.orientation = .horizontal
        self.layout = .tiles
        self.children = []
        self.ratio = 1
    }

    init(container orientation: Orientation, layout: ContainerLayout = .tiles) {
        self.kind = .container
        self.orientation = orientation
        self.layout = layout
        self.children = []
        self.ratio = 1
    }

    // MARK: - Child manipulation (invariant-preserving primitives)

    func index(of child: TreeNode) -> Int? {
        children.firstIndex { $0 === child }
    }

    /// Inserts `node` at `index`, giving it an equal share and scaling the
    /// existing children down to make room.
    func insertChild(_ node: TreeNode, at index: Int) {
        precondition(isContainer)
        let count = CGFloat(children.count)
        let newShare: CGFloat = count == 0 ? 1 : 1 / (count + 1)
        let scale: CGFloat = count == 0 ? 1 : count / (count + 1)
        for child in children { child.ratio *= scale }
        node.ratio = newShare
        node.parent = self
        children.insert(node, at: min(max(0, index), children.count))
    }

    /// Replaces `child` with `replacement` in place, transferring its share.
    func replaceChild(_ child: TreeNode, with replacement: TreeNode) {
        precondition(isContainer)
        guard let idx = index(of: child) else { return }
        replacement.ratio = child.ratio
        replacement.parent = self
        children[idx] = replacement
        child.parent = nil
        if lastFocusedIndex >= children.count { lastFocusedIndex = max(0, children.count - 1) }
    }

    /// Removes `child`, redistributing its share proportionally among the
    /// remaining siblings.
    func removeChild(_ child: TreeNode) {
        precondition(isContainer)
        guard let idx = index(of: child) else { return }
        children.remove(at: idx)
        child.parent = nil
        let remaining = children.reduce(CGFloat(0)) { $0 + $1.ratio }
        if remaining > 0 {
            for c in children { c.ratio /= remaining }
        } else if !children.isEmpty {
            let share = 1 / CGFloat(children.count)
            for c in children { c.ratio = share }
        }
        if lastFocusedIndex > idx || lastFocusedIndex >= children.count {
            lastFocusedIndex = max(0, min(lastFocusedIndex - 1, children.count - 1))
        }
    }

    /// Renormalizes children so ratios sum to exactly 1.
    func renormalizeRatios(minRatio: CGFloat = 0.02) {
        guard isContainer, !children.isEmpty else { return }
        for c in children where !c.ratio.isFinite || c.ratio <= 0 {
            c.ratio = 0.0001
        }
        var sum = children.reduce(CGFloat(0)) { $0 + $1.ratio }
        if sum <= 0 {
            let share = 1 / CGFloat(children.count)
            for c in children { c.ratio = share }
            return
        }
        for c in children { c.ratio /= sum }
        // Enforce a floor so no child collapses to nothing.
        let floorShare = min(minRatio, 1 / CGFloat(children.count))
        var deficit: CGFloat = 0
        for c in children where c.ratio < floorShare {
            deficit += floorShare - c.ratio
            c.ratio = floorShare
        }
        if deficit > 0 {
            let donors = children.filter { $0.ratio > floorShare }
            let donorSum = donors.reduce(CGFloat(0)) { $0 + ($1.ratio - floorShare) }
            if donorSum > 0 {
                for d in donors {
                    d.ratio -= deficit * (d.ratio - floorShare) / donorSum
                }
            }
        }
        sum = children.reduce(CGFloat(0)) { $0 + $1.ratio }
        if sum > 0, abs(sum - 1) > 0.0001 {
            for c in children { c.ratio /= sum }
        }
    }

    // MARK: - Queries

    /// All window IDs in this subtree, in document order.
    public func windowIDs() -> [WindowID] {
        if let id = windowID { return [id] }
        return children.flatMap { $0.windowIDs() }
    }

    /// Descends to a window leaf, preferring the last focused path. When
    /// `enteringFrom` is set, containers matching the movement axis are entered
    /// at the near edge instead (i3 behavior when focus crosses a boundary).
    func descendToLeaf(enteringFrom direction: Direction? = nil) -> TreeNode? {
        if isWindow { return self }
        guard !children.isEmpty else { return nil }
        let child: TreeNode
        if let dir = direction, orientation == dir.orientation {
            child = dir.isForward ? children.first! : children.last!
        } else {
            child = children[min(max(0, lastFocusedIndex), children.count - 1)]
        }
        return child.descendToLeaf(enteringFrom: direction)
    }
}
