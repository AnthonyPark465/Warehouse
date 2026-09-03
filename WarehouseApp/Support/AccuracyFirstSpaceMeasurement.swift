import Foundation
import simd

enum BoundaryAcquisitionPhase: String, Codable, Equatable {
    case findingEdgeStart, tracingEdge, reviewingEdge, confirmingCorner
    case startingNextEdge, closingBoundary, reviewingGeometry, rescanningSection
}

enum MeasurementShapeIntent: String, Codable, CaseIterable, Equatable {
    case straightSidedPolygon, rectangularCompartment, circularBoundary, irregularRoundedBoundary
}

enum MeasurementEvidenceState: String, Codable, Equatable {
    case accepted, weak, inferred, failed
}

enum GeometryApprovalState: String, Codable, Equatable {
    case draft, proposed, approvedRaw, approvedCorrected, rejected
}

struct LineFit2D: Codable, Equatable {
    var point: Vector2D
    var direction: Vector2D
    var rmsResidualMetres: Double
    var maximumResidualMetres: Double
    var uncertaintyMetres: Double
    var physicalLengthMetres: Double
    var spatialCoverage: Double
    var viewingAngleDiversityRadians: Double
    var independentSampleCount: Int
    var inlierCount: Int
}

struct BoundaryEdgeSection: Codable, Equatable, Identifiable {
    var id: UUID
    var index: Int
    var rawObservations: [BorderObservation]
    var acceptedObservations: [BorderObservation]
    var rejectedObservationCount: Int
    var fittedLine: LineFit2D?
    var evidenceState: MeasurementEvidenceState
    var segmentType: BorderSegmentType
    var isConfirmed: Bool
    var isInferred: Bool
}

struct CornerIntersection: Codable, Equatable {
    var position: Vector2D
    var uncertaintyMetres: Double
    var angleRadians: Double
}

struct ProposedBoundaryCorner: Codable, Equatable {
    var position: Vector2D
    var incomingSectionIndex: Int
    var persistenceCount: Int
    var turnAngleRadians: Double
}

struct SectionedBoundaryConfiguration: Equatable {
    var minimumObservationSpacingMetres = 0.008
    var correlatedFrameIntervalSeconds = 0.25
    var maximumMeasurementDistanceMetres = 8.0
    var minimumConfidence = 0.30
    var lineInlierThresholdMetres = 0.015
    var minimumIndependentSamples = 6
    var minimumEdgeLengthMetres = 0.08
    var minimumSpatialCoverage = 0.55
    var minimumCornerTurnRadians = 22.0 * .pi / 180
    var cornerPersistenceSamples = 3
    var minimumIntersectionAngleRadians = 7.0 * .pi / 180
    var closureToleranceMetres = 0.06
    static let standard = Self()
}

enum RobustLineFitter {
    static func fit(
        observations: [BorderObservation],
        configuration: SectionedBoundaryConfiguration = .standard
    ) -> (fit: LineFit2D?, accepted: [BorderObservation], rejected: Int) {
        let finite = observations.filter {
            let p = $0.localPosition
            return p.x.isFinite && p.y.isFinite && $0.measurementDistance.isFinite
                && $0.measurementDistance >= 0.1
                && $0.measurementDistance <= configuration.maximumMeasurementDistanceMetres
                && $0.confidence >= configuration.minimumConfidence
                && $0.trackingState == .normal
        }.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.id.uuidString < b.id.uuidString
        }
        var independent: [BorderObservation] = []
        for sample in finite {
            guard let last = independent.last else { independent.append(sample); continue }
            let spacing = simd_distance(last.localPosition.simd, sample.localPosition.simd)
            let interval = sample.timestamp.timeIntervalSince(last.timestamp)
            let viewDot = max(-1.0, min(1.0, simd_dot(
                simd_normalize(last.viewingDirection.simd), simd_normalize(sample.viewingDirection.simd)
            )))
            let viewChange = acos(viewDot)
            if spacing < configuration.minimumObservationSpacingMetres,
               (interval < configuration.correlatedFrameIntervalSeconds
                || viewChange < 8 * .pi / 180) { continue }
            independent.append(sample)
        }
        guard independent.count >= 2 else {
            return (nil, independent, observations.count - independent.count)
        }
        let points = independent.map { $0.localPosition.simd }
        var best: [Int] = []
        var bestError = Double.infinity
        for first in 0..<(points.count - 1) {
            for second in (first + 1)..<points.count {
                let delta = points[second] - points[first]
                let length = simd_length(delta)
                guard length >= configuration.minimumObservationSpacingMetres else { continue }
                let direction = delta / length
                let inliers = points.indices.filter {
                    abs(cross(points[$0] - points[first], direction)) <= configuration.lineInlierThresholdMetres
                }
                let error = inliers.reduce(0.0) {
                    $0 + abs(cross(points[$1] - points[first], direction))
                }
                if inliers.count > best.count || (inliers.count == best.count && error < bestError) {
                    best = inliers
                    bestError = error
                }
            }
        }
        guard best.count >= 2 else { return (nil, independent, observations.count - independent.count) }
        let inlierPoints = best.map { points[$0] }
        let centre = inlierPoints.reduce(.zero, +) / Double(inlierPoints.count)
        var xx = 0.0, xy = 0.0, yy = 0.0
        for point in inlierPoints {
            let d = point - centre
            xx += d.x * d.x; xy += d.x * d.y; yy += d.y * d.y
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        var direction = SIMD2(cos(angle), sin(angle))
        if simd_dot(direction, inlierPoints.last! - inlierPoints.first!) < 0 { direction = -direction }
        let residuals = inlierPoints.map { abs(cross($0 - centre, direction)) }
        let projections = inlierPoints.map { simd_dot($0 - centre, direction) }
        let length = (projections.max() ?? 0) - (projections.min() ?? 0)
        let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count))
        let bins = Set(projections.map { value -> Int in
            guard length > 1e-9 else { return 0 }
            return min(4, max(0, Int(((value - (projections.min() ?? 0)) / length) * 5)))
        })
        let coverage = Double(bins.count) / 5.0
        var diversity = 0.0
        for a in best.indices { for b in best.indices where b > a {
            let va = simd_normalize(independent[best[a]].viewingDirection.simd)
            let vb = simd_normalize(independent[best[b]].viewingDirection.simd)
            diversity = max(diversity, acos(max(-1, min(1, simd_dot(va, vb)))))
        }}
        let distanceFloor = (best.map { independent[$0].measurementDistance }.reduce(0, +)
            / Double(best.count)) * 0.002
        let uncertainty = max(0.0025, rms / sqrt(Double(best.count)) + distanceFloor)
            + (coverage < configuration.minimumSpatialCoverage ? 0.01 : 0)
            + (diversity < 8 * .pi / 180 ? 0.006 : 0)
        let accepted = best.map { independent[$0] }
        return (LineFit2D(
            point: Vector2D(centre), direction: Vector2D(direction), rmsResidualMetres: rms,
            maximumResidualMetres: residuals.max() ?? 0, uncertaintyMetres: uncertainty,
            physicalLengthMetres: length, spatialCoverage: coverage,
            viewingAngleDiversityRadians: diversity, independentSampleCount: independent.count,
            inlierCount: best.count
        ), accepted, observations.count - accepted.count)
    }

    static func intersection(
        _ first: LineFit2D, _ second: LineFit2D,
        minimumAngleRadians: Double = SectionedBoundaryConfiguration.standard.minimumIntersectionAngleRadians
    ) -> CornerIntersection? {
        let p = first.point.simd, q = second.point.simd
        let r = simd_normalize(first.direction.simd), s = simd_normalize(second.direction.simd)
        let determinant = cross(r, s)
        let angle = acos(max(-1, min(1, abs(simd_dot(r, s)))))
        guard abs(determinant) >= sin(minimumAngleRadians), angle >= minimumAngleRadians else { return nil }
        let t = cross(q - p, s) / determinant
        let position = p + t * r
        let uncertainty = hypot(first.uncertaintyMetres, second.uncertaintyMetres) / abs(determinant)
        guard position.x.isFinite, position.y.isFinite, uncertainty.isFinite else { return nil }
        return CornerIntersection(position: Vector2D(position), uncertaintyMetres: uncertainty, angleRadians: angle)
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }
}

final class SectionedBoundaryAcquisition {
    private(set) var phase: BoundaryAcquisitionPhase = .findingEdgeStart
    private(set) var sections: [BoundaryEdgeSection] = []
    private(set) var proposedCorner: ProposedBoundaryCorner?
    private(set) var confirmedCorners: [CornerIntersection] = []
    let configuration: SectionedBoundaryConfiguration
    private var current: [BorderObservation] = []
    private var directionChangePersistence = 0

    init(configuration: SectionedBoundaryConfiguration = .standard) { self.configuration = configuration }

    var observations: [BorderObservation] { sections.flatMap(\.rawObservations) + current }

    func add(_ observation: BorderObservation) {
        guard proposedCorner == nil else { return }
        current.append(observation)
        phase = current.count == 1 ? .findingEdgeStart : .tracingEdge
        guard current.count >= configuration.minimumIndependentSamples,
              let fit = RobustLineFitter.fit(observations: current, configuration: configuration).fit else { return }
        let recent = Array(current.suffix(3)).map { $0.localPosition.simd }
        guard recent.count == 3 else { return }
        let recentDirection = simd_normalize(recent[2] - recent[0])
        let change = acos(max(-1, min(1, abs(simd_dot(recentDirection, fit.direction.simd)))))
        if change >= configuration.minimumCornerTurnRadians {
            directionChangePersistence += 1
        } else {
            directionChangePersistence = 0
        }
        if directionChangePersistence >= configuration.cornerPersistenceSamples {
            proposedCorner = ProposedBoundaryCorner(
                position: current[current.count - configuration.cornerPersistenceSamples].localPosition,
                incomingSectionIndex: sections.count,
                persistenceCount: directionChangePersistence,
                turnAngleRadians: change
            )
            phase = .confirmingCorner
        }
    }

    @discardableResult func confirmCorner() -> Bool {
        guard let proposal = proposedCorner,
              let split = current.lastIndex(where: { $0.localPosition == proposal.position }), split >= 1 else { return false }
        let incoming = Array(current[...split])
        guard commit(incoming) else { return false }
        if sections.count >= 2,
           let a = sections[sections.count - 2].fittedLine,
           let b = sections.last?.fittedLine,
           let corner = RobustLineFitter.intersection(a, b) { confirmedCorners.append(corner) }
        current = Array(current[split...])
        proposedCorner = nil
        directionChangePersistence = 0
        phase = .startingNextEdge
        return true
    }

    func continueSameEdge() {
        proposedCorner = nil; directionChangePersistence = 0; phase = .tracingEdge
    }

    func rescanCurrentSection() {
        current.removeAll(); proposedCorner = nil; directionChangePersistence = 0; phase = .rescanningSection
    }

    func rescanSection(index: Int) {
        guard sections.indices.contains(index) else { return }
        sections.remove(at: index)
        for offset in sections.indices { sections[offset].index = offset }
        confirmedCorners.removeAll()
        current.removeAll(); proposedCorner = nil; phase = .rescanningSection
    }

    func undoLastSection() {
        if !current.isEmpty { current.removeAll(); proposedCorner = nil; phase = .findingEdgeStart }
        else if !sections.isEmpty { sections.removeLast(); confirmedCorners.removeAll(); phase = .rescanningSection }
    }

    @discardableResult func closeBoundary() -> Bool {
        guard commit(current), sections.count >= 3 else { return false }
        current.removeAll()
        var corners: [CornerIntersection] = []
        for index in sections.indices {
            guard let a = sections[index].fittedLine,
                  let b = sections[(index + 1) % sections.count].fittedLine,
                  let corner = RobustLineFitter.intersection(a, b) else { return false }
            corners.append(corner)
        }
        guard let first = corners.first, let last = corners.last,
              first.uncertaintyMetres <= configuration.closureToleranceMetres,
              last.uncertaintyMetres <= configuration.closureToleranceMetres else { return false }
        confirmedCorners = corners
        phase = .reviewingGeometry
        return true
    }

    func reset() {
        sections.removeAll(); current.removeAll(); confirmedCorners.removeAll(); proposedCorner = nil
        directionChangePersistence = 0; phase = .findingEdgeStart
    }

    private func commit(_ observations: [BorderObservation]) -> Bool {
        let result = RobustLineFitter.fit(observations: observations, configuration: configuration)
        guard let fit = result.fit else { return false }
        let acceptable = fit.inlierCount >= configuration.minimumIndependentSamples
            && fit.physicalLengthMetres >= configuration.minimumEdgeLengthMetres
            && fit.spatialCoverage >= configuration.minimumSpatialCoverage
        let type = Dictionary(grouping: result.accepted, by: \.segmentType)
            .max { $0.value.count < $1.value.count }?.key ?? .inferred
        sections.append(BoundaryEdgeSection(
            id: Self.sectionID(index: sections.count), index: sections.count,
            rawObservations: observations, acceptedObservations: result.accepted,
            rejectedObservationCount: result.rejected, fittedLine: fit,
            evidenceState: acceptable ? .accepted : .weak, segmentType: type,
            isConfirmed: acceptable, isInferred: false
        ))
        return acceptable
    }

    private static func sectionID(index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    }
}

struct CircleFitResult: Codable, Equatable {
    var center: Vector2D
    var radiusMetres: Double
    var rmsResidualMetres: Double
    var maximumResidualMetres: Double
    var uncertaintyMetres: Double
    var angularCoverageRadians: Double
    var inlierCount: Int
    var acceptedAsCircle: Bool
}

enum RobustCircleFitter {
    static func fit(points: [Vector2D], inlierThresholdMetres: Double = 0.015) -> CircleFitResult? {
        let p = points.map(\.simd).filter { $0.x.isFinite && $0.y.isFinite }
        guard p.count >= 6 else { return nil }
        var best: (SIMD2<Double>, Double, [Int])?
        for a in 0..<(p.count - 2) { for b in (a + 1)..<(p.count - 1) { for c in (b + 1)..<p.count {
            guard let circle = circleThrough(p[a], p[b], p[c]) else { continue }
            let inliers = p.indices.filter { abs(simd_distance(p[$0], circle.0) - circle.1) <= inlierThresholdMetres }
            if best == nil || inliers.count > best!.2.count { best = (circle.0, circle.1, inliers) }
        }}}
        guard let seed = best, seed.2.count >= 5 else { return nil }
        let values = seed.2.map { p[$0] }
        let centre = values.reduce(.zero, +) / Double(values.count)
        // Re-centred algebraic least squares avoids the worst conditioning of a raw Kasa fit.
        var suu = 0.0, suv = 0.0, svv = 0.0, suz = 0.0, svz = 0.0
        for point in values {
            let d = point - centre, z = d.x * d.x + d.y * d.y
            suu += d.x * d.x; suv += d.x * d.y; svv += d.y * d.y
            suz += d.x * z; svz += d.y * z
        }
        let determinant = suu * svv - suv * suv
        guard abs(determinant) > 1e-12 else { return nil }
        let offset = SIMD2((suz * svv - svz * suv) / (2 * determinant),
                           (svz * suu - suz * suv) / (2 * determinant))
        let fittedCentre = centre + offset
        let radii = values.map { simd_distance($0, fittedCentre) }
        let radius = radii.reduce(0, +) / Double(radii.count)
        let residuals = radii.map { abs($0 - radius) }
        let angles = values.map { atan2($0.y - fittedCentre.y, $0.x - fittedCentre.x) }.sorted()
        var largestGap = 0.0
        for index in angles.indices {
            let next = index == angles.count - 1 ? angles[0] + 2 * .pi : angles[index + 1]
            largestGap = max(largestGap, next - angles[index])
        }
        let coverage = 2 * .pi - largestGap
        let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count))
        let radialDistortion = ((radii.max() ?? radius) - (radii.min() ?? radius)) / max(radius, 1e-9)
        return CircleFitResult(
            center: Vector2D(fittedCentre), radiusMetres: radius,
            rmsResidualMetres: rms, maximumResidualMetres: residuals.max() ?? 0,
            uncertaintyMetres: max(0.0025, rms / sqrt(Double(values.count))),
            angularCoverageRadians: coverage, inlierCount: values.count,
            acceptedAsCircle: coverage >= 1.5 * .pi && rms <= inlierThresholdMetres
                && radialDistortion <= 0.08
        )
    }

    private static func circleThrough(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> (SIMD2<Double>, Double)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-10 else { return nil }
        let aa = simd_length_squared(a), bb = simd_length_squared(b), cc = simd_length_squared(c)
        let centre = SIMD2(
            (aa * (b.y - c.y) + bb * (c.y - a.y) + cc * (a.y - b.y)) / d,
            (aa * (c.x - b.x) + bb * (a.x - c.x) + cc * (b.x - a.x)) / d
        )
        return (centre, simd_distance(centre, a))
    }
}

enum MeasurementUse: String, Codable, Equatable { case rejected, manualOnly, approximatePlanning, fitCritical }

struct DimensionUncertainty: Codable, Equatable {
    var measuredMetres: Double
    var estimatedUncertaintyMetres: Double
    var robustFitResidualMetres: Double
    var repeatabilityMetres: Double
    var spatialCoverage: Double
    var viewingDiversityRadians: Double
    var closureErrorMetres: Double
    var inferencePenaltyMetres: Double
    var correctionDisplacementMetres: Double
    var correlatedSampleFraction: Double
}

struct MeasurementAcceptance: Codable, Equatable {
    var use: MeasurementUse
    var maximumAllowedUncertaintyMetres: Double
    var reason: String
}

enum MeasurementAccuracyPolicy {
    static func maximumAcceptedUncertainty(for dimensionMetres: Double) -> Double {
        if dimensionMetres <= 1 { return min(dimensionMetres * 0.02, 0.02) }
        if dimensionMetres <= 3 { return min(dimensionMetres * 0.015, 0.04) }
        if dimensionMetres <= 5 { return min(dimensionMetres * 0.01, 0.05) }
        return min(dimensionMetres * 0.01, 0.10)
    }

    static func evaluate(_ value: DimensionUncertainty, fitCritical: Bool) -> MeasurementAcceptance {
        guard value.measuredMetres > 0, value.estimatedUncertaintyMetres.isFinite else {
            return .init(use: .rejected, maximumAllowedUncertaintyMetres: 0, reason: "Measurement is invalid.")
        }
        let ratio = value.estimatedUncertaintyMetres / value.measuredMetres
        if ratio > 0.05 { return .init(use: .manualOnly, maximumAllowedUncertaintyMetres: value.measuredMetres * 0.05, reason: "Uncertainty exceeds 5%; enter or verify dimensions manually.") }
        let maximum = maximumAcceptedUncertainty(for: value.measuredMetres)
        guard value.estimatedUncertaintyMetres <= maximum else {
            return .init(use: .manualOnly, maximumAllowedUncertaintyMetres: maximum, reason: "Estimated uncertainty exceeds the acceptance limit for this distance.")
        }
        if fitCritical && (ratio > 0.01 || value.estimatedUncertaintyMetres > 0.005) {
            return .init(use: .manualOnly, maximumAllowedUncertaintyMetres: min(value.measuredMetres * 0.01, 0.005), reason: "Fit-critical placement needs a stricter local verification scan.")
        }
        if value.measuredMetres > 5, value.estimatedUncertaintyMetres > 0.05 {
            return .init(use: .approximatePlanning, maximumAllowedUncertaintyMetres: maximum, reason: "Suitable only for approximate planning; verify the local placement area.")
        }
        return .init(use: fitCritical ? .fitCritical : .approximatePlanning, maximumAllowedUncertaintyMetres: maximum, reason: "Measurement is within the configured acceptance limit.")
    }
}

struct ConservativeDimensionResult: Codable, Equatable {
    var measuredMetres: Double
    var uncertaintyMetres: Double
    var clearancePerSideMetres: [Double]
    var conservativeUsableMetres: Double
}

enum ConservativeDimensionCalculator {
    static func calculate(measuredMetres: Double, uncertaintyMetres: Double, clearancePerSideMetres: [Double]) -> ConservativeDimensionResult {
        let clearance = clearancePerSideMetres.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        return .init(measuredMetres: measuredMetres, uncertaintyMetres: uncertaintyMetres,
                     clearancePerSideMetres: clearancePerSideMetres,
                     conservativeUsableMetres: max(0, measuredMetres - uncertaintyMetres - clearance))
    }

    static func productFit(productMetres: Double, usable: ConservativeDimensionResult) -> MeasurementFitDecision {
        let remaining = usable.conservativeUsableMetres - productMetres
        if remaining < 0 { return .doesNotFit }
        if remaining < 2 * usable.uncertaintyMetres { return .uncertainVerifyManually }
        return .fits
    }
}

enum MeasurementFitDecision: String, Codable, Equatable { case fits, doesNotFit, uncertainVerifyManually }

struct ScanZoneCheckpoint: Codable, Equatable, Identifiable {
    var id: UUID
    var localPosition: Vector2D
    var uncertaintyMetres: Double
}

struct LargeScanZone: Codable, Equatable, Identifiable {
    var id: UUID
    var checkpoints: [ScanZoneCheckpoint]
    var globalUncertaintyMetres: Double
    var localPlacementUncertaintyMetres: Double?
}

struct ZoneAlignmentResult: Codable, Equatable {
    var accepted: Bool
    var rmsDisagreementMetres: Double
    var maximumDisagreementMetres: Double
    var sharedCheckpointCount: Int
}

enum LargeSpaceZoneValidator {
    static func compare(_ first: LargeScanZone, _ second: LargeScanZone, toleranceMetres: Double) -> ZoneAlignmentResult {
        let right = Dictionary(uniqueKeysWithValues: second.checkpoints.map { ($0.id, $0) })
        let distances = first.checkpoints.compactMap { item in right[item.id].map { simd_distance(item.localPosition.simd, $0.localPosition.simd) } }
        guard distances.count >= 2 else { return .init(accepted: false, rmsDisagreementMetres: .infinity, maximumDisagreementMetres: .infinity, sharedCheckpointCount: distances.count) }
        let rms = sqrt(distances.reduce(0) { $0 + $1 * $1 } / Double(distances.count))
        return .init(accepted: rms <= toleranceMetres && (distances.max() ?? .infinity) <= toleranceMetres * 1.5,
                     rmsDisagreementMetres: rms, maximumDisagreementMetres: distances.max() ?? 0,
                     sharedCheckpointCount: distances.count)
    }

    static func permitsCloseFit(_ zone: LargeScanZone) -> Bool {
        guard let local = zone.localPlacementUncertaintyMetres else { return false }
        return local <= 0.005 && zone.globalUncertaintyMetres <= 0.05
    }
}

enum CompartmentSurface: String, Codable, CaseIterable, Equatable {
    case bottom, back, left, right, top, frontOpening
}

struct PlaneObservation: Codable, Equatable, Identifiable {
    var id: UUID
    var position: Vector3D
    var viewingDirection: Vector3D
    var confidence: Double
    var trackingState: TrackingQualitySnapshot
}

struct FittedCompartmentPlane: Codable, Equatable {
    var surface: CompartmentSurface
    var plane: CodablePlane
    var rmsResidualMetres: Double
    var maximumResidualMetres: Double
    var uncertaintyMetres: Double
    var sampleCoverageMetres: Double
    var viewingDiversityRadians: Double
    var inlierCount: Int
    var evidenceState: MeasurementEvidenceState
}

enum PlaneInferenceProvenance: String, Codable, Equatable {
    case directlyObserved, intersectionOfObservedPlanes, manuallyReplaced
}

struct CompartmentCornerEvidence: Codable, Equatable {
    var position: Vector3D
    var supportingSurfaces: [CompartmentSurface]
    var provenance: PlaneInferenceProvenance
    var uncertaintyMetres: Double
    var approval: GeometryApprovalState
}

struct RectangularCompartmentAssessment: Codable, Equatable {
    var planes: [FittedCompartmentPlane]
    var corners: [CompartmentCornerEvidence]
    var frontOpeningWidthMetres: Double?
    var interiorWidthMetres: Double?
    var frontOpeningHeightMetres: Double?
    var interiorHeightMetres: Double?
    var isTapered: Bool
    var isWarped: Bool
    var hasFrontLip: Bool
    var requiresSeparateCompartmentsOrExclusions: Bool
    var approval: GeometryApprovalState
    var failureReason: String?
}

enum RobustPlaneFitter {
    static func fit(
        surface: CompartmentSurface,
        observations: [PlaneObservation],
        inlierThresholdMetres: Double = 0.012
    ) -> FittedCompartmentPlane? {
        let samples = observations.filter {
            let p = $0.position
            return p.x.isFinite && p.y.isFinite && p.z.isFinite && $0.confidence >= 0.3
                && $0.trackingState == .normal
        }
        guard samples.count >= 6 else { return nil }
        var bestNormal: SIMD3<Double>?, bestOrigin: SIMD3<Double>?, bestIndices: [Int] = []
        for a in 0..<(samples.count - 2) {
            for b in (a + 1)..<(samples.count - 1) {
                for c in (b + 1)..<samples.count {
                    let pa = samples[a].position.simd, pb = samples[b].position.simd, pc = samples[c].position.simd
                    let cross = simd_cross(pb - pa, pc - pa)
                    guard simd_length(cross) > 1e-8 else { continue }
                    let normal = simd_normalize(cross)
                    let inliers = samples.indices.filter {
                        abs(simd_dot(samples[$0].position.simd - pa, normal)) <= inlierThresholdMetres
                    }
                    if inliers.count > bestIndices.count {
                        bestIndices = inliers; bestNormal = normal; bestOrigin = pa
                    }
                }
            }
        }
        guard bestIndices.count >= 6, let normal = bestNormal, bestOrigin != nil else { return nil }
        let points = bestIndices.map { samples[$0].position.simd }
        let centre = points.reduce(.zero, +) / Double(points.count)
        // The highest-consensus deterministic RANSAC plane is retained. Averaging
        // arbitrary triangle normals is biased by sample ordering and can make a
        // good plane worse; a future eigen-solver refinement must prove improvement.
        let residuals = points.map { abs(simd_dot($0 - centre, normal)) }
        let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count))
        let coverage = points.map { simd_distance($0, centre) }.max() ?? 0
        var diversity = 0.0
        for a in bestIndices.indices { for b in bestIndices.indices where b > a {
            let va = simd_normalize(samples[bestIndices[a]].viewingDirection.simd)
            let vb = simd_normalize(samples[bestIndices[b]].viewingDirection.simd)
            diversity = max(diversity, acos(max(-1, min(1, simd_dot(va, vb)))))
        }}
        let uncertainty = max(0.0025, rms / sqrt(Double(points.count)))
            + (coverage < 0.08 ? 0.01 : 0) + (diversity < 8 * .pi / 180 ? 0.006 : 0)
        return .init(surface: surface,
                     plane: CodablePlane(origin: Vector3D(centre), normal: Vector3D(normal)),
                     rmsResidualMetres: rms, maximumResidualMetres: residuals.max() ?? 0,
                     uncertaintyMetres: uncertainty, sampleCoverageMetres: coverage * 2,
                     viewingDiversityRadians: diversity, inlierCount: points.count,
                     evidenceState: rms <= inlierThresholdMetres ? .accepted : .weak)
    }
}

enum RectangularCompartmentEvaluator {
    static func evaluate(
        planes: [FittedCompartmentPlane],
        frontOpeningWidthMetres: Double? = nil,
        interiorWidthMetres: Double? = nil,
        frontOpeningHeightMetres: Double? = nil,
        interiorHeightMetres: Double? = nil,
        dividerOrExclusionDetected: Bool = false,
        taperToleranceMetres: Double = 0.015,
        warpToleranceMetres: Double = 0.012
    ) -> RectangularCompartmentAssessment {
        let bySurface = Dictionary(uniqueKeysWithValues: planes.map { ($0.surface, $0) })
        let required: [CompartmentSurface] = [.bottom, .back, .left, .right]
        let missing = required.filter { bySurface[$0]?.evidenceState != .accepted }
        let contradictory = oppositeContradiction(bySurface[.left], bySurface[.right])
            || oppositeContradiction(bySurface[.bottom], bySurface[.top])
            || oppositeContradiction(bySurface[.back], bySurface[.frontOpening])
        let tapered = if let frontOpeningWidthMetres, let interiorWidthMetres {
            abs(frontOpeningWidthMetres - interiorWidthMetres) > taperToleranceMetres
        } else { false }
        let warped = planes.contains { $0.maximumResidualMetres > warpToleranceMetres }
        let lip = if let frontOpeningWidthMetres, let interiorWidthMetres,
                     let frontOpeningHeightMetres, let interiorHeightMetres {
            frontOpeningWidthMetres + taperToleranceMetres < interiorWidthMetres
                || frontOpeningHeightMetres + taperToleranceMetres < interiorHeightMetres
        } else { false }
        let failure: String? = !missing.isEmpty ? "Required surfaces are not sufficiently observed."
            : contradictory ? "Fitted planes contradict a rectangular compartment."
            : tapered ? "Front and back dimensions show a tapered compartment; keep separate cross-sections."
            : warped ? "A surface is too warped for a rectangular-prism model."
            : dividerOrExclusionDetected ? "A divider or obstruction requires separate compartments or an excluded region."
            : nil
        return .init(
            planes: planes, corners: [], frontOpeningWidthMetres: frontOpeningWidthMetres,
            interiorWidthMetres: interiorWidthMetres, frontOpeningHeightMetres: frontOpeningHeightMetres,
            interiorHeightMetres: interiorHeightMetres, isTapered: tapered, isWarped: warped,
            hasFrontLip: lip, requiresSeparateCompartmentsOrExclusions: dividerOrExclusionDetected,
            approval: failure == nil ? .proposed : .rejected, failureReason: failure
        )
    }

    private static func oppositeContradiction(_ first: FittedCompartmentPlane?, _ second: FittedCompartmentPlane?) -> Bool {
        guard let first, let second else { return false }
        let dot = abs(simd_dot(first.plane.normal.normalized.simd, second.plane.normal.normalized.simd))
        return dot < cos(8 * .pi / 180)
    }
}
