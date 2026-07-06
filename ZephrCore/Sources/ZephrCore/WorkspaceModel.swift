import Foundation
import CoreGraphics

/// The whole-model state: workspaces 1–9 (created lazily), the per-display
/// active workspace, and the window → workspace index. This is the single
/// source of truth for intent (§6.4); the app layer reconciles reality
/// against it.
public final class WorkspaceModel {

    public internal(set) var workspaces: [Int: Workspace] = [:]
    /// Connected displays in a stable order (primary first, then by position).
    public internal(set) var displays: [DisplayID] = []
    public internal(set) var activeWorkspaceByDisplay: [DisplayID: Int] = [:]
    public internal(set) var windowWorkspace: [WindowID: Int] = [:]
    /// The display where commands land (tracks focus).
    public internal(set) var focusedDisplay: DisplayID?
    /// Layout new workspaces start in (config `[layout] default`).
    public var defaultContainerLayout: ContainerLayout = .tiles

    public init() {}

    // MARK: - Workspaces

    @discardableResult
    public func workspace(_ id: Int) -> Workspace {
        if let ws = workspaces[id] { return ws }
        let ws = Workspace(id: id)
        ws.root.layout = defaultContainerLayout
        ws.homeDisplay = focusedDisplay ?? displays.first
        workspaces[id] = ws
        return ws
    }

    public func workspace(containing window: WindowID) -> Workspace? {
        guard let id = windowWorkspace[window] else { return nil }
        return workspaces[id]
    }

    public func activeWorkspace(on display: DisplayID) -> Workspace {
        if let id = activeWorkspaceByDisplay[display] { return workspace(id) }
        // Assign the lowest workspace homed here, else the lowest unused number.
        let homed = workspaces.values
            .filter { $0.homeDisplay == display }
            .map(\.id)
            .sorted()
        let id = homed.first ?? nextFreeWorkspaceID()
        let ws = workspace(id)
        ws.homeDisplay = display
        activeWorkspaceByDisplay[display] = id
        return ws
    }

    private func nextFreeWorkspaceID() -> Int {
        var id = 1
        let active = Set(activeWorkspaceByDisplay.values)
        while workspaces[id] != nil && (active.contains(id) || workspaces[id]?.homeDisplay != nil) {
            id += 1
        }
        return id
    }

    public var focusedWorkspace: Workspace? {
        guard let d = focusedDisplay else { return nil }
        return activeWorkspace(on: d)
    }

    public var focusedWindow: WindowID? {
        focusedWorkspace?.focusedWindow
    }

    // MARK: - Displays

    /// Reconciles the model with the connected display set. Workspaces homed
    /// on vanished displays migrate to the first remaining display in stable
    /// order (§4.5 basic migration; profiles come in P5). Returns displays
    /// whose contents changed.
    @discardableResult
    public func syncDisplays(_ connected: [DisplayID]) -> Set<DisplayID> {
        var affected = Set<DisplayID>()
        let old = displays
        displays = connected
        guard !connected.isEmpty else { return [] }

        // Migrate homeless workspaces.
        let connectedSet = Set(connected)
        for ws in workspaces.values {
            if let home = ws.homeDisplay, !connectedSet.contains(home) {
                ws.homeDisplay = connected[0]
                affected.insert(connected[0])
            } else if ws.homeDisplay == nil {
                ws.homeDisplay = connected[0]
            }
        }

        // Drop active entries for vanished displays.
        for d in old where !connectedSet.contains(d) {
            activeWorkspaceByDisplay.removeValue(forKey: d)
        }

        // Every connected display needs an active workspace.
        for d in connected where activeWorkspaceByDisplay[d] == nil {
            _ = activeWorkspace(on: d)
            affected.insert(d)
        }

        // Two displays can't show the same workspace: keep the first.
        var seen = Set<Int>()
        for d in connected {
            if let id = activeWorkspaceByDisplay[d] {
                if seen.contains(id) {
                    activeWorkspaceByDisplay.removeValue(forKey: d)
                    _ = activeWorkspace(on: d)
                    affected.insert(d)
                } else {
                    seen.insert(id)
                }
            }
        }

        if focusedDisplay == nil || !connectedSet.contains(focusedDisplay!) {
            focusedDisplay = connected[0]
        }
        return affected
    }

    // MARK: - Window membership

    /// Adds a window to a workspace (default: the focused one). Floating
    /// windows keep the given frame.
    public func insertWindow(
        _ id: WindowID,
        workspace wsID: Int? = nil,
        floating: Bool = false,
        frame: CGRect = .zero
    ) {
        guard windowWorkspace[id] == nil else { return }
        let ws: Workspace
        if let wsID {
            ws = workspace(wsID)
        } else if let focused = focusedWorkspace {
            ws = focused
        } else {
            ws = workspace(1)
        }
        if floating || ws.floatByDefault {
            ws.insertFloating(id, frame: frame)
        } else {
            ws.insertTiled(id)
        }
        windowWorkspace[id] = ws.id
    }

    @discardableResult
    public func removeWindow(_ id: WindowID) -> Bool {
        guard let wsID = windowWorkspace.removeValue(forKey: id) else { return false }
        return workspaces[wsID]?.remove(id) ?? false
    }

    /// Moves a window to workspace `n`, keeping its floating state. Focus
    /// stays in the source workspace (i3 behavior).
    @discardableResult
    public func moveWindow(_ id: WindowID, toWorkspace n: Int) -> Bool {
        guard let sourceID = windowWorkspace[id], sourceID != n,
              let source = workspaces[sourceID] else { return false }
        let wasFloating = source.isFloating(id)
        let frame = source.isFloating(id)
            ? (source.floating[id] ?? .zero)
            : (source.lastSolvedFrames[id] ?? .zero)
        source.remove(id)
        let target = workspace(n)
        if wasFloating {
            target.insertFloating(id, frame: frame)
        } else {
            target.insertTiled(id)
        }
        windowWorkspace[id] = n
        return true
    }

    /// The workspace shown before the last switch — re-requesting the
    /// visible workspace bounces back to it (i3 back-and-forth).
    public private(set) var previousWorkspaceID: Int?

    /// Switches the focused (or given) display to workspace `n`. If the
    /// workspace lives on another connected display, focus jumps there
    /// instead (i3 semantics). Requesting the already-visible, focused
    /// workspace toggles back to the previous one. Returns the displays
    /// whose contents changed.
    public func activateWorkspace(_ n: Int, on requested: DisplayID? = nil) -> Set<DisplayID> {
        guard let display = requested ?? focusedDisplay ?? displays.first else { return [] }
        let ws = workspace(n)

        let target: DisplayID
        if let home = ws.homeDisplay, displays.contains(home) {
            target = home
        } else {
            target = display
            ws.homeDisplay = display
        }

        let previous = activeWorkspaceByDisplay[target]
        if previous == n {
            // Back-and-forth: only when this is a true re-press of the
            // workspace the user is looking at.
            if focusedDisplay == target, let back = previousWorkspaceID, back != n {
                return activateWorkspace(back, on: display)
            }
            focusedDisplay = target
            return []
        }

        focusedDisplay = target
        previousWorkspaceID = previous
        activeWorkspaceByDisplay[target] = n
        return [target]
    }

    /// Moves every window in the model into the given workspace — the
    /// `leader w` rescue command backing the "never lose a window" invariant.
    public func rescueAllWindows(into n: Int) {
        let all = Array(windowWorkspace.keys)
        for id in all {
            _ = moveWindow(id, toWorkspace: n)
        }
    }

    /// Points subsequent commands at the given display (⌃⌥` cycling).
    public func focusDisplay(_ d: DisplayID) {
        guard displays.contains(d) else { return }
        focusedDisplay = d
    }

    /// Update focus bookkeeping from an externally observed focus change.
    public func noteFocused(_ id: WindowID) {
        guard let ws = workspace(containing: id) else { return }
        ws.focus(id)
        if let home = ws.homeDisplay { focusedDisplay = home }
    }
}
