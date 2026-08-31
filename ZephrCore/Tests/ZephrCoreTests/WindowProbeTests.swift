import Testing
import CoreGraphics
@testable import ZephrCore

@Suite("Correlating AX windows with the CoreGraphics window list")
struct WindowProbeTests {

    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func anExactMatchYieldsItsLevel() {
        let level = WindowProbe.level(of: window, among: [
            .init(frame: window, level: 0),
            .init(frame: CGRect(x: 900, y: 0, width: 400, height: 300), level: 25),
        ])
        #expect(level == 0)
    }

    /// Overlays are the whole point: a screen-share bar or a screenshot tool
    /// reports itself as an ordinary window through AX and is only
    /// distinguishable by sitting above the normal layer.
    @Test(arguments: [3, 25, 103, 1000, 1001])
    func anOverlayReportsItsRealLevel(_ level: Int) {
        #expect(WindowProbe.level(of: window, among: [.init(frame: window, level: level)]) == level)
    }

    @Test func aSmallSettlingDifferenceStillMatches() {
        let settled = CGRect(x: 102, y: 101, width: 799, height: 602)
        #expect(WindowProbe.level(of: window, among: [.init(frame: settled, level: 0)]) == 0)
    }

    /// The join is on pid and bounds because the identifier that would make
    /// it exact is a private API. Two identically-placed windows of one app
    /// therefore cannot be told apart, and answering anyway would risk
    /// refusing to manage a window the user expects tiled.
    @Test func anAmbiguousMatchAnswersNothing() {
        let level = WindowProbe.level(of: window, among: [
            .init(frame: window, level: 0),
            .init(frame: window, level: 1000),
        ])
        #expect(level == nil)
    }

    @Test func noMatchAnswersNothing() {
        let level = WindowProbe.level(of: window, among: [
            .init(frame: CGRect(x: 0, y: 0, width: 300, height: 200), level: 0),
        ])
        #expect(level == nil)
    }

    @Test func anEmptyListAnswersNothing() {
        #expect(WindowProbe.level(of: window, among: []) == nil)
    }
}
