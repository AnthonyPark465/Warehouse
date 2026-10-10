import Foundation

/// Central configuration for object isolation and measurement. Distances are
/// metres unless a name says otherwise. Defaults target hand-sized products,
/// not rooms or furniture.
///
/// Every threshold below is an engineering default chosen from the sensor's
/// nominal behaviour and synthetic fixtures. None has been calibrated against
/// physical ground truth; see `docs/manual-ar-measurement.md` for the
/// validation procedure that must precede any accuracy statement.
struct LiDARFusionConfiguration: Equatable {
    // MARK: Frame validation

    /// Nearest usable depth. Closer returns are inside the sensor's minimum
    /// working range and are unreliable.
    var minimumDepthMetres: Float = 0.10
    /// Farthest usable depth. Depth noise grows with range, and a hand-sized
    /// product is never scanned from farther away.
    var maximumDepthMetres: Float = 5
    /// Lowest accepted `ARConfidenceLevel` raw value (0 low, 1 medium, 2 high).
    /// Low-confidence samples cluster on edges and reflective surfaces.
    var minimumDepthConfidenceLevel = 1
    /// Depth-map subsampling step in pixels; 2 keeps one sample in four,
    /// which still exceeds the voxel density at typical scan distances.
    var depthPixelStride = 2
    /// Minimum spacing between processed frames (10 Hz). Consecutive 60 Hz
    /// frames are nearly identical and would count one view many times.
    /// The capture layer throttles to this; the engine also enforces it.
    var frameIntervalSeconds: Double = 0.1
    /// Slack on the spacing check for timestamp rounding.
    var frameIntervalToleranceSeconds: Double = 0.001
    /// A frame contributing fewer in-region voxels than this adds no evidence
    /// and is not counted as accepted.
    var minimumFramePointCount = 1
    /// Limited tracking lasting longer than this may have let the world
    /// origin drift, so earlier evidence is discarded.
    var maximumLimitedTrackingSeconds: Double = 1.0
    /// A camera displacement implying more than this speed between accepted
    /// frames is treated as a coordinate-system discontinuity, not motion.
    var maximumCameraSpeedMetresPerSecond: Float = 3

    // MARK: Voxel fusion

    /// Spatial fusion resolution; smaller values improve detail but need more samples.
    var voxelSize: Float = 0.003
    /// A voxel must be seen in this many distinct frames; rejects transient
    /// single-frame returns.
    var minimumFrameObservations = 3
    /// A voxel seen in at least this many frames is kept even when it has not
    /// been observed recently (the far side of the product while walking round).
    var persistentObservationCount = 6
    /// A voxel below `persistentObservationCount` that has not been seen for
    /// this many accepted frames is expired as stale (a hand, a moved item).
    var weakVoxelExpiryFrames = 60
    /// Even a well-established voxel expires after this many accepted frames
    /// unseen (a minute), so a product replaced mid-scan cannot linger.
    var persistentVoxelExpiryFrames = 600
    /// Expired voxels that had passed the multi-frame filter are reported
    /// once they reach this share of the selected component.
    var expiredGeometryWarningFraction = 0.05
    /// Small allowance at the locked crop boundary for LiDAR quantization.
    var cropMargin: Float = 0.003

    // MARK: Support-plane estimation

    /// Vertical histogram resolution used for horizontal support-plane detection.
    var supportPlaneBinSize: Float = 0.003
    /// A height bin needs at least this many voxels to be a plane candidate…
    var supportPlaneMinimumSamples = 24
    /// …and at least this share of all stable voxels, so a product's own
    /// ledge is not mistaken for the support.
    var supportPlaneMinimumFraction = 0.04
    /// From the lowest candidate bin, climb at most this many bins toward a
    /// more populated neighbour: the lowest bin is the noise tail of the
    /// plane, not its centre.
    var supportPlanePeakClimbBins = 2
    /// Minimum thickness removed above the support coordinate.
    var supportPlaneNoiseBand: Float = 0.006
    /// The removal band widens to this many robust standard deviations of the
    /// measured plane noise…
    var supportPlaneNoiseSigmaMultiplier: Float = 3
    /// …but never beyond this, so a noisy plane cannot erase a flat product.
    /// Reaching the cap is reported as `supportPlaneNoisy`.
    var maximumSupportPlaneNoiseBand: Float = 0.012
    /// Percentile of all heights used as the lower boundary when no plane
    /// candidate exists. Reported as `supportPlaneNotFound`.
    var supportPlaneFallbackPercentile = 0.02
    /// Support voxels this far outside the product footprint count as proof
    /// that a surface, not the product's own underside, was detected.
    var supportFootprintMarginInVoxels = 2

    /// Voxels below the support are tolerated up to this share of the
    /// plane's inliers (its noise tail), and always below
    /// `minimumReportedComponentVoxelCount`.
    var supportBelowToleranceFraction = 0.005
    /// The lowest product voxel may sit this far above the removed band
    /// (holes near the base). Farther, and the detected surface is not the
    /// one the product rests on.
    var maximumSupportContactGap: Float = 0.012

    // MARK: Component selection

    /// Strict region-growing reach: 26-neighbour contact only.
    var strictConnectivityRadiusInVoxels = 1
    /// Expanded reach used only by the recorded fallback; 2 bridges a single
    /// missing voxel (one LiDAR hole). It is a Euclidean reach, so a diagonal
    /// (2, 2, 2) step, which spans 10 mm, does not count.
    var connectivityRadiusInVoxels = 2
    /// Segmented voxels required for a component to count as an object.
    var minimumStableVoxelCount = 120
    /// The selected seed must be reasonably close to retained target geometry.
    var maximumSeedDistance: Float = 0.08
    /// Loose fragments beside the selected component are reported once they
    /// hold at least this share of its voxels: part of the product may have
    /// been left out.
    var fragmentationWarningFraction = 0.2
    /// A selection that exists only as bridged fragments is refused once
    /// unbridged fragments within `neighbourProximityWarningDistance` of it
    /// hold at least this share of the voxels of both together: the reach
    /// joined a piece of a patchy surface, not an object. Chosen on
    /// synthetic fixtures only.
    var partialSelectionFragmentFraction = 0.2
    /// A rejected component nearer than this to the selection is reported as
    /// a nearby object: one more missing voxel row could bridge it.
    var neighbourProximityWarningDistance: Float = 0.015
    /// Rejected components smaller than this are noise specks and are only
    /// counted, not described.
    var minimumReportedComponentVoxelCount = 12
    /// Maximum rejected components described individually in the evidence.
    var maximumReportedRejectedComponents = 6

    // MARK: Free-space evidence (experimental, off by default)

    /// When true, a gap is bridged only if no depth ray was seen passing
    /// through it. A ray that crossed a voxel and hit something beyond it
    /// proves the voxel is empty, which a missing return does not. Not
    /// validated on a device, so it does not change the default behaviour.
    var freeSpaceGatingEnabled = false
    /// A ray stops counting as free space this far before its hit point, so
    /// depth noise on a surface is not read as space behind that surface.
    var freeSpaceCarveMarginInVoxels: Float = 2
    /// Distinct frames that must see through a voxel before it counts as
    /// empty; the same bar a voxel must clear to count as occupied.
    var freeSpaceMinimumFrameObservations = 3
    /// The free-space grid covers the region's bounding box. A region
    /// needing more cells than this is not tracked, and gating is skipped.
    var freeSpaceMaximumCellCount = 6_000_000

    // MARK: Ablation switches (evaluation only)

    /// False measures height from the lowest retained product voxel instead
    /// of the support coordinate. Exists to measure what retaining the
    /// coordinate contributes; the app never sets it.
    var heightUsesSupportCoordinate = true
    /// False bridges every component at the expanded reach, object-sized or
    /// not: a single fixed connectivity radius. Evaluation only.
    var connectivityIsConditional = true

    // MARK: Bounds estimation

    /// Robust oriented-bound percentiles; trims isolated fused outliers.
    var lowerPercentile = 0.01
    var upperPercentile = 0.99
    /// Points used for the yaw search; extents always use the full set.
    var orientationSearchPointLimit = 256
    /// Coarse and fine yaw search steps in degrees.
    var orientationCoarseStepDegrees: Float = 3
    var orientationFineStepDegrees: Float = 0.25
    /// A later yaw candidate must beat the best area by this fraction, so
    /// near-ties (square or round footprints) resolve to the first angle.
    var orientationTieTolerance: Float = 1e-4

    // MARK: Boundary contact

    /// Product points this close to a region face indicate possible clipping.
    var boundaryWarningDistance: Float = 0.006
    /// Voxels required near one face before contact is declared, so a single
    /// stray voxel is not reported as clipping.
    var boundaryContactMinimumVoxels = 6

    // MARK: Coverage

    /// Camera azimuths around the seed are binned at this resolution.
    var viewpointAzimuthBinDegrees = 5
    /// Smallest arc of camera azimuths that can expose two adjacent vertical
    /// faces of a box. Below it, one horizontal dimension is unobserved.
    var minimumViewpointSpanDegrees = 60
    /// A footprint side is "supported" when at least this fraction of its
    /// length has voxels within `sideSupportBandInVoxels` of the edge.
    var minimumSideSupportFraction = 0.35
    var sideSupportBandInVoxels: Float = 2
    /// The top is "observed" when voxels near the top height cover at least
    /// this fraction of the footprint rectangle.
    var minimumTopCoverageFraction = 0.25

    /// An interior slice of the footprint this many times denser than the
    /// median slice is a vertical sheet inside the shape: usually the facing
    /// sides of two objects too close for the voxel grid to separate.
    var interiorPartitionDensityRatio = 3.0
    /// …and it must hold at least this many voxels, so a sparse scan's
    /// uneven slices are not mistaken for a sheet.
    var interiorPartitionMinimumVoxels = 60
    /// Slices this close to either end are the object's own outer faces.
    var interiorPartitionEdgeMarginInVoxels = 3

    // MARK: Stability analysis

    /// Analysis runs once per this many accepted frames. Once a result can
    /// be finished it runs on every accepted frame instead, so the offer to
    /// finish always reflects the evidence fused so far.
    var measurementIntervalFrames = 4
    /// Estimates retained for stability analysis.
    var stabilityWindow = 5
    /// Estimates in the window that must agree with the newest one.
    var stableEstimateCount = 3
    /// Estimates agree when each dimension differs by at most this fraction…
    var estimateConsistencyTolerance = 0.08
    /// …or by this absolute amount (two voxels), whichever is larger, so
    /// small products do not flap on quantization alone.
    var estimateConsistencyFloorCM = 0.6
    /// A dimension increase beyond this fraction is flagged as a jump: the
    /// usual cause is nearby geometry joining the selection.
    var dimensionJumpThreshold = 0.25

    // MARK: Acceptance

    /// Accepted frames (since the last coordinate reset) required to finish.
    var minimumFusedFrameCount = 20
    /// A dimension is refused when its estimated uncertainty exceeds this
    /// fraction of the dimension…
    var maximumRelativeUncertainty = 0.10
    /// …unless the uncertainty is below this absolute floor.
    var maximumUncertaintyFloorCM = 1.0
    /// Extra uncertainty per sparsely observed footprint side, in voxels.
    var sparseSideUncertaintyInVoxels: Float = 2

    // MARK: Coverage score (application-level indicator, not accuracy)

    var coverageFrameWeight = 0.25
    var coverageVoxelWeight = 0.25
    var coverageObservationWeight = 0.20
    var coverageStabilityWeight = 0.30
    /// Frames, voxels and mean observations at which each term saturates.
    var coverageFrameSaturationMultiple = 2.0
    var coverageVoxelSaturationMultiple = 6.0
    var coverageObservationSaturation = 8.0
    /// Stability term while dimensions are not yet stable.
    var coverageUnstableScore = 0.25
    /// The score never reaches 1: it is not a probability of correctness.
    var coverageScoreCeiling = 0.95
    /// A qualified (warning-bearing) measurement is never graded "good".
    var qualifiedCoverageScoreCeiling = 0.79

    /// One voxel is added to each horizontal extent, and half a voxel to the
    /// top, to compensate for percentile trimming and for fused positions
    /// being voxel centroids that sit inside the true surface edge.
    var extentQuantizationCompensation: Float { voxelSize }

    static let smallObject = LiDARFusionConfiguration()
}
