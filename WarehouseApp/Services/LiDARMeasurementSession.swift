import Foundation
import simd

// MARK: - Stability analysis

struct LiDARStabilityAssessment: Equatable {
    enum State: String {
        case warmingUp
        case stable
        case unstable
    }

    var state: State
    var estimateCount: Int
    /// Estimates in the window that agree with the newest one (inclusive).
    var consistentEstimateCount: Int
    /// Per-axis range across the agreeing estimates.
    var spreadCM: ObjectDimensions?
    /// The newest estimate is much larger than the last stable one.
    var jumpDetected: Bool
    /// A much larger value recently replaced a stable one.
    var sustainedJumpAdopted: Bool
}

/// Decides whether recent estimates agree. The newest estimate is always the
/// one reported, so reported dimensions and displayed geometry describe the
/// same evidence; stability only says whether that estimate can be trusted
/// not to move.
struct LiDARStabilityAnalyzer {
    private struct Entry {
        let sequence: Int
        let dimensions: ObjectDimensions
    }

    private let configuration: LiDARFusionConfiguration
    private var window: [Entry] = []
    private var nextSequence = 0
    private(set) var stable: ObjectDimensions?
    private var jumpAdoptedAtSequence: Int?

    init(configuration: LiDARFusionConfiguration = .smallObject) {
        self.configuration = configuration
    }

    mutating func reset() {
        window.removeAll()
        nextSequence = 0
        stable = nil
        jumpAdoptedAtSequence = nil
    }

    mutating func consider(_ estimate: ObjectDimensions) -> LiDARStabilityAssessment {
        window.append(Entry(sequence: nextSequence, dimensions: estimate))
        nextSequence += 1
        if window.count > max(configuration.stabilityWindow, 1) {
            window.removeFirst(window.count - max(configuration.stabilityWindow, 1))
        }
        // The jump note lapses once every retained estimate postdates it.
        if let adopted = jumpAdoptedAtSequence,
           let oldest = window.first, oldest.sequence >= adopted {
            jumpAdoptedAtSequence = nil
        }

        let agreeing = window.filter { areConsistent($0.dimensions, estimate) }
        let jump = stable.map { isJump(from: $0, to: estimate) } ?? false
        let isStable = agreeing.count >= configuration.stableEstimateCount
        if isStable {
            if jump, let newest = window.last { jumpAdoptedAtSequence = newest.sequence }
            stable = estimate
        }
        return LiDARStabilityAssessment(
            state: isStable ? .stable : (stable == nil ? .warmingUp : .unstable),
            estimateCount: window.count,
            consistentEstimateCount: agreeing.count,
            spreadCM: spread(of: agreeing.map(\.dimensions)),
            jumpDetected: jump && !isStable,
            sustainedJumpAdopted: jumpAdoptedAtSequence != nil
        )
    }

    private func areConsistent(_ lhs: ObjectDimensions, _ rhs: ObjectDimensions) -> Bool {
        zip(lhs.values, rhs.values).allSatisfy {
            let allowed = max(
                configuration.estimateConsistencyFloorCM,
                configuration.estimateConsistencyTolerance * max(abs($0), abs($1))
            )
            return abs($0 - $1) <= allowed
        }
    }

    private func isJump(from previous: ObjectDimensions, to estimate: ObjectDimensions) -> Bool {
        zip(estimate.values, previous.values).contains {
            $1 > 0 && ($0 - $1) / $1 > configuration.dimensionJumpThreshold
        }
    }

    private func spread(of estimates: [ObjectDimensions]) -> ObjectDimensions? {
        guard !estimates.isEmpty else { return nil }
        func range(_ value: (ObjectDimensions) -> Double) -> Double {
            let values = estimates.map(value)
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        return ObjectDimensions(
            length: range(\.length),
            width: range(\.width),
            height: range(\.height)
        )
    }
}

// MARK: - Final acceptance

enum LiDARMeasurementAcceptance {
    /// Heuristic per-axis uncertainty in centimetres: quantization, the tail
    /// trimmed by the robust bounds, disagreement between recent estimates,
    /// a penalty for each sparsely observed bounding side, and (height only)
    /// the support-plane noise. It orders scans by trustworthiness; it is
    /// not a calibrated error bound.
    static func uncertaintyCM(
        analysis: LiDARGeometryAnalysis,
        stability: LiDARStabilityAssessment?,
        configuration: LiDARFusionConfiguration
    ) -> ObjectDimensions? {
        guard let bounds = analysis.bounds else { return nil }
        let voxelCM = Double(configuration.voxelSize) * 100
        let sparsePenalty = Double(configuration.sparseSideUncertaintyInVoxels) * voxelCM
        let spread = stability?.spreadCM
        func axis(
            full: Double,
            trimmed: Double,
            spread: Double?,
            sparseSides: Int,
            extra: Double = 0
        ) -> Double {
            voxelCM
                + max(full - trimmed, 0) / 2
                + (spread ?? 0) / 2
                + Double(sparseSides) * sparsePenalty
                + extra
        }
        return ObjectDimensions(
            length: axis(
                full: bounds.fullExtentsCM.length,
                trimmed: bounds.trimmedExtentsCM.length,
                spread: spread?.length,
                sparseSides: analysis.sparseSidesOnLength
            ),
            width: axis(
                full: bounds.fullExtentsCM.width,
                trimmed: bounds.trimmedExtentsCM.width,
                spread: spread?.width,
                sparseSides: analysis.sparseSidesOnWidth
            ),
            height: axis(
                full: bounds.fullExtentsCM.height,
                trimmed: bounds.trimmedExtentsCM.height,
                spread: spread?.height,
                sparseSides: 0,
                extra: (analysis.supportPlane?.residualMetres ?? 0) * 100
            )
        )
    }

    static func decide(
        frames: LiDARFrameEvidence,
        lastFrameTracking: LiDARTrackingQuality,
        productIsInView: Bool = true,
        analysis: LiDARGeometryAnalysis?,
        stability: LiDARStabilityAssessment?,
        uncertaintyCM: ObjectDimensions?,
        configuration: LiDARFusionConfiguration
    ) -> LiDARAcceptanceDecision {
        var failures: [LiDARMeasurementReasonCode] = []
        var warnings: [LiDARMeasurementReasonCode] = []
        var fallbacks: [LiDARMeasurementReasonCode] = []

        if frames.acceptedFrameCountSinceReset < configuration.minimumFusedFrameCount {
            failures.append(.insufficientAcceptedFrames)
        }
        if lastFrameTracking != .normal {
            failures.append(.trackingNotNormal)
        } else if !productIsInView {
            failures.append(.productNotInView)
        }
        if let analysis {
            failures.append(contentsOf: analysis.failures)
            warnings.append(contentsOf: analysis.warnings)
            fallbacks.append(contentsOf: analysis.fallbacks)
            if analysis.measurement != nil {
                if stability?.state != .stable {
                    failures.append(.dimensionsUnstable)
                }
                if let measured = analysis.bounds?.measuredDimensionsCM,
                   let uncertaintyCM,
                   zip(uncertaintyCM.values, measured.values).contains(where: {
                       $0 > max(
                           configuration.maximumUncertaintyFloorCM,
                           configuration.maximumRelativeUncertainty * $1
                       )
                   }) {
                    failures.append(.excessiveUncertainty)
                }
            }
        } else if !failures.contains(.insufficientAcceptedFrames) {
            failures.append(.insufficientStableGeometry)
        }
        if stability?.sustainedJumpAdopted == true {
            warnings.append(.sustainedDimensionJump)
        }
        if frames.coordinateResetCount > 0 {
            warnings.append(.evidenceInvalidatedByTrackingReset)
        }

        let status: LiDARAcceptanceStatus
        if !failures.isEmpty {
            status = .refused
        } else if !warnings.isEmpty || !fallbacks.isEmpty {
            status = .qualified
        } else {
            status = .accepted
        }
        return LiDARAcceptanceDecision(
            status: status,
            failures: failures,
            warnings: warnings,
            fallbacks: fallbacks
        )
    }

    /// Application-level coverage and stability indicator in 0...1. It
    /// grades how much evidence backs a scan, not how accurate it is.
    static func coverageScore(
        frames: LiDARFrameEvidence,
        measurement: LiDARFusionMeasurement?,
        isStable: Bool,
        status: LiDARAcceptanceStatus,
        configuration: LiDARFusionConfiguration
    ) -> Double {
        guard let measurement else { return 0 }
        let frameScore = min(
            Double(frames.acceptedFrameCountSinceReset)
                / (Double(configuration.minimumFusedFrameCount)
                    * configuration.coverageFrameSaturationMultiple),
            1
        )
        let voxelScore = min(
            Double(measurement.fusedVoxelCount)
                / (Double(configuration.minimumStableVoxelCount)
                    * configuration.coverageVoxelSaturationMultiple),
            1
        )
        let observationScore = min(
            measurement.averageObservationsPerVoxel / configuration.coverageObservationSaturation,
            1
        )
        let stabilityScore = isStable ? 1.0 : configuration.coverageUnstableScore
        let score = frameScore * configuration.coverageFrameWeight
            + voxelScore * configuration.coverageVoxelWeight
            + observationScore * configuration.coverageObservationWeight
            + stabilityScore * configuration.coverageStabilityWeight
        let ceiling = status == .accepted
            ? configuration.coverageScoreCeiling
            : configuration.qualifiedCoverageScoreCeiling
        return min(score, ceiling)
    }
}

// MARK: - Guidance

/// Turns reason codes into instructions that say which evidence is missing.
enum LiDARMeasurementGuidance {
    static func message(
        for code: LiDARMeasurementReasonCode,
        evidence: LiDARMeasurementEvidence? = nil
    ) -> String {
        switch code {
        case .noSelectionLocked:
            "Set the scan region before scanning."
        case .insufficientAcceptedFrames:
            "Keep scanning. More frames are needed before the measurement can be checked."
        case .trackingNotNormal:
            "Tracking is limited. Hold the phone steady and move more slowly."
        case .insufficientStableGeometry:
            "Too little repeated geometry was captured. Move closer and scan the product slowly."
        case .insufficientGeometryAboveSupport:
            "Only the supporting surface was captured, or the product is too flat to separate from it. Aim at the product, or enter the dimensions of a very flat product manually."
        case .supportPlaneNotFound:
            "The surface under the product was not captured. Include some of the table or floor around the product in the region."
        case .noObjectNearSeed:
            "No product was found near the middle of the region. Re-mark the region so the product sits at its centre."
        case .insufficientConnectedGeometry:
            "The product surface is too sparse to isolate. Scan each side more slowly."
        case .degenerateBounds:
            "The captured surface is too flat to measure. Scan the sides and the top."
        case .regionBoundaryContact:
            contactMessage(evidence?.boundaryContacts ?? [])
        case .insufficientViewpoints:
            "Scan another side. Move around the product so two adjacent sides are seen."
        case .dimensionsUnstable:
            "The dimensions are still changing. Keep scanning slowly."
        case .excessiveUncertainty:
            "The evidence is too uncertain to accept. Scan another side and the top."
        case .objectNotOnSupport:
            "The product does not rest on the detected surface. Set the bottom limit at the surface the product stands on."
        case .geometryBelowSupport:
            "Geometry was found below the surface the product appears to stand on. Set the bottom limit at that surface, not below it."
        case .weakGeometryExpired:
            "Some geometry was seen only briefly and then dropped. Rescan any side you passed quickly."
        case .nearbyObjectClose:
            "Another object is very close to the product. Move farther from the nearby or background object, or take it out of the region."
        case .productNotInView:
            "The product is not in view. Aim at the product inside the region."
        case .fragmentsExcluded:
            "Loose pieces of surface next to the product were left out. Scan that area slowly so it joins up."
        case .possibleMergedObjects:
            "The measured shape has a wall inside it, which usually means two objects are touching. Separate them and rescan."
        case .possiblePartialObject:
            "Only a piece of a patchy surface was joined up; more of it lies right beside the orange box. Scan the sparse areas slowly, or enter the dimensions manually."
        case .supportPlaneNoisy:
            "The supporting surface is noisy, so the height is less certain."
        case .supportNotBeyondFootprint:
            "The surface under the product was not seen around it, so the height has no base. Include some of the table or floor in the region."
        case .sparseSideCoverage:
            "At least one side was barely scanned. Scan another side."
        case .topSurfaceSparse:
            "The top was barely scanned. Scan the top from above."
        case .viewpointCoverageUnknown:
            "Viewpoint coverage could not be checked for this scan."
        case .evidenceInvalidatedByTrackingReset:
            "Tracking was lost and earlier scan data was discarded. Check that the region still surrounds the product."
        case .sustainedDimensionJump:
            "The dimensions recently jumped. Check that nothing else joined the orange box."
        case .expandedConnectivityUsed:
            "Gaps in the scanned surface were bridged. Scan the sparse areas slowly to confirm."
        }
    }

    /// Failures first, then warnings and fallbacks, in the order produced.
    static func messages(
        for decision: LiDARAcceptanceDecision,
        evidence: LiDARMeasurementEvidence? = nil
    ) -> [String] {
        (decision.failures + decision.warnings + decision.fallbacks).map {
            message(for: $0, evidence: evidence)
        }
    }

    private static func contactMessage(_ contacts: [LiDARBoundaryContact]) -> String {
        let touchesTop = contacts.contains { $0.face == LiDARRegionFace.top.label }
        let touchesBottom = contacts.contains { $0.face == LiDARRegionFace.bottom.label }
        let touchesSide = contacts.contains { $0.face.hasPrefix("side") }
        var limits: [String] = []
        if touchesSide { limits.append("side") }
        if touchesTop { limits.append("top") }
        if touchesBottom { limits.append("bottom") }
        let where_ = limits.isEmpty ? "" : " (\(limits.joined(separator: ", ")) limit)"
        return "The product touches the selected scan boundary\(where_). Enlarge the region and rescan."
    }
}

// MARK: - Session

struct LiDARMeasurementReport: Equatable {
    var frame: LiDARFusionIntegrationResult?
    /// Geometry of the latest analysis that completed every stage.
    var measurement: LiDARFusionMeasurement?
    /// Dimensions of `measurement`. Never smoothed or substituted.
    var reportedDimensionsCM: ObjectDimensions?
    var dimensionsAreStable = false
    var decision = LiDARAcceptanceDecision.notStarted
    var evidence = LiDARMeasurementEvidence()
    var guidance: [String] = []
    var totalVoxelCount = 0
    /// The geometric stages ran while producing this report.
    var analysisWasUpdated = false

    var coverageScore: Double { evidence.coverageScore }
}

/// The complete pipeline for one scan: frame validation and fusion (engine),
/// geometric stages, stability analysis, and final acceptance. Contains no
/// ARKit types, so the same code runs on device, in tests, and in the
/// evaluation tool.
final class LiDARMeasurementSession {
    let configuration: LiDARFusionConfiguration
    private let engine: LiDARVoxelFusionEngine
    private var stability: LiDARStabilityAnalyzer
    private var analysis: LiDARGeometryAnalysis?
    private var assessment: LiDARStabilityAssessment?
    private var acceptedFramesSinceAnalysis = 0
    private(set) var report = LiDARMeasurementReport()

    init(configuration: LiDARFusionConfiguration = .smallObject) {
        self.configuration = configuration
        engine = LiDARVoxelFusionEngine(configuration: configuration)
        stability = LiDARStabilityAnalyzer(configuration: configuration)
    }

    func begin(region: LiDARSpatialRegion, seed: SIMD3<Float>) {
        reset()
        engine.lockSelection(region: region, seed: seed)
    }

    func begin(volume: LiDARScanVolume, seed: SIMD3<Float>) {
        begin(region: .box(volume), seed: seed)
    }

    func reset() {
        engine.reset()
        stability.reset()
        analysis = nil
        assessment = nil
        acceptedFramesSinceAnalysis = 0
        report = LiDARMeasurementReport()
    }

    @discardableResult
    func process(_ frame: LiDARDepthFrame) -> LiDARMeasurementReport {
        let result = engine.integrate(frame: frame)
        if result.evidenceWasInvalidated {
            // Estimates computed in the old coordinate system must not vouch
            // for geometry in the new one.
            stability.reset()
            analysis = nil
            assessment = nil
            acceptedFramesSinceAnalysis = 0
        }
        var analysed = false
        if result.disposition.isAccepted {
            acceptedFramesSinceAnalysis += 1
            // While finishing is on offer, every accepted frame is analysed,
            // so the offer never rests on geometry older than the evidence.
            let interval = report.decision.allowsFinish
                ? 1
                : max(1, configuration.measurementIntervalFrames)
            if acceptedFramesSinceAnalysis >= interval {
                runAnalysis()
                analysed = true
            }
        }
        report = makeReport(frame: result, analysisWasUpdated: analysed)
        return report
    }

    /// Runs the geometric stages immediately, without waiting for the next
    /// analysis interval.
    @discardableResult
    func refresh() -> LiDARMeasurementReport {
        runAnalysis()
        report = makeReport(frame: report.frame, analysisWasUpdated: true)
        return report
    }

    private func runAnalysis() {
        acceptedFramesSinceAnalysis = 0
        let current = engine.analyze()
        analysis = current
        if let measurement = current.measurement {
            assessment = stability.consider(measurement.dimensionsCM)
        } else {
            // No estimate: earlier agreement says nothing about this state,
            // so agreement has to be earned again from fresh estimates.
            stability.reset()
            assessment = nil
        }
    }

    private func makeReport(
        frame: LiDARFusionIntegrationResult?,
        analysisWasUpdated: Bool
    ) -> LiDARMeasurementReport {
        let frames = engine.frameEvidence
        let uncertainty = analysis.flatMap {
            LiDARMeasurementAcceptance.uncertaintyCM(
                analysis: $0,
                stability: assessment,
                configuration: configuration
            )
        }
        let decision = LiDARMeasurementAcceptance.decide(
            frames: frames,
            lastFrameTracking: engine.lastFrameTracking,
            productIsInView: engine.productIsInView,
            analysis: analysis,
            stability: assessment,
            uncertaintyCM: uncertainty,
            configuration: configuration
        )
        let measurement = analysis?.measurement
        let isStable = measurement != nil && assessment?.state == .stable

        var evidence = LiDARMeasurementEvidence()
        evidence.frames = frames
        if let analysis {
            evidence.voxels = analysis.voxels
            evidence.supportPlane = analysis.supportPlane
            evidence.components = analysis.components
            evidence.freeSpace = analysis.freeSpace
            evidence.bounds = analysis.bounds
            evidence.boundaryContacts = analysis.boundaryContacts
            evidence.coverage = analysis.coverage
        }
        evidence.voxels.totalVoxelCount = engine.voxelCount
        evidence.stability = assessment.map {
            LiDARStabilityEvidence(
                state: $0.state.rawValue,
                estimateCount: $0.estimateCount,
                consistentEstimateCount: $0.consistentEstimateCount,
                spreadCM: $0.spreadCM,
                jumpDetected: $0.jumpDetected,
                sustainedJumpAdopted: $0.sustainedJumpAdopted
            )
        }
        evidence.reportedDimensionsCM = measurement?.dimensionsCM
        evidence.uncertaintyCM = uncertainty
        evidence.decision = decision.status.rawValue
        evidence.failureCodes = decision.failures.map(\.rawValue)
        evidence.warningCodes = decision.warnings.map(\.rawValue)
        evidence.fallbackCodes = decision.fallbacks.map(\.rawValue)
        evidence.coverageScore = LiDARMeasurementAcceptance.coverageScore(
            frames: frames,
            measurement: measurement,
            isStable: isStable,
            status: decision.status,
            configuration: configuration
        )

        return LiDARMeasurementReport(
            frame: frame,
            measurement: measurement,
            reportedDimensionsCM: measurement?.dimensionsCM,
            dimensionsAreStable: isStable,
            decision: decision,
            evidence: evidence,
            guidance: LiDARMeasurementGuidance.messages(for: decision, evidence: evidence),
            totalVoxelCount: engine.voxelCount,
            analysisWasUpdated: analysisWasUpdated
        )
    }
}
