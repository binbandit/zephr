import Testing
import CoreGraphics
@testable import ZephrCore

/// Deterministic RNG so failures reproduce (SplitMix64).
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite("Property: random command sequences preserve invariants")
struct PropertyTests {

    @Test(arguments: [UInt64(1), 7, 42, 1337, 99999])
    func randomOperationStorm(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let model = WorkspaceModel()
        let d1 = DisplayID(1), d2 = DisplayID(2)
        model.syncDisplays([d1, d2])

        let rect1 = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let rect2 = CGRect(x: 1600, y: 0, width: 2560, height: 1440)
        var nextWindow: UInt64 = 1
        var live: [WindowID] = []

        func solveAll() {
            for d in [d1, d2] {
                let ws = model.activeWorkspace(on: d)
                _ = Solver.solve(workspace: ws, in: d == d1 ? rect1 : rect2)
            }
        }

        func validateAll() throws {
            for ws in model.workspaces.values {
                try ws.validate()
            }
            // Bijection, both directions: every live window is in exactly one
            // workspace, and no workspace holds a window that isn't live — a
            // phantom node left behind by a buggy remove would otherwise be
            // invisible here (invariant 1 cuts both ways: a ghost entry makes
            // the engine fight over a window that no longer exists).
            #expect(
                Set(model.workspaces.values.flatMap(\.allWindows)) == Set(live),
                "model window contents diverge from live set (seed \(seed))"
            )
            for w in live {
                let holders = model.workspaces.values.filter { $0.contains(w) }
                #expect(holders.count == 1, "window \(w) in \(holders.count) workspaces (seed \(seed))")
            }
            // Solver yields exactly one frame per window in the active workspaces.
            for d in [d1, d2] {
                let ws = model.activeWorkspace(on: d)
                let result = Solver.solve(workspace: ws, in: d == d1 ? rect1 : rect2)
                for w in ws.allWindows {
                    #expect(result.placements[w] != nil, "no placement for \(w) (seed \(seed))")
                }
                #expect(result.placements.count == ws.allWindows.count)
            }
        }

        // Mixed insert geometry so the split-orientation heuristic's portrait
        // branch (and its degenerate-frame guard) run during the storm, not
        // just the landscape default.
        let insertFrames = [
            CGRect(x: 100, y: 100, width: 600, height: 400),  // landscape
            CGRect(x: 200, y: 50, width: 300, height: 800),   // portrait
            CGRect(x: 0, y: 0, width: 500, height: 500),      // square
            CGRect(x: 40, y: 40, width: 0, height: 0),        // degenerate
            CGRect(x: -50, y: 2000, width: 1, height: 900),   // sliver, off-display
        ]

        // Mutating calls must actually mutate: a build where move/resize/
        // toggleFloat all return early still "preserves invariants", so the
        // storm also proves a meaningful fraction of operations succeed.
        var succeeded = 0
        var attempted = 0

        for _ in 0..<1200 {
            let op = Int.random(in: 0..<100, using: &rng)
            switch op {
            case 0..<22: // insert
                let id = WindowID(nextWindow); nextWindow += 1
                let floating = Int.random(in: 0..<10, using: &rng) == 0
                attempted += 1
                model.insertWindow(id, floating: floating,
                                   frame: insertFrames.randomElement(using: &rng)!)
                live.append(id)
                #expect(model.workspace(containing: id) != nil, "insert dropped \(id) (seed \(seed))")
                succeeded += 1
            case 22..<34: // remove
                if let id = live.randomElement(using: &rng) {
                    attempted += 1
                    if model.removeWindow(id) { succeeded += 1 }
                    live.removeAll { $0 == id }
                }
            case 34..<50: // move directionally
                if let id = live.randomElement(using: &rng),
                   let dir = Direction.allCases.randomElement(using: &rng),
                   let ws = model.workspace(containing: id) {
                    attempted += 1
                    if ws.move(id, direction: dir) == .moved { succeeded += 1 }
                }
            case 50..<60: // focus a random window
                if let id = live.randomElement(using: &rng) {
                    model.noteFocused(id)
                }
            case 60..<68: // focus neighbor
                if let ws = model.focusedWorkspace, let f = ws.focusedWindow,
                   let dir = Direction.allCases.randomElement(using: &rng),
                   let n = ws.neighbor(of: f, direction: dir) {
                    ws.focus(n)
                }
            case 68..<76: // resize
                if let id = live.randomElement(using: &rng),
                   let dir = Direction.allCases.randomElement(using: &rng),
                   let ws = model.workspace(containing: id) {
                    attempted += 1
                    if ws.resize(id, direction: dir, delta: 0.05, minRatio: 0.05) { succeeded += 1 }
                }
            case 76..<82: // toggle float
                if let id = live.randomElement(using: &rng),
                   let ws = model.workspace(containing: id) {
                    attempted += 1
                    if ws.toggleFloat(id, defaultFrame: CGRect(x: 50, y: 50, width: 500, height: 400)) != nil {
                        succeeded += 1
                    }
                }
            case 82..<88: // send to workspace
                if let id = live.randomElement(using: &rng) {
                    attempted += 1
                    if model.moveWindow(id, toWorkspace: Int.random(in: 1...9, using: &rng)) {
                        succeeded += 1
                    }
                }
            case 88..<94: // switch workspace
                _ = model.activateWorkspace(Int.random(in: 1...9, using: &rng))
            case 94..<96: // preselect
                if let ws = model.focusedWorkspace {
                    ws.setPreselect(Bool.random(using: &rng) ? .horizontal : .vertical)
                }
            case 96..<98: // cycle layout / monocle
                if let ws = model.focusedWorkspace {
                    if let f = ws.focusedWindow, Bool.random(using: &rng) {
                        ws.cycleLayout(f)
                    } else {
                        ws.toggleMonocle()
                    }
                }
            default: // display churn: unplug/replug the second display
                if Bool.random(using: &rng) {
                    model.syncDisplays([d1])
                } else {
                    model.syncDisplays([d1, d2])
                }
            }

            solveAll()
            // Validate every step: corruption must be reported at the
            // operation that caused it, not up to 49 operations later.
            try validateAll()
        }

        // ~700 of 1200 steps attempt a mutation; the storm is degenerate if
        // most of them no-op. The floor is far below the observed ~85% so a
        // distribution shift can't flake it, while a mass-early-return build
        // still fails loudly.
        #expect(attempted > 500, "only \(attempted) mutating attempts (seed \(seed))")
        #expect(succeeded * 2 > attempted,
                "only \(succeeded)/\(attempted) mutating operations took effect (seed \(seed))")

        // Grand finale: the rescue command reaches every window (§4.4).
        model.syncDisplays([d1, d2])
        if let current = model.focusedWorkspace?.id {
            model.rescueAllWindows(into: current)
            for w in live {
                #expect(model.workspace(containing: w)?.id == current)
            }
            try validateAll()
        }
    }
}
