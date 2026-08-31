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
        // Assign the lowest workspace homed here that isn't already visible
        // on another display (two displays can't show the same workspace),
        // else the lowest unused number.
        let activeElsewhere = Set(activeWorkspaceByDisplay.values)
        let homed = workspaces.values
            .filter { $0.homeDisplay == display && !activeElsewhere.contains($0.id) }
            .map(\.id)
            .sorted()
        let id = homed.first ?? nextFreeWorkspaceID()
        let ws = workspace(id)
        ws.homeDisplay = display
        ws.preferredDisplay = display
        activeWorkspaceByDisplay[display] = id
        return ws
    }

    /// A workspace id this display can take. Ids are the keys 1-9 and
    /// nothing else: inventing a tenth produces a workspace no binding can
    /// reach and that profile restore silently drops, so once all nine
    /// exist we reuse one rather than counting past the keyboard.
    private func nextFreeWorkspaceID() -> Int {
        let active = Set(activeWorkspaceByDisplay.values)
        let free = (1...9).filter { !active.contains($0) }
        // Never created yet, then created-but-empty, then anything free.
        return free.first { workspaces[$0] == nil }
            ?? free.first { workspaces[$0]?.isEmpty == true }
            ?? free.first
            ?? 1
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
        displays = connected
        // A zero-display interval (lid closed, displays asleep) keeps the
        // active-workspace map intact so reopening the same arrangement
        // restores it; stale entries are cleaned on the next non-empty sync.
        guard !connected.isEmpty else { return [] }

        // Migrate homeless workspaces, and bring back any that a previous
        // undock displaced — `preferredDisplay` is where the user actually
        // put them, `homeDisplay` is only where they are surviving.
        let connectedSet = Set(connected)
        for ws in workspaces.values {
            if let preferred = ws.preferredDisplay, connectedSet.contains(preferred),
               ws.homeDisplay != preferred {
                ws.homeDisplay = preferred
                affected.insert(preferred)
                if let stale = activeWorkspaceByDisplay.first(where: { $0.value == ws.id })?.key,
                   stale != preferred {
                    activeWorkspaceByDisplay.removeValue(forKey: stale)
                    affected.insert(stale)
                }
                activeWorkspaceByDisplay[preferred] = ws.id
            } else if let home = ws.homeDisplay, !connectedSet.contains(home) {
                ws.homeDisplay = connected[0]
                affected.insert(connected[0])
            } else if ws.homeDisplay == nil {
                ws.homeDisplay = connected[0]
            }
        }

        // Drop active entries for vanished displays — checked against the
        // *current* keys, not the previous display list, so entries left
        // behind by a zero-display interval are cleaned too. Missing this
        // let two connected displays end up showing the same workspace.
        for d in Array(activeWorkspaceByDisplay.keys) where !connectedSet.contains(d) {
            activeWorkspaceByDisplay.removeValue(forKey: d)
        }

        // Every connected display needs an active workspace.
        for d in connected where activeWorkspaceByDisplay[d] == nil {
            _ = activeWorkspace(on: d)
            affected.insert(d)
        }

        // Two displays can't show the same workspace: keep the first. The
        // replacement's id joins `seen` so later displays can't re-pick it.
        var seen = Set<Int>()
        for d in connected {
            if let id = activeWorkspaceByDisplay[d] {
                if seen.contains(id) {
                    activeWorkspaceByDisplay.removeValue(forKey: d)
                    seen.insert(activeWorkspace(on: d).id)
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

    /// See `Workspace.replace`. `new` must not already be placed.
    @discardableResult
    public func replaceWindow(_ old: WindowID, with new: WindowID) -> Bool {
        guard let wsID = windowWorkspace[old], windowWorkspace[new] == nil,
              let ws = workspaces[wsID], ws.replace(old, with: new) else { return false }
        windowWorkspace.removeValue(forKey: old)
        windowWorkspace[new] = wsID
        return true
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

    /// Per display, the workspace it showed before its last switch —
    /// re-requesting the visible workspace bounces back to it (i3
    /// back-and-forth). Keyed by display because a single global value made
    /// a re-press on one monitor jump to the other monitor's history,
    /// switching the wrong screen and dragging focus across with it.
    public private(set) var previousWorkspaceByDisplay: [DisplayID: Int] = [:]

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
            if focusedDisplay == target,
               let back = previousWorkspaceByDisplay[target], back != n {
                return activateWorkspace(back, on: target)
            }
            focusedDisplay = target
            return []
        }

        focusedDisplay = target
        previousWorkspaceByDisplay[target] = previous
        activeWorkspaceByDisplay[target] = n
        ws.preferredDisplay = target
        return [target]
    }

    /// Re-homes workspace `n` onto `display`, and gives the display it left
    /// something to show.
    ///
    /// The relationship was one-way before this: `homeDisplay` was assigned
    /// by the model and by profile restore, and nothing the user could do
    /// reassigned it — so a workspace that ended up on the laptop panel
    /// stayed there, and pressing its number yanked focus across instead of
    /// bringing the workspace over. Returns the displays whose contents
    /// changed.
    @discardableResult
    public func moveWorkspace(_ n: Int, toDisplay display: DisplayID) -> Set<DisplayID> {
        guard displays.contains(display) else { return [] }
        let ws = workspace(n)
        guard ws.homeDisplay != display else { return [] }
        var affected: Set<DisplayID> = [display]

        // If it was on screen somewhere, that display needs a replacement —
        // otherwise it would keep showing a workspace that now lives
        // elsewhere.
        if let previous = activeWorkspaceByDisplay.first(where: { $0.value == n })?.key {
            activeWorkspaceByDisplay.removeValue(forKey: previous)
            affected.insert(previous)
        }
        // The target's current occupant goes back to being just a workspace.
        activeWorkspaceByDisplay[display] = n
        ws.homeDisplay = display
        ws.preferredDisplay = display

        // Every display still needs something active, including the one we
        // just vacated.
        for d in displays where activeWorkspaceByDisplay[d] == nil {
            _ = activeWorkspace(on: d)
            affected.insert(d)
        }
        focusedDisplay = display
        return affected
    }

    /// Moves every window in the model into the given workspace — the
    /// `leader w` rescue command backing the "never lose a window" invariant.
    /// Windows move in ascending id order: Dictionary key order varies with
    /// the per-process hash seed, and the recovery keystroke must produce
    /// the same layout every time.
    public func rescueAllWindows(into n: Int) {
        let all = windowWorkspace.keys.sorted { $0.raw < $1.raw }
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
