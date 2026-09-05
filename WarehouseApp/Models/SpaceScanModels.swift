import Foundation
import simd

enum StorageGeometryType: String, Codable, CaseIterable, Identifiable {
    case shelf
    case openSpace
    var id: String { rawValue }
}

enum SpaceSurfaceType: String, Codable, CaseIterable, Identifiable {
    case shelf, floor, tabletop, workbench, platform, counter, customHorizontalSurface, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shelf: "Shelf"
        case .floor: "Floor"
        case .tabletop: "Tabletop"
        case .workbench: "Workbench"
        case .platform: "Raised platform"
        case .counter: "Counter"
        case .customHorizontalSurface: "Custom horizontal surface"
        case .unknown: "Not sure"
        }
    }
    var isElevated: Bool { ![.floor, .unknown].contains(self) }
}

struct Vector2D: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    init(_ value: SIMD2<Double>) { self.init(value.x, value.y) }
    var simd: SIMD2<Double> { SIMD2(x, y) }
}

struct CodablePlane: Codable, Equatable {
    var origin: Vector3D
    var normal: Vector3D
}

enum SpaceTopDefinition: Codable, Equatable {
    case physicalPlane(CodablePlane)
    case physicalPoint(Vector3D)
    case manualLimitCM(Double)
}

enum SpaceGeometryApproval: String, Codable { case draft, approved }

struct SpaceConfidence: Codable, Equatable {
    var baseSurface: Double
    var boundary: Double
    var corners: Double
    var walls: Double?
    var surfaceEdges: Double?
    var height: Double
    var overall: Double {
        let values = [baseSurface, boundary, corners, height] + [walls, surfaceEdges].compactMap { $0 }
        return values.reduce(0, +) / Double(max(values.count, 1))
    }
}

struct ScannedSpaceGeometry: Codable, Equatable, Identifiable {
    var id: UUID
    var geometryType: StorageGeometryType
    var surfaceType: SpaceSurfaceType
    var rawBoundary2D: [Vector2D]
    var suggestedBoundary2D: [Vector2D]?
    var approvedBoundary2D: [Vector2D]
    /// Each polygon is a closed unusable region in the same local centimetre coordinate system.
    var excludedRegions2D: [[Vector2D]]
    var localOrigin: Vector3D
    var localXAxis: Vector3D
    var localYAxis: Vector3D
    var localVerticalAxis: Vector3D
    var bottomPlane: CodablePlane
    var topDefinition: SpaceTopDefinition
    var heightCM: Double
    var accessDirections: [Vector3D]
    var confidence: SpaceConfidence
    var approval: SpaceGeometryApproval
    var geometryVersion: Int
    var createdAt: Date
    var updatedAt: Date
    /// Present for corner-placement geometry (schema v3+); nil identifies legacy records.
    var measurementMethod: SpaceMeasurementMethod? = nil
    var measuredCorners: [MeasuredSpaceCornerRecord]? = nil
    /// Full border-scan provenance (schema v4+). Older corner-placement records decode with nil.
    var scannedBoundary: ScannedStorageBoundary? = nil
    /// Selected base-plane provenance plus exactly four wall boundaries.
    var markerMeasurement: StorageMarkerMeasurementRecord? = nil

    var isApprovedForPlacement: Bool {
        approval == .approved && approvedBoundary2D.count >= 3 && heightCM.isFinite && heightCM > 0
    }
}

enum SpaceGeometryError: LocalizedError, Equatable {
    case unapproved, invalidHeight, invalidBoundary, invalidExcludedRegion, reversedVerticalAxis
    case geometryConfidenceTooLow
    case accuracyNotVerified
    case localVerificationRequired
    var errorDescription: String? {
        switch self {
        case .unapproved: "Approve the complete space before automatic placement."
        case .invalidHeight: "Height must be a finite positive value greater than the safety margin."
        case .invalidBoundary: "The usable footprint is incomplete or invalid."
        case .invalidExcludedRegion: "An excluded region is invalid or extends outside the usable footprint."
        case .reversedVerticalAxis: "The stored vertical direction is invalid. Rescan the base surface."
        case .geometryConfidenceTooLow: "The border scan is not sufficiently confident and valid for placement."
        case .accuracyNotVerified: "This scan does not have approved dimension-level accuracy evidence."
        case .localVerificationRequired: "Approximate global geometry cannot authorize a close fit. Run a local verification scan."
        }
    }
}

enum SpaceGeometryValidator {
    static func validate(_ space: ScannedSpaceGeometry, safetyMarginCM: Double = 1) throws {
        guard space.isApprovedForPlacement else { throw SpaceGeometryError.unapproved }
        guard space.heightCM > safetyMarginCM, space.heightCM < 5_000 else {
            throw SpaceGeometryError.invalidHeight
        }
        guard validPolygon(space.approvedBoundary2D.map(\.simd)) else {
            throw SpaceGeometryError.invalidBoundary
        }
        if let border = space.scannedBoundary {
            guard border.validationState == .valid,
                  border.geometryConfidence >= 0.55,
                  border.approvedPolygon.count >= 3 else {
                throw SpaceGeometryError.geometryConfidenceTooLow
            }
            if border.schemaVersion >= 5 {
                guard border.approvalState == .approvedRaw || border.approvalState == .approvedCorrected,
                      let diagnostics = border.dimensionUncertainties, !diagnostics.isEmpty,
                      diagnostics.allSatisfy({
                          let use = MeasurementAccuracyPolicy.evaluate($0, fitCritical: false).use
                          return use != .rejected && use != .manualOnly
                      }) else { throw SpaceGeometryError.accuracyNotVerified }
            }
        }
        if let markerMeasurement = space.markerMeasurement {
            guard markerMeasurement.isValidForPlacement,
                  polygonsApproximatelyEqual(
                      markerMeasurement.approvedFootprint2D,
                      space.approvedBoundary2D.map { Vector2D($0.x / 100, $0.y / 100) }
                  ),
                  abs(markerMeasurement.heightCM - space.heightCM) < 0.001 else {
                throw SpaceGeometryError.invalidBoundary
            }
        }
        guard space.localVerticalAxis.normalized.y.isFinite,
              simd_length(space.localVerticalAxis.simd) > 0.9 else {
            throw SpaceGeometryError.reversedVerticalAxis
        }
        for excluded in space.excludedRegions2D.map({ $0.map(\.simd) }) {
            guard validPolygon(excluded), excluded.allSatisfy({ pointInPolygon($0, space.approvedBoundary2D.map(\.simd)) }) else {
                throw SpaceGeometryError.invalidExcludedRegion
            }
        }
    }

    static func validateForCloseFit(_ space: ScannedSpaceGeometry) throws {
        try validate(space)
        guard let border = space.scannedBoundary, border.schemaVersion >= 5,
              border.localPlacementUncertaintyMetres != nil,
              border.dimensionUncertainties?.allSatisfy({
                  MeasurementAccuracyPolicy.evaluate($0, fitCritical: true).use == .fitCritical
              }) == true else { throw SpaceGeometryError.localVerificationRequired }
    }

    private static func validPolygon(_ polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let doubledArea: Double = polygon.indices.reduce(0.0) { value, i in
            let n = polygon[(i + 1) % polygon.count]
            return value + polygon[i].x * n.y - n.x * polygon[i].y
        }
        let area = abs(doubledArea / 2)
        guard area > 0.01 else { return false }
        for first in polygon.indices {
            let firstNext = (first + 1) % polygon.count
            for second in polygon.indices where second > first {
                let secondNext = (second + 1) % polygon.count
                if first == second || firstNext == second || secondNext == first { continue }
                if segmentsIntersect(
                    polygon[first], polygon[firstNext], polygon[second], polygon[secondNext]
                ) { return false }
            }
        }
        return true
    }

    private static func segmentsIntersect(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>,
        _ c: SIMD2<Double>, _ d: SIMD2<Double>
    ) -> Bool {
        let epsilon = 0.000_001
        func cross(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>) -> Double {
            let pq = q - p, pr = r - p
            return pq.x * pr.y - pq.y * pr.x
        }
        func onSegment(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>) -> Bool {
            q.x >= min(p.x, r.x) - epsilon && q.x <= max(p.x, r.x) + epsilon &&
                q.y >= min(p.y, r.y) - epsilon && q.y <= max(p.y, r.y) + epsilon
        }
        let abC = cross(a, b, c), abD = cross(a, b, d)
        let cdA = cross(c, d, a), cdB = cross(c, d, b)
        if abC * abD < -epsilon && cdA * cdB < -epsilon { return true }
        if abs(abC) <= epsilon && onSegment(a, c, b) { return true }
        if abs(abD) <= epsilon && onSegment(a, d, b) { return true }
        if abs(cdA) <= epsilon && onSegment(c, a, d) { return true }
        if abs(cdB) <= epsilon && onSegment(c, b, d) { return true }
        return false
    }

    private static func pointInPolygon(_ point: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index], b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = index
        }
        return inside
    }

    private static func polygonsApproximatelyEqual(
        _ first: [Vector2D], _ second: [Vector2D]
    ) -> Bool {
        guard first.count == second.count else { return false }
        return zip(first, second).allSatisfy {
            simd_distance($0.simd, $1.simd) <= 0.000_001
        }
    }
}

enum OpenSpacePlacementAdapter {
    static func shelfState(from space: ScannedSpaceGeometry) throws -> ShelfState {
        try SpaceGeometryValidator.validate(space)
        let polygon = space.approvedBoundary2D
        guard let minX = polygon.map(\.x).min(), let maxX = polygon.map(\.x).max(),
              let minZ = polygon.map(\.y).min(), let maxZ = polygon.map(\.y).max()
        else { throw SpaceGeometryError.invalidBoundary }
        let boundary = AxisAlignedVolume(
            id: "\(space.id)-volume", minimum: Vector3D(minX, 0, minZ),
            dimensions: PackageDimensions(widthCM: maxX - minX, heightCM: space.heightCM, depthCM: maxZ - minZ)
        )
        let metadata = ShelfMeasurementMetadata(
            capturedAt: space.createdAt, deviceModel: "Space Scan",
            hasLiDAR: space.markerMeasurement?.deviceHasLiDAR == true
                || space.measurementMethod == .lidarBorderScan
                || space.measurementMethod == .lidarCornerPlacement,
            coordinateSpace: .shelfLocal, unit: .centimetres,
            planeRMSResidualMetres: 0, planeMaximumResidualMetres: 0,
            cornerMeasurements: [], expectedWidthCM: nil, expectedDepthCM: nil
        )
        let geometry = ShelfGeometryRecord(
            version: space.geometryVersion, inputRevision: space.id,
            rawBoundary: space.rawBoundary2D.map { Vector3D($0.x, 0, $0.y) },
            correctedBoundary: space.suggestedBoundary2D?.map { Vector3D($0.x, 0, $0.y) },
            approvedBoundary: polygon.map { Vector3D($0.x, 0, $0.y) },
            detectedShapeType: polygon.count == 4 ? .likelyRectangle : .irregularPolygon,
            requestedShapeIntent: .automatic, boundaryMeaning: .innerUsable,
            correctionConfidence: space.confidence.boundary, scanConfidence: space.confidence.overall,
            correctionReasons: [], approval: .approvedManual, approvedAt: space.updatedAt,
            placementSafetyMarginCM: 1, measurementMetadata: metadata,
            excludedRegions: space.excludedRegions2D.map { $0.map { Vector3D($0.x, 0, $0.y) } }
        )
        return ShelfState(
            id: space.id.uuidString, label: "Scanned \(space.surfaceType.title)", barcode: "SPACE-\(space.id)",
            version: max(space.geometryVersion, 2), boundary: boundary,
            coordinateSystem: ShelfLocalCoordinateSystem(anchorOrigin: space.localOrigin,
                widthAxis: space.localXAxis, upAxis: space.localVerticalAxis, depthAxis: space.localYAxis),
            primaryFrontDirection: space.accessDirections.first ?? Vector3D(0, 0, 1),
            secondaryAccessDirections: Array(space.accessDirections.dropFirst()),
            compartments: [.init(id: "open", label: space.surfaceType.title, volume: boundary, ratedWeightKG: nil)],
            obstacles: [], products: [],
            scanQuality: .init(hasClosedBoundary: true, missingSurfaceCount: 0, trackingDriftCM: 0,
                confidence: space.confidence.overall, capturedAt: space.createdAt),
            geometry: geometry, ratedWeightKG: nil, updatedAt: space.updatedAt
        )
    }
}
