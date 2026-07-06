import AppKit
import ApplicationServices
import os
import ZephrCore

/// Owns one AXObserver per watched application, delivering notifications on
/// the main run loop and forwarding them to the engine. AX events are lossy
/// in practice (§6.4) — the engine's reconciliation audit backstops anything
/// missed here.
@MainActor
final class ObserverHub {

    /// The observer C callback has no context beyond refcon; it finds the hub
    /// through this. Set once at startup, read only on the main thread.
    nonisolated(unsafe) static weak var shared: ObserverHub?

    enum Event {
        case windowCreated(pid_t, AXElement)
        case appFocusChanged(pid_t, AXElement?)
        case windowDestroyed(WindowID)
        case windowMoved(WindowID)
        case windowResized(WindowID)
        case windowTitleChanged(WindowID)
        case windowMiniaturized(WindowID)
        case windowDeminiaturized(WindowID)
    }

    var onEvent: ((Event) -> Void)?

    private struct AppWatch {
        var observer: AXObserver
        var appElement: AXElement
    }

    private var watches: [pid_t: AppWatch] = [:]
    private static let log = Logger(subsystem: "dev.zephr", category: "observer")

    init() {
        Self.shared = self
    }

    private static let appNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    private static let windowNotifications: [String] = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    func watchApp(pid: pid_t) {
        guard watches[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, hubObserverCallback, &observer) == .success, let observer else {
            Self.log.warning("AXObserverCreate failed for pid \(pid)")
            return
        }
        let appElement = AXElement.application(pid: pid)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        // refcon for app-level notifications encodes the pid (low bits only —
        // window refcons always have a nonzero sequence in the low 32 bits,
        // pids never exceed 32 bits, so the two are distinguished by the
        // notification name anyway).
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: pid)))
        for name in Self.appNotifications {
            AXObserverAddNotification(observer, appElement.raw, name as CFString, refcon)
        }
        watches[pid] = AppWatch(observer: observer, appElement: appElement)
    }

    func watchWindow(pid: pid_t, element: AXElement, id: WindowID) {
        guard let watch = watches[pid] else { return }
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id.raw))
        for name in Self.windowNotifications {
            AXObserverAddNotification(watch.observer, element.raw, name as CFString, refcon)
        }
    }

    func unwatchApp(pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
    }

    fileprivate func handle(notification: String, element: AXElement, refcon: UInt64) {
        switch notification {
        case kAXWindowCreatedNotification:
            onEvent?(.windowCreated(pid_t(bitPattern: UInt32(truncatingIfNeeded: refcon)), element))
        case kAXFocusedWindowChangedNotification:
            onEvent?(.appFocusChanged(pid_t(bitPattern: UInt32(truncatingIfNeeded: refcon)), element))
        case kAXUIElementDestroyedNotification:
            onEvent?(.windowDestroyed(WindowID(refcon)))
        case kAXWindowMovedNotification:
            onEvent?(.windowMoved(WindowID(refcon)))
        case kAXWindowResizedNotification:
            onEvent?(.windowResized(WindowID(refcon)))
        case kAXTitleChangedNotification:
            onEvent?(.windowTitleChanged(WindowID(refcon)))
        case kAXWindowMiniaturizedNotification:
            onEvent?(.windowMiniaturized(WindowID(refcon)))
        case kAXWindowDeminiaturizedNotification:
            onEvent?(.windowDeminiaturized(WindowID(refcon)))
        default:
            break
        }
    }
}

/// AXObserver callbacks arrive on the run loop that hosts the observer
/// source — the main run loop here, so hopping to the MainActor is safe.
private nonisolated func hubObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    let name = notification as String
    let value = UInt64(UInt(bitPattern: refcon))
    let wrapped = AXElement(element)
    MainActor.assumeIsolated {
        ObserverHub.shared?.handle(notification: name, element: wrapped, refcon: value)
    }
}
