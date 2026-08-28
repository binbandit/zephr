import ApplicationServices
import CoreGraphics
import ZephrCore

/// Sendable wrapper for AXUIElement. The Accessibility API tokens are
/// process-global references; all *messaging* through them is serialized on
/// the owning app's `AppAXConnection` actor, which is what makes this safe.
nonisolated struct AXElement: @unchecked Sendable, Hashable {
    let raw: AXUIElement

    init(_ raw: AXUIElement) { self.raw = raw }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.raw, rhs.raw)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(raw))
    }

    static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    /// The system-wide accessibility object.
    static let systemWide = AXElement(AXUIElementCreateSystemWide())

    /// The §6.3 deadline on every AX call, in seconds.
    static let messagingDeadline: Float = 0.25

    /// Installs the process-global messaging-timeout floor (§6.3). Per
    /// AXUIElement.h: "Pass the system-wide accessibility object … if you
    /// want to set the timeout globally for this process. Setting the
    /// timeout on another accessibility object sets it only for that
    /// object, not for other accessibility objects that are equal to it."
    /// So the timeout set on an app element does NOT cascade to its window
    /// or button elements — this floor plus an explicit per-element
    /// deadline as each element enters its connection are BOTH required.
    /// Do not "simplify" either half away.
    static let globalTimeoutFloor: Void = {
        systemWide.setMessagingTimeout(messagingDeadline)
    }()

    // MARK: - Attribute access (call only from the owning connection actor)

    func attribute(_ name: String) -> CFTypeRef? {
        attributeResult(name).value
    }

    /// Attribute read that surfaces the AXError, letting the owning
    /// connection distinguish a messaging timeout (`.cannotComplete`, §6.3)
    /// from a plain missing attribute.
    func attributeResult(_ name: String) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(raw, name as CFString, &value)
        return (error, error == .success ? value : nil)
    }

    func string(_ name: String) -> String? {
        attribute(name) as? String
    }

    func bool(_ name: String) -> Bool? {
        attribute(name) as? Bool
    }

    func element(_ name: String) -> AXElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    func elements(_ name: String) -> [AXElement] {
        guard let value = attribute(name) as? [AnyObject] else { return [] }
        return value.compactMap {
            guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
            return AXElement($0 as! AXUIElement)
        }
    }

    func point(_ name: String) -> CGPoint? {
        guard let value = attribute(name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &pt) else { return nil }
        return pt
    }

    func size(_ name: String) -> CGSize? {
        guard let value = attribute(name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var sz = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &sz) else { return nil }
        return sz
    }

    var frame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let sz = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: sz)
    }

    /// Result of the cheap liveness probe (§6.4). Only
    /// `kAXErrorInvalidUIElement` means the backing UI object is gone;
    /// `.cannotComplete` is a messaging timeout — the app is busy, NOT dead
    /// (§6.3), and conflating the two would purge every window of any app
    /// that blocks its main thread for a moment (invariant 1).
    enum Liveness {
        case alive, dead, unresponsive
    }

    var liveness: Liveness {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &value) {
        case .invalidUIElement: return .dead
        case .cannotComplete: return .unresponsive
        default: return .alive
        }
    }

    /// Whether the element is still backed by a live UI object. Dead means
    /// `kAXErrorInvalidUIElement` only (§6.4) — a timeout is never death.
    var isAlive: Bool {
        liveness != .dead
    }

    @discardableResult
    func set(_ name: String, to value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(raw, name as CFString, value) == .success
    }

    @discardableResult
    func set(_ name: String, point: CGPoint) -> Bool {
        var pt = point
        guard let value = AXValueCreate(.cgPoint, &pt) else { return false }
        return set(name, to: value)
    }

    @discardableResult
    func set(_ name: String, size: CGSize) -> Bool {
        var sz = size
        guard let value = AXValueCreate(.cgSize, &sz) else { return false }
        return set(name, to: value)
    }

    var isSettableSize: Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(raw, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }

    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(raw, seconds)
    }
}

/// Everything the engine needs to classify and place a window, captured in
/// one round trip on the app's actor.
nonisolated struct WindowSnapshot: Sendable {
    var title: String
    var role: String?
    var subrole: String?
    var frame: CGRect
    var resizable: Bool
    var minimized: Bool
    var modal: Bool
    var fullscreen: Bool
}
