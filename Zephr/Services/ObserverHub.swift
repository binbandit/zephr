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

    /// Elements that `unwatchWindow`/`unwatchApp` have retired. Read and
    /// written only on the owning watch's serial queue, so the `@unchecked`
    /// is sound. A pending retry from the §6.4 ladder must not re-register a
    /// window that has since closed — that would reinstate exactly the leak
    /// `unwatchWindow` exists to prevent.
    private nonisolated final class RetiredElements: @unchecked Sendable {
        var elements: Set<AXElement> = []
        var all = false
        func contains(_ element: AXElement) -> Bool { all || elements.contains(element) }
    }

    private struct AppWatch {
        var observer: AXObserver
        var appElement: AXElement
        let retired = RetiredElements()
        /// Notification (de)registration is synchronous IPC into the target
        /// app; it runs here, off the MainActor, so a hung app can never
        /// freeze the UI or the keyboard (§6.3). Per-pid, so a slow app
        /// never delays observing another.
        var queue: DispatchSerialQueue
    }

    private var watches: [pid_t: AppWatch] = [:]
    private nonisolated static let log = Logger(subsystem: "dev.zephr", category: "observer")

    init() {
        Self.shared = self
    }

    private nonisolated static let appNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    private nonisolated static let windowNotifications: [String] = [
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
        // §6.3 deadlines: the global floor for any token this file creates,
        // plus the explicit per-element timeout (AXUIElement.h — a timeout
        // set on one element covers only that element).
        _ = AXElement.globalTimeoutFloor
        appElement.setMessagingTimeout(AXElement.messagingDeadline)
        // Only the run-loop source touches the main run loop; the actual
        // registrations are IPC and run on the watch's own queue.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let queue = DispatchSerialQueue(label: "dev.zephr.observer.\(pid)", qos: .userInitiated)
        let watch = AppWatch(observer: observer, appElement: appElement, queue: queue)
        watches[pid] = watch
        // refcon for app-level notifications encodes the pid (low bits only —
        // window refcons always have a nonzero sequence in the low 32 bits,
        // pids never exceed 32 bits, so the two are distinguished by the
        // notification name anyway).
        Self.addNotifications(
            ObserverRef(raw: observer), element: appElement,
            names: Self.appNotifications, refconBits: UInt(UInt32(bitPattern: pid)),
            queue: queue, retired: watch.retired, pid: pid)
    }

    func watchWindow(pid: pid_t, element: AXElement, id: WindowID) {
        guard let watch = watches[pid] else { return }
        // Un-retire first: a spurious destroyed notification retires an
        // element the app is still using, and the audit re-adopts it moments
        // later (§6.4). Without this the re-adopted window is deaf to every
        // notification for the rest of the session. The serial queue keeps
        // this ordered behind any pending unwatch, so the retirement still
        // blocks the retries it was added for.
        let retired = watch.retired
        watch.queue.async { retired.elements.remove(element) }
        Self.addNotifications(
            ObserverRef(raw: watch.observer), element: element,
            names: Self.windowNotifications, refconBits: UInt(id.raw),
            queue: watch.queue, retired: retired, pid: pid)
    }

    /// Removes the registrations added by `watchWindow`. Without this every
    /// closed window leaks six registrations — each retaining a dead
    /// AXUIElement — on the app's observer for the app's lifetime (§6.3
    /// RSS budget).
    func unwatchWindow(pid: pid_t, element: AXElement) {
        guard let watch = watches[pid] else { return }
        let observer = ObserverRef(raw: watch.observer)
        let retired = watch.retired
        watch.queue.async {
            // Retire first, so any retry still queued behind us bails out
            // instead of re-adding the registrations we are about to drop.
            retired.elements.insert(element)
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer.raw, element.raw, name as CFString)
            }
        }
    }

    /// Registers `names` for `element` on the watch's queue, retrying on
    /// the §6.4 ladder (10 ms / 50 ms / 250 ms): a window can exist before
    /// its app's AX server is ready, and a discarded failure would leave
    /// the app unobserved for the whole session.
    private nonisolated static func addNotifications(
        _ observer: ObserverRef,
        element: AXElement,
        names: [String],
        refconBits: UInt,
        queue: DispatchSerialQueue,
        retired: RetiredElements,
        pid: pid_t,
        attempt: Int = 0
    ) {
        queue.async {
            guard !retired.contains(element) else { return }
            let refcon = UnsafeMutableRawPointer(bitPattern: refconBits)
            var failed: [String] = []
            for name in names {
                let err = AXObserverAddNotification(observer.raw, element.raw, name as CFString, refcon)
                if err != .success && err != .notificationAlreadyRegistered {
                    failed.append(name)
                }
            }
            guard !failed.isEmpty else { return }
            let ladderMs = [10, 50, 250]
            guard attempt < ladderMs.count else {
                log.warning("pid \(pid): giving up on \(failed.count) observer registrations")
                return
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(ladderMs[attempt])) { [failed] in
                addNotifications(observer, element: element, names: failed,
                                 refconBits: refconBits, queue: queue,
                                 retired: retired, pid: pid,
                                 attempt: attempt + 1)
            }
        }
    }

    func unwatchApp(pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        // Same reasoning as `unwatchWindow`: kill any retry still in flight.
        let retired = watch.retired
        watch.queue.async { retired.all = true }
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

/// Carries the AXObserver handle from the MainActor to the watch's
/// registration queue. Safe for the same reason AXElement is: the token is
/// process-global, all (de)registration messaging for a pid is serialized
/// on that watch's own queue, and run-loop-source manipulation stays on the
/// main run loop.
private nonisolated struct ObserverRef: @unchecked Sendable {
    let raw: AXObserver
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
