import Foundation
import CoreGraphics

/// Display profiles and session restore (§4.5) — the signature feature.
///
/// A profile is a full, serializable picture of the model keyed by the
/// display-arrangement fingerprint: workspace→display mapping, every tree
/// with its split ratios, floating frames, and per-window assignments.
/// Windows are recorded as (bundleID, title) fingerprints so a profile
/// survives app restarts and reboots, where macOS hands out new window
/// identities.

public struct DisplaySlot: Sendable, Equatable {
    public let id: DisplayID
    public let frame: CGRect
    public init(id: DisplayID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// A window's session identity: how profiles refer to windows across
/// launches.
public struct WindowFingerprint: Codable, Sendable, Hashable {
    public var bundleID: String
    public var title: String
    public init(bundleID: String, title: String) {
        self.bundleID = bundleID
        self.title = title
    }
}

public struct NodeSnapshot: Codable, Sendable {
    /// Index into `ModelSnapshot.windows` for leaves; nil for containers.
    public var window: Int?
    public var orientation: Orientation?
    public var layout: ContainerLayout?
    public var ratio: CGFloat
    public var children: [NodeSnapshot]
}

public struct WorkspaceSnapshot: Codable, Sendable {
    public var id: Int
    public var name: String?
    public var root: NodeSnapshot?
    public var floats: [FloatSnapshot]
    public var monocle: Bool
    public var floatByDefault: Bool
    public var homeSlot: Int?
    public var focused: Int?

    public struct FloatSnapshot: Codable, Sendable {
        public var window: Int
        public var frame: CGRect
    }
}

public struct ModelSnapshot: Codable, Sendable {
    public var fingerprint: String
    public var windows: [WindowFingerprint]
    public var workspaces: [WorkspaceSnapshot]
    /// display slot index → active workspace id
    public var activeBySlot: [Int: Int]
}

public enum ProfileEngine {

    /// Stable across reboots: geometry only, order-normalized. Display IDs
    /// are deliberately excluded — CGDirectDisplayIDs churn between boots.
    public static func fingerprint(_ slots: [DisplaySlot]) -> String {
        slots
            .map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            .sorted()
            .joined(separator: "|")
    }

    private static func orderedSlots(_ slots: [DisplaySlot]) -> [DisplaySlot] {
        slots.sorted {
            ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY)
        }
    }

    // MARK: - Capture

    /// Serializes the model. `meta` supplies each window's session identity;
    /// windows without one (no bundle id) are skipped.
    public static func capture(
        model: WorkspaceModel,
        slots: [DisplaySlot],
        meta: (WindowID) -> WindowFingerprint?
    ) -> ModelSnapshot {
        let ordered = orderedSlots(slots)
        var windows: [WindowFingerprint] = []
        var indexByID: [WindowID: Int] = [:]

        func windowIndex(_ id: WindowID) -> Int? {
            if let existing = indexByID[id] { return existing }
            guard let fp = meta(id) else { return nil }
            windows.append(fp)
            indexByID[id] = windows.count - 1
            return windows.count - 1
        }

        func snapshot(_ node: TreeNode) -> NodeSnapshot? {
            if let id = node.windowID {
                guard let idx = windowIndex(id) else { return nil }
                return NodeSnapshot(window: idx, ratio: node.ratio, children: [])
            }
            let children = node.children.compactMap(snapshot)
            guard !children.isEmpty else { return nil }
            return NodeSnapshot(
                window: nil,
                orientation: node.orientation,
                layout: node.layout,
                ratio: node.ratio,
                children: children
            )
        }

        var workspaceSnapshots: [WorkspaceSnapshot] = []
        for ws in model.workspaces.values.sorted(by: { $0.id < $1.id }) {
            guard !ws.isEmpty else { continue }
            let floats: [WorkspaceSnapshot.FloatSnapshot] = ws.floatingOrder.compactMap { id in
                guard let idx = windowIndex(id), let frame = ws.floating[id] else { return nil }
                return .init(window: idx, frame: frame)
            }
            let root = snapshot(ws.root)
            guard root != nil || !floats.isEmpty else { continue }
            workspaceSnapshots.append(WorkspaceSnapshot(
                id: ws.id,
                name: ws.name,
                root: root,
                floats: floats,
                monocle: ws.monocle,
                floatByDefault: ws.floatByDefault,
                homeSlot: ordered.firstIndex { $0.id == ws.homeDisplay },
                focused: ws.focusedWindow.flatMap { indexByID[$0] }
            ))
        }

        var activeBySlot: [Int: Int] = [:]
        for (slotIndex, slot) in ordered.enumerated() {
            if let wsID = model.activeWorkspaceByDisplay[slot.id] {
                activeBySlot[slotIndex] = wsID
            }
        }

        return ModelSnapshot(
            fingerprint: fingerprint(slots),
            windows: windows,
            workspaces: workspaceSnapshots,
            activeBySlot: activeBySlot
        )
    }

    // MARK: - Apply

    /// Rebuilds the model from a snapshot, matching live windows to recorded
    /// fingerprints — exact (bundleID, title) first, then bundleID-only in
    /// FIFO order. Returns live windows the profile didn't place (the caller
    /// re-inserts them normally); unmatched recorded windows are dropped.
    @discardableResult
    public static func apply(
        _ snapshot: ModelSnapshot,
        to model: WorkspaceModel,
        slots: [DisplaySlot],
        live: [WindowID: WindowFingerprint]
    ) -> [WindowID] {
        let ordered = orderedSlots(slots)

        // Match live windows to recorded ones.
        var byExact: [WindowFingerprint: [WindowID]] = [:]
        var byBundle: [String: [WindowID]] = [:]
        for (id, fp) in live.sorted(by: { $0.key.raw < $1.key.raw }) {
            byExact[fp, default: []].append(id)
            byBundle[fp.bundleID, default: []].append(id)
        }
        var claimed = Set<WindowID>()
        var matched: [Int: WindowID] = [:]
        for (index, fp) in snapshot.windows.enumerated() {
            if var candidates = byExact[fp] {
                while let id = candidates.first {
                    candidates.removeFirst()
                    if !claimed.contains(id) {
                        matched[index] = id
                        claimed.insert(id)
                        break
                    }
                }
                byExact[fp] = candidates
            }
        }
        for (index, fp) in snapshot.windows.enumerated() where matched[index] == nil {
            if var candidates = byBundle[fp.bundleID] {
                while let id = candidates.first {
                    candidates.removeFirst()
                    if !claimed.contains(id) {
                        matched[index] = id
                        claimed.insert(id)
                        break
                    }
                }
                byBundle[fp.bundleID] = candidates
            }
        }

        // Reset model membership and rebuild workspaces from the snapshot.
        model.workspaces.removeAll()
        model.windowWorkspace.removeAll()
        model.activeWorkspaceByDisplay.removeAll()

        func rebuild(_ node: NodeSnapshot) -> TreeNode? {
            if let windowIndex = node.window {
                guard let id = matched[windowIndex] else { return nil }
                let leaf = TreeNode(window: id)
                leaf.ratio = node.ratio
                return leaf
            }
            let container = TreeNode(
                container: node.orientation ?? .horizontal,
                layout: node.layout ?? .tiles
            )
            container.ratio = node.ratio
            for child in node.children.compactMap(rebuild) {
                child.parent = container
                container.children.append(child)
            }
            guard !container.children.isEmpty else { return nil }
            return container
        }

        for wsSnapshot in snapshot.workspaces {
            let ws = model.workspace(wsSnapshot.id)
            ws.name = wsSnapshot.name
            ws.floatByDefault = wsSnapshot.floatByDefault
            if ws.monocle != wsSnapshot.monocle { ws.toggleMonocle() }
            if let slotIndex = wsSnapshot.homeSlot, ordered.indices.contains(slotIndex) {
                ws.homeDisplay = ordered[slotIndex].id
            }

            let root = wsSnapshot.root.flatMap(rebuild) ?? TreeNode(container: .horizontal)
            let floats: [(WindowID, CGRect)] = wsSnapshot.floats.compactMap {
                guard let id = matched[$0.window] else { return nil }
                return (id, $0.frame)
            }
            let focused = wsSnapshot.focused.flatMap { matched[$0] }
            ws.adoptContents(root: root, floats: floats, focused: focused)

            for id in ws.allWindows {
                model.windowWorkspace[id] = ws.id
            }
        }

        for (slotIndex, wsID) in snapshot.activeBySlot {
            guard ordered.indices.contains(slotIndex) else { continue }
            model.activeWorkspaceByDisplay[ordered[slotIndex].id] = wsID
            model.workspace(wsID).homeDisplay = ordered[slotIndex].id
        }

        // Re-derive per-display state for anything the snapshot missed.
        model.syncDisplays(slots.map(\.id))

        return live.keys.filter { !claimed.contains($0) }.sorted { $0.raw < $1.raw }
    }
}
