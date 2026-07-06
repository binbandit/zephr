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
        _ = s.resize(w1, direction: .right, delta: 0.2, minRatio: 0.05) // 0.7 / 0.3
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
        _ = s.resize(w2, direction: .left, delta: 0.45, minRatio: 0.05)
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
