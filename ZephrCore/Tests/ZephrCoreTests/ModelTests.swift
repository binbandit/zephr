import Testing
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

    @Test func rescueGathersEverything() {
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
        try? m.workspace(3).validate()
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
}

@Suite("Stash planner")
struct StashTests {
    private let laptop = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let external = CGRect(x: 1600, y: -400, width: 2560, height: 1440)
    private let win = CGRect(x: 200, y: 200, width: 900, height: 700)

    @Test func singleDisplayStashesBelow() {
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop])
        // Sliver-visible at the bottom edge; body below the display.
        #expect(f.minY == 1000 - StashPlanner.sliver)
        #expect(StashPlanner.looksStashed(f, displays: [laptop]))
    }

    @Test func sideBySideAvoidsTheNeighbor() {
        // External sits to the right of the laptop: stash must not splash onto it.
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop, external])
        let offScreen = f.subtracting(laptop)
        #expect(!offScreen.intersects(external))
        #expect(StashPlanner.looksStashed(f, displays: [laptop, external]))
    }

    @Test func externalDisplayStashesAwayFromLaptop() {
        let f = StashPlanner.stashFrame(for: win, on: external, allDisplays: [laptop, external])
        let offScreen = f.subtracting(external)
        #expect(!offScreen.intersects(laptop))
        #expect(StashPlanner.looksStashed(f, displays: [laptop, external]))
    }

    @Test func stackedArrangementUsesSides() {
        // A display directly below the laptop blocks the south candidate.
        let below = CGRect(x: 0, y: 1000, width: 1600, height: 1000)
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop, below])
        let offScreen = f.subtracting(laptop)
        #expect(!offScreen.intersects(below))
    }

    @Test func stashPreservesWindowSize() {
        let f = StashPlanner.stashFrame(for: win, on: laptop, allDisplays: [laptop])
        #expect(f.size == win.size)
    }

    @Test func visibleFrameDoesNotLookStashed() {
        #expect(!StashPlanner.looksStashed(win, displays: [laptop]))
    }
}
