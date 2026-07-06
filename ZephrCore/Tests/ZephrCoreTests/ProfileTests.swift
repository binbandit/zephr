import Testing
import Foundation
import CoreGraphics
@testable import ZephrCore

@Suite("Display profiles and session restore")
struct ProfileTests {

    private let d1 = DisplayID(1), d2 = DisplayID(2)
    private var slots2: [DisplaySlot] {
        [
            DisplaySlot(id: d1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
            DisplaySlot(id: d2, frame: CGRect(x: 1600, y: -400, width: 2560, height: 1440)),
        ]
    }

    private func meta(_ id: WindowID) -> WindowFingerprint {
        WindowFingerprint(bundleID: "app.\(id.raw % 3)", title: "window \(id.raw)")
    }

    /// A model with 6 windows over 3 workspaces on 2 displays, custom ratios,
    /// one float, one accordion container.
    private func populatedModel() -> (WorkspaceModel, [WindowID]) {
        let m = WorkspaceModel()
        m.syncDisplays([d1, d2])
        var ids: [WindowID] = []
        for raw in 1...6 { ids.append(WindowID(UInt64(raw))) }

        m.focusDisplay(d1)
        m.insertWindow(ids[0])
        m.insertWindow(ids[1])
        _ = m.workspace(containing: ids[0])!.resize(ids[0], direction: .right, delta: 0.15, minRatio: 0.05)

        _ = m.activateWorkspace(3)
        m.insertWindow(ids[2])
        m.insertWindow(ids[3], floating: true, frame: CGRect(x: 300, y: 200, width: 640, height: 480))
        m.workspace(3).cycleLayout(ids[2])

        m.focusDisplay(d2)
        let wsB = m.activeWorkspace(on: d2)
        m.insertWindow(ids[4], workspace: wsB.id)
        m.insertWindow(ids[5], workspace: wsB.id)
        return (m, ids)
    }

    @Test func fingerprintIsOrderIndependentAndIDFree() {
        let a = ProfileEngine.fingerprint(slots2)
        let b = ProfileEngine.fingerprint(slots2.reversed())
        let c = ProfileEngine.fingerprint([
            DisplaySlot(id: DisplayID(99), frame: slots2[0].frame),
            DisplaySlot(id: DisplayID(42), frame: slots2[1].frame),
        ])
        #expect(a == b)
        #expect(a == c) // IDs churn across reboots; geometry is the identity
    }

    @Test func captureApplyRoundTripsOnFreshModel() throws {
        let (original, ids) = populatedModel()
        let snapshot = ProfileEngine.capture(model: original, slots: slots2, meta: meta)

        // Simulate a new session: fresh model, new window identities (+100),
        // same apps and titles.
        let fresh = WorkspaceModel()
        fresh.syncDisplays([d1, d2])
        var live: [WindowID: WindowFingerprint] = [:]
        for id in ids {
            live[WindowID(id.raw + 100)] = meta(id)
        }
        let unplaced = ProfileEngine.apply(snapshot, to: fresh, slots: slots2, live: live)
        #expect(unplaced.isEmpty)

        for ws in fresh.workspaces.values { try ws.validate() }

        // Same workspace populations (by fingerprint).
        for id in ids {
            let originalWS = original.workspace(containing: id)!.id
            let newID = WindowID(id.raw + 100)
            #expect(fresh.workspace(containing: newID)?.id == originalWS, "\(id)")
        }
        // Ratios survive.
        let ws1 = fresh.workspace(containing: WindowID(101))!
        let ratios = ws1.root.children.map(\.ratio)
        #expect(abs(ratios[0] - 0.65) < 0.01)
        // Float frame survives.
        #expect(fresh.workspace(3).floating[WindowID(104)] == CGRect(x: 300, y: 200, width: 640, height: 480))
        // Accordion layout survives.
        #expect(fresh.workspace(3).node(for: WindowID(103))?.parent?.layout == .accordion)
        // Active workspace per display survives.
        #expect(fresh.activeWorkspaceByDisplay[d1] == original.activeWorkspaceByDisplay[d1])
        #expect(fresh.activeWorkspaceByDisplay[d2] == original.activeWorkspaceByDisplay[d2])
    }

    @Test func undockRedockRestoresExactly() throws {
        let (model, ids) = populatedModel()
        let profile = ProfileEngine.capture(model: model, slots: slots2, meta: meta)
        let homesBefore = model.workspaces.mapValues(\.homeDisplay)

        // Undock: everything migrates to the laptop display.
        model.syncDisplays([d1])
        for ws in model.workspaces.values {
            #expect(ws.homeDisplay == d1)
        }

        // Redock: apply the recorded profile — same session, same IDs.
        var live: [WindowID: WindowFingerprint] = [:]
        for id in ids { live[id] = meta(id) }
        let unplaced = ProfileEngine.apply(profile, to: model, slots: slots2, live: live)
        #expect(unplaced.isEmpty)

        for (wsID, home) in homesBefore where model.workspaces[wsID] != nil {
            #expect(model.workspace(wsID).homeDisplay == home, "workspace \(wsID)")
        }
        for ws in model.workspaces.values { try ws.validate() }
    }

    @Test func windowsWithoutRecordsComeBackUnplaced() {
        let (model, ids) = populatedModel()
        let snapshot = ProfileEngine.capture(model: model, slots: slots2, meta: meta)

        let fresh = WorkspaceModel()
        fresh.syncDisplays([d1, d2])
        var live: [WindowID: WindowFingerprint] = [:]
        for id in ids { live[WindowID(id.raw + 100)] = meta(id) }
        let stranger = WindowID(999)
        live[stranger] = WindowFingerprint(bundleID: "app.new", title: "Untracked")

        let unplaced = ProfileEngine.apply(snapshot, to: fresh, slots: slots2, live: live)
        #expect(unplaced == [stranger])
    }

    @Test func titleDriftFallsBackToBundleMatch() {
        let (model, ids) = populatedModel()
        let snapshot = ProfileEngine.capture(model: model, slots: slots2, meta: meta)

        let fresh = WorkspaceModel()
        fresh.syncDisplays([d1, d2])
        var live: [WindowID: WindowFingerprint] = [:]
        for id in ids {
            var fp = meta(id)
            fp.title = "renamed \(id.raw)" // titles changed since the snapshot
            live[WindowID(id.raw + 100)] = fp
        }
        let unplaced = ProfileEngine.apply(snapshot, to: fresh, slots: slots2, live: live)
        // Same bundle ids: everything still finds a slot.
        #expect(unplaced.isEmpty)
    }

    @Test func snapshotSurvivesJSONRoundTrip() throws {
        let (model, _) = populatedModel()
        let snapshot = ProfileEngine.capture(model: model, slots: slots2, meta: meta)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ModelSnapshot.self, from: data)
        #expect(decoded.fingerprint == snapshot.fingerprint)
        #expect(decoded.windows == snapshot.windows)
        #expect(decoded.workspaces.count == snapshot.workspaces.count)
        #expect(decoded.activeBySlot == snapshot.activeBySlot)
    }
}
