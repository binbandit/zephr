import Testing
import CoreGraphics
@testable import ZephrCore

private func ws() -> Workspace { Workspace(id: 1) }
private let w1 = WindowID(1), w2 = WindowID(2), w3 = WindowID(3), w4 = WindowID(4)

@Suite("Tree insertion")
struct InsertionTests {
    @Test func firstWindowFillsWorkspace() throws {
        let s = ws()
        s.insertTiled(w1)
        try s.validate()
        #expect(s.root.windowIDs() == [w1])
        #expect(s.focusedWindow == w1)
    }

    @Test func secondWindowSplitsAlongLongerEdge() throws {
        let s = ws()
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: CGRect(x: 0, y: 0, width: 1600, height: 900))
        s.insertTiled(w2)
        try s.validate()
        // Landscape frame → horizontal split.
        #expect(s.root.orientation == .horizontal)
        #expect(s.root.windowIDs() == [w1, w2])
    }

    @Test func tallFrameSplitsVertically() throws {
        let s = ws()
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: CGRect(x: 0, y: 0, width: 600, height: 1200))
        s.insertTiled(w2)
        try s.validate()
        #expect(s.root.orientation == .vertical)
    }

    @Test func preselectOverridesHeuristic() throws {
        let s = ws()
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: CGRect(x: 0, y: 0, width: 1600, height: 900))
        s.setPreselect(.vertical)
        s.insertTiled(w2)
        try s.validate()
        #expect(s.root.orientation == .vertical)
        // Preselect is one-shot.
        #expect(s.preselect == nil)
    }

    @Test func insertTakesHalfOfFocusedShare() throws {
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: rect)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)
        s.setPreselect(.horizontal)
        s.insertTiled(w3) // splits w2's half
        try s.validate()
        let ratios = s.root.children.map(\.ratio)
        #expect(abs(ratios[0] - 0.5) < 0.01)
        #expect(abs(ratios[1] - 0.25) < 0.01)
        #expect(abs(ratios[2] - 0.25) < 0.01)
    }

    @Test func perpendicularSplitWrapsInContainer() throws {
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: rect)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)
        s.setPreselect(.vertical)
        s.insertTiled(w3)
        try s.validate()
        // Root stays horizontal: [w1, V[w2, w3]]
        #expect(s.root.orientation == .horizontal)
        #expect(s.root.children.count == 2)
        let second = s.root.children[1]
        #expect(second.isContainer)
        #expect(second.orientation == .vertical)
        #expect(second.windowIDs() == [w2, w3])
    }
}

@Suite("Tree removal and normalization")
struct RemovalTests {
    @Test func removalRedistributesProportionally() throws {
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        for w in [w1, w2, w3] {
            s.insertTiled(w)
            _ = Solver.solve(workspace: s, in: rect)
        }
        s.remove(w2)
        try s.validate()
        let sum = s.root.children.reduce(CGFloat(0)) { $0 + $1.ratio }
        #expect(abs(sum - 1) < 0.001)
        #expect(s.root.windowIDs() == [w1, w3])
    }

    @Test func removingSiblingCollapsesContainer() throws {
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: rect)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)
        s.setPreselect(.vertical)
        s.insertTiled(w3) // [w1, V[w2, w3]]
        s.remove(w2)
        try s.validate()
        // V collapses; back to flat [w1, w3].
        let flat = s.root.children.allSatisfy { $0.isWindow }
        #expect(flat)
        #expect(s.root.windowIDs() == [w1, w3])
    }

    @Test func removingLastWindowLeavesEmptyRoot() throws {
        let s = ws()
        s.insertTiled(w1)
        s.remove(w1)
        try s.validate()
        #expect(s.isEmpty)
        #expect(s.focusedWindow == nil)
    }

    @Test func focusFallsToSiblingOnRemoval() throws {
        let s = ws()
        s.insertTiled(w1)
        s.insertTiled(w2)
        #expect(s.focusedWindow == w2)
        s.remove(w2)
        #expect(s.focusedWindow == w1)
    }
}

@Suite("Directional focus")
struct FocusTests {
    /// Layout: root H [w1, V[w2, w3]]
    private func nested() throws -> Workspace {
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: rect)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)
        s.setPreselect(.vertical)
        s.insertTiled(w3)
        try s.validate()
        return s
    }

    @Test func focusAcrossSiblings() throws {
        let s = try nested()
        #expect(s.neighbor(of: w1, direction: .right) != nil)
        #expect(s.neighbor(of: w1, direction: .left) == nil)
        #expect(s.neighbor(of: w2, direction: .down) == w3)
        #expect(s.neighbor(of: w3, direction: .up) == w2)
        #expect(s.neighbor(of: w3, direction: .left) == w1)
    }

    @Test func focusDescendsToLastFocused() throws {
        let s = try nested()
        s.focus(w3)
        // From w1 going right, we should land on the last focused child of V.
        #expect(s.neighbor(of: w1, direction: .right) == w3)
        s.focus(w2)
        #expect(s.neighbor(of: w1, direction: .right) == w2)
    }
}

@Suite("Window movement")
struct MoveTests {
    @Test func swapWithinContainer() throws {
        let s = ws()
        for w in [w1, w2, w3] { s.insertTiled(w) } // flat row
        // [w1, w2, w3]; move w2 left → [w2, w1, w3]
        #expect(s.move(w2, direction: .left) == .moved)
        try s.validate()
        #expect(s.root.windowIDs() == [w2, w1, w3])
    }

    @Test func edgeReturnsHitEdge() throws {
        let s = ws()
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        #expect(s.move(w1, direction: .left) == .hitEdge)
        #expect(s.move(w2, direction: .right) == .hitEdge)
        try s.validate()
    }

    @Test func soleWindowHitsEveryEdge() throws {
        let s = ws()
        s.insertTiled(w1)
        for d in Direction.allCases {
            #expect(s.move(w1, direction: d) == .hitEdge)
        }
    }

    @Test func popOutOfNestedContainer() throws {
        // root H [w1, V[w2, w3]]; move w3 left → [w1, w3, w2] flat.
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: rect)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)
        s.setPreselect(.vertical)
        s.insertTiled(w3)
        #expect(s.move(w3, direction: .left) == .moved)
        try s.validate()
        #expect(s.root.windowIDs() == [w1, w3, w2])
        let flat = s.root.children.allSatisfy { $0.isWindow }
        #expect(flat)
    }

    @Test func moveIntoNeighborContainer() throws {
        // root H [w1, V[w2, w3]]; move w1 right → it joins V.
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        _ = Solver.solve(workspace: s, in: rect)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)
        s.setPreselect(.vertical)
        s.insertTiled(w3)
        #expect(s.move(w1, direction: .right) == .moved)
        try s.validate()
        // Root collapses to the vertical container holding all three.
        #expect(s.root.orientation == .vertical)
        #expect(Set(s.root.windowIDs()) == Set([w1, w2, w3]))
    }

    @Test func rootReorientsOnPerpendicularMove() throws {
        let s = ws()
        s.insertTiled(w1)
        s.insertTiled(w2) // flat horizontal [w1, w2]
        #expect(s.move(w2, direction: .down) == .moved)
        try s.validate()
        #expect(s.root.orientation == .vertical)
        // w2 below the (wrapped) w1.
        #expect(s.root.windowIDs() == [w1, w2])
        #expect(s.neighbor(of: w1, direction: .down) == w2)
    }

    @Test func movedWindowStaysFocused() throws {
        let s = ws()
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.focus(w2)
        _ = s.move(w2, direction: .right)
        #expect(s.focusedWindow == w2)
    }
}

@Suite("Resize and layout ops")
struct ResizeTests {
    @Test func resizeMovesSharedBoundary() throws {
        let s = ws()
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        #expect(s.resize(w1, direction: .right, delta: 0.05, minRatio: 0.05))
        let ratios = s.root.children.map(\.ratio)
        #expect(abs(ratios[0] - 0.55) < 0.001)
        #expect(abs(ratios[1] - 0.45) < 0.001)
        try s.validate()
    }

    @Test func resizeClampsAtMinimum() throws {
        let s = ws()
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        #expect(s.resize(w1, direction: .right, delta: 0.9, minRatio: 0.05))
        let ratios = s.root.children.map(\.ratio)
        #expect(ratios[1] >= 0.049)
        try s.validate()
    }

    @Test func resizeAtEdgeFails() throws {
        let s = ws()
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        // No vertical ancestor at all.
        #expect(!s.resize(w1, direction: .down, delta: 0.05, minRatio: 0.05))
        // w1 has no left neighbor... but growth toward the right neighbor's
        // boundary from the left edge is direction .right; .left has none.
        #expect(!s.resize(w1, direction: .left, delta: 0.05, minRatio: 0.05))
    }

    @Test func growShrinkShare() throws {
        let s = ws()
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        let before = s.node(for: w2)!.ratio
        #expect(s.resizeShare(w2, delta: 0.1, minRatio: 0.05))
        #expect(s.node(for: w2)!.ratio > before)
        let sum = s.root.children.reduce(CGFloat(0)) { $0 + $1.ratio }
        #expect(abs(sum - 1) < 0.01)
        try s.validate()
    }

    @Test func balanceEqualizes() throws {
        let s = ws()
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        _ = s.resize(w1, direction: .right, delta: 0.2, minRatio: 0.05)
        s.balance(w1)
        for c in s.root.children {
            #expect(abs(c.ratio - 1.0 / 3.0) < 0.001)
        }
        try s.validate()
    }
}

@Suite("Float toggle")
struct FloatTests {
    @Test func roundTrip() throws {
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)

        let nowFloating = s.toggleFloat(w2, defaultFrame: CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(nowFloating == true)
        try s.validate()
        #expect(s.isFloating(w2))
        #expect(s.root.windowIDs() == [w1])

        let backTiled = s.toggleFloat(w2, defaultFrame: .zero)
        #expect(backTiled == false)
        try s.validate()
        #expect(!s.isFloating(w2))
        #expect(Set(s.root.windowIDs()) == Set([w1, w2]))
    }

    @Test func floatKeepsSolvedFrame() throws {
        let s = ws()
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        s.insertTiled(w1)
        s.insertTiled(w2)
        _ = Solver.solve(workspace: s, in: rect)
        let solved = s.lastSolvedFrames[w2]!
        _ = s.toggleFloat(w2, defaultFrame: .zero)
        #expect(s.floating[w2] == solved)
    }
}
