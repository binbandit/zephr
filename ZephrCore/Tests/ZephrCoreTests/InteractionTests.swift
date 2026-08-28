import Testing
import CoreGraphics
@testable import ZephrCore

private let w1 = WindowID(1), w2 = WindowID(2), w3 = WindowID(3)
private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

@Suite("Mouse interactions: gap drag-resize and drop re-tile")
struct InteractionTests {

    @Test func dragResizeConvertsPixelsToRatio() {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        _ = Solver.solve(workspace: s, in: screen, config: LayoutConfig(innerGap: 0, outerGap: 0))
        // Drag the shared boundary 160 px right: 0.5 → 0.6 / 0.4.
        #expect(s.dragResize(w1, direction: .right, deltaPixels: 160, minRatio: 0.05))
        let ratios = s.root.children.map(\.ratio)
        #expect(abs(ratios[0] - 0.6) < 0.01)
        #expect(abs(ratios[1] - 0.4) < 0.01)
    }

    @Test func dragResizeFailsAtWorkspaceEdge() {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        _ = Solver.solve(workspace: s, in: screen)
        #expect(!s.dragResize(w1, direction: .left, deltaPixels: 50, minRatio: 0.05))
        #expect(!s.dragResize(w1, direction: .down, deltaPixels: 50, minRatio: 0.05))
    }

    @Test(arguments: Direction.allCases)
    func retilePlacesOnTheDroppedEdge(edge: Direction) throws {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        s.insertTiled(w2)
        s.normalize()
        _ = Solver.solve(workspace: s, in: screen)
        s.insertFloating(w3, frame: CGRect(x: 10, y: 10, width: 400, height: 300))

        #expect(s.retile(w3, at: w2, edge: edge))
        try s.validate()
        #expect(!s.isFloating(w3))
        // w3 must now be w2's neighbor on that edge.
        #expect(s.neighbor(of: w2, direction: edge) == w3, "\(edge)")
        #expect(s.focusedWindow == w3)
    }

    @Test func retileRequiresFloatingSource() {
        let s = Workspace(id: 1)
        s.insertTiled(w1)
        s.insertTiled(w2)
        #expect(!s.retile(w1, at: w2, edge: .right))
    }
}

@Suite("AeroSpace importer")
struct AeroSpaceImportTests {

    @Test func importsGapsAndRules() {
        let result = AeroSpaceImport.parse("""
        start-at-login = true

        [gaps]
        inner.horizontal = 10
        inner.vertical = 10

        [mode.main.binding]
        alt-h = 'focus left'
        alt-l = 'focus right'
        alt-shift-h = 'move left'

        [[on-window-detected]]
        if.app-id = 'com.apple.systempreferences'
        run = 'layout floating'

        [[on-window-detected]]
        if.app-id = 'us.zoom.xos'
        if.window-title-regex-substring = 'zoom floating'
        run = ['layout floating']

        [[on-window-detected]]
        if.app-id = 'com.example.mail'
        run = ['move-node-to-workspace 3']
        """)

        #expect(result.innerGaps == 10)
        #expect(result.rules.count == 2)
        #expect(result.rules[0] == WindowRule(bundleID: "com.apple.systempreferences", action: .float))
        #expect(result.rules[1].bundleID == "us.zoom.xos")
        #expect(result.rules[1].action == .float)
        // Unmappables are reported, not dropped silently.
        #expect(result.skipped.contains { $0.contains("com.example.mail") })
        #expect(result.skipped.contains { $0.contains("3 keybindings") })
        #expect(!result.report.isEmpty)
    }

    @Test func emptyConfigReportsNothingFound() {
        let result = AeroSpaceImport.parse("")
        #expect(result.rules.isEmpty)
        #expect(result.report.contains("Nothing"))
    }

    @Test func quotedAppIDWithTrailingCommentImportsACleanBundleID() {
        // A double-quoted id with a trailing comment used to import with the
        // quote/comment garbage attached — a rule written into the user's
        // config that can never match, reported as a success (§4.7).
        let result = AeroSpaceImport.parse("""
        [[on-window-detected]]
        if.app-id = "com.apple.systempreferences" # keep Settings floating
        run = "layout floating"

        [[on-window-detected]]
        if.app-id = 'com.example.picker' # single-quoted with comment
        run = 'layout floating'
        """)
        #expect(result.rules == [
            WindowRule(bundleID: "com.apple.systempreferences", action: .float),
            WindowRule(bundleID: "com.example.picker", action: .float),
        ])
        #expect(result.skipped.isEmpty)
    }

    @Test func emptyAppIDIsSkippedAndReported() {
        let result = AeroSpaceImport.parse("""
        [[on-window-detected]]
        if.app-id = ""
        run = "layout floating"
        """)
        #expect(result.rules.isEmpty)
        #expect(result.skipped.contains { $0.contains("app-id") })
        #expect(result.imported.isEmpty)
    }

    @Test func zeroGapsImportAsZeroNotDropped() {
        // 0 is meaningful — flush tiling must import as flush tiling, not as
        // "no gap setting found".
        let result = AeroSpaceImport.parse("""
        [gaps]
        inner.horizontal = 0
        outer.left = 0
        """)
        #expect(result.innerGaps == 0)
        #expect(result.outerGaps == 0)
        #expect(result.imported.contains { $0.contains("inner gaps = 0") })
        #expect(result.imported.contains { $0.contains("outer gaps = 0") })
    }
}
