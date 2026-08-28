import Testing
import Foundation
import CoreGraphics
@testable import ZephrCore

// Deep structural equality for snapshots, so profile tests can assert the
// §4.5 acceptance criterion ("exact workspace, display, position, and split
// ratio … zero deviations") instead of comparing counts. Lives in the test
// target: synthesis isn't available across modules, so `==` is spelled out.
extension NodeSnapshot: Equatable {
    public static func == (l: NodeSnapshot, r: NodeSnapshot) -> Bool {
        l.window == r.window
            && l.orientation == r.orientation
            && l.layout == r.layout
            && l.ratio == r.ratio
            && l.children == r.children
    }
}

extension WorkspaceSnapshot.FloatSnapshot: Equatable {
    public static func == (l: WorkspaceSnapshot.FloatSnapshot, r: WorkspaceSnapshot.FloatSnapshot) -> Bool {
        l.window == r.window && l.frame == r.frame
    }
}

extension WorkspaceSnapshot: Equatable {
    public static func == (l: WorkspaceSnapshot, r: WorkspaceSnapshot) -> Bool {
        l.id == r.id
            && l.name == r.name
            && l.root == r.root
            && l.floats == r.floats
            && l.monocle == r.monocle
            && l.floatByDefault == r.floatByDefault
            && l.homeSlot == r.homeSlot
            && l.focused == r.focused
    }
}

extension ModelSnapshot: Equatable {
    public static func == (l: ModelSnapshot, r: ModelSnapshot) -> Bool {
        l.fingerprint == r.fingerprint
            && l.windows == r.windows
            && l.workspaces == r.workspaces
            && l.activeBySlot == r.activeBySlot
    }
}

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

    @Test func identityFreeFingerprintKeepsItsHistoricalForm() {
        // Slots without an identity must fingerprint exactly as they always
        // have — stored profiles are keyed by this string, and changing the
        // rendering silently orphans every saved profile (§4.5).
        #expect(ProfileEngine.fingerprint(slots2) == "1600x1000@0,0|2560x1440@1600,-400")
        // An empty identity behaves like no identity.
        let blank = slots2.map { DisplaySlot(id: $0.id, frame: $0.frame, identity: "") }
        #expect(ProfileEngine.fingerprint(blank) == ProfileEngine.fingerprint(slots2))
    }

    @Test func identityDistinguishesSameGeometryArrangements() {
        // Two sites with identical geometry but different physical panels
        // (same laptop, a different 1440p at home vs. office) must NOT share
        // a profile — the panel identity is part of the fingerprint (§4.5).
        func slots(_ identities: [String?]) -> [DisplaySlot] {
            zip(slots2, identities).map { DisplaySlot(id: $0.id, frame: $0.frame, identity: $1) }
        }
        let office = ProfileEngine.fingerprint(slots(["panelA", "panelB"]))
        let home = ProfileEngine.fingerprint(slots(["panelA", "panelC"]))
        let anonymous = ProfileEngine.fingerprint(slots2)
        #expect(office != home)
        #expect(office != anonymous)
        // Same identities in either slot order: still one profile.
        let officeAgain = ProfileEngine.fingerprint(slots(["panelA", "panelB"]).reversed())
        #expect(office == officeAgain)
        // The `|` slot separator is sanitized out of identities so an
        // identity can't forge a slot boundary.
        let piped = ProfileEngine.fingerprint(slots(["panel|A", "panelB"]))
        #expect(piped == ProfileEngine.fingerprint(slots(["panel_A", "panelB"])))
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
        // §4.5's acceptance test, verbatim: "every window returns to its
        // exact workspace, display, position, and split ratio; fifty
        // consecutive round-trips, zero deviations."
        let (model, ids) = populatedModel()
        let profile = ProfileEngine.capture(model: model, slots: slots2, meta: meta)
        let homesBefore = model.workspaces.mapValues(\.homeDisplay)
        let membershipBefore = model.windowWorkspace
        let activeBefore = model.activeWorkspaceByDisplay
        let floatFrameBefore = model.workspace(3).floating[ids[3]]

        var live: [WindowID: WindowFingerprint] = [:]
        for id in ids { live[id] = meta(id) }

        for trip in 1...50 {
            // Undock: everything migrates to the laptop display.
            model.syncDisplays([d1])
            for ws in model.workspaces.values {
                #expect(ws.homeDisplay == d1, "trip \(trip)")
            }
            // Work on the laptop screen: switch around, refocus.
            _ = model.activateWorkspace(1)
            if let f = model.workspace(1).allWindows.first { model.noteFocused(f) }
            _ = model.activateWorkspace(3)

            // Redock: apply the recorded profile — same session, same IDs.
            let unplaced = ProfileEngine.apply(profile, to: model, slots: slots2, live: live)
            #expect(unplaced.isEmpty, "trip \(trip)")

            // Exact restoration, checked in full every trip.
            #expect(model.windowWorkspace == membershipBefore, "trip \(trip)")
            #expect(model.activeWorkspaceByDisplay == activeBefore, "trip \(trip)")
            for (wsID, home) in homesBefore where model.workspaces[wsID] != nil {
                #expect(model.workspace(wsID).homeDisplay == home, "workspace \(wsID), trip \(trip)")
            }
            #expect(model.workspace(3).floating[ids[3]] == floatFrameBefore, "trip \(trip)")
            for ws in model.workspaces.values { try ws.validate() }

            // The re-captured snapshot must be structurally identical to the
            // original: trees, ratios, floats, monocle, homes, focus — zero
            // deviations, every trip.
            let recaptured = ProfileEngine.capture(model: model, slots: slots2, meta: meta)
            #expect(recaptured == profile, "trip \(trip)")
        }
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

    @Test func titleDriftFallsBackToBundleMatch() throws {
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
        for ws in fresh.workspaces.values { try ws.validate() }

        // Every window lands in a recorded slot for its bundle. Same-bundle
        // windows are interchangeable once titles drift, so the pinned
        // contract is FIFO: snapshot slots fill in capture order (ws1 tree,
        // ws2 tree, ws3 floats, ws3 tree) from live ids in ascending order.
        // Bundles: w1,w4 → app.1 · w2,w5 → app.2 · w3,w6 → app.0.
        #expect(fresh.workspace(containing: WindowID(101))?.id == 1) // app.1 slot: old w1
        #expect(fresh.workspace(containing: WindowID(102))?.id == 1) // app.2 slot: old w2
        #expect(fresh.workspace(containing: WindowID(105))?.id == 2) // app.2 slot: old w5
        #expect(fresh.workspace(containing: WindowID(103))?.id == 2) // app.0 slot: old w6
        #expect(fresh.workspace(containing: WindowID(104))?.id == 3) // app.1 slot: old w4 (float)
        #expect(fresh.workspace(containing: WindowID(106))?.id == 3) // app.0 slot: old w3
        #expect(fresh.workspace(3).isFloating(WindowID(104)))
        #expect(!fresh.workspace(3).isFloating(WindowID(106)))
    }

    @Test func bundleFallbackFillsRecordedWorkspacesInFIFOOrder() throws {
        // Two windows of the same bundle recorded in different workspaces:
        // after title drift the lower live id must fill the earlier-recorded
        // slot — deterministic FIFO, not hash order.
        let m = WorkspaceModel()
        m.syncDisplays([d1])
        let a = WindowID(1), b = WindowID(2)
        m.insertWindow(a, workspace: 1)
        m.insertWindow(b, workspace: 5)
        let fps: [WindowID: WindowFingerprint] = [
            a: WindowFingerprint(bundleID: "com.example.editor", title: "notes"),
            b: WindowFingerprint(bundleID: "com.example.editor", title: "todo"),
        ]
        let snapshot = ProfileEngine.capture(
            model: m,
            slots: [DisplaySlot(id: d1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))],
            meta: { fps[$0] }
        )

        let fresh = WorkspaceModel()
        fresh.syncDisplays([d1])
        let live: [WindowID: WindowFingerprint] = [
            WindowID(201): WindowFingerprint(bundleID: "com.example.editor", title: "drifted 1"),
            WindowID(202): WindowFingerprint(bundleID: "com.example.editor", title: "drifted 2"),
        ]
        let unplaced = ProfileEngine.apply(
            snapshot, to: fresh,
            slots: [DisplaySlot(id: d1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))],
            live: live
        )
        #expect(unplaced.isEmpty)
        #expect(fresh.workspace(containing: WindowID(201))?.id == 1)
        #expect(fresh.workspace(containing: WindowID(202))?.id == 5)
        for ws in fresh.workspaces.values { try ws.validate() }
    }

    @Test func snapshotSurvivesJSONRoundTrip() throws {
        let (model, _) = populatedModel()
        let snapshot = ProfileEngine.capture(model: model, slots: slots2, meta: meta)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ModelSnapshot.self, from: data)
        // Full structural equality: trees with ratios and layouts, float
        // frames, monocle, homeSlot, focused — a lossy field here silently
        // breaks session restore (§4.5).
        #expect(decoded == snapshot)
        // Belt and braces on the collections the deep == walks.
        #expect(decoded.workspaces.map(\.id) == snapshot.workspaces.map(\.id))
        #expect(decoded.workspaces.map(\.homeSlot) == snapshot.workspaces.map(\.homeSlot))
        #expect(decoded.workspaces.map(\.focused) == snapshot.workspaces.map(\.focused))
        #expect(decoded.workspaces.map(\.monocle) == snapshot.workspaces.map(\.monocle))
    }
}
