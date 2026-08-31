import Testing
@testable import ZephrCore

/// The shipped database is knowledge, not code: every entry stands for a
/// window some app really produces, and none of it can be derived from first
/// principles. So each rule is pinned twice - to the window it was written
/// for, and to a neighbouring window it must *not* catch. An over-matching
/// rule pulls a real window out of the layout, which is a worse failure than
/// the one the rule was fixing.
///
/// `RuleTests` in ModelTests.swift covers the matching machinery (precedence,
/// anchoring, the regex time budget); this suite covers the contents.
@Suite("Shipped rules")
struct ShippedRulesTests {

    private let rules = RuleSet()

    /// Windows taken from real AX dumps, paired with what the database must
    /// say about them. `nil` means "no rule applies" - the engine's own
    /// structural gates decide, and the entry is here to prove the database
    /// keeps its hands off.
    private static let samples: [(bundleID: String, title: String, expected: WindowRule.Action?)] = [
        // Rules that exist because a structural gate gets these wrong.
        ("org.qutebrowser.qutebrowser", "Change Log - qutebrowser", .tile),
        // Title-independent on purpose: a window that has not been titled
        // yet is still the browser.
        ("org.qutebrowser.qutebrowser", "", .tile),
        ("com.glzr.zebar", "Zebar - glzr-io.starter / vanilla", .ignore),
        ("com.apple.PhotoBooth", "Photo Booth", .float),
        ("com.apple.ActivityMonitor", "Inspect Process", .float),
        ("com.apple.ActivityMonitor", "Sample of Safari", .float),
        ("com.apple.systempreferences", "General", .float),
        ("com.apple.calculator", "Calculator", .float),
        ("com.apple.iphonesimulator", "iPhone 15 Pro - iOS 17.4", .float),
        ("us.zoom.xos", "zoom floating video window", .float),
        ("com.1password.1password", "1Password Quick Access", .float),
        ("com.raycast.macos", "Raycast", .ignore),
        ("com.apple.dock", "", .ignore),
        ("com.apple.WindowManager", "", .ignore),
        ("com.apple.ScreenSaver.Engine", "", .ignore),

        // Same app, different window: the title patterns above must leave
        // these alone.
        ("com.apple.ActivityMonitor", "CPU", nil),
        ("com.apple.ActivityMonitor", "Memory", nil),
        ("us.zoom.xos", "Zoom Meeting", nil),
        ("com.1password.1password", "Account Name - All Items - 1Password", nil),

        // Near-miss bundle ids. Matching is exact, and a prefix match here
        // would silently ignore an unrelated app.
        ("com.apple.Photos", "Photos", nil),
        ("com.glzr.zebar.helper", "Zebar", nil),
        ("com.apple.systempreferences.helper", "General", nil),

        // Deliberately absent. Each of these is a real misclassification in
        // some other window manager that Zephr's structural gates already
        // handle, and a rule for it would never fire: Firefox's
        // picture-in-picture and Slack's huddle overlays sit above the
        // ordinary window level, IntelliJ's tooltips and Emacs' child frames
        // carry subroles the engine does not accept, and Xcode's
        // "Build Succeeded" popup is at level 101.
        ("org.mozilla.firefox", "Picture-in-Picture", nil),
        ("com.tinyspeck.slackmacgap", "Slack", nil),
        ("com.jetbrains.intellij", "", nil),
        ("org.gnu.Emacs", "EmacsCorfuGUI", nil),
        ("com.apple.dt.Xcode", "Build Succeeded", nil),
    ]

    @Test func samplesClassifyAsExpected() {
        for sample in Self.samples {
            #expect(
                rules.action(bundleID: sample.bundleID, title: sample.title) == sample.expected,
                "\(sample.bundleID) \"\(sample.title)\""
            )
        }
    }

    /// The failure Zephr has already shipped once: a pattern anchored to
    /// text the app never produces compiles cleanly, reads correctly, and
    /// can never match. Every title pattern must be reachable from a window
    /// somebody has actually seen.
    @Test func everyTitlePatternIsExercisedByASample() {
        for rule in RuleSet.shippedRules {
            guard let pattern = rule.titlePattern else { continue }
            let fired = Self.samples.contains {
                $0.bundleID == rule.bundleID && rule.matchesTitle($0.title)
            }
            #expect(fired, "no sample title reaches \(rule.bundleID) /\(pattern)/")
        }
    }

    /// Apps routinely create a window and title it a moment later, and the
    /// engine classifies on that first snapshot. A shipped pattern that
    /// matches the empty title would therefore claim every window of the app
    /// during its first few frames - including, for an `ignore` rule, the
    /// real one.
    @Test func noShippedTitlePatternClaimsAnUntitledWindow() {
        for rule in RuleSet.shippedRules {
            guard let pattern = rule.titlePattern else { continue }
            #expect(!rule.matchesTitle(""), "\(rule.bundleID) /\(pattern)/ matches an untitled window")
        }
    }

    /// First match wins, so an app-wide rule answers for every title and
    /// anything more specific listed after it is dead weight.
    @Test func noAppWideRuleShadowsATitleRuleForTheSameApp() {
        var appWide: Set<String> = []
        for rule in RuleSet.shippedRules {
            guard let pattern = rule.titlePattern else {
                appWide.insert(rule.bundleID)
                continue
            }
            #expect(
                !appWide.contains(rule.bundleID),
                "\(rule.bundleID) /\(pattern)/ sits behind an app-wide rule for the same app"
            )
        }
    }

    @Test func everyShippedTitlePatternCompiles() throws {
        for rule in RuleSet.shippedRules {
            guard let pattern = rule.titlePattern else { continue }
            try WindowRule.validateTitlePattern(pattern)
        }
    }
}
