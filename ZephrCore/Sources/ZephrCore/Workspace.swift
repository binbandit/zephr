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
    /// The display the user last deliberately put this workspace on.
    /// `homeDisplay` follows an undock (workspaces must never be stranded on
    /// a display that is gone); this remembers where they belong, so a
    /// redock puts them back instead of leaving the returning monitor on a
    /// fresh empty workspace.
    public internal(set) var preferredDisplay: DisplayID?

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

    /// Swaps `old` for `new` in place, keeping the slot, its ratio, its
    /// place in the floating order and its focus (§4.3 native tabs).
    ///
    /// Selecting another native macOS tab hands the layout a different
    /// AXWindow for what is physically the same window. Removing the old node
    /// and inserting the new one would re-run placement and drop that window
    /// wherever the split policy decides, reflowing the whole workspace
    /// because the user clicked a tab. Repointing the existing node is what
    /// makes a tab group a single leaf.
    @discardableResult
    public func replace(_ old: WindowID, with new: WindowID) -> Bool {
        guard old != new, !contains(new) else { return false }
        if let node = index.removeValue(forKey: old) {
            node.retarget(to: new)
            index[new] = node
        } else if let frame = floating.removeValue(forKey: old) {
            floating[new] = frame
            if let slot = floatingOrder.firstIndex(of: old) { floatingOrder[slot] = new }
        } else {
            return false
        }
        if let solved = lastSolvedFrames.removeValue(forKey: old) {
            lastSolvedFrames[new] = solved
        }
        // No `normalize()`: the shape of the tree is deliberately untouched.
        if focusedWindow == old { focusedWindow = new }
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

    /// The neighbouring window in `direction`, tiled or floating.
    ///
    /// The tree walk is tried first, so tiled navigation keeps its i3
    /// semantics and respects nesting. Geometry is the fallback, and it is
    /// what makes floats reachable at all: they are not in the tree, so the
    /// walk can neither find one nor start from one. Without it, pressing
    /// focus-left inside a floating window returned nil, which the engine
    /// reads as "hit the edge of the display" — so focus jumped to another
    /// monitor instead of the window sitting right next to it.
    public func neighbor(of id: WindowID, direction: Direction) -> WindowID? {
        if index[id] != nil, let tiled = treeNeighbor(of: id, direction: direction) {
            return tiled
        }
        return geometricNeighbor(of: id, direction: direction)
    }

    /// Where a window is right now, tiled or floating.
    private func currentFrame(_ id: WindowID) -> CGRect? {
        floating[id] ?? lastSolvedFrames[id]
    }

    /// Nearest window whose centre lies in `direction` and whose span on the
    /// other axis overlaps the source — so "left" cannot match something
    /// diagonally opposite.
    private func geometricNeighbor(of id: WindowID, direction: Direction) -> WindowID? {
        guard let from = currentFrame(id) else { return nil }
        let horizontal = direction.orientation == .horizontal
        var best: (id: WindowID, distance: CGFloat)?
        for other in allWindows where other != id {
            guard let rect = currentFrame(other) else { continue }
            let advance = horizontal ? rect.midX - from.midX : rect.midY - from.midY
            guard direction.isForward ? advance > 1 : advance < -1 else { continue }
            let overlap = horizontal
                ? min(from.maxY, rect.maxY) - max(from.minY, rect.minY)
                : min(from.maxX, rect.maxX) - max(from.minX, rect.minX)
            guard overlap > 1 else { continue }
            let distance = abs(advance)
            if best == nil || distance < best!.distance { best = (other, distance) }
        }
        return best?.id
    }

    private func treeNeighbor(of id: WindowID, direction: Direction) -> WindowID? {
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

    /// Moves the boundary the window shares with its neighbour *in
    /// `direction`* by `delta`. This is the drag gesture: which edge moves
    /// is chosen by the user's cursor, so unlike `resize` there is a
    /// specific neighbour and no fallback — let go of a divider that isn't
    /// there and nothing should happen.
    @discardableResult
    func moveBoundary(_ id: WindowID, direction: Direction, delta: CGFloat, minRatio: CGFloat) -> Bool {
        guard let leaf = index[id] else { return false }
        var node: TreeNode = leaf
        while let parent = node.parent {
            if parent.orientation == direction.orientation, let idx = parent.index(of: node) {
                let nIdx = direction.isForward ? idx + 1 : idx - 1
                if parent.children.indices.contains(nIdx) {
                    let child = parent.children[idx]
                    let neighbor = parent.children[nIdx]
                    let applied = Self.clampBracketingZero(
                        delta,
                        lower: -(child.ratio - minRatio),
                        upper: neighbor.ratio - minRatio)
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

    /// Grows (positive `delta`) or shrinks (negative) the focused window
    /// along `axis`, taking the difference from a neighbour in the first
    /// ancestor container laid out on that axis.
    ///
    /// The sign is the whole point. The obvious alternative — "move the
    /// boundary shared with the neighbour in direction X" — makes the same
    /// key grow a window in the middle of a row and shrink one at its edge,
    /// because at the edge there is no neighbour in that direction and the
    /// only thing left to do is the opposite. Nobody can build a mental
    /// model of a key whose meaning depends on where they are standing.
    @discardableResult
    public func resize(_ id: WindowID, axis: Orientation, delta: CGFloat, minRatio: CGFloat) -> Bool {
        guard let leaf = index[id] else { return false }
        var node: TreeNode = leaf
        while let parent = node.parent {
            if parent.orientation == axis, parent.children.count > 1,
               let idx = parent.index(of: node) {
                // Take from the next sibling, falling back to the previous
                // one when the next has nothing left to give. Trying both is
                // what lets the last tile in a row grow, and what lets any
                // tile grow when the neighbour on one side is already at its
                // minimum.
                let child = parent.children[idx]
                for donorIdx in [idx + 1, idx - 1]
                where parent.children.indices.contains(donorIdx) {
                    let donor = parent.children[donorIdx]
                    let applied = Self.clampBracketingZero(
                        delta,
                        lower: -(child.ratio - minRatio),
                        upper: donor.ratio - minRatio)
                    guard abs(applied) > 0.0001 else { continue }
                    child.ratio += applied
                    donor.ratio -= applied
                    return true
                }
                return false
            }
            node = parent
        }
        return false
    }

    /// Clamps `delta` into `[lower, upper]` widened so the range always
    /// contains zero.
    ///
    /// A ratio that already sits outside `[minRatio, max]` produces naive
    /// bounds that exclude zero, and clamping into them inverts the request:
    /// asking to grow shrinks the window instead. Widening makes the worst
    /// case a no-op, which the callers then reject as too small to apply.
    private static func clampBracketingZero(
        _ delta: CGFloat, lower: CGFloat, upper: CGFloat
    ) -> CGFloat {
        min(max(delta, min(0, lower)), max(0, upper))
    }

    /// Grows (positive) or shrinks (negative) the focused window's share of
    /// its parent, redistributing across siblings (⌃⌥-= chords).
    @discardableResult
    public func resizeShare(_ id: WindowID, delta: CGFloat, minRatio: CGFloat) -> Bool {
        guard let leaf = index[id], let parent = leaf.parent, parent.children.count > 1 else { return false }
        let siblings = parent.children.filter { $0 !== leaf }
        let maxShare = 1 - minRatio * CGFloat(siblings.count)
        let applied = Self.clampBracketingZero(
            delta,
            lower: minRatio - leaf.ratio,
            upper: maxShare - leaf.ratio)
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
                    return moveBoundary(id, direction: direction, delta: deltaPixels / extent, minRatio: minRatio)
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
    /// Evens out every tiled container in the workspace.
    ///
    /// Deliberately the whole tree, not just the focused window's own
    /// container. "Balance sizes" is what people reach for when a layout has
    /// drifted into something lopsided, and evening out one container while
    /// leaving its siblings skewed does not answer that — it just moves
    /// which part looks wrong. Balancing one container also cannot be
    /// composed into balancing the workspace, because focusing each window
    /// in turn and pressing the key undoes the previous one.
    ///
    /// Accordion containers keep their ratios: their geometry comes from
    /// which child is focused, not from shares, so equalising them would be
    /// a no-op that only looks like one.
    public func balance() {
        balanceSubtree(root)
    }

    private func balanceSubtree(_ node: TreeNode) {
        guard node.isContainer, !node.children.isEmpty else { return }
        if node.layout == .tiles {
            let share = 1 / CGFloat(node.children.count)
            for child in node.children { child.ratio = share }
        }
        for child in node.children { balanceSubtree(child) }
    }

    /// Groups `id` with its neighbour in `direction` inside a new container
    /// laid out on the other axis.
    ///
    /// This is the only way to build structure out of windows that already
    /// exist. Without it a nested group can be created solely as a side
    /// effect of *opening* a window with a preselect set, so "put these two
    /// side by side" means closing one and reopening it.
    @discardableResult
    public func joinWith(_ id: WindowID, direction: Direction) -> Bool {
        // The direction's axis is a hint, not a requirement: what matters is
        // which side of *this* container the neighbour sits on. That lets a
        // single "group with the next one" key work whether the row runs
        // across or down, which is the difference between a binding people
        // remember and one they have to think about.
        guard let leaf = index[id], let parent = leaf.parent,
              let idx = parent.index(of: leaf)
        else { return false }
        let neighborIdx = direction.isForward ? idx + 1 : idx - 1
        guard parent.children.indices.contains(neighborIdx) else { return false }
        let neighbor = parent.children[neighborIdx]

        // The group takes the space the pair already occupied, and lies on
        // the opposite axis so it reads as a visible regrouping — and so
        // `normalize` does not immediately splice it back out.
        let group = TreeNode(container: parent.orientation.flipped, layout: parent.layout)
        group.ratio = leaf.ratio + neighbor.ratio
        let first = min(idx, neighborIdx)
        let ordered = idx < neighborIdx ? [leaf, neighbor] : [neighbor, leaf]
        for child in ordered { parent.removeChild(child) }
        parent.insertChild(group, at: min(first, parent.children.count))
        for (offset, child) in ordered.enumerated() {
            child.ratio = 0.5
            child.parent = group
            group.children.insert(child, at: offset)
        }
        normalize()
        focus(id)
        return true
    }

    /// Reparents every window directly onto the root at equal shares — the
    /// layout reset button, for when a tree has been nested into a shape
    /// that is quicker to abandon than to unpick.
    public func flatten() {
        let ids = root.windowIDs()
        guard !ids.isEmpty else { return }
        let keepFocus = focusedWindow
        root.children = []
        index.removeAll()
        for id in ids {
            let leaf = TreeNode(window: id)
            leaf.parent = root
            root.children.append(leaf)
            index[id] = leaf
        }
        root.layout = .tiles
        root.renormalizeRatios()
        normalize()
        if let keepFocus, contains(keepFocus) { focus(keepFocus) }
    }

    /// Lays the focused window's container out along `orientation`.
    /// Complements `cycleLayout`, which changes tiles/accordion but never
    /// the axis — so a row of columns could not be turned into a column of
    /// rows without moving every window by hand.
    @discardableResult
    public func setOrientation(_ id: WindowID, _ orientation: Orientation) -> Bool {
        guard let leaf = index[id], let parent = leaf.parent,
              parent.orientation != orientation else { return false }
        parent.orientation = orientation
        normalize()
        focus(id)
        return true
    }

    /// Toggles tiles ↔ accordion on the focused window's container, then
    /// normalizes: the toggle can make a nested container's layout match a
    /// same-orientation parent, which the merge pass splices away (§4.3).
    public func cycleLayout(_ id: WindowID) {
        guard let leaf = index[id], let parent = leaf.parent else { return }
        parent.layout = parent.layout.cycled
        normalize()
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
        // Splices and hoists reindex siblings, stranding every
        // `lastFocusedIndex` above the focused window — which is what
        // accordions expand and directional focus descends through. Repair
        // the path here so no caller has to remember to.
        if let focused = focusedWindow, contains(focused) { focus(focused) }
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
