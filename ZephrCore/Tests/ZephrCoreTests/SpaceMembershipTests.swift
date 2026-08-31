import Testing
import CoreGraphics
@testable import ZephrCore

@Suite("Space membership")
struct SpaceMembershipTests {

    private let a = WindowID(1), b = WindowID(2), c = WindowID(3)
    private let pidOne: pid_t = 100, pidTwo: pid_t = 200

    private func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 800, height: 600)
    }

    @Test func aWindowPresentOnScreenIsNotAbsent() {
        let missing = SpaceMembership.absent(
            candidates: [.init(id: a, pid: pidOne, frame: rect(0, 0))],
            onScreenByPID: [pidOne: [rect(0, 0)]])
        #expect(missing.isEmpty)
    }

    /// The whole point: an app whose window is on another Space contributes
    /// nothing to the on-screen list.
    @Test func aWindowOnAnotherSpaceIsAbsent() {
        let missing = SpaceMembership.absent(
            candidates: [.init(id: a, pid: pidOne, frame: rect(0, 0))],
            onScreenByPID: [pidTwo: [rect(0, 0)]])
        #expect(missing == [a])
    }

    /// Apps settle a few points off the frame we asked for; that is
    /// convergence, not a different Space.
    @Test func smallBoundsDriftStillMatches() {
        let missing = SpaceMembership.absent(
            candidates: [.init(id: a, pid: pidOne, frame: rect(0, 0))],
            onScreenByPID: [pidOne: [CGRect(x: 3, y: 2, width: 802, height: 597)]])
        #expect(missing.isEmpty)
    }

    /// One live window must not satisfy two candidates, or an app with two
    /// identically-framed windows looks fully present when half of it is on
    /// another Space.
    @Test func eachOnScreenWindowSatisfiesOnlyOneCandidate() {
        let missing = SpaceMembership.absent(
            candidates: [
                .init(id: a, pid: pidOne, frame: rect(0, 0)),
                .init(id: b, pid: pidOne, frame: rect(0, 0)),
            ],
            onScreenByPID: [pidOne: [rect(0, 0)]])
        #expect(missing.count == 1)
    }

    /// Which one is claimed must not depend on dictionary seeding — a
    /// verdict that flips between runs would add and remove a tile at
    /// random.
    @Test func theVerdictIsStableAcrossRuns() {
        let candidates: [SpaceMembership.Candidate] = [
            .init(id: c, pid: pidOne, frame: rect(0, 0)),
            .init(id: a, pid: pidOne, frame: rect(0, 0)),
            .init(id: b, pid: pidOne, frame: rect(0, 0)),
        ]
        let once = SpaceMembership.absent(
            candidates: candidates, onScreenByPID: [pidOne: [rect(0, 0)]])
        let twice = SpaceMembership.absent(
            candidates: candidates.reversed(), onScreenByPID: [pidOne: [rect(0, 0)]])
        #expect(once == twice)
        #expect(once == [b, c], "the lowest id should claim the live window")
    }

    @Test func multipleWindowsOfOneAppMatchPositionally() {
        let missing = SpaceMembership.absent(
            candidates: [
                .init(id: a, pid: pidOne, frame: rect(0, 0)),
                .init(id: b, pid: pidOne, frame: rect(900, 0)),
            ],
            onScreenByPID: [pidOne: [rect(900, 0), rect(0, 0)]])
        #expect(missing.isEmpty)
    }

    /// An empty probe means the API told us nothing, not that every window
    /// vanished. The caller refuses to act on it, but the pure function
    /// still has to report honestly.
    @Test func anEmptyProbeMarksEverythingAbsent() {
        let missing = SpaceMembership.absent(
            candidates: [.init(id: a, pid: pidOne, frame: rect(0, 0))],
            onScreenByPID: [:])
        #expect(missing == [a])
    }

    @Test func noCandidatesMeansNothingAbsent() {
        #expect(SpaceMembership.absent(
            candidates: [], onScreenByPID: [pidOne: [rect(0, 0)]]).isEmpty)
    }
}

@Suite("Space membership: the count gate")
struct SpaceMembershipCountGateTests {

    private let a = WindowID(1), b = WindowID(2)
    private let pidOne: pid_t = 100

    private func rect(_ x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 800, height: 600)
    }

    /// A window the user just dragged has a stale cached frame. The app
    /// still shows every window it should, so nothing may be blamed — this
    /// is the property that keeps a drag from ejecting a window from the
    /// layout.
    @Test func staleFramesAreIgnoredWhileTheCountIsRight() {
        let missing = SpaceMembership.absent(
            candidates: [.init(id: a, pid: pidOne, frame: rect(0))],
            onScreenByPID: [pidOne: [rect(4000)]])
        #expect(missing.isEmpty, "count matched, so no frame may be read as a Space change")
    }

    /// Only as many windows as are actually missing may be blamed, even
    /// when several frames fail to match.
    @Test func blameIsCappedAtTheShortfall() {
        let missing = SpaceMembership.absent(
            candidates: [
                .init(id: a, pid: pidOne, frame: rect(0)),
                .init(id: b, pid: pidOne, frame: rect(900)),
            ],
            onScreenByPID: [pidOne: [rect(4000)]])  // one live window, neither frame matches
        #expect(missing.count == 1)
        #expect(missing == [a], "lowest id is blamed, deterministically")
    }
}
