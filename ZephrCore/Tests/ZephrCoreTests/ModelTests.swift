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
