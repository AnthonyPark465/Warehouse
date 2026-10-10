import Foundation
import simd

/// One registered depth observation: world-space points plus the capture
/// metadata needed to decide whether the frame may contribute evidence.
struct LiDARDepthFrame {
    var points: [SIMD3<Float>]
    var timestamp: TimeInterval
    var tracking = LiDARTrackingQuality.normal
    /// Incremented by the capture layer whenever the session's world
    /// coordinate system may have changed (interruption, re-run).
    var coordinateEpoch = 0
    var cameraPosition: SIMD3<Float>?
    var source = LiDARDepthSource.unspecified
    /// Per-sample statistics gathered while reading the depth map.
    var examinedSampleCount = 0
    var lowConfidenceSampleCount = 0
    var outOfRangeSampleCount = 0
    var highConfidenceSampleCount = 0
}

/// Per-sample acceptance rule applied while reading a depth map.
enum LiDARDepthSampleFilter {
    enum Verdict: Equatable {
        case accepted(isHighConfidence: Bool)
        case outOfRange
        case lowConfidence
    }

    /// `confidenceLevel` is the `ARConfidenceLevel` raw value, or nil when
    /// the frame carries no confidence map.
    static func classify(
        depth: Float,
        confidenceLevel: Int?,
        configuration: LiDARFusionConfiguration
    ) -> Verdict {
        guard depth.isFinite,
              depth >= configuration.minimumDepthMetres,
              depth <= configuration.maximumDepthMetres
        else { return .outOfRange }
        guard let confidenceLevel else { return .accepted(isHighConfidence: false) }
        guard confidenceLevel >= configuration.minimumDepthConfidenceLevel else {
            return .lowConfidence
        }
        return .accepted(isHighConfidence: confidenceLevel > configuration.minimumDepthConfidenceLevel)
    }
}

enum LiDARFrameDisposition: Equatable {
    case accepted
    /// Accepted as the first frame after earlier evidence was discarded.
    case acceptedAfterReset
    case rejected(LiDARFrameRejectionReason)

    var isAccepted: Bool {
        switch self {
        case .accepted, .acceptedAfterReset: true
        case .rejected: false
        }
    }
}

struct LiDARFusionIntegrationResult: Equatable {
    let disposition: LiDARFrameDisposition
    /// Distinct voxels observed by this frame.
    let acceptedPointCount: Int
    let rejectedOutsideVolumeCount: Int
    /// Earlier voxels were discarded while handling this frame.
    let evidenceWasInvalidated: Bool
}

struct LiDARFusionMeasurement: Equatable {
    let dimensionsCM: ObjectDimensions
    let centredPointsInMetres: [SIMD3<Float>]
    let worldPointsInMetres: [SIMD3<Float>]
    let boundingBoxCornersWorld: [SIMD3<Float>]
    let touchesRegionBoundary: Bool
    let fusedVoxelCount: Int
    let averageObservationsPerVoxel: Double
    let supportPlaneY: Float
    let connectivityMode: LiDARComponentSelection.Mode
}

/// Output of every geometric stage for the evidence currently fused.
struct LiDARGeometryAnalysis: Equatable {
    /// Present when every geometric stage produced a result, even if
    /// `failures` then disqualifies it.
    var measurement: LiDARFusionMeasurement?
    var voxels = LiDARVoxelEvidence()
    var supportPlane: LiDARSupportPlaneEvidence?
    var components: LiDARComponentEvidence?
    var freeSpace: LiDARFreeSpaceEvidence?
    var bounds: LiDARBoundsEvidence?
    var boundaryContacts: [LiDARBoundaryContact] = []
    var coverage: LiDARCoverageEvidence?
    var failures: [LiDARMeasurementReasonCode] = []
    var warnings: [LiDARMeasurementReasonCode] = []
    var fallbacks: [LiDARMeasurementReasonCode] = []
    /// Sparse footprint sides bounding the length and width axes.
    var sparseSidesOnLength = 0
    var sparseSidesOnWidth = 0
}

/// Frame validation, voxel fusion, and orchestration of the geometric stages
/// in `LiDARMeasurementStages.swift`:
///
///     frame validation → voxel fusion → support-plane estimation
///         → component selection → bounds estimation → coverage
///
/// Stability analysis and final acceptance live in `LiDARMeasurementSession`.
final class LiDARVoxelFusionEngine {
    private struct Voxel {
        var positionSum: SIMD3<Float>
        var frameObservations: Int
        var lastObservedFrame: Int
    }

    let configuration: LiDARFusionConfiguration
    private var selection: (region: LiDARSpatialRegion, seed: SIMD3<Float>)?
    private var voxels: [LiDARVoxelKey: Voxel] = [:]
    /// Nil unless free-space gating is enabled and the region fits the grid.
    private var freeSpace: LiDARFreeSpaceGrid?

    private(set) var frameEvidence = LiDARFrameEvidence()
    private(set) var lastFrameTracking = LiDARTrackingQuality.normal
    /// False once a normally tracked frame arrives with no depth inside the
    /// region; true again on the next accepted frame.
    private(set) var productIsInView = true
    private var expiredVoxelCount = 0
    private var expiredStableVoxelCount = 0
    private var coordinateEpoch: Int?
    private var lastTimestamp: TimeInterval?
    private var limitedTrackingSince: TimeInterval?
    private var lastCamera: (position: SIMD3<Float>, timestamp: TimeInterval)?
    private var azimuthBins: [Bool] = []
    private var viewpointFrameCount = 0

    init(configuration: LiDARFusionConfiguration = .smallObject) {
        self.configuration = configuration
    }

    var voxelCount: Int { voxels.count }
    /// Depth rays behind the current free-space evidence; 0 when gating is off.
    var freeSpaceRayCount: Int { freeSpace?.rayCount ?? 0 }

    func lockSelection(volume: LiDARScanVolume, seed: SIMD3<Float>) {
        lockSelection(region: .box(volume), seed: seed)
    }

    func lockSelection(region: LiDARSpatialRegion, seed: SIMD3<Float>) {
        reset()
        selection = (region, seed)
        if configuration.freeSpaceGatingEnabled {
            freeSpace = LiDARFreeSpaceGrid(
                region: region,
                cellSize: configuration.voxelSize,
                margin: configuration.cropMargin,
                maximumCellCount: configuration.freeSpaceMaximumCellCount
            )
        }
    }

    func reset() {
        selection = nil
        voxels.removeAll(keepingCapacity: true)
        freeSpace = nil
        frameEvidence = LiDARFrameEvidence()
        lastFrameTracking = .normal
        productIsInView = true
        expiredVoxelCount = 0
        expiredStableVoxelCount = 0
        coordinateEpoch = nil
        lastTimestamp = nil
        limitedTrackingSince = nil
        lastCamera = nil
        azimuthBins = []
        viewpointFrameCount = 0
    }

    // MARK: Frame validation and voxel fusion

    /// Integrates points with no capture metadata, as one normally tracked
    /// frame. Viewpoint coverage is unknown for frames added this way.
    @discardableResult
    func integrate(framePoints: [SIMD3<Float>]) -> LiDARFusionIntegrationResult {
        return integrate(frame: LiDARDepthFrame(
            points: framePoints,
            timestamp: (lastTimestamp ?? 0) + configuration.frameIntervalSeconds
        ))
    }

    /// Validates one frame, then adds at most one averaged observation per
    /// voxel. The locked region is enforced here, before a point can enter
    /// fusion.
    @discardableResult
    func integrate(frame: LiDARDepthFrame) -> LiDARFusionIntegrationResult {
        frameEvidence.capturedFrameCount += 1
        frameEvidence.examinedDepthSampleCount += frame.examinedSampleCount
        frameEvidence.lowConfidenceSampleCount += frame.lowConfidenceSampleCount
        frameEvidence.outOfRangeSampleCount += frame.outOfRangeSampleCount
        frameEvidence.highConfidenceSampleCount += frame.highConfidenceSampleCount
        if frame.source != .unspecified { frameEvidence.depthSource = frame.source }
        lastFrameTracking = frame.tracking

        func rejected(
            _ reason: LiDARFrameRejectionReason,
            outside: Int = 0,
            invalidated: Bool = false
        ) -> LiDARFusionIntegrationResult {
            frameEvidence.rejectedFrameCounts[reason.rawValue, default: 0] += 1
            return LiDARFusionIntegrationResult(
                disposition: .rejected(reason),
                acceptedPointCount: 0,
                rejectedOutsideVolumeCount: outside,
                evidenceWasInvalidated: invalidated
            )
        }

        guard let selection else {
            return rejected(.noSelectionLocked, outside: frame.points.count)
        }

        // Evidence from an earlier coordinate system must never be fused
        // with new observations. This is checked before anything that can
        // reject the frame, so a reset is honoured even when the frame that
        // announces it is unusable.
        var invalidated = false
        if let coordinateEpoch, coordinateEpoch != frame.coordinateEpoch {
            invalidated = invalidateEvidence() || invalidated
        }
        coordinateEpoch = frame.coordinateEpoch

        guard frame.timestamp.isFinite else {
            return rejected(.invalidTimestamp, invalidated: invalidated)
        }
        if let lastTimestamp {
            guard frame.timestamp > lastTimestamp else {
                return rejected(.invalidTimestamp, invalidated: invalidated)
            }
            let minimumSpacing = configuration.frameIntervalSeconds
                - configuration.frameIntervalToleranceSeconds
            guard frame.timestamp - lastTimestamp >= minimumSpacing else {
                return rejected(.tooSoonAfterPreviousFrame, invalidated: invalidated)
            }
        }
        lastTimestamp = frame.timestamp

        switch frame.tracking {
        case .normal:
            limitedTrackingSince = nil
            frameEvidence.trackingNormalFrameCount += 1
        case .limited:
            let since = limitedTrackingSince ?? frame.timestamp
            limitedTrackingSince = since
            if frame.timestamp - since > configuration.maximumLimitedTrackingSeconds {
                invalidated = invalidateEvidence() || invalidated
            }
            return rejected(.trackingNotNormal, invalidated: invalidated)
        case .relocalizing, .notAvailable:
            invalidated = invalidateEvidence() || invalidated
            return rejected(.trackingNotNormal, invalidated: invalidated)
        }

        if let camera = frame.cameraPosition {
            if let lastCamera {
                let elapsed = max(
                    frame.timestamp - lastCamera.timestamp,
                    configuration.frameIntervalSeconds
                )
                let allowed = configuration.maximumCameraSpeedMetresPerSecond * Float(elapsed)
                if simd_distance(camera, lastCamera.position) > allowed {
                    invalidated = invalidateEvidence() || invalidated
                }
            }
            lastCamera = (camera, frame.timestamp)
        }

        var frameBins: [LiDARVoxelKey: (sum: SIMD3<Float>, count: Int)] = [:]
        frameBins.reserveCapacity(min(frame.points.count, 4_096))
        var outside = 0
        var inRegion = 0
        var nonFinite = 0
        for point in frame.points {
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                nonFinite += 1
                continue
            }
            guard selection.region.contains(point, margin: configuration.cropMargin) else {
                outside += 1
                continue
            }
            inRegion += 1
            let key = LiDARVoxelKey.containing(point, cellSize: configuration.voxelSize)
            if let existing = frameBins[key] {
                frameBins[key] = (existing.sum + point, existing.count + 1)
            } else {
                frameBins[key] = (point, 1)
            }
        }
        frameEvidence.nonFiniteSampleCount += nonFinite
        frameEvidence.outsideRegionSampleCount += outside
        frameEvidence.inRegionSampleCount += inRegion
        frameEvidence.duplicateSampleCount += inRegion - frameBins.count

        guard frameBins.count >= configuration.minimumFramePointCount else {
            productIsInView = false
            return rejected(.noPointsInRegion, outside: outside, invalidated: invalidated)
        }
        productIsInView = true

        frameEvidence.acceptedFrameCount += 1
        frameEvidence.acceptedFrameCountSinceReset += 1
        let frameIndex = frameEvidence.acceptedFrameCountSinceReset
        // Each voxel is updated independently, so iteration order here does
        // not affect the fused state.
        for (key, bin) in frameBins {
            let frameAverage = bin.sum / Float(bin.count)
            if var voxel = voxels[key] {
                voxel.positionSum += frameAverage
                voxel.frameObservations += 1
                voxel.lastObservedFrame = frameIndex
                voxels[key] = voxel
            } else {
                voxels[key] = Voxel(
                    positionSum: frameAverage,
                    frameObservations: 1,
                    lastObservedFrame: frameIndex
                )
            }
        }
        expireWeakVoxels(at: frameIndex)
        if let camera = frame.cameraPosition {
            recordViewpoint(camera, selection: selection)
            // Every return, inside the region or beyond it, shows the space
            // in front of it to be empty.
            freeSpace?.integrate(
                camera: camera,
                points: frame.points,
                stopShort: configuration.freeSpaceCarveMarginInVoxels * configuration.voxelSize,
                frame: UInt32(truncatingIfNeeded: frameEvidence.acceptedFrameCount)
            )
        }

        return LiDARFusionIntegrationResult(
            disposition: invalidated ? .acceptedAfterReset : .accepted,
            acceptedPointCount: frameBins.count,
            rejectedOutsideVolumeCount: outside,
            evidenceWasInvalidated: invalidated
        )
    }

    /// Discards every fused observation. Returns false when there was
    /// nothing to discard, so an idle engine does not count a reset.
    @discardableResult
    private func invalidateEvidence() -> Bool {
        lastCamera = nil
        limitedTrackingSince = nil
        guard !voxels.isEmpty || frameEvidence.acceptedFrameCountSinceReset > 0 else {
            return false
        }
        voxels.removeAll(keepingCapacity: true)
        freeSpace?.removeAll()
        azimuthBins = []
        viewpointFrameCount = 0
        expiredVoxelCount = 0
        expiredStableVoxelCount = 0
        frameEvidence.acceptedFrameCountSinceReset = 0
        frameEvidence.coordinateResetCount += 1
        return true
    }

    /// A voxel that never became well established and has not been seen for
    /// a while was a moving or momentary surface, not the product.
    private func expireWeakVoxels(at frameIndex: Int) {
        let expiry = configuration.weakVoxelExpiryFrames
        guard expiry > 0, frameIndex.isMultiple(of: max(1, expiry / 4)) else { return }
        let before = voxels.count
        var expiredStable = 0
        let persistentExpiry = max(expiry, configuration.persistentVoxelExpiryFrames)
        voxels = voxels.filter {
            let unseen = frameIndex - $0.value.lastObservedFrame
            if unseen <= expiry { return true }
            if $0.value.frameObservations >= configuration.persistentObservationCount,
               unseen <= persistentExpiry {
                return true
            }
            if $0.value.frameObservations >= configuration.minimumFrameObservations {
                expiredStable += 1
            }
            return false
        }
        expiredVoxelCount += before - voxels.count
        expiredStableVoxelCount += expiredStable
    }

    private func recordViewpoint(
        _ camera: SIMD3<Float>,
        selection: (region: LiDARSpatialRegion, seed: SIMD3<Float>)
    ) {
        let binDegrees = max(1, configuration.viewpointAzimuthBinDegrees)
        let binCount = 360 / binDegrees
        if azimuthBins.count != binCount {
            azimuthBins = [Bool](repeating: false, count: binCount)
        }
        let offset = selection.region.coordinates(of: camera)
            - selection.region.coordinates(of: selection.seed)
        // Directly overhead has no meaningful azimuth.
        guard simd_length(SIMD2(offset.x, offset.z)) > configuration.voxelSize else { return }
        var degrees = atan2(offset.z, offset.x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        azimuthBins[min(Int(degrees) / binDegrees, binCount - 1)] = true
        viewpointFrameCount += 1
    }

    // MARK: Geometric stages

    /// The latest geometric estimate, or nil when a stage could not complete.
    /// Acceptance is decided separately; see `LiDARMeasurementSession`.
    func measurement() -> LiDARFusionMeasurement? {
        analyze().measurement
    }

    func analyze() -> LiDARGeometryAnalysis {
        var analysis = LiDARGeometryAnalysis()
        guard let selection else {
            analysis.failures = [.noSelectionLocked]
            return analysis
        }
        let region = selection.region

        // Temporal filter. Sorting by key fixes the order every later stage
        // sees, whatever order the dictionary happens to iterate in.
        var stable: [LiDARStableVoxel] = []
        stable.reserveCapacity(voxels.count)
        var observationSum = 0
        for (key, voxel) in voxels
        where voxel.frameObservations >= configuration.minimumFrameObservations {
            let position = voxel.positionSum / Float(voxel.frameObservations)
            stable.append(LiDARStableVoxel(
                key: key,
                position: position,
                local: region.coordinates(of: position),
                observations: voxel.frameObservations
            ))
            observationSum += voxel.frameObservations
        }
        stable.sort { $0.key < $1.key }
        analysis.voxels = LiDARVoxelEvidence(
            totalVoxelCount: voxels.count,
            stableVoxelCount: stable.count,
            transientVoxelCount: voxels.count - stable.count,
            expiredVoxelCount: expiredVoxelCount,
            expiredStableVoxelCount: expiredStableVoxelCount,
            meanObservationsPerStableVoxel: stable.isEmpty
                ? 0
                : Double(observationSum) / Double(stable.count)
        )
        guard stable.count >= configuration.minimumStableVoxelCount else {
            analysis.failures = [.insufficientStableGeometry]
            return analysis
        }

        // Support plane.
        guard let support = LiDARSupportPlaneEstimator.estimate(
            heights: stable.map { $0.local.y },
            configuration: configuration
        ) else {
            analysis.failures = [.supportPlaneNotFound]
            return analysis
        }
        let supportWorldY = region.worldPoint(horizontal: .zero, height: support.coordinate).y
        var supportEvidence = LiDARSupportPlaneEvidence(
            coordinateMetres: Double(support.coordinate),
            worldHeightMetres: Double(supportWorldY),
            method: support.method.rawValue,
            inlierCount: support.inlierCount,
            residualMetres: support.residual.map(Double.init),
            removalBandMetres: Double(support.removalBand),
            removalBandWasCapped: support.removalBandWasCapped,
            voxelsBeyondFootprint: nil,
            contactGapMetres: nil,
            voxelsBelowSupport: nil
        )
        analysis.supportPlane = supportEvidence
        if support.method == .percentileFallback {
            analysis.failures.append(.supportPlaneNotFound)
        }
        if support.removalBandWasCapped {
            analysis.warnings.append(.supportPlaneNoisy)
        }
        if support.method == .histogramPeak {
            // Nothing should lie under the surface a product stands on.
            let floor = support.coordinate - support.removalBand
            let below = stable.reduce(0) { $0 + ($1.local.y < floor ? 1 : 0) }
            supportEvidence.voxelsBelowSupport = below
            analysis.supportPlane = supportEvidence
            let tolerated = max(
                Double(configuration.minimumReportedComponentVoxelCount),
                configuration.supportBelowToleranceFraction * Double(support.inlierCount)
            )
            if Double(below) >= tolerated {
                analysis.failures.append(.geometryBelowSupport)
            }
        }

        // The support and its noise band are removed from segmentation, but
        // `support.coordinate` stays the lower height boundary, so removing
        // the contact band does not shorten the product.
        let aboveSupport = stable.filter { $0.local.y > support.removalThreshold }
        guard aboveSupport.count >= configuration.minimumStableVoxelCount else {
            analysis.failures.append(.insufficientGeometryAboveSupport)
            return analysis
        }

        // Free-space evidence: a voxel counts as observed empty when enough
        // frames saw through it, and more saw through it than saw a surface
        // in it.
        var isObservedEmpty: ((LiDARVoxelKey) -> Bool)?
        if configuration.freeSpaceGatingEnabled {
            let isUsable = freeSpace.map { $0.rayCount > 0 } ?? false
            analysis.freeSpace = LiDARFreeSpaceEvidence(
                wasAvailable: isUsable,
                rayCount: freeSpace?.rayCount ?? 0,
                observedVoxelCount: freeSpace?.observedVoxelCount ?? 0,
                minimumFrameObservations: configuration.freeSpaceMinimumFrameObservations,
                carveMarginMetres: Double(
                    configuration.freeSpaceCarveMarginInVoxels * configuration.voxelSize
                )
            )
            if isUsable, let grid = freeSpace {
                let minimum = max(1, configuration.freeSpaceMinimumFrameObservations)
                let occupied = voxels
                isObservedEmpty = { key in
                    let seenThrough = grid.frameCount(at: key)
                    return seenThrough >= minimum
                        && seenThrough > (occupied[key]?.frameObservations ?? 0)
                }
            }
        }

        // Component selection.
        let selected = LiDARComponentSelector.select(
            voxels: aboveSupport,
            seed: selection.seed,
            configuration: configuration,
            isObservedEmpty: isObservedEmpty
        )
        if let failure = selected.failure {
            analysis.failures.append(failure)
            return analysis
        }
        guard let selectedStatistics = selected.selected else {
            analysis.failures.append(.insufficientConnectedGeometry)
            return analysis
        }
        analysis.components = LiDARComponentEvidence(
            connectivityMode: selected.mode.rawValue,
            fallbackReason: selected.fallbackReason?.rawValue,
            strictRadiusInVoxels: configuration.strictConnectivityRadiusInVoxels,
            expandedRadiusInVoxels: configuration.connectivityRadiusInVoxels,
            selected: selectedStatistics,
            absorbedFragmentCount: selected.absorbedFragmentCount,
            absorbedVoxelCount: selected.absorbedVoxelCount,
            rejectedComponentCount: selected.rejectedComponentCount,
            rejectedVoxelCount: selected.rejectedVoxelCount,
            rejected: selected.rejected,
            looseFragmentVoxelCount: selected.looseFragmentVoxelCount,
            freeSpaceBlockedBridgeCount: isObservedEmpty == nil
                ? nil
                : selected.freeSpaceBlockedBridgeCount,
            nearbyFragmentVoxelCount: selected.nearbyFragmentVoxelCount
        )
        if selected.significantFragmentsExcluded {
            analysis.warnings.append(.fragmentsExcluded)
        }
        if selected.mode == .expanded {
            analysis.fallbacks.append(.expandedConnectivityUsed)
        }
        // A sliver bridged out of a patchy surface stands on the support and
        // is stable and evenly covered within its own bounds, so no later
        // check can tell it from a small product.
        if selected.selectionLooksPartial {
            analysis.failures.append(.possiblePartialObject)
        }
        if selected.nearbyObjectDetected {
            analysis.warnings.append(.nearbyObjectClose)
        }

        let component = selected.selectedIndices.map { aboveSupport[$0] }
        let componentLocal = component.map { $0.local }

        // The product must rest on the surface that was detected. A lower
        // shelf or the floor would otherwise be taken as its base.
        let lowest = componentLocal.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
        let contactGap = lowest - support.removalThreshold
        supportEvidence.contactGapMetres = Double(contactGap)
        analysis.supportPlane = supportEvidence
        if contactGap > configuration.maximumSupportContactGap {
            analysis.failures.append(.objectNotOnSupport)
        }
        let expiryLimit = max(
            Double(configuration.minimumReportedComponentVoxelCount),
            configuration.expiredGeometryWarningFraction * Double(component.count)
        )
        if Double(expiredStableVoxelCount) >= expiryLimit {
            analysis.warnings.append(.weakGeometryExpired)
        }

        // Bounds. The support coordinate, not the lowest retained voxel, is
        // the lower height boundary (the alternative exists for ablation).
        guard let bounds = LiDARBoundsEstimator.estimate(
            local: componentLocal,
            supportCoordinate: configuration.heightUsesSupportCoordinate
                ? support.coordinate
                : lowest,
            configuration: configuration
        ) else {
            analysis.failures.append(.degenerateBounds)
            return analysis
        }
        analysis.bounds = LiDARBoundsEvidence(
            yawDegrees: Double(bounds.yawRadians) * 180 / .pi,
            trimmedExtentsCM: bounds.trimmedExtentsCM,
            fullExtentsCM: bounds.fullExtentsCM,
            measuredDimensionsCM: bounds.measuredDimensionsCM
        )

        // Boundary contact, per region face.
        var contactCounts: [LiDARRegionFace: Int] = [:]
        for voxel in component {
            for face in region.faces(
                near: voxel.position,
                distance: configuration.boundaryWarningDistance
            ) {
                contactCounts[face, default: 0] += 1
            }
        }
        analysis.boundaryContacts = contactCounts
            .filter { $0.value >= configuration.boundaryContactMinimumVoxels }
            .sorted { $0.key < $1.key }
            .map { LiDARBoundaryContact(face: $0.key.label, voxelCount: $0.value) }
        if !analysis.boundaryContacts.isEmpty {
            analysis.failures.append(.regionBoundaryContact)
        }

        // Coverage: surfaces that define each dimension, and viewpoints.
        let surface = LiDARCoverageAnalyzer.surfaceCoverage(
            local: componentLocal,
            bounds: bounds,
            configuration: configuration
        )
        let sparseSides = surface.sparseSides(
            minimumFraction: configuration.minimumSideSupportFraction
        )
        let sparseOnU = sparseSides.filter { $0 < 2 }.count
        let sparseOnV = sparseSides.count - sparseOnU
        analysis.sparseSidesOnLength = bounds.uIsLength ? sparseOnU : sparseOnV
        analysis.sparseSidesOnWidth = bounds.uIsLength ? sparseOnV : sparseOnU
        let viewpointSpan: Double? = viewpointFrameCount > 0
            ? LiDARCoverageAnalyzer.viewpointSpanDegrees(
                occupiedBins: azimuthBins,
                binDegrees: max(1, configuration.viewpointAzimuthBinDegrees)
            )
            : nil
        let hasPartition = LiDARCoverageAnalyzer.hasInteriorPartition(
            local: componentLocal,
            bounds: bounds,
            configuration: configuration
        )
        let sideFractions = bounds.uIsLength
            ? surface.sideSupportFractions
            : Array(surface.sideSupportFractions[2...] + surface.sideSupportFractions[..<2])
        analysis.coverage = LiDARCoverageEvidence(
            viewpointSpanDegrees: viewpointSpan,
            viewpointFrameCount: viewpointFrameCount,
            sideSupportFractions: sideFractions,
            sparseSideCount: sparseSides.count,
            topCoverageFraction: surface.topCoverageFraction,
            interiorPartitionDetected: hasPartition
        )
        if hasPartition { analysis.failures.append(.possibleMergedObjects) }
        if !sparseSides.isEmpty { analysis.warnings.append(.sparseSideCoverage) }
        if surface.topCoverageFraction < configuration.minimumTopCoverageFraction {
            analysis.warnings.append(.topSurfaceSparse)
        }
        if let viewpointSpan {
            if viewpointSpan < Double(configuration.minimumViewpointSpanDegrees) {
                analysis.failures.append(.insufficientViewpoints)
            }
        } else {
            analysis.warnings.append(.viewpointCoverageUnknown)
        }

        // A real support extends past the product. A "plane" lying wholly
        // under the footprint may be the product's own underside or a ledge.
        if support.method == .histogramPeak {
            let margin = Float(configuration.supportFootprintMarginInVoxels)
                * configuration.voxelSize
            var beyond = 0
            for voxel in stable
            where abs(voxel.local.y - support.coordinate) <= support.removalBand {
                let horizontal = SIMD2<Float>(voxel.local.x, voxel.local.z)
                let u = simd_dot(horizontal, bounds.axisU)
                let v = simd_dot(horizontal, bounds.axisV)
                if u < bounds.lowU - margin || u > bounds.highU + margin
                    || v < bounds.lowV - margin || v > bounds.highV + margin {
                    beyond += 1
                }
            }
            supportEvidence.voxelsBeyondFootprint = beyond
            analysis.supportPlane = supportEvidence
            if beyond < configuration.supportPlaneMinimumSamples {
                analysis.failures.append(.supportNotBeyondFootprint)
            }
        }

        analysis.measurement = makeMeasurement(
            component: component,
            bounds: bounds,
            region: region,
            supportWorldY: supportWorldY,
            touchesBoundary: !analysis.boundaryContacts.isEmpty,
            mode: selected.mode
        )
        return analysis
    }

    private func makeMeasurement(
        component: [LiDARStableVoxel],
        bounds: LiDARBoundsEstimate,
        region: LiDARSpatialRegion,
        supportWorldY: Float,
        touchesBoundary: Bool,
        mode: LiDARComponentSelection.Mode
    ) -> LiDARFusionMeasurement {
        let halfU = bounds.extentU / 2
        let halfV = bounds.extentV / 2
        let rectangleCentre = bounds.axisU * ((bounds.lowU + bounds.highU) / 2)
            + bounds.axisV * ((bounds.lowV + bounds.highV) / 2)
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for height in [bounds.supportCoordinate, bounds.top] {
            let horizontalCorners: [SIMD2<Float>] = [
                rectangleCentre - bounds.axisU * halfU - bounds.axisV * halfV,
                rectangleCentre + bounds.axisU * halfU - bounds.axisV * halfV,
                rectangleCentre + bounds.axisU * halfU + bounds.axisV * halfV,
                rectangleCentre - bounds.axisU * halfU + bounds.axisV * halfV
            ]
            for corner in horizontalCorners {
                corners.append(region.worldPoint(horizontal: corner, height: height))
            }
        }

        // Express review points in the measured box's own basis (X = length,
        // Y = height, Z = width) so the 3D viewer's axis-aligned box outline
        // lines up with the cloud even for rotated objects.
        let worldAxisU = region.axisX * bounds.axisU.x + region.axisZ * bounds.axisU.y
        let worldAxisV = region.axisX * bounds.axisV.x + region.axisZ * bounds.axisV.y
        let lengthAxis = bounds.uIsLength ? worldAxisU : worldAxisV
        let widthAxis = bounds.uIsLength ? worldAxisV : worldAxisU
        let centre = region.worldPoint(
            horizontal: rectangleCentre,
            height: (bounds.supportCoordinate + bounds.trimmedTop) / 2
        )
        let points = component.map { $0.position }
        let displayStep = max(1, points.count / 4_000)
        let displayPoints = points.enumerated().compactMap { index, point -> SIMD3<Float>? in
            guard index.isMultiple(of: displayStep) else { return nil }
            let offset = point - centre
            return SIMD3<Float>(
                simd_dot(offset, lengthAxis),
                simd_dot(offset, region.axisY),
                simd_dot(offset, widthAxis)
            )
        }
        let observations = component.reduce(0) { $0 + $1.observations }
        return LiDARFusionMeasurement(
            dimensionsCM: bounds.measuredDimensionsCM,
            centredPointsInMetres: displayPoints,
            worldPointsInMetres: points,
            boundingBoxCornersWorld: corners,
            touchesRegionBoundary: touchesBoundary,
            fusedVoxelCount: component.count,
            averageObservationsPerVoxel: Double(observations) / Double(component.count),
            supportPlaneY: supportWorldY,
            connectivityMode: mode
        )
    }
}
