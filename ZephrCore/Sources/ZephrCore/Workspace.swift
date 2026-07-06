import Foundation
import CoreGraphics

/// One virtual workspace: a layout tree of tiled windows plus a set of
/// floating windows. All tree mutations live here so they can maintain the
/// window index and normalization invariants in one place.
public final class Workspace {
    public let id: Int
    public var name: String?
    /// Root container. Always present, always a container.
    public private(set) var root: TreeNode
    /// Floating windows and their frames (global CG coordinates).
    public private(set) var floating: [WindowID: CGRect] = [:]
    /// Order floats were added; later = raised above earlier.
    public private(set) var floatingOrder: [WindowID] = []
    public internal(set) var focusedWindow: WindowID?
    public internal(set) var monocle: Bool = false
    /// If set, the next insert splits in this orientation (leader s/v).
    public internal(set) var preselect: Orientation?
    /// Workspaces can default new windows to floating (§4.3 junk drawer).
    public var floatByDefault: Bool = false
    /// Display this workspace belongs to.
    public internal(set) var homeDisplay: DisplayID?

    /// Frames from the most recent solve, used for split-orientation
    /// heuristics and float-toggle placement.
    public internal(set) var lastSolvedFrames: [WindowID: CGRect] = [:]

    private var index: [WindowID: TreeNode] = [:]

    public init(id: Int, orientation: Orientation = .horizontal) {
        self.id = id
        self.root = TreeNode(container: orientation)
    }

    // MARK: - Queries

    public var isEmpty: Bool { root.children.isEmpty && floating.isEmpty }

    public var tiledCount: Int { index.count }

    public func contains(_ id: WindowID) -> Bool {
        index[id] != nil || floating[id] != nil
    }

    public func isFloating(_ id: WindowID) -> Bool { floating[id] != nil }

    public func node(for id: WindowID) -> TreeNode? { index[id] }

    public var allWindows: [WindowID] {
        root.windowIDs() + floatingOrder
    }

    /// The window focus falls to when the focused window disappears:
    /// last-focused leaf of the tree, else the top float.
    public func fallbackFocus() -> WindowID? {
        if let leaf = root.descendToLeaf(), let id = leaf.windowID { return id }
        return floatingOrder.last
    }

    // MARK: - Insertion / removal

    /// Inserts a tiled window by splitting the target (usually focused) leaf
    /// along its longer edge, or per the pending preselect. Returns quietly if
    /// the window is already present.
    public func insertTiled(_ id: WindowID, near target: WindowID? = nil) {
        guard !contains(id) else { return }
        let leafNode = TreeNode(window: id)

        let anchor: TreeNode? = {
            if let t = target, let n = index[t] { return n }
            if let f = focusedWindow, let n = index[f] { return n }
            return root.descendToLeaf()
        }()

        defer {
            index[id] = leafNode
            preselect = nil
            normalize()
            focus(id)
        }

        guard let anchor, anchor !== root else {
            // Empty tree: first window.
            root.insertChild(leafNode, at: root.children.count)
            return
        }

        let desired = preselect ?? splitOrientation(for: anchor)
        guard let parent = anchor.parent else {
            root.insertChild(leafNode, at: root.children.count)
            return
        }

        if parent.orientation == desired {
            // Slot in right after the anchor, taking half of its share.
            let idx = parent.index(of: anchor) ?? parent.children.count - 1
            let share = anchor.ratio / 2
            anchor.ratio = share
            leafNode.ratio = share
            leafNode.parent = parent
            parent.children.insert(leafNode, at: idx + 1)
        } else {
            // Wrap the anchor in a new container of the desired orientation.
            let wrapper = TreeNode(container: desired)
            parent.replaceChild(anchor, with: wrapper)
            anchor.ratio = 0.5
            anchor.parent = wrapper
            leafNode.ratio = 0.5
            leafNode.parent = wrapper
            wrapper.children = [anchor, leafNode]
        }
    }

    /// Chooses the split orientation for a new sibling of `node`: preselect
    /// wins (handled by caller), else the longer edge of the node's last
    /// solved frame, else alternate from the parent.
    private func splitOrientation(for node: TreeNode) -> Orientation {
        if let id = node.windowID, let frame = lastSolvedFrames[id], frame.width > 0, frame.height > 0 {
            return frame.longerEdgeOrientation
        }
        // No geometry yet: join the current container (i3's default).
        return node.parent?.orientation ?? root.orientation
    }

    public func insertFloating(_ id: WindowID, frame: CGRect) {
        guard !contains(id) else { return }
        floating[id] = frame
        floatingOrder.append(id)
        focus(id)
    }

    /// Removes a window entirely. Returns true if it was present.
    @discardableResult
    public func remove(_ id: WindowID) -> Bool {
        var removed = false
        if let node = index.removeValue(forKey: id) {
            node.parent?.removeChild(node)
            removed = true
        }
        if floating.removeValue(forKey: id) != nil {
            floatingOrder.removeAll { $0 == id }
            removed = true
        }
        guard removed else { return false }
        normalize()
        if focusedWindow == id {
            focusedWindow = fallbackFocus()
            if let f = focusedWindow { focus(f) }
        }
        return true
    }

    // MARK: - Focus

    /// Marks `id` focused and records the path from root for later descents.
    public func focus(_ id: WindowID) {
        guard contains(id) else { return }
        focusedWindow = id
        var node = index[id]
        while let n = node, let parent = n.parent {
            if let idx = parent.index(of: n) { parent.lastFocusedIndex = idx }
            node = parent
        }
    }

    /// The neighboring window in `direction` from the focused window,
    /// i3-style: walk up until a container matching the axis has a sibling.
    public func neighbor(of id: WindowID, direction: Direction) -> WindowID? {
        guard let leaf = index[id] else { return nil }
        var node: TreeNode = leaf
        while let parent = node.parent {
            if parent.orientation == direction.orientation,
               let idx = parent.index(of: node) {
                let next = direction.isForward ? idx + 1 : idx - 1
                if parent.children.indices.contains(next) {
                    return parent.children[next]
                        .descendToLeaf(enteringFrom: direction)?
                        .windowID
                }
            }
            node = parent
        }
        return nil
    }

    // MARK: - Move

    public enum MoveOutcome: Equatable {
        case moved
        case hitEdge
        case notTiled
    }

    /// Moves a tiled window one step in `direction` with i3 semantics:
    /// swap with a window sibling, descend into a container sibling, pop out
    /// of the enclosing container at a boundary, and re-orient at the root.
    public func move(_ id: WindowID, direction: Direction) -> MoveOutcome {
        guard let leaf = index[id] else { return .notTiled }
        let want = direction.orientation

        var node: TreeNode = leaf
        while let parent = node.parent {
            if parent.orientation == want, let idx = parent.index(of: node) {
                let nextIdx = direction.isForward ? idx + 1 : idx - 1
                if parent.children.indices.contains(nextIdx) {
                    let target = parent.children[nextIdx]
                    if node === leaf {
                        if target.isWindow {
                            parent.children.swapAt(idx, nextIdx)
                        } else {
                            detachLeaf(leaf)
                            insert(leaf, into: target, entering: direction)
                        }
                    } else {
                        // The leaf sits inside `node`'s subtree: pull it out and
                        // place it between the subtree and the neighbor.
                        detachLeaf(leaf)
                        // Indices may have shifted if the detach pruned within
                        // `parent`; recompute.
                        if let newIdx = parent.index(of: node) {
                            parent.insertChild(leaf, at: direction.isForward ? newIdx + 1 : newIdx)
                        } else {
                            parent.insertChild(leaf, at: direction.isForward ? parent.children.count : 0)
                        }
                    }
                    normalize()
                    focus(id)
                    return .moved
                }
            }
            node = parent
        }

        // No neighbor anywhere up the chain: we're at the workspace edge.
        if root.orientation == want {
            // Already a direct edge child of root?
            if leaf.parent === root, let idx = root.index(of: leaf),
               idx == (direction.isForward ? root.children.count - 1 : 0) {
                return .hitEdge
            }
            detachLeaf(leaf)
            root.insertChild(leaf, at: direction.isForward ? root.children.count : 0)
        } else {
            if root.children.count <= 1 {
                // Sole window (or sole subtree that IS the leaf).
                if root.children.first === leaf { return .hitEdge }
                if root.children.isEmpty { return .hitEdge }
            }
            // Re-orient: wrap current root content, root takes the new axis.
            let wrapper = TreeNode(container: root.orientation, layout: root.layout)
            wrapper.children = root.children
            wrapper.lastFocusedIndex = root.lastFocusedIndex
            for c in wrapper.children { c.parent = wrapper }
            wrapper.ratio = 1
            root.children = [wrapper]
            wrapper.parent = root
            root.orientation = want
            root.layout = .tiles
            root.lastFocusedIndex = 0
            detachLeaf(leaf)
            root.insertChild(leaf, at: direction.isForward ? root.children.count : 0)
        }
        normalize()
        focus(id)
        return .moved
    }

    /// Detaches a leaf from the tree without touching the index, pruning any
    /// container chain it leaves empty.
    private func detachLeaf(_ leaf: TreeNode) {
        var parent = leaf.parent
        parent?.removeChild(leaf)
        // Prune now-empty containers so index computations stay valid.
        while let p = parent, p !== root, p.children.isEmpty {
            let grand = p.parent
            grand?.removeChild(p)
            parent = grand
        }
    }

    private func insert(_ leaf: TreeNode, into container: TreeNode, entering direction: Direction) {
        if container.orientation == direction.orientation {
            // Entering along the container's axis: land at the near edge.
            container.insertChild(leaf, at: direction.isForward ? 0 : container.children.count)
        } else {
            // Perpendicular entry: land next to the container's active child.
            let at = min(container.lastFocusedIndex + 1, container.children.count)
            container.insertChild(leaf, at: at)
        }
    }

    // MARK: - Resize / layout

    /// Moves the boundary the focused window shares with a neighbor in
    /// `direction` by `delta` (fraction of their common container).
    @discardableResult
    public func resize(_ id: WindowID, direction: Direction, delta: CGFloat, minRatio: CGFloat) -> Bool {
        guard let leaf = index[id] else { return false }
        var node: TreeNode = leaf
        while let parent = node.parent {
            if parent.orientation == direction.orientation, let idx = parent.index(of: node) {
                let nIdx = direction.isForward ? idx + 1 : idx - 1
                if parent.children.indices.contains(nIdx) {
                    let child = parent.children[idx]
                    let neighbor = parent.children[nIdx]
                    let applied = min(max(delta, -(child.ratio - minRatio)), neighbor.ratio - minRatio)
                    guard abs(applied) > 0.0001 else { return false }
                    child.ratio += applied
                    neighbor.ratio -= applied
                    return true
                }
            }
            node = parent
        }
        return false
    }

    /// Grows (positive) or shrinks (negative) the focused window's share of
    /// its parent, redistributing across siblings (⌃⌥-= chords).
    @discardableResult
    public func resizeShare(_ id: WindowID, delta: CGFloat, minRatio: CGFloat) -> Bool {
        guard let leaf = index[id], let parent = leaf.parent, parent.children.count > 1 else { return false }
        let siblings = parent.children.filter { $0 !== leaf }
        let maxShare = 1 - minRatio * CGFloat(siblings.count)
        let applied = min(max(delta, minRatio - leaf.ratio), maxShare - leaf.ratio)
        guard abs(applied) > 0.0001 else { return false }
        let donorSum = siblings.reduce(CGFloat(0)) { $0 + $1.ratio }
        guard donorSum > 0 else { return false }
        for s in siblings { s.ratio -= applied * (s.ratio / donorSum) }
        leaf.ratio += applied
        parent.renormalizeRatios(minRatio: minRatio)
        return true
    }

    /// Pixel-space resize for mouse drags on gaps: converts `deltaPixels`
    /// along the shared boundary into a ratio change on the common container,
    /// whose pixel extent is derived from the last solve.
    @discardableResult
    public func dragResize(_ id: WindowID, direction: Direction, deltaPixels: CGFloat, minRatio: CGFloat) -> Bool {
        guard let leaf = index[id] else { return false }
        var node: TreeNode = leaf
        while let parent = node.parent {
            if parent.orientation == direction.orientation, let idx = parent.index(of: node) {
                let nIdx = direction.isForward ? idx + 1 : idx - 1
                if parent.children.indices.contains(nIdx) {
                    let frames = parent.windowIDs().compactMap { lastSolvedFrames[$0] }
                    guard !frames.isEmpty else { return false }
                    let axis = direction.orientation
                    let minEdge = frames.map { axis == .horizontal ? $0.minX : $0.minY }.min()!
                    let maxEdge = frames.map { axis == .horizontal ? $0.maxX : $0.maxY }.max()!
                    let extent = maxEdge - minEdge
                    guard extent > 1 else { return false }
                    return resize(id, direction: direction, delta: deltaPixels / extent, minRatio: minRatio)
                }
            }
            node = parent
        }
        return false
    }

    /// Re-tiles a floating window as `target`'s direct neighbor on the given
    /// edge — the drag-and-drop commit (§4.3 drop targets).
    @discardableResult
    public func retile(_ id: WindowID, at target: WindowID, edge: Direction) -> Bool {
        guard floating[id] != nil, let targetNode = index[target], targetNode !== root else { return false }
        floating.removeValue(forKey: id)
        floatingOrder.removeAll { $0 == id }

        preselect = edge.orientation
        insertTiled(id, near: target)
        // insertTiled places the new window after the target; left/up drops
        // want it before.
        if !edge.isForward {
            _ = move(id, direction: edge)
        }
        focus(id)
        return true
    }

    /// Equalizes shares in the focused window's container (leader =).
    public func balance(_ id: WindowID) {
        guard let leaf = index[id], let parent = leaf.parent else { return }
        let share = 1 / CGFloat(parent.children.count)
        for c in parent.children { c.ratio = share }
    }

    /// Toggles tiles ↔ accordion on the focused window's container.
    public func cycleLayout(_ id: WindowID) {
        guard let leaf = index[id], let parent = leaf.parent else { return }
        parent.layout = parent.layout.cycled
    }

    // MARK: - Normalization

    /// Restores the canonical tree shape (§4.3): no empty containers, no
    /// single-child containers, no same-orientation nesting, sane ratios.
    public func normalize() {
        normalizeSubtree(root)
        // Root special cases: hoist a lone container child's contents.
        while root.children.count == 1, let only = root.children.first, only.isContainer {
            root.orientation = only.orientation
            root.layout = only.layout
            root.lastFocusedIndex = only.lastFocusedIndex
            root.children = only.children
            for c in root.children { c.parent = root }
            only.parent = nil
        }
        root.renormalizeRatios()
        root.ratio = 1
    }

    private func normalizeSubtree(_ node: TreeNode) {
        guard node.isContainer else { return }
        for child in node.children { normalizeSubtree(child) }

        // Drop empty child containers.
        for child in node.children where child.isContainer && child.children.isEmpty {
            node.removeChild(child)
        }

        // Collapse single-child containers: the child takes the container's slot.
        for child in node.children where child.isContainer && child.children.count == 1 {
            let grandchild = child.children[0]
            child.children = []
            node.replaceChild(child, with: grandchild)
        }

        // Merge same-orientation nesting: splice grandchildren up, scaled.
        var i = 0
        while i < node.children.count {
            let child = node.children[i]
            if child.isContainer, child.orientation == node.orientation, child.layout == node.layout {
                let scale = child.ratio
                let grandchildren = child.children
                for g in grandchildren {
                    g.ratio *= scale
                    g.parent = node
                }
                child.children = []
                child.parent = nil
                node.children.replaceSubrange(i...i, with: grandchildren)
                continue // re-check at same position (splice may nest further)
            }
            i += 1
        }

        node.renormalizeRatios()
        if node.lastFocusedIndex >= node.children.count {
            node.lastFocusedIndex = max(0, node.children.count - 1)
        }
    }

    // MARK: - Float toggle

    /// Tiled → floating: keeps its solved frame. Floating → tiled: splits the
    /// focused/last-focused leaf. Returns the window's new floating state, or
    /// nil if the window isn't in this workspace.
    public func toggleFloat(_ id: WindowID, defaultFrame: CGRect) -> Bool? {
        if let node = index[id] {
            let frame = lastSolvedFrames[id] ?? defaultFrame
            index.removeValue(forKey: id)
            node.parent?.removeChild(node)
            normalize()
            floating[id] = frame
            floatingOrder.append(id)
            focus(id)
            return true
        }
        if floating.removeValue(forKey: id) != nil {
            floatingOrder.removeAll { $0 == id }
            insertTiled(id)
            return false
        }
        return nil
    }

    public func setFloatingFrame(_ id: WindowID, frame: CGRect) {
        guard floating[id] != nil else { return }
        floating[id] = frame
    }

    public func toggleMonocle() {
        monocle.toggle()
    }

    public func setPreselect(_ orientation: Orientation?) {
        preselect = orientation
    }

    // MARK: - Wholesale tree adoption (profile restore, §4.5)

    /// Replaces this workspace's contents with a rebuilt tree and float set.
    /// Used by `ProfileEngine.apply`; normalization and the index are
    /// re-derived so all invariants hold afterwards.
    func adoptContents(root newRoot: TreeNode, floats: [(WindowID, CGRect)], focused: WindowID?) {
        root = newRoot.isContainer ? newRoot : {
            let container = TreeNode(container: .horizontal)
            container.insertChild(newRoot, at: 0)
            return container
        }()
        index.removeAll()
        floating.removeAll()
        floatingOrder.removeAll()
        rebuildIndex(root)
        for (id, frame) in floats where index[id] == nil && floating[id] == nil {
            floating[id] = frame
            floatingOrder.append(id)
        }
        normalize()
        if let focused, contains(focused) {
            focus(focused)
        } else {
            focusedWindow = fallbackFocus()
            if let f = focusedWindow { focus(f) }
        }
    }

    private func rebuildIndex(_ node: TreeNode) {
        if let id = node.windowID {
            index[id] = node
            return
        }
        for child in node.children { rebuildIndex(child) }
    }

    // MARK: - Validation (used by tests and debug audits)

    public struct ValidationError: Error, CustomStringConvertible {
        public let description: String
    }

    public func validate() throws {
        var seen = Set<WindowID>()
        try validateNode(root, isRoot: true, seen: &seen)
        for (id, node) in index {
            guard node.windowID == id else {
                throw ValidationError(description: "index entry \(id) points at wrong node")
            }
            guard seen.contains(id) else {
                throw ValidationError(description: "index entry \(id) not reachable from root")
            }
        }
        guard seen.count == index.count else {
            throw ValidationError(description: "tree has \(seen.count) windows, index has \(index.count)")
        }
        for id in floatingOrder {
            guard floating[id] != nil else {
                throw ValidationError(description: "floatingOrder contains \(id) missing from floating")
            }
            guard !seen.contains(id) else {
                throw ValidationError(description: "\(id) is both tiled and floating")
            }
        }
        guard floatingOrder.count == floating.count else {
            throw ValidationError(description: "floatingOrder/floating size mismatch")
        }
        if let f = focusedWindow, !contains(f) {
            throw ValidationError(description: "focusedWindow \(f) not in workspace")
        }
    }

    private func validateNode(_ node: TreeNode, isRoot: Bool, seen: inout Set<WindowID>) throws {
        if let id = node.windowID {
            guard node.children.isEmpty else {
                throw ValidationError(description: "window node \(id) has children")
            }
            guard seen.insert(id).inserted else {
                throw ValidationError(description: "duplicate window \(id) in tree")
            }
            return
        }
        if !isRoot {
            guard node.children.count >= 2 else {
                throw ValidationError(description: "non-root container with \(node.children.count) children survived normalize")
            }
            if let parent = node.parent, parent.orientation == node.orientation, parent.layout == node.layout {
                throw ValidationError(description: "same-orientation nesting survived normalize")
            }
        }
        if !node.children.isEmpty {
            let sum = node.children.reduce(CGFloat(0)) { $0 + $1.ratio }
            guard abs(sum - 1) < 0.01 else {
                throw ValidationError(description: "child ratios sum to \(sum)")
            }
        }
        for child in node.children {
            guard child.parent === node else {
                throw ValidationError(description: "broken parent pointer")
            }
            try validateNode(child, isRoot: false, seen: &seen)
        }
    }
}
