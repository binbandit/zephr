import Foundation
import CoreGraphics

/// Layout tuning knobs. Interim hardcoded defaults until the ConfigService
/// (P4, lossless TOML) lands; every value here maps 1:1 to a config key.
public struct LayoutConfig: Sendable, Equatable {
    /// Gap between adjacent tiled windows.
    public var innerGap: CGFloat
    /// Gap between tiled windows and the workspace edge.
    public var outerGap: CGFloat
    /// Width of the collapsed sliver each non-focused accordion sibling keeps.
    public var accordionPadding: CGFloat
    /// Minimum width/height the solver will allot a tile before degrading the
    /// container to accordion.
    public var minTileSize: CGSize
    /// Windows smaller than this at creation are floated by the structural
    /// heuristics (§4.3).
    public var floatIfSmallerThan: CGSize
    /// Smallest share a child may hold in its container.
    public var minRatio: CGFloat
    /// Resize step for the resize mode / chords (fraction of the container).
    public var resizeStep: CGFloat
    public var resizeStepFine: CGFloat

    public init(
        innerGap: CGFloat = 8,
        outerGap: CGFloat = 8,
        accordionPadding: CGFloat = 48,
        minTileSize: CGSize = CGSize(width: 120, height: 90),
        floatIfSmallerThan: CGSize = CGSize(width: 500, height: 350),
        minRatio: CGFloat = 0.05,
        resizeStep: CGFloat = 0.05,
        resizeStepFine: CGFloat = 0.01
    ) {
        self.innerGap = innerGap
        self.outerGap = outerGap
        self.accordionPadding = accordionPadding
        self.minTileSize = minTileSize
        self.floatIfSmallerThan = floatIfSmallerThan
        self.minRatio = minRatio
        self.resizeStep = resizeStep
        self.resizeStepFine = resizeStepFine
    }

    public static let `default` = LayoutConfig()
}
