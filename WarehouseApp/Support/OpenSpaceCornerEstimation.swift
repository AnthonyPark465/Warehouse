import Foundation
import simd

struct CornerPatchCapture: Equatable {
    var samples: [LocalCornerPatchSample]
    var reticleLocalPosition: Vector2D
    var coordinateEpoch: UUID
    var startedAt: TimeInterval
    var endedAt: TimeInterval
}

enum CornerEstimationFailure: Error, LocalizedError, Equatable {
    case mixedCoordinateEpoch
    case insufficientIndependentFrames
    case insufficientSpatialCoverage
    case noReliableIntersection
    case excessiveUncertainty

    var errorDescription: String? {
        switch self {
        case .mixedCoordinateEpoch: "Tracking changed during capture. Rescan this corner."
        case .insufficientIndependentFrames: "Hold still and scan the corner for longer."
        case .insufficientSpatialCoverage: "Move slightly so both sides of the corner are visible."
        case .noReliableIntersection: "Two reliable supporting edges or planes were not found. Rescan or use manual dimensions."
        case .excessiveUncertainty: "The corner is too uncertain to accept. Rescan or use manual dimensions."
        }
    }
}

struct CornerEstimatorConfiguration: Equatable {
    var basePlaneToleranceMetres = 0.025
    var minimumIndependentFrames = 6
    var minimumCaptureDurationSeconds = 1.0
    var maximumCaptureDurationSeconds = 2.0
    var minimumCoverageMetres = 0.06
    var lineInlierThresholdMetres = 0.012
    var planeInlierThresholdMetres = 0.012
    var minimumLineSupport = 8
    var minimumPlaneSupport = 12
    var minimumIntersectionAngleRadians = 28.0 * .pi / 180
    var maximumIntersectionAngleRadians = 152.0 * .pi / 180
    var maximumIntersectionDistanceFromReticleMetres = 0.12
    var maximumPersistedDiagnosticSamples = 160

    static let standard = Self()
}

protocol LocalCornerEstimating {
    var kind: CornerEstimatorKind { get }
    func estimate(
        capture: CornerPatchCapture,
        configuration: CornerEstimatorConfiguration
    ) -> Result<GuidedCornerMeasurement, CornerEstimationFailure>
}

enum CornerAccuracyPolicy {
    static func maximumAcceptedUncertainty(measurementDistanceMetres: Double) -> Double {
        MeasurementAccuracyPolicy.maximumAcceptedUncertainty(
            for: max(0.01, measurementDistanceMetres)
        )
    }

    static func accepts(uncertaintyMetres: Double, measurementDistanceMetres: Double) -> Bool {
        guard uncertaintyMetres.isFinite, uncertaintyMetres > 0,
              measurementDistanceMetres.isFinite, measurementDistanceMetres > 0 else { return false }
        let ratio = uncertaintyMetres / measurementDistanceMetres
        return ratio <= 0.05
            && uncertaintyMetres <= maximumAcceptedUncertainty(
                measurementDistanceMetres: measurementDistanceMetres
            )
    }
}

struct TabletopCornerEstimator: LocalCornerEstimating {
    let kind: CornerEstimatorKind = .tabletopTerminationEdges

    func estimate(
        capture: CornerPatchCapture,
        configuration: CornerEstimatorConfiguration = .standard
    ) -> Result<GuidedCornerMeasurement, CornerEstimationFailure> {
        guard validEpoch(capture) else { return .failure(.mixedCoordinateEpoch) }
        let samples = capture.samples.filter {
            $0.trackingState == .normal && finite($0.localPosition.simd)
                && abs($0.localPosition.y) <= configuration.basePlaneToleranceMetres
                && $0.depthConfidence >= 0.3
        }
        let frameCount = Set(samples.map(\.frameSequence)).count
        guard frameCount >= configuration.minimumIndependentFrames,
              capture.endedAt - capture.startedAt >= configuration.minimumCaptureDurationSeconds
        else { return .failure(.insufficientIndependentFrames) }

        // Keep enough spatially distributed evidence that both perpendicular
        // terminations survive downsampling; a tiny subset can overrepresent one edge.
        let points = deterministicSubset(samples, limit: 160)
        guard planarCoverage(points.map { SIMD2($0.localPosition.x, $0.localPosition.z) })
                >= configuration.minimumCoverageMetres
        else { return .failure(.insufficientSpatialCoverage) }
        let lines = candidateLines(points: points, configuration: configuration)
        let target = capture.reticleLocalPosition.simd
        var best: (CandidateLine, CandidateLine, SIMD2<Double>, Double)?
        for firstIndex in lines.indices {
            for secondIndex in lines.indices where secondIndex > firstIndex {
                let first = lines[firstIndex], second = lines[secondIndex]
                let angle = acuteAngle(first.direction, second.direction)
                guard angle >= configuration.minimumIntersectionAngleRadians,
                      angle <= .pi / 2 else { continue }
                guard let intersection = lineIntersection(first, second),
                      simd_distance(intersection, target)
                        <= configuration.maximumIntersectionDistanceFromReticleMetres else { continue }
                let shared = Set(first.sampleIDs).intersection(second.sampleIDs).count
                let score = first.score + second.score - Double(shared) * 0.4
                    - simd_distance(intersection, target) * 20
                if best == nil || score > best!.3 {
                    best = (first, second, intersection, score)
                }
            }
        }
        guard let best else { return .failure(.noReliableIntersection) }
        let residual = sqrt((best.0.rms * best.0.rms + best.1.rms * best.1.rms) / 2)
        let angle = acuteAngle(best.0.direction, best.1.direction)
        let anglePenalty = max(1, 1 / max(sin(angle), 0.2))
        let independentFrameScale = sqrt(Double(frameCount))
        let framePenalty = 0.004 / independentFrameScale
        // The fit residual is per observation; the corner estimate is supported by
        // independent frames. Reduce only by that frame count (not raw sample count)
        // and retain a 2.5 mm systematic floor for depth/calibration error.
        let uncertainty = max(
            0.0025,
            residual * anglePenalty / independentFrameScale + framePenalty
        )
        let distance = median(samples.map { simd_distance($0.cameraPositionLocal.simd, $0.localPosition.simd) })
        guard CornerAccuracyPolicy.accepts(
            uncertaintyMetres: uncertainty,
            measurementDistanceMetres: distance
        ) else { return .failure(.excessiveUncertainty) }
        let measurement = makeMeasurement(
            capture: capture, samples: samples, position: best.2,
            estimator: kind, provenance: .directlyObserved,
            uncertainty: uncertainty, rms: residual,
            maximumResidual: max(best.0.maximumResidual, best.1.maximumResidual),
            coverage: min(best.0.coverage, best.1.coverage), frameCount: frameCount,
            distance: distance,
            edges: [fittedEdge(best.0), fittedEdge(best.1)], planes: [],
            configuration: configuration
        )
        return .success(measurement)
    }
}

struct CompartmentCornerEstimator: LocalCornerEstimating {
    let kind: CornerEstimatorKind = .compartmentPlaneIntersection

    func estimate(
        capture: CornerPatchCapture,
        configuration: CornerEstimatorConfiguration = .standard
    ) -> Result<GuidedCornerMeasurement, CornerEstimationFailure> {
        guard validEpoch(capture) else { return .failure(.mixedCoordinateEpoch) }
        let samples = capture.samples.filter {
            $0.trackingState == .normal && finite($0.localPosition.simd)
                && $0.depthConfidence >= 0.3
                && abs($0.localPosition.y) > configuration.basePlaneToleranceMetres
        }
        let frameCount = Set(samples.map(\.frameSequence)).count
        guard frameCount >= configuration.minimumIndependentFrames,
              capture.endedAt - capture.startedAt >= configuration.minimumCaptureDurationSeconds
        else { return .failure(.insufficientIndependentFrames) }
        let subset = deterministicSubset(samples, limit: 96)
        guard let first = bestVerticalPlane(subset, threshold: configuration.planeInlierThresholdMetres,
                                            minimumSupport: configuration.minimumPlaneSupport) else {
            return .failure(.noReliableIntersection)
        }
        let firstIDs = Set(first.indices.map { subset[$0].id })
        let remaining = subset.filter { !firstIDs.contains($0.id) }
        guard let second = bestVerticalPlane(remaining, threshold: configuration.planeInlierThresholdMetres,
                                             minimumSupport: configuration.minimumPlaneSupport) else {
            return .failure(.noReliableIntersection)
        }
        let angle = acuteAngle(SIMD2(first.normal.x, first.normal.z), SIMD2(second.normal.x, second.normal.z))
        guard angle >= configuration.minimumIntersectionAngleRadians else {
            return .failure(.noReliableIntersection)
        }
        let a = SIMD2(first.normal.x, first.normal.z)
        let b = SIMD2(second.normal.x, second.normal.z)
        let determinant = a.x * b.y - a.y * b.x
        guard abs(determinant) > 1e-8 else { return .failure(.noReliableIntersection) }
        let rhsA = simd_dot(first.normal, first.origin)
        let rhsB = simd_dot(second.normal, second.origin)
        let intersection = SIMD2(
            (rhsA * b.y - a.y * rhsB) / determinant,
            (a.x * rhsB - rhsA * b.x) / determinant
        )
        guard simd_distance(intersection, capture.reticleLocalPosition.simd)
                <= configuration.maximumIntersectionDistanceFromReticleMetres else {
            return .failure(.noReliableIntersection)
        }
        let residual = sqrt((first.rms * first.rms + second.rms * second.rms) / 2)
        let uncertainty = max(0.004, residual / max(sin(angle), 0.2) + 0.006 / sqrt(Double(frameCount)))
        let distance = median(subset.map { simd_distance($0.cameraPositionLocal.simd, $0.localPosition.simd) })
        guard CornerAccuracyPolicy.accepts(uncertaintyMetres: uncertainty, measurementDistanceMetres: distance)
        else { return .failure(.excessiveUncertainty) }
        let planes = [
            fittedPlane(first, surface: .back, samples: subset),
            fittedPlane(second, surface: .left, samples: remaining)
        ]
        return .success(makeMeasurement(
            capture: capture, samples: subset, position: intersection,
            estimator: kind, provenance: .inferredFromSupportingGeometry,
            uncertainty: uncertainty, rms: residual,
            maximumResidual: max(first.maximumResidual, second.maximumResidual),
            coverage: min(first.coverage, second.coverage), frameCount: frameCount,
            distance: distance, edges: [], planes: planes, configuration: configuration
        ))
    }
}

enum DefaultLocalCornerEstimator {
    static func estimate(
        capture: CornerPatchCapture,
        configuration: CornerEstimatorConfiguration = .standard
    ) -> Result<GuidedCornerMeasurement, CornerEstimationFailure> {
        let tabletop = TabletopCornerEstimator().estimate(capture: capture, configuration: configuration)
        if case .success = tabletop { return tabletop }
        return CompartmentCornerEstimator().estimate(capture: capture, configuration: configuration)
    }
}

private struct CandidateLine {
    var point: SIMD2<Double>
    var direction: SIMD2<Double>
    var sampleIDs: [UUID]
    var rms: Double
    var maximumResidual: Double
    var coverage: Double
    var score: Double
}

private struct PlaneCandidate {
    var origin: SIMD3<Double>
    var normal: SIMD3<Double>
    var indices: [Int]
    var rms: Double
    var maximumResidual: Double
    var coverage: Double
}

private func candidateLines(
    points: [LocalCornerPatchSample], configuration: CornerEstimatorConfiguration
) -> [CandidateLine] {
    let positions = points.map { SIMD2($0.localPosition.x, $0.localPosition.z) }
    var candidates: [CandidateLine] = []
    guard positions.count >= configuration.minimumLineSupport else { return [] }
    for first in positions.indices {
        for second in positions.indices where second > first {
            let delta = positions[second] - positions[first]
            let length = simd_length(delta)
            guard length >= configuration.minimumCoverageMetres * 0.65 else { continue }
            let direction = delta / length
            let normal = SIMD2(-direction.y, direction.x)
            let residuals = positions.map { abs(simd_dot($0 - positions[first], normal)) }
            let indices = residuals.indices.filter { residuals[$0] <= configuration.lineInlierThresholdMetres }
            guard indices.count >= configuration.minimumLineSupport else { continue }
            let inlierProjections = indices.map { simd_dot(positions[$0], direction) }
            let coverage = (inlierProjections.max() ?? 0) - (inlierProjections.min() ?? 0)
            guard coverage >= configuration.minimumCoverageMetres else { continue }
            // A second edge legitimately contributes a handful of points close to
            // the intersection. Use a robust residual for scoring/uncertainty so
            // those points do not make an otherwise crisp termination look noisy.
            let robustResidual = median(indices.map { residuals[$0] }) * 1.4826
            candidates.append(CandidateLine(
                point: positions[first], direction: direction,
                sampleIDs: indices.map { points[$0].id }, rms: robustResidual,
                maximumResidual: indices.map { residuals[$0] }.max() ?? 0,
                coverage: coverage,
                score: Double(indices.count) + coverage * 25 - robustResidual * 200
            ))
        }
    }
    let sorted = candidates.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.point.x != $1.point.x { return $0.point.x < $1.point.x }
        return $0.point.y < $1.point.y
    }
    // RANSAC generates many nearly identical hypotheses from one physical edge.
    // Suppress those before applying the cap, otherwise the shortlist can contain
    // only one direction and manufacture a false "no intersection" result.
    var selected: [CandidateLine] = []
    for candidate in sorted {
        let duplicate = selected.contains { existing in
            let angle = acuteAngle(existing.direction, candidate.direction)
            let normal = SIMD2(-existing.direction.y, existing.direction.x)
            let offset = abs(simd_dot(candidate.point - existing.point, normal))
            return angle < 4 * .pi / 180
                && offset < configuration.lineInlierThresholdMetres * 0.75
        }
        if !duplicate { selected.append(candidate) }
        if selected.count == 48 { break }
    }
    return selected
}

private func lineIntersection(_ first: CandidateLine, _ second: CandidateLine) -> SIMD2<Double>? {
    let determinant = first.direction.x * second.direction.y - first.direction.y * second.direction.x
    guard abs(determinant) > 1e-8 else { return nil }
    let delta = second.point - first.point
    let t = (delta.x * second.direction.y - delta.y * second.direction.x) / determinant
    return first.point + first.direction * t
}

private func fittedEdge(_ value: CandidateLine) -> FittedCornerEdge {
    FittedCornerEdge(
        line: LineFit2D(
            point: Vector2D(value.point), direction: Vector2D(value.direction),
            rmsResidualMetres: value.rms, maximumResidualMetres: value.maximumResidual,
            uncertaintyMetres: max(0.0025, value.rms / sqrt(Double(value.sampleIDs.count))),
            physicalLengthMetres: value.coverage, spatialCoverage: 1,
            viewingAngleDiversityRadians: 0, independentSampleCount: value.sampleIDs.count,
            inlierCount: value.sampleIDs.count
        ),
        supportingSampleIDs: value.sampleIDs
    )
}

private func bestVerticalPlane(
    _ samples: [LocalCornerPatchSample], threshold: Double, minimumSupport: Int
) -> PlaneCandidate? {
    let points = samples.map(\.localPosition.simd)
    guard points.count >= minimumSupport else { return nil }
    var best: PlaneCandidate?
    for a in 0..<(points.count - 2) {
        for b in (a + 1)..<(points.count - 1) {
            for c in (b + 1)..<points.count {
                let cross = simd_cross(points[b] - points[a], points[c] - points[a])
                guard simd_length(cross) > 1e-8 else { continue }
                let normal = simd_normalize(cross)
                guard abs(normal.y) <= 0.45 else { continue }
                let residuals = points.map { abs(simd_dot($0 - points[a], normal)) }
                let indices = residuals.indices.filter { residuals[$0] <= threshold }
                guard indices.count >= minimumSupport else { continue }
                let inliers = indices.map { points[$0] }
                let centre = inliers.reduce(.zero, +) / Double(inliers.count)
                let rms = sqrt(indices.reduce(0) { $0 + residuals[$1] * residuals[$1] } / Double(indices.count))
                let coverage = inliers.map { simd_distance($0, centre) }.max() ?? 0
                let candidate = PlaneCandidate(
                    origin: centre, normal: normal, indices: indices, rms: rms,
                    maximumResidual: indices.map { residuals[$0] }.max() ?? 0,
                    coverage: coverage * 2
                )
                if best == nil || indices.count > best!.indices.count
                    || (indices.count == best!.indices.count && rms < best!.rms) { best = candidate }
            }
        }
    }
    return best
}

private func fittedPlane(
    _ value: PlaneCandidate, surface: CompartmentSurface, samples: [LocalCornerPatchSample]
) -> FittedCompartmentPlane {
    let directions = value.indices.map {
        simd_normalize(samples[$0].localPosition.simd - samples[$0].cameraPositionLocal.simd)
    }
    var diversity = 0.0
    for a in directions.indices {
        for b in directions.indices where b > a {
            diversity = max(diversity, acos(max(-1, min(1, simd_dot(directions[a], directions[b])))))
        }
    }
    return FittedCompartmentPlane(
        surface: surface,
        plane: CodablePlane(origin: Vector3D(value.origin), normal: Vector3D(value.normal)),
        rmsResidualMetres: value.rms, maximumResidualMetres: value.maximumResidual,
        uncertaintyMetres: max(0.003, value.rms / sqrt(Double(value.indices.count))),
        sampleCoverageMetres: value.coverage, viewingDiversityRadians: diversity,
        inlierCount: value.indices.count, evidenceState: .accepted
    )
}

private func makeMeasurement(
    capture: CornerPatchCapture, samples: [LocalCornerPatchSample], position: SIMD2<Double>,
    estimator: CornerEstimatorKind, provenance: CornerObservationProvenance,
    uncertainty: Double, rms: Double, maximumResidual: Double, coverage: Double,
    frameCount: Int, distance: Double, edges: [FittedCornerEdge],
    planes: [FittedCompartmentPlane], configuration: CornerEstimatorConfiguration
) -> GuidedCornerMeasurement {
    let views = samples.map {
        simd_normalize($0.localPosition.simd - $0.cameraPositionLocal.simd)
    }
    var diversity = 0.0
    for a in views.indices {
        for b in views.indices where b > a {
            diversity = max(diversity, acos(max(-1, min(1, simd_dot(views[a], views[b])))))
        }
    }
    return GuidedCornerMeasurement(
        id: UUID(), acceptedLocalPosition: Vector2D(position),
        originalCandidatePosition: Vector2D(position), estimator: estimator,
        provenance: provenance, approval: .candidate,
        uncertaintyMetres: uncertainty, rmsResidualMetres: rms,
        maximumResidualMetres: maximumResidual, spatialCoverageMetres: coverage,
        independentFrameCount: frameCount, viewingAngleDiversityRadians: diversity,
        measurementDistanceMetres: distance, trackingState: .normal,
        fittedEdges: edges, fittedPlanes: planes,
        diagnosticSamples: deterministicSubset(samples, limit: configuration.maximumPersistedDiagnosticSamples),
        coordinateSpace: .planeAnchorLocal, coordinateEpoch: capture.coordinateEpoch,
        schemaVersion: 1, capturedAt: .now
    )
}

private func validEpoch(_ capture: CornerPatchCapture) -> Bool {
    !capture.samples.isEmpty && capture.samples.allSatisfy {
        $0.trackingState == .normal
    }
}

private func deterministicSubset(
    _ samples: [LocalCornerPatchSample], limit: Int
) -> [LocalCornerPatchSample] {
    let sorted = samples.sorted {
        if $0.frameSequence != $1.frameSequence { return $0.frameSequence < $1.frameSequence }
        if $0.localPosition.x != $1.localPosition.x { return $0.localPosition.x < $1.localPosition.x }
        if $0.localPosition.z != $1.localPosition.z { return $0.localPosition.z < $1.localPosition.z }
        if $0.localPosition.y != $1.localPosition.y { return $0.localPosition.y < $1.localPosition.y }
        if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
        return $0.id.uuidString < $1.id.uuidString
    }
    guard sorted.count > limit else { return sorted }
    let stride = Double(sorted.count - 1) / Double(limit - 1)
    return (0..<limit).map { sorted[Int((Double($0) * stride).rounded())] }
}

private func planarCoverage(_ points: [SIMD2<Double>]) -> Double {
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
          let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return 0 }
    return min(maxX - minX, maxY - minY)
}

private func acuteAngle(_ first: SIMD2<Double>, _ second: SIMD2<Double>) -> Double {
    guard simd_length(first) > 1e-9, simd_length(second) > 1e-9 else { return 0 }
    return acos(max(-1, min(1, abs(simd_dot(simd_normalize(first), simd_normalize(second))))))
}

private func finite(_ point: SIMD3<Double>) -> Bool {
    point.x.isFinite && point.y.isFinite && point.z.isFinite
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return .infinity }
    if sorted.count.isMultiple(of: 2) {
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    return sorted[sorted.count / 2]
}
