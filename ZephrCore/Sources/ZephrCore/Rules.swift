import Foundation

/// Per-app window rules (§4.3). First match wins; user rules are checked
/// before the shipped database.
public struct WindowRule: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case float
        case tile
        case ignore
        case workspace(Int)
    }

    public var bundleID: String
    /// Optional regex applied to the window title. Matching is
    /// case-insensitive and unanchored — anchor with ^/$ to pin it.
    public var titlePattern: String? {
        didSet { matcher = TitleMatcher(titlePattern) }
    }
    public var action: Action

    /// Index of this rule's `[[rules]]` block in the config file, for rules
    /// that came from one. Provenance, not identity: the parser drops rules
    /// whose title regex will not compile, so a position in `userRules` does
    /// not track a position in the file, and Settings needs the file's own
    /// ordinal to delete the block the user actually clicked.
    public var sourceOrdinal: Int?

    /// Compiled once at construction so user patterns are never re-compiled
    /// per window, and matching stays bounded (§6.3).
    private var matcher: TitleMatcher?

    public init(bundleID: String, titlePattern: String? = nil, action: Action, sourceOrdinal: Int? = nil) {
        self.bundleID = bundleID
        self.titlePattern = titlePattern
        self.action = action
        self.sourceOrdinal = sourceOrdinal
        self.matcher = TitleMatcher(titlePattern)
    }

    /// The compiled matcher is derived state; equality is the three
    /// user-visible fields.
    public static func == (lhs: WindowRule, rhs: WindowRule) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.titlePattern == rhs.titlePattern
            && lhs.action == rhs.action
    }

    /// Whether `titlePattern` matches `title`. Rules without a pattern (and
    /// patterns that failed to compile) match nothing here — callers treat
    /// pattern-less rules as app-wide before asking.
    public func matchesTitle(_ title: String) -> Bool {
        matcher?.matches(title) ?? false
    }

    /// Throws the ICU error when `pattern` is not a valid regular
    /// expression. Config parsing calls this so a bad pattern is an inline
    /// error at parse time, never a rule that silently never fires (§4.6).
    public static func validateTitlePattern(_ pattern: String) throws {
        _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

/// A pre-compiled title matcher. Literal patterns (no regex metacharacters)
/// use a plain substring scan; real regexes run under a hard time budget,
/// so one pathological pattern — catastrophic backtracking like `^(a+)+$` —
/// can never stall the app (§6.3, invariant 3). The budget is temporal, not
/// a title-length cap: truncating the title changes what `$` anchors to and
/// can flip a non-match into a match, while a timeout degrades to "no
/// match" — the same answer a backtracking blowup was crawling toward.
private enum TitleMatcher: @unchecked Sendable {
    // @unchecked: NSRegularExpression is documented immutable and
    // thread-safe; the enum adds no mutable state.
    case substring(String)
    case regex(NSRegularExpression)

    /// Hard per-match budget. A pattern that exhausts it is treated as
    /// "no match" instead of hanging the MainActor.
    static let timeBudget: CFAbsoluteTime = 0.05

    init?(_ pattern: String?) {
        guard let pattern else { return nil }
        let metacharacters: Set<Character> = ["\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"]
        if !pattern.contains(where: { metacharacters.contains($0) }) {
            self = .substring(pattern)
        } else if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            self = .regex(regex)
        } else {
            return nil // config parsing rejects these before a rule exists
        }
    }

    func matches(_ title: String) -> Bool {
        switch self {
        case .substring(let literal):
            return title.range(of: literal, options: [.caseInsensitive]) != nil
        case .regex(let regex):
            let deadline = CFAbsoluteTimeGetCurrent() + Self.timeBudget
            var found = false
            let range = NSRange(location: 0, length: (title as NSString).length)
            regex.enumerateMatches(in: title, options: [.reportProgress], range: range) { result, _, stop in
                if result != nil {
                    found = true
                    stop.pointee = true
                } else if CFAbsoluteTimeGetCurrent() > deadline {
                    stop.pointee = true
                }
            }
            return found
        }
    }
}

public struct RuleSet: Sendable {
    public var userRules: [WindowRule]
    public var builtinRules: [WindowRule]

    public init(userRules: [WindowRule] = [], builtinRules: [WindowRule] = RuleSet.shippedRules) {
        self.userRules = userRules
        self.builtinRules = builtinRules
    }

    /// First match wins, user rules before the shipped list.
    ///
    /// The two arrays are walked in turn rather than concatenated: this runs
    /// on the per-window event path, and `userRules + builtinRules` built a
    /// throwaway array — retaining every compiled `NSRegularExpression` in
    /// it — on each call (§6.3).
    public func action(bundleID: String?, title: String?) -> WindowRule.Action? {
        guard let bundleID else { return nil }
        func firstMatch(in rules: [WindowRule]) -> WindowRule.Action? {
            for rule in rules where rule.bundleID == bundleID {
                if rule.titlePattern != nil {
                    guard let title, rule.matchesTitle(title) else { continue }
                }
                return rule.action
            }
            return nil
        }
        return firstMatch(in: userRules) ?? firstMatch(in: builtinRules)
    }

    /// The shipped rules database (§4.3). Curated starter set; grows via
    /// community PRs and ships updates through the normal update channel.
    public static let shippedRules: [WindowRule] = [
        // Launchers and system chrome are never touched.
        .init(bundleID: "com.raycast.macos", action: .ignore),
        .init(bundleID: "com.runningwithcrayons.Alfred", action: .ignore),
        .init(bundleID: "com.apple.Spotlight", action: .ignore),
        .init(bundleID: "com.apple.dock", action: .ignore),
        .init(bundleID: "com.apple.controlcenter", action: .ignore),
        .init(bundleID: "com.apple.notificationcenterui", action: .ignore),
        .init(bundleID: "com.apple.systemuiserver", action: .ignore),
        .init(bundleID: "com.apple.WindowManager", action: .ignore),
        .init(bundleID: "com.apple.ScreenSaver.Engine", action: .ignore),

        // Windows that should float.
        .init(bundleID: "com.apple.systempreferences", action: .float),
        .init(bundleID: "com.apple.ActivityMonitor", titlePattern: "^(Inspect|Sample)", action: .float),
        .init(bundleID: "com.apple.calculator", action: .float),
        .init(bundleID: "com.apple.ColorSyncUtility", action: .float),
        .init(bundleID: "com.apple.DigitalColorMeter", action: .float),
        .init(bundleID: "com.apple.archiveutility", action: .float),
        .init(bundleID: "us.zoom.xos", titlePattern: "^zoom floating", action: .float),
        .init(bundleID: "com.1password.1password", titlePattern: "Quick Access", action: .float),
        .init(bundleID: "com.apple.FaceTime", action: .float),
        .init(bundleID: "com.apple.iphonesimulator", action: .float),
    ]
}
