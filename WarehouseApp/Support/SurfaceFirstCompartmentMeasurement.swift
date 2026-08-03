import Foundation
import simd

enum SurfaceFirstAcquisitionState: String, Codable, Equatable {
    case findingCompartment
    case confirmingTarget
    case scanningSurface
    case reviewingSurface
    case reviewingGeometry
    case completed
    case failed
}

enum SurfaceCaptureApproval: String, Codable, Equatable {
    case candidate, accepted, rejected
}

extension CompartmentSurface {
    var scanTitle: String {
        switch self {
        case .bottom: "bottom"
        case .back: "back"
        case .left: "left side"
        case .right: "right side"
        case .top: "top"
        case .frontOpening: "front opening or frame"
        }
    }
}

struct LocalTargetVolume: Codable, Equatable {
    var centre: Vector3D
    var halfExtents: Vector3D
    var coordinateEpoch: UUID
    var seedDepthMetres: Double

    func contains(_ point: Vector3D, margin: Double = 0) -> Bool {
        abs(point.x - centre.x) <= halfExtents.x + margin
            && abs(point.y - centre.y) <= halfExtents.y + margin
            && abs(point.z - centre.z) <= halfExtents.z + margin
    }
}

struct SurfaceCaptureObservation: Codable, Equatable, Identifiable {
    var id: UUID
    var position: Vector3D
    var normal: Vector3D?
    var cameraPosition: Vector3D
    var viewingDirection: Vector3D
    var depthConfidence: Double
    var trackingState: TrackingQualitySnapshot
    var frameSequence: Int
    var timestamp: TimeInterval
    var coordinateEpoch: UUID
}

struct SurfaceCaptureRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var surface: CompartmentSurface
    var targetVolume: LocalTargetVolume
    var selectedRegionSeed: Vector3D
    var fittedPlane: FittedCompartmentPlane
    var acceptedObservationIDs: [UUID]
    var diagnosticObservations: [SurfaceCaptureObservation]
    var rejectedObservationCount: Int
    var independentViewCount: Int
    var coverageFirstAxisMetres: Double
    var coverageSecondAxisMetres: Double
    var coordinateEpoch: UUID
    var approval: SurfaceCaptureApproval
    var schemaVersion: Int
}

struct CompartmentDimensions: Codable, Equatable {
    var interiorWidthMetres: Double
    var interiorHeightMetres: Double?
    var interiorDepthMetres: Double
    var openingWidthMetres: Double?
    var openingHeightMetres: Double?
    var uncertaintyMetres: Double
    var hasVerifiedUsableOpening: Bool
}

struct SurfaceFirstCompartmentRecord: Codable, Equatable {
    var targetVolume: LocalTargetVolume
    var surfaces: [SurfaceCaptureRecord]
    var corners: [CompartmentCornerEvidence]
    var dimensions: CompartmentDimensions?
    var rectangularCorrectionApproved: Bool
    var approval: GeometryApprovalState
    var schemaVersion: Int
}

enum SurfaceCaptureFailure: Error, LocalizedError, Equatable {
    case mixedCoordinateEpoch
    case insufficientIndependentViews
    case insufficientCoverage
    case noConnectedSurface
    case ambiguousSurfaces
    case unexpectedOrientation
    case excessiveResidual
    case excessiveUncertainty
    case outsideTargetVolume
    case inconsistentWithAcceptedSurfaces
    case illConditionedIntersection
    case cornerOutsideTargetVolume

    var errorDescription: String? {
        switch self {
        case .mixedCoordinateEpoch: "Tracking changed during capture. Rescan this surface."
        case .insufficientIndependentViews: "Move slowly to scan more of this surface from a different viewpoint."
        case .insufficientCoverage: "Not enough surface area was visible."
        case .noConnectedSurface: "No persistent connected surface was found in the target region."
        case .ambiguousSurfaces: "Two possible surfaces were found—select one or rescan."
        case .unexpectedOrientation: "The observed surface has the wrong orientation for this step."
        case .excessiveResidual: "Surface is too reflective, warped, or inconsistent."
        case .excessiveUncertainty: "Uncertainty is too high—rescan the highlighted surface."
        case .outsideTargetVolume: "The observed surface is outside the selected compartment."
        case .inconsistentWithAcceptedSurfaces: "The surface is incompatible with the accepted compartment surfaces."
        case .illConditionedIntersection: "Supporting planes are nearly parallel and cannot define a reliable corner."
        case .cornerOutsideTargetVolume: "The calculated corner falls outside the selected compartment."
        }
    }
}

struct SurfaceCaptureConfiguration: Equatable {
    var minimumDepthMetres = 0.15
    var maximumDepthMetres = 5.0
    var targetHalfExtentsMetres = SIMD3<Double>(0.75, 0.75, 0.75)
    var desiredPhysicalSampleHalfWidthMetres = 0.10
    var minimumPixelRadius = 8
    var maximumPixelRadius = 72
    var minimumDepthConfidence = 0.5
    var minimumCameraTranslationMetres = 0.015
    var minimumViewingAngleRadians = 4.0 * .pi / 180
    var correlatedFrameIntervalSeconds = 0.45
    var deduplicationVoxelMetres = 0.012
    var connectivityDistanceMetres = 0.055
    var minimumIndependentViews = 4
    var minimumInliers = 24
    var minimumCoveragePerAxisMetres = 0.07
    var planeInlierThresholdMetres = 0.010
    var maximumRMSResidualMetres = 0.008
    var maximumResidualMetres = 0.025
    var minimumOrientationDot = cos(18.0 * .pi / 180)
    var ambiguitySupportRatio = 0.72
    var maximumDiagnosticObservations = 320

    static let standard = Self()
}

enum AdaptiveDepthSampling {
    static func pixelRadius(
        seedDepthMetres: Double,
        focalLengthPixels: Double,
        configuration: SurfaceCaptureConfiguration = .standard
    ) -> Int {
        guard seedDepthMetres.isFinite, seedDepthMetres > 0,
              focalLengthPixels.isFinite, focalLengthPixels > 0 else {
            return configuration.maximumPixelRadius
        }
        let pixels = configuration.desiredPhysicalSampleHalfWidthMetres
            * focalLengthPixels / seedDepthMetres
        return min(configuration.maximumPixelRadius,
                   max(configuration.minimumPixelRadius, Int(ceil(pixels))))
    }
}

enum SurfaceFirstPlaneEstimator {
    static func fit(
        surface: CompartmentSurface,
        observations: [SurfaceCaptureObservation],
        targetVolume: LocalTargetVolume,
        selectedRegionSeed: Vector3D,
        acceptedSurfaces: [FittedCompartmentPlane] = [],
        configuration: SurfaceCaptureConfiguration = .standard
    ) -> Result<SurfaceCaptureRecord, SurfaceCaptureFailure> {
        guard Set(observations.map(\.coordinateEpoch)).count <= 1,
              observations.allSatisfy({ $0.coordinateEpoch == targetVolume.coordinateEpoch }) else {
            return .failure(.mixedCoordinateEpoch)
        }
        let finite = observations.filter {
            $0.trackingState == .normal && $0.depthConfidence >= configuration.minimumDepthConfidence
                && targetVolume.contains($0.position)
                && isFinite($0.position.simd) && isFinite($0.cameraPosition.simd)
        }
        guard !finite.isEmpty else { return .failure(.outsideTargetVolume) }
        let independent = independentObservations(finite, configuration: configuration)
        let independentFrames = Set(independent.map(\.frameSequence)).count
        guard independentFrames >= configuration.minimumIndependentViews else {
            return .failure(.insufficientIndependentViews)
        }
        let deduplicated = deduplicate(independent, voxel: configuration.deduplicationVoxelMetres)
        let components = connectedComponents(deduplicated, distance: configuration.connectivityDistanceMetres)
            .filter { $0.count >= configuration.minimumInliers }
            .sorted { componentScore($0, seed: selectedRegionSeed) > componentScore($1, seed: selectedRegionSeed) }
        guard let selected = components.first else { return .failure(.noConnectedSurface) }
        if components.count > 1,
           Double(components[1].count) / Double(selected.count) >= configuration.ambiguitySupportRatio,
           abs(componentScore(selected, seed: selectedRegionSeed)
               - componentScore(components[1], seed: selectedRegionSeed)) < 0.18 {
            return .failure(.ambiguousSurfaces)
        }
        guard let candidate = robustPlane(surface: surface, observations: selected,
                                          threshold: configuration.planeInlierThresholdMetres) else {
            return .failure(.noConnectedSurface)
        }
        let oriented = orientedNormal(candidate.plane.normal.simd, surface: surface)
        guard orientationIsValid(oriented, surface: surface,
                                 minimumDot: configuration.minimumOrientationDot) else {
            return .failure(.unexpectedOrientation)
        }
        var fit = candidate
        fit.plane.normal = Vector3D(oriented)
        guard fit.rmsResidualMetres <= configuration.maximumRMSResidualMetres,
              fit.maximumResidualMetres <= configuration.maximumResidualMetres else {
            return .failure(.excessiveResidual)
        }
        let inliers = selected.filter {
            abs(simd_dot($0.position.simd - fit.plane.origin.simd, oriented))
                <= configuration.planeInlierThresholdMetres
        }
        let coverage = planeCoverage(inliers.map { $0.position.simd }, normal: oriented)
        guard coverage.0 >= configuration.minimumCoveragePerAxisMetres,
              coverage.1 >= configuration.minimumCoveragePerAxisMetres else {
            return .failure(.insufficientCoverage)
        }
        fit.sampleCoverageMetres = min(coverage.0, coverage.1)
        fit.viewingDiversityRadians = maximumViewDiversity(inliers)
        fit.inlierCount = inliers.count
        fit.uncertaintyMetres = max(0.0025,
            fit.rmsResidualMetres / sqrt(Double(max(independentFrames, 1))))
            + (fit.viewingDiversityRadians < configuration.minimumViewingAngleRadians ? 0.008 : 0)
        guard fit.viewingDiversityRadians >= configuration.minimumViewingAngleRadians else {
            return .failure(.insufficientIndependentViews)
        }
        guard fit.uncertaintyMetres <= MeasurementAccuracyPolicy.maximumAcceptedUncertainty(for: 0.5) else {
            return .failure(.excessiveUncertainty)
        }
        guard relationshipIsPlausible(fit, accepted: acceptedSurfaces, volume: targetVolume) else {
            return .failure(.inconsistentWithAcceptedSurfaces)
        }
        let ids = Set(inliers.map(\.id))
        return .success(SurfaceCaptureRecord(
            id: UUID(), surface: surface, targetVolume: targetVolume,
            selectedRegionSeed: selectedRegionSeed, fittedPlane: fit,
            acceptedObservationIDs: Array(ids).sorted { $0.uuidString < $1.uuidString },
            diagnosticObservations: Array(finite.prefix(configuration.maximumDiagnosticObservations)),
            rejectedObservationCount: observations.count - inliers.count,
            independentViewCount: independentFrames,
            coverageFirstAxisMetres: coverage.0, coverageSecondAxisMetres: coverage.1,
            coordinateEpoch: targetVolume.coordinateEpoch, approval: .candidate, schemaVersion: 1
        ))
    }

    private static func independentObservations(
        _ samples: [SurfaceCaptureObservation], configuration: SurfaceCaptureConfiguration
    ) -> [SurfaceCaptureObservation] {
        let ordered = samples.sorted {
            $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp
        }
        var accepted: [SurfaceCaptureObservation] = []
        var lastByFrame: SurfaceCaptureObservation?
        for sample in ordered {
            if let last = lastByFrame, sample.frameSequence != last.frameSequence {
                let translation = simd_distance(sample.cameraPosition.simd, last.cameraPosition.simd)
                let angle = vectorAngle(sample.viewingDirection.simd, last.viewingDirection.simd)
                let interval = sample.timestamp - last.timestamp
                if translation < configuration.minimumCameraTranslationMetres,
                   angle < configuration.minimumViewingAngleRadians,
                   interval < configuration.correlatedFrameIntervalSeconds { continue }
            }
            accepted.append(sample)
            if sample.frameSequence != lastByFrame?.frameSequence { lastByFrame = sample }
        }
        return accepted
    }

    private static func deduplicate(
        _ samples: [SurfaceCaptureObservation], voxel: Double
    ) -> [SurfaceCaptureObservation] {
        var best: [SIMD3<Int>: SurfaceCaptureObservation] = [:]
        for sample in samples {
            let p = sample.position.simd / voxel
            let key = SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
            if best[key] == nil || best[key]!.depthConfidence < sample.depthConfidence { best[key] = sample }
        }
        return best.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func connectedComponents(
        _ samples: [SurfaceCaptureObservation], distance: Double
    ) -> [[SurfaceCaptureObservation]] {
        guard !samples.isEmpty else { return [] }
        var remaining = Set(samples.indices), result: [[SurfaceCaptureObservation]] = []
        while let start = remaining.first {
            remaining.remove(start)
            var queue = [start], indices = [start]
            while let current = queue.popLast() {
                let neighbours = remaining.filter {
                    simd_distance(samples[current].position.simd, samples[$0].position.simd) <= distance
                }
                for item in neighbours { remaining.remove(item); queue.append(item); indices.append(item) }
            }
            result.append(indices.map { samples[$0] })
        }
        return result
    }

    private static func componentScore(_ samples: [SurfaceCaptureObservation], seed: Vector3D) -> Double {
        let centre = samples.map { $0.position.simd }.reduce(.zero, +) / Double(samples.count)
        return Double(samples.count) / 100 - simd_distance(centre, seed.simd)
    }

    private static func robustPlane(
        surface: CompartmentSurface, observations: [SurfaceCaptureObservation], threshold: Double
    ) -> FittedCompartmentPlane? {
        let samples = Array(observations.prefix(180))
        guard samples.count >= 3 else { return nil }
        var best: [Int] = []
        let anchors = stride(from: 0, to: samples.count, by: max(1, samples.count / 18)).map { $0 }
        for ai in anchors.indices {
            for bi in anchors.indices where bi > ai {
                for ci in anchors.indices where ci > bi {
                    let a = samples[anchors[ai]].position.simd
                    let b = samples[anchors[bi]].position.simd
                    let c = samples[anchors[ci]].position.simd
                    let cross = simd_cross(b - a, c - a)
                    guard simd_length(cross) > 1e-7 else { continue }
                    let normal = simd_normalize(cross)
                    let inliers = samples.indices.filter {
                        abs(simd_dot(samples[$0].position.simd - a, normal)) <= threshold
                    }
                    if inliers.count > best.count { best = inliers }
                }
            }
        }
        guard best.count >= 3 else { return nil }
        let points = best.map { samples[$0].position.simd }
        let centre = points.reduce(.zero, +) / Double(points.count)
        let normal = smallestEigenvector(points: points, centre: centre)
        let residuals = points.map { abs(simd_dot($0 - centre, normal)) }
        let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count))
        return FittedCompartmentPlane(
            surface: surface, plane: CodablePlane(origin: Vector3D(centre), normal: Vector3D(normal)),
            rmsResidualMetres: rms, maximumResidualMetres: residuals.max() ?? 0,
            uncertaintyMetres: max(0.0025, rms / sqrt(Double(points.count))),
            sampleCoverageMetres: 0, viewingDiversityRadians: 0, inlierCount: points.count,
            evidenceState: .accepted
        )
    }

    private static func smallestEigenvector(points: [SIMD3<Double>], centre: SIMD3<Double>) -> SIMD3<Double> {
        var a = simd_double3x3(columns: (.zero, .zero, .zero))
        for point in points {
            let d = point - centre
            a += simd_double3x3(rows: [d * d.x, d * d.y, d * d.z])
        }
        var v = SIMD3<Double>(0.31, 0.57, 0.76)
        let scale = max(a[0][0] + a[1][1] + a[2][2], 1e-9)
        let shifted = simd_double3x3(diagonal: SIMD3(repeating: scale)) - a
        for _ in 0..<18 { v = simd_normalize(shifted * v) }
        return v
    }

    private static func planeCoverage(
        _ points: [SIMD3<Double>], normal: SIMD3<Double>
    ) -> (Double, Double) {
        guard !points.isEmpty else { return (0, 0) }
        let reference = abs(normal.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let u = simd_normalize(simd_cross(normal, reference)), v = simd_normalize(simd_cross(normal, u))
        let pu = points.map { simd_dot($0, u) }, pv = points.map { simd_dot($0, v) }
        return ((pu.max() ?? 0) - (pu.min() ?? 0), (pv.max() ?? 0) - (pv.min() ?? 0))
    }

    private static func maximumViewDiversity(_ samples: [SurfaceCaptureObservation]) -> Double {
        let directions = Dictionary(grouping: samples, by: \.frameSequence).values.compactMap { $0.first?.viewingDirection.simd }
        var result = 0.0
        for a in directions.indices { for b in directions.indices where b > a {
            result = max(result, vectorAngle(directions[a], directions[b]))
        }}
        return result
    }

    private static func orientationIsValid(
        _ normal: SIMD3<Double>, surface: CompartmentSurface, minimumDot: Double
    ) -> Bool {
        switch surface {
        case .bottom, .top: abs(simd_dot(normal, SIMD3(0, 1, 0))) >= minimumDot
        case .back, .left, .right, .frontOpening: abs(simd_dot(normal, SIMD3(0, 1, 0))) <= 1 - minimumDot
        }
    }

    private static func orientedNormal(_ normal: SIMD3<Double>, surface: CompartmentSurface) -> SIMD3<Double> {
        switch surface {
        case .bottom: normal.y < 0 ? -normal : normal
        case .top: normal.y > 0 ? -normal : normal
        default: normal
        }
    }

    private static func relationshipIsPlausible(
        _ fit: FittedCompartmentPlane, accepted: [FittedCompartmentPlane], volume: LocalTargetVolume
    ) -> Bool {
        guard volume.contains(fit.plane.origin, margin: 0.05) else { return false }
        if let bottom = accepted.first(where: { $0.surface == .bottom }) {
            let height = signedDistance(fit.plane.origin.simd, plane: bottom.plane)
            if fit.surface == .top && height <= 0.05 { return false }
            if [.back, .left, .right].contains(fit.surface), abs(height) > volume.halfExtents.y * 2 { return false }
        }
        if let back = accepted.first(where: { $0.surface == .back }),
           [.left, .right].contains(fit.surface) {
            let angle = vectorAngle(back.plane.normal.simd, fit.plane.normal.simd)
            if min(angle, .pi - angle) < 20 * .pi / 180 { return false }
        }
        return true
    }
}

enum CompartmentPlaneGeometry {
    static func intersect(
        _ first: FittedCompartmentPlane,
        _ second: FittedCompartmentPlane,
        _ third: FittedCompartmentPlane,
        targetVolume: LocalTargetVolume
    ) -> Result<CompartmentCornerEvidence, SurfaceCaptureFailure> {
        let a = first.plane.normal.normalized.simd
        let b = second.plane.normal.normalized.simd
        let c = third.plane.normal.normalized.simd
        let determinant = simd_dot(a, simd_cross(b, c))
        guard abs(determinant) >= 0.08 else { return .failure(.illConditionedIntersection) }
        let da = simd_dot(a, first.plane.origin.simd)
        let db = simd_dot(b, second.plane.origin.simd)
        let dc = simd_dot(c, third.plane.origin.simd)
        let point = (da * simd_cross(b, c) + db * simd_cross(c, a) + dc * simd_cross(a, b)) / determinant
        let value = Vector3D(point)
        guard targetVolume.contains(value, margin: 0.05) else { return .failure(.cornerOutsideTargetVolume) }
        let uncertainty = sqrt(
            first.uncertaintyMetres * first.uncertaintyMetres
                + second.uncertaintyMetres * second.uncertaintyMetres
                + third.uncertaintyMetres * third.uncertaintyMetres
        ) / abs(determinant)
        return .success(CompartmentCornerEvidence(
            position: value, supportingSurfaces: [first.surface, second.surface, third.surface],
            provenance: .intersectionOfObservedPlanes, uncertaintyMetres: uncertainty,
            approval: .proposed
        ))
    }

    static func dimensions(
        planes: [FittedCompartmentPlane],
        verifiedOpeningWidthMetres: Double? = nil,
        verifiedOpeningHeightMetres: Double? = nil
    ) -> CompartmentDimensions? {
        let by = Dictionary(uniqueKeysWithValues: planes.map { ($0.surface, $0) })
        guard let left = by[.left], let right = by[.right], let back = by[.back],
              let front = by[.frontOpening] else { return nil }
        let width = parallelPlaneDistance(left.plane, right.plane)
        guard width.isFinite, width > 0 else { return nil }
        let depth = parallelPlaneDistance(back.plane, front.plane)
        let height: Double? = if let bottom = by[.bottom], let top = by[.top] {
            parallelPlaneDistance(bottom.plane, top.plane)
        } else { nil }
        let uncertainty = planes.map(\.uncertaintyMetres).reduce(0) { hypot($0, $1) }
        return CompartmentDimensions(
            interiorWidthMetres: width, interiorHeightMetres: height, interiorDepthMetres: depth,
            openingWidthMetres: verifiedOpeningWidthMetres,
            openingHeightMetres: verifiedOpeningHeightMetres,
            uncertaintyMetres: uncertainty,
            hasVerifiedUsableOpening: verifiedOpeningWidthMetres != nil
                && (height == nil || verifiedOpeningHeightMetres != nil)
        )
    }

    private static func parallelPlaneDistance(_ first: CodablePlane, _ second: CodablePlane) -> Double {
        abs(signedDistance(second.origin.simd, plane: first))
    }
}

private func signedDistance(_ point: SIMD3<Double>, plane: CodablePlane) -> Double {
    simd_dot(point - plane.origin.simd, plane.normal.normalized.simd)
}

private func vectorAngle(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> Double {
    guard simd_length(first) > 1e-9, simd_length(second) > 1e-9 else { return 0 }
    return acos(max(-1, min(1, simd_dot(simd_normalize(first), simd_normalize(second)))))
}

private func isFinite(_ value: SIMD3<Double>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
}
