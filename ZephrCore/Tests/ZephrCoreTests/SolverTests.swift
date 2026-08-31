import Testing
import CoreGraphics
@testable import ZephrCore

private let w1 = WindowID(1), w2 = WindowID(2), w3 = WindowID(3)
private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

@Suite("Solver — tiles")
struct SolverTilesTests {
    @Test func singleWindowGetsOuterGappedRect() {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        let config = LayoutConfig(innerGap: 8, outerGap: 8)
        let result = Solver.solve(workspace: s, in: screen, config: config)
        #expect(result.placements[w1]?.frame == CGRect(x: 8, y: 8, width: 1584, height: 984))
    }

    @Test func gapsMathIsExact() {
        let s = Workspace(id: 1)
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        let config = LayoutConfig(innerGap: 10, outerGap: 0)
        let result = Solver.solve(workspace: s, in: screen, config: config)
        let frames = [w1, w2, w3].map { result.placements[$0]!.frame }

        // No overlap, gaps exactly 10, full coverage.
        #expect(frames[0].minX == 0)
        #expect(abs(frames[1].minX - frames[0].maxX - 10) < 1)
        #expect(abs(frames[2].minX - frames[1].maxX - 10) < 1)
        #expect(abs(frames[2].maxX - 1600) < 1)
        // Later inserts split the focused window's share: 0.5 / 0.25 / 0.25.
        for f in frames {
            #expect(f.height == 1000)
            #expect(f.width > 300)
        }
    }

    @Test func framesArePixelAligned() {
        let s = Workspace(id: 1)
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        let result = Solver.solve(workspace: s, in: CGRect(x: 0, y: 0, width: 1601, height: 999))
        for p in result.placements.values {
            let f = p.frame
            #expect(f.origin.x == f.origin.x.rounded())
            #expect(f.origin.y == f.origin.y.rounded())
            #expect(f.width == f.width.rounded())
            #expect(f.height == f.height.rounded())
        }
    }

    @Test func ratiosDriveWidths() {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        _ = s.resize(w1, axis: .horizontal, delta: 0.2, minRatio: 0.05) // 0.7 / 0.3
        let config = LayoutConfig(innerGap: 0, outerGap: 0)
        let result = Solver.solve(workspace: s, in: screen, config: config)
        let f1 = result.placements[w1]!.frame
        #expect(abs(f1.width - 1120) < 2) // 0.7 × 1600
    }

    @Test func minimumsClampAndRedistribute() {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        // Squeeze w1 to 5%: min tile width must win.
        _ = s.resize(w1, axis: .horizontal, delta: -0.45, minRatio: 0.05)
        let config = LayoutConfig(innerGap: 0, outerGap: 0, minTileSize: CGSize(width: 200, height: 90))
        let result = Solver.solve(workspace: s, in: screen, config: config)
        #expect(result.placements[w1]!.frame.width >= 199)
        let total = result.placements[w1]!.frame.width + result.placements[w2]!.frame.width
        #expect(abs(total - 1600) < 2)
    }

    @Test func impossibleMinimumsDegradeToAccordion() {
        let s = Workspace(id: 1)
        for i in 1...10 { s.insertTiled(WindowID(UInt64(i))) }
        s.normalize()
        let config = LayoutConfig(innerGap: 0, outerGap: 0, minTileSize: CGSize(width: 300, height: 90))
        // 10 × 300 > 1600 → accordion fallback: one big window, slivers elsewhere.
        let result = Solver.solve(workspace: s, in: screen, config: config)
        let widths = result.placements.values.map(\.frame.width).sorted()
        #expect(widths.last! > 1000)
        #expect(widths.first! < 300)
    }
}

@Suite("Solver — accordion and monocle")
struct SolverAccordionTests {
    @Test func accordionGivesFocusedAlmostEverything() {
        let s = Workspace(id: 1)
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        s.cycleLayout(w1)
        s.focus(w2)
        let config = LayoutConfig(innerGap: 0, outerGap: 0, accordionPadding: 40)
        let result = Solver.solve(workspace: s, in: screen, config: config)
        let f2 = result.placements[w2]!.frame
        let expected: CGFloat = 1600 - 80
        #expect(f2.width == expected)
        #expect(result.placements[w1]!.frame.width == 40)
        #expect(result.placements[w3]!.frame.width == 40)
        // Slivers hug the edges; focused sits between.
        #expect(result.placements[w1]!.frame.minX == 0)
        #expect(result.placements[w3]!.frame.maxX == 1600)
        // Active window raises above slivers.
        #expect(result.raiseOrder.contains(w2))
    }

    @Test func monocleFillsWorkspace() {
        let s = Workspace(id: 1)
        for w in [w1, w2] { s.insertTiled(w) }
        s.normalize()
        s.focus(w1)
        s.toggleMonocle()
        let config = LayoutConfig(innerGap: 8, outerGap: 8)
        let result = Solver.solve(workspace: s, in: screen, config: config)
        #expect(result.placements[w1]!.frame == CGRect(x: 8, y: 8, width: 1584, height: 984))
        // The other window keeps its normal tile.
        #expect(result.placements[w2]!.frame.width < 1000)
        #expect(result.raiseOrder.last == w1)
    }

    @Test func floatingWindowsAreClampedAndRaised() {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        s.insertFloating(w2, frame: CGRect(x: 1500, y: 900, width: 400, height: 300))
        let result = Solver.solve(workspace: s, in: screen)
        let f = result.placements[w2]!.frame
        #expect(f.maxX <= 1600)
        #expect(f.maxY <= 1000)
        #expect(result.placements[w2]!.layer == .floating)
        #expect(result.raiseOrder.last == w2) // focused float raises last
    }
}

@Suite("Solver — degenerate inputs")
struct SolverDegenerateTests {

    /// Every emitted frame must be finite, non-negatively sized, and inside
    /// the workspace rect: a frame at an origin outside the rect is a stashed
    /// window nobody stashed (window-loss, invariant 1).
    private func expectSane(_ result: PlacementSet, within rect: CGRect, context: String) {
        for (id, p) in result.placements {
            let f = p.frame
            let finite = f.isFinite
            #expect(finite, "\(context): non-finite frame \(f) for \(id)")
            #expect(f.width >= 0 && f.height >= 0, "\(context): negative size \(f) for \(id)")
            guard finite else { continue }
            #expect(f.minX >= rect.minX - 0.5 && f.maxX <= rect.maxX + 0.5,
                    "\(context): \(id) x-range \(f.minX)–\(f.maxX) outside \(rect.minX)–\(rect.maxX)")
            #expect(f.minY >= rect.minY - 0.5 && f.maxY <= rect.maxY + 0.5,
                    "\(context): \(id) y-range \(f.minY)–\(f.maxY) outside \(rect.minY)–\(rect.maxY)")
        }
    }

    @Test func emptyWorkspaceSolvesToNothing() {
        let s = Workspace(id: 1)
        let result = Solver.solve(workspace: s, in: screen)
        #expect(result.placements.isEmpty)
        #expect(result.raiseOrder.isEmpty)
        #expect(result.focused == nil)
    }

    @Test func zeroSizeRectYieldsFiniteFramesInsideIt() {
        let s = Workspace(id: 1)
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        let rect = CGRect(x: 100, y: 50, width: 0, height: 0)
        let result = Solver.solve(workspace: s, in: rect)
        #expect(result.placements.count == 3)
        expectSane(result, within: rect, context: "zero-size rect")
    }

    @Test func nullRectYieldsFiniteFrames() {
        // CGRect.null (origin at +inf) can reach the solver during display
        // teardown races. Frames must stay finite: an infinite frame written
        // to AX strands the window somewhere no rescue can see.
        //
        // The solver refuses a non-finite rect outright rather than inventing
        // geometry for it: `TilingEngine.applyDisplay` writes a frame only for
        // windows that appear in `placements`, so emitting none leaves every
        // window exactly where it is — the safe degradation. Producing three
        // finite-but-meaningless frames (all at the origin, say) would instead
        // pile the workspace into a corner.
        let s = Workspace(id: 1)
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        for rect in [CGRect.null, .infinite] {
            let result = Solver.solve(workspace: s, in: rect)
            #expect(result.placements.isEmpty, "\(rect) should solve to nothing")
            for (id, p) in result.placements {
                #expect(p.frame.isFinite, "non-finite frame \(p.frame) for \(id)")
            }
        }
    }

    @Test func gapsLargerThanTheDisplayStayInside() {
        let s = Workspace(id: 1)
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let config = LayoutConfig(innerGap: 60, outerGap: 60)
        let result = Solver.solve(workspace: s, in: rect, config: config)
        #expect(result.placements.count == 3)
        expectSane(result, within: rect, context: "oversized gaps")
    }

    @Test func threeWindowsInATwoPointRectStayInside() {
        // The accordion case that used to emit a zero-width frame at an
        // origin outside the rect: padding exceeded the rect and the focused
        // length went negative, standardizing into an out-of-rect frame.
        let s = Workspace(id: 1)
        for w in [w1, w2, w3] { s.insertTiled(w) }
        s.normalize()
        s.cycleLayout(w1) // accordion
        s.focus(w2)
        let rect = CGRect(x: 10, y: 10, width: 2, height: 300)
        let result = Solver.solve(workspace: s, in: rect)
        #expect(result.placements.count == 3)
        expectSane(result, within: rect, context: "2pt accordion")
    }
}

@Suite("Coordinate conversion")
struct CoordinateTests {
    @Test func cocoaRoundTrip() {
        // Primary display 1600×1000 in Cocoa space; a secondary display below.
        let primaryHeight: CGFloat = 1000
        let cocoa = CGRect(x: 100, y: 200, width: 800, height: 500)
        let global = cocoaToGlobal(cocoa, primaryDisplayHeight: primaryHeight)
        #expect(global == CGRect(x: 100, y: 300, width: 800, height: 500))
        #expect(globalToCocoa(global, primaryDisplayHeight: primaryHeight) == cocoa)
    }
}

@Suite("Solver — degenerate rects are refused, not laid out")
struct SolverDegenerateRectTests {

    /// `.null` is rejected by the finiteness clause alone; `.infinite` is
    /// not, because its components are ±greatestFiniteMagnitude. Both must
    /// still produce no placements — this pins the reason the guard has two
    /// clauses rather than three.
    @Test(arguments: [CGRect.null, CGRect.infinite])
    func degenerateWorkspaceRectsProduceNoPlacements(_ rect: CGRect) {
        let ws = Workspace(id: 1)
        ws.insertTiled(w1)
        ws.insertTiled(w2)
        #expect(Solver.solve(workspace: ws, in: rect).placements.isEmpty)
    }

    @Test func nullIsAlreadyCaughtByFiniteness() {
        #expect(!CGRect.null.isFinite, "isFinite must reject .null, or the guard needs !isNull back")
        #expect(CGRect.infinite.isFinite, "the !isInfinite clause exists precisely because this is true")
    }
}
