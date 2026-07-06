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

    // MARK: - Attribute access (call only from the owning connection actor)

    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else { return nil }
        return value
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

    /// Whether the element is still backed by a live UI object.
    var isAlive: Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &value)
        return err != .invalidUIElement && err != .cannotComplete
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
