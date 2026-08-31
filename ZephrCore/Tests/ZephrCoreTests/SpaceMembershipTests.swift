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
    /// nothing to the on-screen list. A second window that *is* present is
    /// what distinguishes this from the user simply switching Space.
    @Test func aWindowOnAnotherSpaceIsAbsent() {
        let missing = SpaceMembership.absent(
            candidates: [
                .init(id: a, pid: pidOne, frame: rect(0, 0)),
                .init(id: b, pid: pidTwo, frame: rect(900, 0)),
            ],
            onScreenByPID: [pidTwo: [rect(900, 0)]])
        #expect(missing == [a])
    }

    /// Switching to a Space none of the managed windows live on must change
    /// nothing. Withdrawing them all would tear the layout out of the tree
    /// and rebuild a different one on the way back — and entering native
    /// fullscreen looks identical, because macOS gives the fullscreen
    /// window its own Space.
    @Test func aSpaceSwitchAwayWithdrawsNothing() {
        let missing = SpaceMembership.absent(
            candidates: [
                .init(id: a, pid: pidOne, frame: rect(0, 0)),
                .init(id: b, pid: pidOne, frame: rect(900, 0)),
                .init(id: c, pid: pidTwo, frame: rect(0, 700)),
            ],
            onScreenByPID: [:])
        #expect(missing.isEmpty)
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

    /// An empty probe means the API told us nothing. Nothing may be
    /// withdrawn on the strength of it — the caller also refuses to act,
    /// but the guarantee belongs here too.
    @Test func anEmptyProbeWithdrawsNothing() {
        let missing = SpaceMembership.absent(
            candidates: [.init(id: a, pid: pidOne, frame: rect(0, 0))],
            onScreenByPID: [:])
        #expect(missing.isEmpty)
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
        // A third window elsewhere is present, so this is a migration and
        // not a Space switch; pidOne is short by one.
        let missing = SpaceMembership.absent(
            candidates: [
                .init(id: a, pid: pidOne, frame: rect(0)),
                .init(id: b, pid: pidOne, frame: rect(900)),
                .init(id: WindowID(9), pid: 200, frame: rect(0)),
            ],
            onScreenByPID: [pidOne: [rect(4000)], 200: [rect(0)]])
        #expect(missing.count == 1)
        #expect(missing == [a], "lowest id is blamed, deterministically")
    }
}
