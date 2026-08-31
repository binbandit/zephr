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
    ///
    /// The bar for an entry is that the engine's structural gates get the
    /// window wrong. Those gates already refuse anything whose role is not
    /// `AXWindow`, anything whose subrole is neither a standard window nor a
    /// dialog, and anything the window server places above the ordinary
    /// window level; they float modal, non-resizable and small windows. A
    /// rule that only restates one of them never fires and is worse than no
    /// rule at all, so every entry below records what breaks in its absence.
    ///
    /// Title patterns are English-only by nature. That is the safe
    /// direction: a localized system falls back to the structural gates and
    /// at worst tiles something it should have floated, which the user can
    /// undo with one keystroke.
    public static let shippedRules: [WindowRule] = [
        // Launchers. The search field is a plain `AXWindow`, and so are the
        // side panels each of these opens - Raycast's Floating Notes and
        // confetti, Alfred's clipboard history. Ignoring the app covers the
        // whole family, and a tile where the user expects an overlay is the
        // most jarring thing a tiling manager can do.
        .init(bundleID: "com.raycast.macos", action: .ignore),
        .init(bundleID: "com.runningwithcrayons.Alfred", action: .ignore),
        .init(bundleID: "com.apple.Spotlight", action: .ignore),

        // Desktop furniture, not content. `com.apple.dock` owns Mission
        // Control and Launchpad as well as the Dock itself, `WindowManager`
        // is Stage Manager's strip, and the three menu-bar agents put their
        // popovers on screen as windows. Managing any of it means fighting
        // the OS for control of the screen.
        .init(bundleID: "com.apple.dock", action: .ignore),
        .init(bundleID: "com.apple.controlcenter", action: .ignore),
        .init(bundleID: "com.apple.notificationcenterui", action: .ignore),
        .init(bundleID: "com.apple.systemuiserver", action: .ignore),
        .init(bundleID: "com.apple.WindowManager", action: .ignore),

        // The screen saver covers a whole display without ever reporting
        // native fullscreen. Adopted, it holds a tile for as long as the
        // saver runs and the layout reflows twice around a window nobody is
        // looking at.
        .init(bundleID: "com.apple.ScreenSaver.Engine", action: .ignore),

        // Zebar is a desktop bar: a menu-bar-only app whose one window is a
        // full-width strip with no close button, sitting at the *ordinary*
        // window level where the level gate cannot see it. Tiled, it takes a
        // whole column and every real window shrinks to make room.
        .init(bundleID: "com.glzr.zebar", action: .ignore),

        // System Settings is resizable and opens around 720x970, so nothing
        // structural keeps it out of the tree. It is an errand, not a window
        // to live in.
        .init(bundleID: "com.apple.systempreferences", action: .float),

        // Activity Monitor's process inspector ("Inspect Process") and its
        // sampler ("Sample of Safari") are full-size resizable windows. The
        // main window is titled after the selected tab - CPU, Memory, Energy
        // - so anchoring at the start leaves it tiling.
        .init(bundleID: "com.apple.ActivityMonitor", titlePattern: "^(Inspect|Sample)", action: .float),

        // Calculator is 198x350, sitting exactly on the boundary of the
        // small-window heuristic, which needs both dimensions *strictly*
        // under 500x350. One point of height is all that separates it from
        // being tiled.
        .init(bundleID: "com.apple.calculator", action: .float),

        // Single-purpose instrument panels: opened to read one value and
        // closed again. ColorSync Utility's profile browser in particular is
        // large and resizable, so nothing structural catches it, and tiling
        // it reflows the workspace twice for a two-second errand.
        .init(bundleID: "com.apple.ColorSyncUtility", action: .float),
        .init(bundleID: "com.apple.DigitalColorMeter", action: .float),

        // Archive Utility's progress window is sized to the file name, so a
        // long path pushes it past 500 points wide and into a tile for the
        // length of an unzip - then it vanishes and the layout reflows again.
        .init(bundleID: "com.apple.archiveutility", action: .float),

        // Zoom's screen-share control strip: an ordinary resizable window at
        // the ordinary level, so only its title marks it out. It appears
        // mid-call, which is the worst possible moment to reflow a layout.
        // Zoom titles it a beat after creating it, which is why the engine
        // re-checks title rules on `kAXTitleChanged`.
        .init(bundleID: "us.zoom.xos", titlePattern: "^zoom floating", action: .float),

        // 1Password's Quick Access panel. Its overlays normally sit above
        // the ordinary window level, but that gate joins AX to the window
        // server on frame alone and declines to answer when the match is
        // ambiguous - and a password panel yanked into a tile is the one
        // misclassification with a security cost, so it gets a second line
        // of defence.
        .init(bundleID: "com.1password.1password", titlePattern: "Quick Access", action: .float),

        // Video windows that hold their aspect ratio. They come back from
        // any tile a different size, so the engine writes a frame the app
        // refuses, twice, before the frame-veto path floats them anyway -
        // and that path also persists a learned rule into the user's config
        // for something we already knew.
        .init(bundleID: "com.apple.FaceTime", action: .float),
        .init(bundleID: "com.apple.PhotoBooth", action: .float),

        // The Simulator's window is the shape of the device it emulates:
        // 447x950 for a phone, tall enough to clear the small-window
        // heuristic. Stretched into a landscape tile the device shrinks to a
        // sliver of the space it was given.
        .init(bundleID: "com.apple.iphonesimulator", action: .float),

        // qutebrowser with `window.hide_decoration` set reports its ordinary
        // browser window as `AXDialog`, and the engine floats every dialog:
        // without this the user's main window never tiles. Its context menus
        // share that subrole but sit above the ordinary window level, so the
        // level gate has already dropped them before this is consulted.
        .init(bundleID: "org.qutebrowser.qutebrowser", action: .tile),
    ]
}
