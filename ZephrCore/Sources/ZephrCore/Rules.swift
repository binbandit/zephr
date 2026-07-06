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
    /// Optional regex applied to the window title.
    public var titlePattern: String?
    public var action: Action

    public init(bundleID: String, titlePattern: String? = nil, action: Action) {
        self.bundleID = bundleID
        self.titlePattern = titlePattern
        self.action = action
    }
}

public struct RuleSet: Sendable {
    public var userRules: [WindowRule]
    public var builtinRules: [WindowRule]

    public init(userRules: [WindowRule] = [], builtinRules: [WindowRule] = RuleSet.shippedRules) {
        self.userRules = userRules
        self.builtinRules = builtinRules
    }

    public func action(bundleID: String?, title: String?) -> WindowRule.Action? {
        guard let bundleID else { return nil }
        for rule in userRules + builtinRules where rule.bundleID == bundleID {
            if let pattern = rule.titlePattern {
                guard let title,
                      title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                else { continue }
            }
            return rule.action
        }
        return nil
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
