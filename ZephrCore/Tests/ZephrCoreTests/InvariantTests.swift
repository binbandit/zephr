import Testing
import CoreGraphics
@testable import ZephrCore

private let d1 = DisplayID(1), d2 = DisplayID(2), d3 = DisplayID(3)
private let w1 = WindowID(1), w2 = WindowID(2), w3 = WindowID(3)
private let w4 = WindowID(4), w5 = WindowID(5), w6 = WindowID(6)

// MARK: - Workspace.adoptContents (§4.5 profile restore)

@Suite("adoptContents rebuilds without losing windows")
struct AdoptContentsTests {

    @Test func leafRootIsWrappedInAContainer() throws {
        let ws = Workspace(id: 1)
        ws.insertTiled(WindowID(9)) // pre-existing content must be fully replaced
        ws.adoptContents(root: TreeNode(window: w1), floats: [], focused: w1)
        try ws.validate()
        #expect(ws.root.isContainer)
        #expect(ws.root.windowIDs() == [w1])
        #expect(!ws.contains(WindowID(9)))
        #expect(ws.focusedWindow == w1)
    }

    @Test func floatDuplicatingATreeWindowIsNotDoubled() throws {
        // A corrupt snapshot can list the same id as both tiled and floating.
        // The tiled placement wins; the window must appear exactly once —
        // validate() rejects "both tiled and floating" outright.
        let root = TreeNode(container: .horizontal)
        root.insertChild(TreeNode(window: w1), at: 0)
        root.insertChild(TreeNode(window: w2), at: 1)
        let ws = Workspace(id: 2)
        ws.adoptContents(
            root: root,
            floats: [
                (w2, CGRect(x: 10, y: 10, width: 300, height: 200)),
                (w3, CGRect(x: 40, y: 40, width: 400, height: 300)),
            ],
            focused: w2
        )
        try ws.validate()
        #expect(!ws.isFloating(w2))
        #expect(ws.node(for: w2) != nil)
        #expect(ws.isFloating(w3))
        #expect(Set(ws.allWindows) == [w1, w2, w3])
        #expect(ws.focusedWindow == w2)
    }

    @Test func emptyRootPlusFloatsIsValidAndFocusFallsToTopFloat() throws {
        let ws = Workspace(id: 3)
        let frameA = CGRect(x: 10, y: 20, width: 500, height: 400)
        ws.adoptContents(
            root: TreeNode(container: .horizontal),
            floats: [
                (w1, frameA),
                (w1, CGRect(x: 99, y: 99, width: 100, height: 100)), // duplicate id: first wins
            ],
            focused: nil
        )
        try ws.validate()
        #expect(ws.tiledCount == 0)
        #expect(ws.isFloating(w1))
        #expect(ws.floatingOrder == [w1])
        #expect(ws.floating[w1] == frameA)
        #expect(ws.focusedWindow == w1)
    }
}

// MARK: - ProfileEngine.apply return contract (invariant 1)

@Suite("ProfileEngine.apply hands every non-landed window back")
struct ApplyContractTests {

    private let slot1 = [DisplaySlot(id: d1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))]
    private let fpA = WindowFingerprint(bundleID: "app.a", title: "A")
    private let fpB = WindowFingerprint(bundleID: "app.b", title: "B")

    private func leaf(_ index: Int) -> NodeSnapshot {
        NodeSnapshot(window: index, orientation: nil, layout: nil, ratio: 1, children: [])
    }

    private func workspaceSnapshot(id: Int, root: NodeSnapshot?) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id, name: nil, root: root, floats: [],
            monocle: false, floatByDefault: false, homeSlot: 0, focused: nil
        )
    }

    @Test func recordedWindowNoTreeNodeReferencesComesBackUnplaced() throws {
        // The snapshot fingerprints two windows but the tree only references
        // one: the matched-but-unreferenced window must return for re-insertion,
        // or it silently leaves management.
        let snapshot = ModelSnapshot(
            fingerprint: "t",
            windows: [fpA, fpB],
            workspaces: [workspaceSnapshot(id: 1, root: leaf(0))],
            activeBySlot: [0: 1]
        )
        let model = WorkspaceModel()
        model.syncDisplays([d1])
        let unplaced = ProfileEngine.apply(
            snapshot, to: model, slots: slot1,
            live: [WindowID(10): fpA, WindowID(11): fpB]
        )
        #expect(unplaced == [WindowID(11)])
        #expect(model.workspace(containing: WindowID(10))?.id == 1)
        #expect(model.workspace(containing: WindowID(11)) == nil)
        for ws in model.workspaces.values { try ws.validate() }
    }

    @Test func windowIndexReferencedByTwoWorkspacesMaterializesOnce() throws {
        // A corrupt snapshot references index 0 from two trees. The window
        // must land exactly once; the surplus live candidate comes back.
        let snapshot = ModelSnapshot(
            fingerprint: "t",
            windows: [fpA],
            workspaces: [
                workspaceSnapshot(id: 1, root: leaf(0)),
                workspaceSnapshot(id: 2, root: leaf(0)),
            ],
            activeBySlot: [0: 1]
        )
        let model = WorkspaceModel()
        model.syncDisplays([d1])
        let unplaced = ProfileEngine.apply(
            snapshot, to: model, slots: slot1,
            live: [WindowID(10): fpA, WindowID(11): fpA]
        )
        #expect(unplaced == [WindowID(11)])
        let holders = model.workspaces.values.filter { $0.contains(WindowID(10)) }
        #expect(holders.count == 1)
        #expect(model.workspace(containing: WindowID(10))?.id == 1)
        for ws in model.workspaces.values { try ws.validate() }
    }

    @Test func outOfRangeWorkspaceIDIsSkippedAndItsWindowsReturned() throws {
        // Workspace -3 can't exist (no keybinding reaches it, §4.4): the
        // entry is skipped — not clamped onto a legitimate workspace — and
        // its window comes back through the unplaced return.
        let snapshot = ModelSnapshot(
            fingerprint: "t",
            windows: [fpA],
            workspaces: [workspaceSnapshot(id: -3, root: leaf(0))],
            activeBySlot: [:]
        )
        let model = WorkspaceModel()
        model.syncDisplays([d1])
        let unplaced = ProfileEngine.apply(
            snapshot, to: model, slots: slot1,
            live: [WindowID(10): fpA]
        )
        #expect(unplaced == [WindowID(10)])
        #expect(model.workspaces[-3] == nil)
        #expect(model.workspace(containing: WindowID(10)) == nil)
        for ws in model.workspaces.values { try ws.validate() }
    }

    @Test func previouslyManagedWindowAbsentFromLiveIsReturned() throws {
        // A window under management going in but missing from `live` (its AX
        // element vanished mid-restore) must still reach the caller — it may
        // reappear, and dropping it from the return means dropping it from
        // management forever.
        let model = WorkspaceModel()
        model.syncDisplays([d1])
        model.insertWindow(WindowID(7))
        let snapshot = ModelSnapshot(fingerprint: "t", windows: [], workspaces: [], activeBySlot: [:])
        let unplaced = ProfileEngine.apply(snapshot, to: model, slots: slot1, live: [:])
        #expect(unplaced == [WindowID(7)])
        #expect(model.workspace(containing: WindowID(7)) == nil)
        for ws in model.workspaces.values { try ws.validate() }
    }
}

// MARK: - WorkspaceModel.syncDisplays (§4.5 migration)

@Suite("syncDisplays across lid-close and display churn")
struct SyncDisplaysTests {

    @Test func lidCloseWakeReplaceSequenceLeavesNoStaleOrDuplicateActives() throws {
        // The proven sequence: [d1,d2] → [] (lid closed) → [d3] (woke on a
        // projector) → [d1,d3]. The zero-display interval keeps the active
        // map; the later syncs must clean the d2 leftovers so no two
        // connected displays ever show the same workspace.
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        m.insertWindow(w1)
        m.focusDisplay(d2)
        m.insertWindow(w2)

        m.syncDisplays([])
        m.syncDisplays([d3])
        m.syncDisplays([d1, d3])

        let active = m.activeWorkspaceByDisplay
        #expect(Set(active.keys) == [d1, d3]) // no stale d2 entry
        #expect(Set(active.values).count == active.count) // no duplicates
        for w in [w1, w2] {
            #expect(m.workspace(containing: w) != nil) // never lose a window
        }
        for ws in m.workspaces.values {
            #expect(ws.homeDisplay == nil || ws.homeDisplay == d1 || ws.homeDisplay == d3)
            try ws.validate()
        }
        #expect(m.focusedDisplay == d1 || m.focusedDisplay == d3)
    }

    @Test func displayReplacementMigratesCleanly() throws {
        // Unplug d2, plug d3 in the same sync.
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        m.insertWindow(w1)
        m.focusDisplay(d2)
        m.insertWindow(w2)
        let wsOfW2 = m.workspace(containing: w2)!.id

        m.syncDisplays([d1, d3])

        let active = m.activeWorkspaceByDisplay
        #expect(Set(active.keys) == [d1, d3])
        #expect(Set(active.values).count == active.count)
        #expect(m.workspace(containing: w2)?.id == wsOfW2) // window stays put
        #expect(m.workspace(wsOfW2).homeDisplay == d1) // migrated to a live display
        for ws in m.workspaces.values { try ws.validate() }
    }

    @Test func forcedDuplicateActivesAreDeduplicated() {
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        // Corrupt the map directly: both displays claim the same workspace.
        m.activeWorkspaceByDisplay[d2] = m.activeWorkspaceByDisplay[d1]!
        m.syncDisplays([d1, d2])
        let active = m.activeWorkspaceByDisplay
        #expect(Set(active.keys) == [d1, d2])
        #expect(active[d1] != active[d2])
    }
}

// MARK: - Rescue determinism (§4.4, invariant 1)

@Suite("rescueAllWindows is deterministic")
struct RescueDeterminismTests {

    private func populated() -> WorkspaceModel {
        let m = WorkspaceModel()
        m.syncDisplays([d1])
        m.insertWindow(w2) // ws1
        m.insertWindow(w5) // ws1
        _ = m.activateWorkspace(2)
        m.insertWindow(w1)
        m.insertWindow(w4)
        _ = m.activateWorkspace(3)
        m.insertWindow(w3, floating: true, frame: CGRect(x: 30, y: 40, width: 500, height: 400))
        return m
    }

    @Test func rescueProducesTheExactSameTreeEveryTime() throws {
        // Windows move in ascending id order regardless of Dictionary hash
        // seed, so the one-keystroke recovery path always yields this tree:
        // ws1 starts as [w2, w5] (w5 focused); w1 splits w5, w4 splits w1;
        // w3 rejoins as the sole float with its frame intact.
        for run in 1...3 {
            let m = populated()
            m.rescueAllWindows(into: 1)
            let ws = m.workspace(1)
            try ws.validate()
            #expect(ws.root.windowIDs() == [w2, w5, w1, w4], "run \(run)")
            let flat = ws.root.children.allSatisfy(\.isWindow)
            #expect(flat, "run \(run)")
            #expect(ws.floatingOrder == [w3], "run \(run)")
            #expect(ws.floating[w3] == CGRect(x: 30, y: 40, width: 500, height: 400), "run \(run)")
            #expect(m.workspace(2).isEmpty)
            #expect(m.workspace(3).isEmpty)
        }
    }
}

// MARK: - Resize clamps (§4.2 resize mode)

@Suite("Resize clamps never invert a grow into a shrink")
struct ResizeClampTests {

    /// Six windows flat in the root, with a ladder of ratios where every
    /// neighbor of w1 already sits below minRatio — the no-solve setup the
    /// audit used to expose the inverted clamp.
    private func ladder() throws -> Workspace {
        let ws = Workspace(id: 1)
        for i in 1...6 { ws.insertTiled(WindowID(UInt64(i))) }
        ws.normalize()
        let ratios: [CGFloat] = [0.9, 0.02, 0.02, 0.02, 0.02, 0.02]
        for (i, r) in ratios.enumerated() { ws.root.children[i].ratio = r }
        try ws.validate()
        return ws
    }

    @Test func growAgainstASubMinimumNeighborNeverShrinks() throws {
        let ws = try ladder()
        let before = ws.root.children[0].ratio
        // w1 grows; its only neighbour w2 is 0.02, already below minRatio
        // 0.05, so there is no room and the request must no-op — the old
        // clamp inverted it into a shrink.
        let ok = ws.resize(w1, axis: .horizontal, delta: 0.05, minRatio: 0.05)
        #expect(!ok)
        #expect(ws.root.children[0].ratio >= before, "grow request shrank the window")
        #expect(ws.root.children[1].ratio == 0.02)
        try ws.validate()
    }

    @Test func growBetweenTwoSubMinimumSiblingsNoOps() throws {
        let ws = try ladder()
        // w3 is the one genuinely boxed in: both its neighbours sit at the
        // floor, so neither can donate and the grow must no-op. (w2 is not
        // — its previous neighbour is the 0.9 tile, and growing from that
        // side is exactly what the donor fallback is for.)
        let ok = ws.resize(w3, axis: .horizontal, delta: 0.05, minRatio: 0.05)
        #expect(!ok)
        #expect(ws.root.children[1].ratio == 0.02)
        #expect(ws.root.children[2].ratio == 0.02)
        #expect(ws.root.children[3].ratio == 0.02)
        try ws.validate()
    }

    @Test func growIntoTheLargeNeighborStillWorks() throws {
        let ws = try ladder()
        // w2's next sibling is at the floor, so it falls back to w1 (0.9),
        // which has plenty to give. Growing must still work.
        let ok = ws.resize(w2, axis: .horizontal, delta: 0.05, minRatio: 0.05)
        #expect(ok)
        #expect(ws.root.children[1].ratio > 0.02)
        #expect(ws.root.children[0].ratio < 0.9)
        try ws.validate()
    }

    @Test func resizeShareGrowAboveMaxShareNeverShrinks() throws {
        let ws = try ladder()
        // w1 already holds 0.9 > maxShare (1 − 5·0.05 = 0.75): a further grow
        // request must no-op, not snap the window down to 0.75.
        let ok = ws.resizeShare(w1, delta: 0.05, minRatio: 0.05)
        #expect(!ok)
        #expect(ws.root.children[0].ratio >= 0.9, "grow request shrank the window")
        try ws.validate()
    }

    @Test func resizeShareShrinkStillWorks() throws {
        let ws = try ladder()
        let ok = ws.resizeShare(w1, delta: -0.1, minRatio: 0.05)
        #expect(ok)
        #expect(ws.root.children[0].ratio < 0.9)
        let sum = ws.root.children.reduce(CGFloat(0)) { $0 + $1.ratio }
        #expect(abs(sum - 1) < 0.01)
        try ws.validate()
    }
}

// MARK: - cycleLayout normalization (§4.3)

@Suite("cycleLayout re-normalizes same-orientation nesting")
struct CycleLayoutNormalizationTests {

    @Test func togglingANestedContainerIntoItsParentsLayoutSplices() throws {
        let ws = Workspace(id: 1)
        ws.insertTiled(w1)
        ws.insertTiled(w2) // H[w1, w2]
        ws.focus(w2)
        ws.setPreselect(.vertical)
        ws.insertTiled(w3) // H[w1, V[w2, w3]]
        ws.cycleLayout(w2) // the V wrapper becomes accordion
        try ws.validate()

        // Move w1 down: the root re-orients to vertical, leaving
        // V-tiles [V-accordion[w2, w3], w1] — same orientation, different
        // layout, which is legal.
        #expect(ws.move(w1, direction: .down) == .moved)
        try ws.validate()
        #expect(ws.root.orientation == .vertical)

        // The toggle that used to strand same-orientation nesting: the inner
        // accordion flips back to tiles, now matching its parent in both
        // orientation and layout — normalize must splice it away.
        ws.cycleLayout(w2)
        try ws.validate()
        let flat = ws.root.children.allSatisfy(\.isWindow)
        #expect(flat, "nested same-orientation container survived")
        #expect(Set(ws.root.windowIDs()) == [w1, w2, w3])
    }
}

// MARK: - Focus path (§4.3 accordion expansion, directional descent)

/// Descends `lastFocusedIndex` from the root the way `solveAccordion` and
/// directional focus do. It must land on the focused window; when it does
/// not, the accordion expands a stranger and focus descends into the wrong
/// pane.
private func focusPathLeaf(_ ws: Workspace) -> WindowID? {
    var node = ws.root
    while node.isContainer {
        guard !node.children.isEmpty else { return nil }
        node = node.children[min(max(0, node.lastFocusedIndex), node.children.count - 1)]
    }
    return node.windowID
}

@Suite("Focus path survives structural rewrites")
struct FocusPathTests {

    /// A merge splices a container away and shifts every later sibling down
    /// one index. The focused window moves with them; the stale
    /// `lastFocusedIndex` does not.
    @Test func cycleLayoutKeepsTheFocusedWindowExpanded() throws {
        // V-tiles [ V-accordion[w1, w3], w2 ], focused w2.
        let inner = TreeNode(container: .vertical, layout: .accordion)
        inner.insertChild(TreeNode(window: w1), at: 0)
        inner.insertChild(TreeNode(window: w3), at: 1)
        let root = TreeNode(container: .vertical)
        root.insertChild(inner, at: 0)
        root.insertChild(TreeNode(window: w2), at: 1)
        let ws = Workspace(id: 1)
        ws.adoptContents(root: root, floats: [], focused: w2)
        try ws.validate()

        // Toggling w2's container (the root) to accordion makes the inner
        // container match in orientation and layout, so normalize splices
        // it: V-accordion[w1, w3, w2].
        ws.cycleLayout(w2)
        try ws.validate()
        #expect(ws.root.layout == .accordion)
        #expect(ws.root.windowIDs() == [w1, w3, w2])
        #expect(focusPathLeaf(ws) == w2)

        // The user-visible consequence: the focused window gets the pane,
        // not a 48pt sliver.
        let solved = Solver.solve(workspace: ws, in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let focusedHeight = solved.placements[w2]!.frame.height
        for other in [w1, w3] {
            #expect(solved.placements[other]!.frame.height < focusedHeight)
        }
    }

    /// `remove()` repaired the focus path only when the *removed* window was
    /// the focused one, but a removal that collapses a container reindexes
    /// siblings regardless of who had focus.
    @Test func removingAnUnfocusedWindowKeepsTheFocusPath() throws {
        // V-tiles [ H-tiles[ w1, V-tiles[w2, w3] ], w4 ], focused w4.
        let deep = TreeNode(container: .vertical)
        deep.insertChild(TreeNode(window: w2), at: 0)
        deep.insertChild(TreeNode(window: w3), at: 1)
        let mid = TreeNode(container: .horizontal)
        mid.insertChild(TreeNode(window: w1), at: 0)
        mid.insertChild(deep, at: 1)
        let root = TreeNode(container: .vertical)
        root.insertChild(mid, at: 0)
        root.insertChild(TreeNode(window: w4), at: 1)
        let ws = Workspace(id: 1)
        ws.adoptContents(root: root, floats: [], focused: w4)
        try ws.validate()

        // Removing w1 leaves mid single-child, which hoists and then merges
        // into the root: V-tiles[w2, w3, w4].
        #expect(ws.remove(w1))
        try ws.validate()
        #expect(ws.root.windowIDs() == [w2, w3, w4])
        #expect(ws.focusedWindow == w4)
        #expect(focusPathLeaf(ws) == w4)
    }
}

// MARK: - Display churn (§4.4 multi-monitor, §4.5 dock/undock)

@Suite("Docking and undocking keeps workspaces where the user left them")
struct DisplayChurnTests {

    /// Unplugging a display migrates its workspaces to the survivor so
    /// nothing is stranded. Plugging it back in must undo that, or the
    /// returning monitor comes up on a brand-new empty workspace while the
    /// windows the user expects sit on the laptop.
    @Test func repluggingADisplayReturnsItsWorkspaces() {
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        // syncDisplays gives the second display its own workspace.
        let onD2 = m.activeWorkspaceByDisplay[d2]!
        m.insertWindow(w1, workspace: onD2)
        #expect(m.workspace(onD2).homeDisplay == d2)

        m.syncDisplays([d1])                         // undock
        #expect(m.workspace(onD2).homeDisplay == d1) // rescued, not stranded

        m.syncDisplays([d1, d2])                     // redock
        #expect(m.workspace(onD2).homeDisplay == d2, "workspace did not return to its own display")
        #expect(m.activeWorkspaceByDisplay[d2] == onD2)
    }

    /// Workspace ids are the keys 1-9. Inventing a tenth makes it
    /// unreachable by any binding, and profile restore drops it outright.
    @Test func aDisplayNeedingAWorkspaceNeverInventsAnUnreachableID() {
        let m = WorkspaceModel()
        m.syncDisplays([d1])
        for n in 1...9 { _ = m.activateWorkspace(n, on: d1) }
        #expect(m.workspaces.count == 9)

        m.syncDisplays([d1, d2])
        let assigned = m.activeWorkspaceByDisplay[d2]
        #expect(assigned != nil)
        #expect((1...9).contains(assigned!), "invented workspace \(assigned!) — no key can reach it")
        #expect(assigned != m.activeWorkspaceByDisplay[d1])
    }

    /// Back-and-forth is per-display: re-pressing the visible workspace's
    /// key must bounce to what *this* display showed before, not to whatever
    /// the other monitor was last on — which would switch the wrong screen
    /// and drag focus across with it.
    @Test func backAndForthDoesNotReachAcrossDisplays() {
        // Workspaces pin to the display they were opened on, so build each
        // display's history while that display is the focused one.
        let m = WorkspaceModel()
        m.syncDisplays([d1])
        _ = m.activateWorkspace(1, on: d1)
        _ = m.activateWorkspace(2, on: d1)   // d1 history: 1 -> 2
        m.syncDisplays([d1, d2])
        m.focusDisplay(d2)
        _ = m.activateWorkspace(5, on: d2)
        _ = m.activateWorkspace(6, on: d2)   // d2 history: 5 -> 6

        m.focusDisplay(d1)
        _ = m.activateWorkspace(2, on: d1) // re-press the visible one
        #expect(m.activeWorkspaceByDisplay[d1] == 1, "bounced to the other display's history")
        #expect(m.activeWorkspaceByDisplay[d2] == 6, "the other display must not move")
    }
}

@Suite("Moving a workspace between displays")
struct MoveWorkspaceTests {

    @Test func aWorkspaceFollowsTheDisplayItIsSentTo() {
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        let onD1 = m.activeWorkspaceByDisplay[d1]!
        m.insertWindow(w1, workspace: onD1)

        let affected = m.moveWorkspace(onD1, toDisplay: d2)
        #expect(m.workspace(onD1).homeDisplay == d2)
        #expect(m.activeWorkspaceByDisplay[d2] == onD1)
        #expect(affected.contains(d1) && affected.contains(d2))
        // Its windows come with it.
        #expect(m.workspace(onD1).contains(w1))
    }

    /// The display it left cannot be left showing a workspace that now
    /// lives somewhere else.
    @Test func theVacatedDisplayGetsSomethingElse() {
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        let onD1 = m.activeWorkspaceByDisplay[d1]!
        _ = m.moveWorkspace(onD1, toDisplay: d2)

        let replacement = m.activeWorkspaceByDisplay[d1]
        #expect(replacement != nil)
        #expect(replacement != onD1, "the vacated display still shows the moved workspace")
        #expect((1...9).contains(replacement!))
    }

    @Test func movingToTheDisplayItIsAlreadyOnDoesNothing() {
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        let onD1 = m.activeWorkspaceByDisplay[d1]!
        #expect(m.moveWorkspace(onD1, toDisplay: d1).isEmpty)
    }

    @Test func anUnknownDisplayIsRefused() {
        let m = WorkspaceModel()
        m.syncDisplays([d1])
        #expect(m.moveWorkspace(1, toDisplay: d3).isEmpty)
    }

    /// A redock must not drag it back: the move is a deliberate choice and
    /// updates the remembered preference too.
    @Test func theMoveSurvivesAnUndockRedock() {
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        let onD1 = m.activeWorkspaceByDisplay[d1]!
        _ = m.moveWorkspace(onD1, toDisplay: d2)

        m.syncDisplays([d1])
        m.syncDisplays([d1, d2])
        #expect(m.workspace(onD1).homeDisplay == d2)
    }
}
