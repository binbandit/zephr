import Testing
import Foundation
import CoreGraphics
@testable import ZephrCore

private let d1 = DisplayID(1), d2 = DisplayID(2)
private let w1 = WindowID(1), w2 = WindowID(2), w3 = WindowID(3)

@Suite("Workspace model")
struct ModelTests {
    private func model(displays: [DisplayID] = [d1]) -> WorkspaceModel {
        let m = WorkspaceModel()
        m.syncDisplays(displays)
        return m
    }

    @Test func firstDisplayGetsWorkspaceOne() {
        let m = model()
        #expect(m.activeWorkspace(on: d1).id == 1)
        #expect(m.focusedDisplay == d1)
    }

    @Test func secondDisplayGetsItsOwnWorkspace() {
        let m = model(displays: [d1, d2])
        let a = m.activeWorkspace(on: d1).id
        let b = m.activeWorkspace(on: d2).id
        #expect(a != b)
    }

    @Test func insertLandsInFocusedWorkspace() {
        let m = model()
        m.insertWindow(w1)
        #expect(m.workspace(containing: w1)?.id == 1)
        #expect(m.focusedWindow == w1)
    }

    @Test func moveToWorkspaceKeepsFocusInSource() {
        let m = model()
        m.insertWindow(w1)
        m.insertWindow(w2)
        #expect(m.moveWindow(w2, toWorkspace: 3))
        #expect(m.workspace(containing: w2)?.id == 3)
        // Focus fell back to w1 in the source workspace.
        #expect(m.focusedWindow == w1)
        // Workspace 3 will focus w2 when activated.
        #expect(m.workspace(3).focusedWindow == w2)
    }

    @Test func activateSwitchesAndReturnsAffected() {
        let m = model()
        m.insertWindow(w1)
        let affected = m.activateWorkspace(2)
        #expect(affected == [d1])
        #expect(m.focusedWorkspace?.id == 2)
    }

    @Test func repressingCurrentWorkspaceBouncesBack() {
        let m = model()
        _ = m.activateWorkspace(2)
        _ = m.activateWorkspace(5)
        // Re-press 5 → back to 2; re-press again → back to 5.
        #expect(m.activateWorkspace(5) == [d1])
        #expect(m.focusedWorkspace?.id == 2)
        #expect(m.activateWorkspace(2) == [d1])
        #expect(m.focusedWorkspace?.id == 5)
    }

    @Test func noBounceWithoutHistory() {
        let m = model()
        // Workspace 1 active from the start, nothing to bounce back to.
        #expect(m.activateWorkspace(1).isEmpty)
        #expect(m.focusedWorkspace?.id == 1)
    }

    @Test func activateJumpsToWorkspaceHomeDisplay() {
        let m = model(displays: [d1, d2])
        _ = m.activeWorkspace(on: d1)
        let wsB = m.activeWorkspace(on: d2)
        m.focusedDisplay = d1
        let affected = m.activateWorkspace(wsB.id)
        // Workspace lives on d2: focus jumps, nothing re-renders.
        #expect(affected.isEmpty)
        #expect(m.focusedDisplay == d2)
    }

    @Test func displayVanishesWorkspacesMigrate() {
        let m = model(displays: [d1, d2])
        _ = m.activeWorkspace(on: d2)
        m.focusedDisplay = d2
        m.insertWindow(w1)
        let wsID = m.workspace(containing: w1)!.id

        m.syncDisplays([d1])
        #expect(m.workspace(wsID).homeDisplay == d1)
        #expect(m.focusedDisplay == d1)
        // Window is still reachable.
        #expect(m.workspace(containing: w1) != nil)
    }

    @Test func rescueGathersEverything() throws {
        let m = model()
        m.insertWindow(w1)
        _ = m.activateWorkspace(2)
        m.insertWindow(w2)
        _ = m.activateWorkspace(3)
        m.insertWindow(w3)
        m.rescueAllWindows(into: 3)
        for w in [w1, w2, w3] {
            #expect(m.workspace(containing: w)?.id == 3)
        }
        // The sources are drained, the target holds everything, and the
        // invariants hold on the recovery path (§4.4, invariant 1).
        #expect(m.workspace(1).isEmpty)
        #expect(m.workspace(2).isEmpty)
        #expect(Set(m.workspace(3).allWindows) == [w1, w2, w3])
        try m.workspace(3).validate()
    }

    @Test func removeWindowClearsIndex() {
        let m = model()
        m.insertWindow(w1)
        #expect(m.removeWindow(w1))
        #expect(m.workspace(containing: w1) == nil)
        #expect(!m.removeWindow(w1))
    }
}

@Suite("Rules")
struct RuleTests {
    @Test func userRulesWinOverBuiltins() {
        var rules = RuleSet()
        rules.userRules = [WindowRule(bundleID: "com.apple.systempreferences", action: .tile)]
        #expect(rules.action(bundleID: "com.apple.systempreferences", title: "General") == .tile)
    }

    @Test func titlePatternMustMatch() {
        let rules = RuleSet()
        #expect(rules.action(bundleID: "us.zoom.xos", title: "zoom floating video") == .float)
        #expect(rules.action(bundleID: "us.zoom.xos", title: "Zoom Meeting") == nil)
    }

    @Test func launchersAreIgnored() {
        let rules = RuleSet()
        #expect(rules.action(bundleID: "com.raycast.macos", title: "Raycast") == .ignore)
        #expect(rules.action(bundleID: "com.apple.dock", title: nil) == .ignore)
    }

    @Test func unknownAppHasNoRule() {
        let rules = RuleSet()
        #expect(rules.action(bundleID: "com.example.someapp", title: "Window") == nil)
    }

    @Test func catastrophicBacktrackingPatternStaysWithinTimeBudget() {
        // `^(a+)+$` against a long run of `a` plus a non-matching tail is the
        // classic exponential-backtracking bomb: ~2^46 steps if the matcher
        // runs unbounded, i.e. an implementation without the §6.3 time budget
        // hangs here for years rather than failing an assertion. The budget
        // degrades it to "no match" within 50 ms; the elapsed bound is
        // generous so a loaded CI machine can't flake this test.
        let rule = WindowRule(bundleID: "com.example.evil", titlePattern: "^(a+)+$", action: .float)
        let title = String(repeating: "a", count: 46) + "!"
        let start = Date()
        let matched = rule.matchesTitle(title)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!matched)
        #expect(elapsed < 2.0, "pathological pattern took \(elapsed)s — the time budget is not working")
        // Sanity: the budget must not break ordinary matching.
        #expect(rule.matchesTitle(String(repeating: "a", count: 40)))
    }
}

@Suite("Stash planner")
struct StashTests {
    private let laptop = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let external = CGRect(x: 1600, y: -400, width: 2560, height: 1440)
    private let win = CGRect(x: 200, y: 200, width: 900, height: 700)

    @Test func singleDisplayStashesBelow() {
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop])
        // Sliver-visible at the bottom edge; body below the display. The
        // literal pins sliver > 0: a zero sliver parks the window fully
        // off-screen, where macOS may kill it (window-loss, invariant 1).
        #expect(StashPlanner.sliver > 0)
        #expect(f.minY == 999)
        #expect(f.minY < 1000)
        #expect(StashPlanner.looksStashed(f, displays: [laptop]))
    }

    @Test func sideBySideAvoidsTheNeighbor() {
        // External sits to the right of the laptop: the stash frame must not
        // splash onto it. Displays are disjoint, so any intersection with a
        // neighboring display is an off-screen collision.
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop, external])
        #expect(!f.intersects(external))
        #expect(StashPlanner.looksStashed(f, displays: [laptop, external]))
    }

    @Test func externalDisplayStashesAwayFromLaptop() {
        let f = StashPlanner.stashFrame(for: win, on: external, allDisplays: [laptop, external])
        #expect(!f.intersects(laptop))
        #expect(StashPlanner.looksStashed(f, displays: [laptop, external]))
    }

    @Test func stackedArrangementUsesSides() {
        // A display directly below the laptop blocks the south candidate.
        let below = CGRect(x: 0, y: 1000, width: 1600, height: 1000)
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop, below])
        #expect(!f.intersects(below))
        #expect(StashPlanner.looksStashed(f, displays: [laptop, below]))
    }

    @Test func oversizedWindowProtrudingPastTwoEdgesAvoidsAllNeighbors() {
        // A window larger than its display protrudes past *two* edges of any
        // stash candidate — the case the old single-edge protrusion check
        // (`subtracting`) got wrong. With neighbors east and south, the
        // planner must reject both collided candidates and park it west.
        let right = CGRect(x: 1600, y: 0, width: 1000, height: 1000)
        let below = CGRect(x: 0, y: 1000, width: 1600, height: 1000)
        let big = CGRect(x: 200, y: 100, width: 1800, height: 900)
        let f = StashPlanner.stashFrame(for: big, on: laptop, allDisplays: [laptop, right, below])
        #expect(!f.intersects(right))
        #expect(!f.intersects(below))
        #expect(f.size == big.size)
        #expect(StashPlanner.looksStashed(f, displays: [laptop, right, below]))
    }

    @Test func stashPreservesWindowSize() {
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop])
        #expect(f.size == win.size)
    }

    @Test func visibleFrameDoesNotLookStashed() {
        #expect(!StashPlanner.looksStashed(win, displays: [laptop]))
    }
}

@Suite("Stash placement hides windows in a corner")
struct StashCornerTests {

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    /// The bug this replaced: a window pushed straight down left a
    /// full-width strip visible along the bottom of the screen. macOS
    /// clamps vertical displacement to keep a title bar reachable, so the
    /// stash has to move the window off *sideways* as well.
    @Test func aStashedWindowIsPushedOffHorizontally() {
        let window = CGRect(x: 8, y: 47, width: 884, height: 1025)
        let stashed = StashPlanner.stashFrame(for: window, on: display, allDisplays: [display])
        #expect(stashed.minX >= display.maxX - StashPlanner.sliver
                || stashed.maxX <= display.minX + StashPlanner.sliver,
                "stash must leave the display horizontally, not only downwards")
    }

    /// Whatever corner is chosen, almost none of the window may remain on
    /// the display — and `looksStashed` must agree, since crash recovery
    /// uses it to decide what to rescue.
    @Test(arguments: [
        CGRect(x: 8, y: 47, width: 884, height: 1025),
        CGRect(x: 900, y: 47, width: 442, height: 1025),
        CGRect(x: 0, y: 0, width: 1800, height: 1169),   // full-screen window
        CGRect(x: 0, y: 0, width: 200, height: 120),     // small window
    ])
    func almostNothingOfAStashedWindowStaysOnScreen(_ window: CGRect) {
        let stashed = StashPlanner.stashFrame(for: window, on: display, allDisplays: [display])
        let onScreen = stashed.intersection(display)
        let visible = onScreen.isNull ? 0 : onScreen.width * onScreen.height
        #expect(visible <= StashPlanner.sliver * StashPlanner.sliver + 0.01,
                "\(visible)pt² of \(window.size) still visible at \(stashed.origin)")
        #expect(StashPlanner.looksStashed(stashed, displays: [display]))
    }

    /// Even if macOS clamps the vertical part of the move back onto the
    /// display, the horizontal displacement alone must keep the window
    /// essentially invisible — that is what makes the corner robust.
    @Test func aClampedVerticalMoveStillHidesTheWindow() {
        let window = CGRect(x: 8, y: 47, width: 884, height: 1025)
        let stashed = StashPlanner.stashFrame(for: window, on: display, allDisplays: [display])
        // Simulate the OS refusing to move it below the display at all.
        let clamped = CGRect(x: stashed.minX, y: 47, width: stashed.width, height: stashed.height)
        let onScreen = clamped.intersection(display)
        let visible = onScreen.isNull ? 0 : onScreen.width * onScreen.height
        #expect(visible <= StashPlanner.sliver * display.height + 0.01,
                "a vertically-clamped stash still showed \(visible)pt²")
    }
}

@Suite("Stash placement in awkward monitor arrangements")
struct StashArrangementTests {

    private func visibleArea(_ frame: CGRect, on displays: [CGRect]) -> CGFloat {
        displays.reduce(0) { $0 + frame.intersection($1).area }
    }

    /// A display flanked on both sides has no corner that spills nowhere.
    /// Rejecting every candidate that overlaps and falling back to a corner
    /// *inside* the display left the window almost entirely visible on the
    /// neighbour; ranking by spill keeps the near-miss answer instead.
    @Test func aDisplayFlankedOnBothSidesPicksTheLeastBadCorner() {
        let left = CGRect(x: -1800, y: 0, width: 1800, height: 1169)
        let middle = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let right = CGRect(x: 1800, y: 0, width: 1800, height: 1169)
        let all = [left, middle, right]
        let window = CGRect(x: 8, y: 47, width: 884, height: 1025)

        let stashed = StashPlanner.stashFrame(for: window, on: middle, allDisplays: all)
        let visible = visibleArea(stashed, on: all)
        #expect(visible < window.width * window.height * 0.05,
                "\(visible)pt² of the window stayed visible somewhere")
        #expect(StashPlanner.looksStashed(stashed, displays: all))
    }

    /// Three in a row: the middle display is the hard one, the outer two
    /// each have a free side and must still be hidden essentially perfectly.
    @Test(arguments: [0, 1, 2])
    func everyDisplayInARowCanStash(_ index: Int) {
        let all = (0..<3).map { CGRect(x: CGFloat($0) * 1800, y: 0, width: 1800, height: 1169) }
        let display = all[index]
        let window = CGRect(x: display.minX + 8, y: 47, width: 884, height: 1025)
        let stashed = StashPlanner.stashFrame(for: window, on: display, allDisplays: all)
        let visible = visibleArea(stashed, on: all)
        #expect(visible < window.width * window.height * 0.05,
                "display \(index): \(visible)pt² still visible")
    }

    /// A stack of displays has no free side, only free top and bottom — the
    /// arrangement AeroSpace's two-bottom-corners model cannot express.
    @Test func aVerticalStackStillFindsSpace() {
        let all = (0..<3).map { CGRect(x: 0, y: CGFloat($0) * 1169, width: 1800, height: 1169) }
        let display = all[1]
        let window = CGRect(x: 8, y: display.minY + 8, width: 884, height: 1025)
        let stashed = StashPlanner.stashFrame(for: window, on: display, allDisplays: all)
        let visible = visibleArea(stashed, on: all)
        #expect(visible < window.width * window.height * 0.05,
                "\(visible)pt² still visible in a vertical stack")
    }
}
