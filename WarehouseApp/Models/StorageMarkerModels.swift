import Foundation
import simd

enum StorageMarkerStage: Equatable {
    case selectSurface
    case placeBoundaries
    case review
    case enterHeight
    case preview
    case complete
}

enum StorageBoundarySource: String, Codable, Equatable {
    case verticalPlaneAnchor
    case localLiDARMesh
}

struct StorageBasePlaneCoordinateSystem: Equatable {
    var originWorld: Vector3D
    var widthAxisWorld: Vector3D
    var depthAxisWorld: Vector3D
    var verticalAxisWorld: Vector3D
}

struct StorageBoundaryVisualBasis: Equatable {
    var rightAxisWorld: Vector3D
    var normalAxisWorld: Vector3D
    var upAxisWorld: Vector3D
}

enum StorageWallGeometry {
    /// A wall may be noisy, but its normal must remain substantially tangent to
    /// the selected base plane. Values above this are floor/ceiling-like.
    static let maximumWallBaseNormalAlignment = 0.35

    static func projectedBoundaryNormal(
        wallNormalWorld: Vector3D,
        baseNormalWorld: Vector3D
    ) -> Vector3D? {
        let wallLength = simd_length(wallNormalWorld.simd)
        let baseLength = simd_length(baseNormalWorld.simd)
        guard wallLength > 0.000_001, baseLength > 0.000_001 else { return nil }
        let wallNormal = wallNormalWorld.simd / wallLength
        let baseNormal = baseNormalWorld.simd / baseLength
        let alignment = simd_dot(wallNormal, baseNormal)
        guard abs(alignment) <= maximumWallBaseNormalAlignment else { return nil }
        let projected = wallNormal - alignment * baseNormal
        guard simd_length(projected) > 0.000_001 else { return nil }
        return Vector3D(simd_normalize(projected))
    }

    /// RealityKit's generated plane lies in its local X/Z axes with local Y as
    /// its normal. These axes therefore orient that primitive as a vertical wall.
    static func visualBasis(
        boundaryNormalWorld: Vector3D,
        baseNormalWorld: Vector3D
    ) -> StorageBoundaryVisualBasis? {
        guard let normal = projectedBoundaryNormal(
            wallNormalWorld: boundaryNormalWorld,
            baseNormalWorld: baseNormalWorld
        )?.simd else { return nil }
        let up = baseNormalWorld.normalized.simd
        let right = simd_cross(normal, up)
        guard simd_length(right) > 0.000_001 else { return nil }
        return StorageBoundaryVisualBasis(
            rightAxisWorld: Vector3D(simd_normalize(right)),
            normalAxisWorld: Vector3D(normal),
            upAxisWorld: Vector3D(up)
        )
    }

    /// Intersects a world-space wall plane with the selected base coordinate
    /// system. Marker height is deliberately absent from the resulting 2D line.
    static func boundary(
        hitPositionWorld: Vector3D,
        wallNormalWorld: Vector3D,
        source: StorageBoundarySource,
        confidence: Double,
        base: StorageBasePlaneCoordinateSystem,
        id: UUID = UUID()
    ) -> StorageBoundary? {
        let rawWallNormal = wallNormalWorld.normalized
        guard let boundaryNormal = projectedBoundaryNormal(
            wallNormalWorld: rawWallNormal,
            baseNormalWorld: base.verticalAxisWorld
        ) else { return nil }
        let localNormal = SIMD2(
            simd_dot(boundaryNormal.simd, base.widthAxisWorld.normalized.simd),
            simd_dot(boundaryNormal.simd, base.depthAxisWorld.normalized.simd)
        )
        let squaredLength = simd_length_squared(localNormal)
        guard squaredLength >= 0.75 else { return nil }
        let constant = simd_dot(
            boundaryNormal.simd,
            hitPositionWorld.simd - base.originWorld.simd
        )
        let linePoint = localNormal * (constant / squaredLength)
        return StorageBoundary(
            id: id,
            rawPoint2D: Vector2D(linePoint),
            rawNormal2D: Vector2D(simd_normalize(localNormal)),
            correctedNormal2D: nil,
            insideSign: 1,
            hitPositionWorld: hitPositionWorld,
            wallNormalWorld: rawWallNormal,
            wallPlane: CodablePlane(origin: hitPositionWorld, normal: boundaryNormal),
            source: source,
            confidence: confidence
        )
    }
}

/// A generalized wall constraint. `rawPoint2D` and `rawNormal2D` describe the
/// wall/base-plane intersection in storage-local metres. World-space evidence
/// is retained so a rendered dot is never mistaken for the actual constraint.
struct StorageBoundary: Codable, Equatable, Identifiable {
    var id: UUID
    var rawPoint2D: Vector2D
    var rawNormal2D: Vector2D
    var correctedNormal2D: Vector2D?
    var insideSign: Double
    var hitPositionWorld: Vector3D? = nil
    var wallNormalWorld: Vector3D? = nil
    var wallPlane: CodablePlane? = nil
    var source: StorageBoundarySource? = nil
    var confidence: Double? = nil
}

struct StorageMarkerMeasurementRecord: Codable, Equatable {
    var schemaVersion: Int
    var selectedPlaneIdentifier: UUID
    /// Coordinate origin of the selected base plane; never a user-placed marker.
    var basePlaneOriginWorld: Vector3D
    var localXAxisWorld: Vector3D
    var localDepthAxisWorld: Vector3D
    var verticalAxisWorld: Vector3D
    var horizontalDeviationDegrees: Double
    var boundaries: [StorageBoundary]
    var rawFootprint2D: [Vector2D]
    var correctedFootprint2D: [Vector2D]?
    var approvedFootprint2D: [Vector2D]
    var appliedRightAngleCorrection: Bool
    var heightCM: Double
    var confidence: Double
    var deviceHasLiDAR: Bool
    var capturedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedPlaneIdentifier
        case basePlaneOriginWorld
        /// Schema 1/2 used this key for the base-plane origin. It was not a
        /// marker in the four-wall workflow.
        case legacySurfacePointWorld = "surfacePointWorld"
        case localXAxisWorld
        case localDepthAxisWorld
        case verticalAxisWorld
        case horizontalDeviationDegrees
        case boundaries
        case rawFootprint2D
        case correctedFootprint2D
        case approvedFootprint2D
        case appliedRightAngleCorrection
        case heightCM
        case confidence
        case deviceHasLiDAR
        case capturedAt
    }

    init(
        schemaVersion: Int,
        selectedPlaneIdentifier: UUID,
        basePlaneOriginWorld: Vector3D,
        localXAxisWorld: Vector3D,
        localDepthAxisWorld: Vector3D,
        verticalAxisWorld: Vector3D,
        horizontalDeviationDegrees: Double,
        boundaries: [StorageBoundary],
        rawFootprint2D: [Vector2D],
        correctedFootprint2D: [Vector2D]?,
        approvedFootprint2D: [Vector2D],
        appliedRightAngleCorrection: Bool,
        heightCM: Double,
        confidence: Double,
        deviceHasLiDAR: Bool,
        capturedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.selectedPlaneIdentifier = selectedPlaneIdentifier
        self.basePlaneOriginWorld = basePlaneOriginWorld
        self.localXAxisWorld = localXAxisWorld
        self.localDepthAxisWorld = localDepthAxisWorld
        self.verticalAxisWorld = verticalAxisWorld
        self.horizontalDeviationDegrees = horizontalDeviationDegrees
        self.boundaries = boundaries
        self.rawFootprint2D = rawFootprint2D
        self.correctedFootprint2D = correctedFootprint2D
        self.approvedFootprint2D = approvedFootprint2D
        self.appliedRightAngleCorrection = appliedRightAngleCorrection
        self.heightCM = heightCM
        self.confidence = confidence
        self.deviceHasLiDAR = deviceHasLiDAR
        self.capturedAt = capturedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        selectedPlaneIdentifier = try container.decode(UUID.self, forKey: .selectedPlaneIdentifier)
        if let current = try container.decodeIfPresent(Vector3D.self, forKey: .basePlaneOriginWorld) {
            basePlaneOriginWorld = current
        } else {
            basePlaneOriginWorld = try container.decode(
                Vector3D.self, forKey: .legacySurfacePointWorld
            )
        }
        localXAxisWorld = try container.decode(Vector3D.self, forKey: .localXAxisWorld)
        localDepthAxisWorld = try container.decode(Vector3D.self, forKey: .localDepthAxisWorld)
        verticalAxisWorld = try container.decode(Vector3D.self, forKey: .verticalAxisWorld)
        horizontalDeviationDegrees = try container.decode(
            Double.self, forKey: .horizontalDeviationDegrees
        )
        boundaries = try container.decode([StorageBoundary].self, forKey: .boundaries)
        rawFootprint2D = try container.decode([Vector2D].self, forKey: .rawFootprint2D)
        correctedFootprint2D = try container.decodeIfPresent(
            [Vector2D].self, forKey: .correctedFootprint2D
        )
        approvedFootprint2D = try container.decode(
            [Vector2D].self, forKey: .approvedFootprint2D
        )
        appliedRightAngleCorrection = try container.decode(
            Bool.self, forKey: .appliedRightAngleCorrection
        )
        heightCM = try container.decode(Double.self, forKey: .heightCM)
        confidence = try container.decode(Double.self, forKey: .confidence)
        deviceHasLiDAR = try container.decode(Bool.self, forKey: .deviceHasLiDAR)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(selectedPlaneIdentifier, forKey: .selectedPlaneIdentifier)
        try container.encode(basePlaneOriginWorld, forKey: .basePlaneOriginWorld)
        try container.encode(localXAxisWorld, forKey: .localXAxisWorld)
        try container.encode(localDepthAxisWorld, forKey: .localDepthAxisWorld)
        try container.encode(verticalAxisWorld, forKey: .verticalAxisWorld)
        try container.encode(horizontalDeviationDegrees, forKey: .horizontalDeviationDegrees)
        try container.encode(boundaries, forKey: .boundaries)
        try container.encode(rawFootprint2D, forKey: .rawFootprint2D)
        try container.encodeIfPresent(correctedFootprint2D, forKey: .correctedFootprint2D)
        try container.encode(approvedFootprint2D, forKey: .approvedFootprint2D)
        try container.encode(appliedRightAngleCorrection, forKey: .appliedRightAngleCorrection)
        try container.encode(heightCM, forKey: .heightCM)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(deviceHasLiDAR, forKey: .deviceHasLiDAR)
        try container.encode(capturedAt, forKey: .capturedAt)
    }

    var isValidForPlacement: Bool {
        let hasWallEvidence = schemaVersion < 2 || boundaries.allSatisfy {
            $0.hitPositionWorld != nil && $0.wallNormalWorld != nil
                && $0.wallPlane != nil && $0.source != nil
        }
        let rawInterior = StorageMarkerGeometryBuilder.verifiedInteriorPoint(
            polygon: rawFootprint2D.map(\.simd)
        )
        let approvedInterior = StorageMarkerGeometryBuilder.verifiedInteriorPoint(
            polygon: approvedFootprint2D.map(\.simd)
        )
        let halfSpacesFaceInward = rawInterior.map { interior in
            boundaries.allSatisfy { boundary in
                boundary.insideSign * simd_dot(
                    boundary.rawNormal2D.simd,
                    interior - boundary.rawPoint2D.simd
                ) >= -0.000_01
            }
        } ?? false
        return schemaVersion >= 1
            && boundaries.count == StorageMarkerGeometryBuilder.requiredBoundaryCount
            && approvedFootprint2D.count >= 3
            && heightCM.isFinite && heightCM > 1 && heightCM <= 5_000
            && horizontalDeviationDegrees.isFinite
            && horizontalDeviationDegrees <= StorageMarkerGeometryBuilder.maximumHorizontalDeviationDegrees
            && confidence >= 0.55
            && hasWallEvidence
            && simd_length(localXAxisWorld.simd) > 0.9
            && simd_length(localDepthAxisWorld.simd) > 0.9
            && simd_length(verticalAxisWorld.simd) > 0.9
            && verticalAxisWorld.normalized.y > 0.99
            && abs(simd_dot(localXAxisWorld.normalized.simd, localDepthAxisWorld.normalized.simd)) < 0.05
            && rawInterior != nil
            && approvedInterior != nil
            && halfSpacesFaceInward
    }
}

struct StorageMarkerDraft: Equatable {
    var id: UUID
    var selectedPlaneIdentifier: UUID
    var basePlaneOriginWorld: Vector3D
    var localXAxisWorld: Vector3D
    var localDepthAxisWorld: Vector3D
    var verticalAxisWorld: Vector3D
    var horizontalDeviationDegrees: Double
    var boundaries: [StorageBoundary]
    var rawFootprint2D: [Vector2D]
    var correctedFootprint2D: [Vector2D]?
    var correctionAppliedAutomatically: Bool
    var correctionMaximumMovementMetres: Double
    var confidence: Double
    var deviceHasLiDAR: Bool

    func volumeOutline(
        useCorrectedFootprint: Bool,
        heightCM: Double
    ) -> StorageVolumeOutline? {
        guard boundaries.count == StorageMarkerGeometryBuilder.requiredBoundaryCount else {
            return nil
        }
        let footprint = useCorrectedFootprint
            ? correctedFootprint2D ?? rawFootprint2D
            : rawFootprint2D
        return StorageVolumeGeometry.outline(
            footprint2D: footprint,
            base: StorageBasePlaneCoordinateSystem(
                originWorld: basePlaneOriginWorld,
                widthAxisWorld: localXAxisWorld,
                depthAxisWorld: localDepthAxisWorld,
                verticalAxisWorld: verticalAxisWorld
            ),
            heightCM: heightCM
        )
    }

    func record(approvedCorrected: Bool, heightCM: Double) -> StorageMarkerMeasurementRecord {
        StorageMarkerMeasurementRecord(
            schemaVersion: 3,
            selectedPlaneIdentifier: selectedPlaneIdentifier,
            basePlaneOriginWorld: basePlaneOriginWorld,
            localXAxisWorld: localXAxisWorld,
            localDepthAxisWorld: localDepthAxisWorld,
            verticalAxisWorld: verticalAxisWorld,
            horizontalDeviationDegrees: horizontalDeviationDegrees,
            boundaries: boundaries,
            rawFootprint2D: rawFootprint2D,
            correctedFootprint2D: correctedFootprint2D,
            approvedFootprint2D: approvedCorrected
                ? correctedFootprint2D ?? rawFootprint2D
                : rawFootprint2D,
            appliedRightAngleCorrection: approvedCorrected && correctedFootprint2D != nil,
            heightCM: heightCM,
            confidence: confidence,
            deviceHasLiDAR: deviceHasLiDAR,
            capturedAt: .now
        )
    }
}

struct StorageMarkerGeometryResult: Equatable {
    var boundaries: [StorageBoundary]
    var raw: [SIMD2<Double>]
    var corrected: [SIMD2<Double>]?
    var interior: SIMD2<Double>
    var maximumCorrection: Double
}

struct StorageRectangularDimensions: Equatable {
    var widthMetres: Double
    var depthMetres: Double
}

struct StorageVolumeOutline: Equatable {
    var footprint2D: [Vector2D]
    var bottomVerticesWorld: [Vector3D]
    var topVerticesWorld: [Vector3D]
    var baseNormalWorld: Vector3D
    var heightMetres: Double
    var floorAreaSquareMetres: Double
    var volumeCubicMetres: Double
    var rectangularDimensions: StorageRectangularDimensions?
}

enum StorageVolumeGeometry {
    static func outline(
        footprint2D: [Vector2D],
        base: StorageBasePlaneCoordinateSystem,
        heightCM: Double
    ) -> StorageVolumeOutline? {
        let polygon = footprint2D.map(\.simd)
        guard polygon.count >= 3,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              heightCM.isFinite, heightCM > 1, heightCM <= 5_000,
              simd_length(base.widthAxisWorld.simd) > 0.9,
              simd_length(base.depthAxisWorld.simd) > 0.9,
              simd_length(base.verticalAxisWorld.simd) > 0.9 else { return nil }
        let area = polygonArea(polygon)
        guard area >= StorageMarkerGeometryBuilder.minimumAreaSquareMetres else { return nil }

        let widthAxis = base.widthAxisWorld.normalized.simd
        let depthAxis = base.depthAxisWorld.normalized.simd
        let normal = base.verticalAxisWorld.normalized.simd
        let origin = base.originWorld.simd
        let heightMetres = heightCM / 100
        let bottom = polygon.map { point in
            origin + widthAxis * point.x + depthAxis * point.y
        }
        let top = bottom.map { $0 + normal * heightMetres }
        return StorageVolumeOutline(
            footprint2D: footprint2D,
            bottomVerticesWorld: bottom.map(Vector3D.init),
            topVerticesWorld: top.map(Vector3D.init),
            baseNormalWorld: Vector3D(normal),
            heightMetres: heightMetres,
            floorAreaSquareMetres: area,
            volumeCubicMetres: area * heightMetres,
            rectangularDimensions: rectangularDimensions(polygon)
        )
    }

    private static func polygonArea(_ polygon: [SIMD2<Double>]) -> Double {
        abs(polygon.indices.reduce(0.0) { value, index in
            let next = polygon[(index + 1) % polygon.count]
            return value + polygon[index].x * next.y - next.x * polygon[index].y
        }) / 2
    }

    private static func rectangularDimensions(
        _ polygon: [SIMD2<Double>]
    ) -> StorageRectangularDimensions? {
        guard polygon.count == 4 else { return nil }
        let edges = polygon.indices.map { index in
            polygon[(index + 1) % polygon.count] - polygon[index]
        }
        let lengths = edges.map(simd_length)
        guard lengths.allSatisfy({ $0 > 0.01 }) else { return nil }
        let maximumAdjacentDot = sin(StorageMarkerGeometryBuilder.rightAngleSnapToleranceDegrees * .pi / 180)
        guard edges.indices.allSatisfy({ index in
            let next = (index + 1) % edges.count
            return abs(simd_dot(edges[index] / lengths[index], edges[next] / lengths[next]))
                <= maximumAdjacentDot
        }) else { return nil }
        let firstPair = (lengths[0] + lengths[2]) / 2
        let secondPair = (lengths[1] + lengths[3]) / 2
        guard abs(lengths[0] - lengths[2]) <= firstPair * 0.12,
              abs(lengths[1] - lengths[3]) <= secondPair * 0.12 else { return nil }
        return StorageRectangularDimensions(
            widthMetres: max(firstPair, secondPair),
            depthMetres: min(firstPair, secondPair)
        )
    }
}

enum StorageMarkerGeometryError: LocalizedError, Equatable {
    case wrongBoundaryCount
    case invalidCoordinate
    case boundaryTooClose
    case duplicateBoundary
    case invalidFootprint
    case ambiguousInterior

    var errorDescription: String? {
        switch self {
        case .wrongBoundaryCount:
            "Place exactly four wall boundaries before continuing."
        case .invalidCoordinate:
            "A wall boundary contains invalid coordinates. Reset and measure it again."
        case .boundaryTooClose:
            "Two wall boundaries are too close together. Reposition one boundary."
        case .duplicateBoundary:
            "That physical wall has already been measured. Aim at a different limiting wall."
        case .invalidFootprint:
            "The four wall planes do not enclose a usable footprint. Reposition one or more boundaries."
        case .ambiguousInterior:
            "The wall planes do not define one reliable inside region. Reposition the unclear boundary."
        }
    }
}

enum StorageMarkerGeometryBuilder {
    static let requiredBoundaryCount = 4
    static let maximumHorizontalDeviationDegrees = 8.0
    static let rightAngleSnapToleranceDegrees = 12.0
    static let minimumBoundarySpacingMetres = 0.03
    static let minimumAreaSquareMetres = 0.01

    static func build(boundaries input: [StorageBoundary]) throws -> StorageMarkerGeometryResult {
        guard input.count == requiredBoundaryCount else {
            throw StorageMarkerGeometryError.wrongBoundaryCount
        }
        guard input.allSatisfy({ boundary in
            let point = boundary.rawPoint2D.simd, normal = boundary.rawNormal2D.simd
            return point.x.isFinite && point.y.isFinite
                && normal.x.isFinite && normal.y.isFinite && simd_length(normal) > 0.9
        }) else { throw StorageMarkerGeometryError.invalidCoordinate }

        var boundaries = input
        for index in boundaries.indices {
            boundaries[index].rawNormal2D = Vector2D(simd_normalize(boundaries[index].rawNormal2D.simd))
        }
        try validateDistinctLines(boundaries)

        let rawSolution = try automaticInteriorSolution(
            points: boundaries.map { $0.rawPoint2D.simd },
            normals: boundaries.map { $0.rawNormal2D.simd }
        )
        for index in boundaries.indices {
            boundaries[index].insideSign = rawSolution.signs[index]
        }

        var corrected: [SIMD2<Double>]?
        var maximumCorrection = 0.0
        if let correctedNormals = correctionNormals(for: boundaries) {
            let correctedSigns = correctedNormals.indices.map { index in
                simd_dot(
                    correctedNormals[index],
                    rawSolution.interior - boundaries[index].rawPoint2D.simd
                ) >= 0 ? 1.0 : -1.0
            }
            if let proposed = try? footprint(
                points: boundaries.map { $0.rawPoint2D.simd },
                normals: correctedNormals,
                signs: correctedSigns,
                requireEveryBoundary: true
            ) {
                maximumCorrection = proposed.map { point in
                    rawSolution.polygon.map { simd_distance(point, $0) }.min() ?? .infinity
                }.max() ?? .infinity
                let spanX = (rawSolution.polygon.map(\.x).max() ?? 0)
                    - (rawSolution.polygon.map(\.x).min() ?? 0)
                let spanY = (rawSolution.polygon.map(\.y).max() ?? 0)
                    - (rawSolution.polygon.map(\.y).min() ?? 0)
                let movementLimit = max(0.04, min(spanX, spanY) * 0.08)
                if maximumCorrection <= movementLimit {
                    corrected = proposed
                    for index in boundaries.indices {
                        boundaries[index].correctedNormal2D = Vector2D(correctedNormals[index])
                    }
                } else {
                    maximumCorrection = 0
                }
            }
        }
        return StorageMarkerGeometryResult(
            boundaries: boundaries,
            raw: rawSolution.polygon,
            corrected: corrected,
            interior: rawSolution.interior,
            maximumCorrection: maximumCorrection
        )
    }

    static func contains(_ point: SIMD2<Double>, polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current], b = polygon[previous]
            if distance(point, toSegmentFrom: a, to: b) <= 0.000_001 { return true }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    /// Derives an interior point from an already constructed polygon. This is
    /// transient geometry, not a fifth user marker or persisted input.
    static func verifiedInteriorPoint(
        polygon: [SIMD2<Double>]
    ) -> SIMD2<Double>? {
        guard polygon.count >= 3,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              polygonArea(polygon) >= minimumAreaSquareMetres else { return nil }
        let interior = polygonCentroid(polygon)
        return contains(interior, polygon: polygon) ? interior : nil
    }

    private struct InteriorSolution {
        var polygon: [SIMD2<Double>]
        var interior: SIMD2<Double>
        var signs: [Double]
        var area: Double
    }

    private static func automaticInteriorSolution(
        points: [SIMD2<Double>], normals: [SIMD2<Double>]
    ) throws -> InteriorSolution {
        var candidates: [InteriorSolution] = []
        for mask in 0..<(1 << points.count) {
            let signs = points.indices.map { mask & (1 << $0) == 0 ? -1.0 : 1.0 }
            guard let polygon = try? footprint(
                points: points, normals: normals, signs: signs,
                requireEveryBoundary: true
            ) else { continue }
            let area = polygonArea(polygon)
            guard let interior = verifiedInteriorPoint(polygon: polygon) else { continue }
            candidates.append(.init(polygon: polygon, interior: interior, signs: signs, area: area))
        }
        guard let best = candidates.max(by: { $0.area < $1.area }) else {
            throw StorageMarkerGeometryError.invalidFootprint
        }
        let competing = candidates.filter {
            $0.area >= best.area * 0.98 && simd_distance($0.interior, best.interior) > 0.02
        }
        guard competing.isEmpty else { throw StorageMarkerGeometryError.ambiguousInterior }
        return best
    }

    private static func validateDistinctLines(_ boundaries: [StorageBoundary]) throws {
        for first in boundaries.indices {
            for second in boundaries.indices where second > first {
                let n1 = boundaries[first].rawNormal2D.simd
                let n2 = boundaries[second].rawNormal2D.simd
                guard abs(simd_dot(n1, n2)) >= cos(15 * .pi / 180) else { continue }
                let separation = abs(simd_dot(
                    n1,
                    boundaries[second].rawPoint2D.simd - boundaries[first].rawPoint2D.simd
                ))
                if separation < 0.005 { throw StorageMarkerGeometryError.duplicateBoundary }
                if separation < minimumBoundarySpacingMetres {
                    throw StorageMarkerGeometryError.boundaryTooClose
                }
            }
        }
    }

    private static func correctionNormals(
        for boundaries: [StorageBoundary]
    ) -> [SIMD2<Double>]? {
        guard boundaries.count == 4 else { return nil }
        let normals = boundaries.map { simd_normalize($0.rawNormal2D.simd) }
        let pairings = [
            [[0, 1], [2, 3]], [[0, 2], [1, 3]], [[0, 3], [1, 2]]
        ]
        guard let pairing = pairings.min(by: { pairingScore($0, normals) < pairingScore($1, normals) }) else {
            return nil
        }
        let parallelDeviation = pairing.map { pair -> Double in
            acos(min(max(abs(simd_dot(normals[pair[0]], normals[pair[1]])), -1), 1)) * 180 / .pi
        }.max() ?? .infinity
        guard parallelDeviation <= rightAngleSnapToleranceDegrees else { return nil }
        let firstAxis = alignedAverage(normals[pairing[0][0]], normals[pairing[0][1]])
        let secondAxis = alignedAverage(normals[pairing[1][0]], normals[pairing[1][1]])
        let angle = acos(min(max(abs(simd_dot(firstAxis, secondAxis)), -1), 1)) * 180 / .pi
        guard abs(90 - angle) <= rightAngleSnapToleranceDegrees else { return nil }
        let snapped = orthogonalized(firstAxis, secondAxis)
        var result = normals
        for index in pairing[0] {
            result[index] = simd_dot(normals[index], snapped.0) >= 0 ? snapped.0 : -snapped.0
        }
        for index in pairing[1] {
            result[index] = simd_dot(normals[index], snapped.1) >= 0 ? snapped.1 : -snapped.1
        }
        return result
    }

    private static func pairingScore(_ pairing: [[Int]], _ normals: [SIMD2<Double>]) -> Double {
        pairing.reduce(0) { score, pair in
            score + (1 - abs(simd_dot(normals[pair[0]], normals[pair[1]])))
        }
    }

    private static func alignedAverage(
        _ first: SIMD2<Double>, _ second: SIMD2<Double>
    ) -> SIMD2<Double> {
        simd_normalize(first + (simd_dot(first, second) >= 0 ? second : -second))
    }

    private static func orthogonalized(
        _ first: SIMD2<Double>, _ second: SIMD2<Double>
    ) -> (SIMD2<Double>, SIMD2<Double>) {
        let firstAngle = atan2(first.y, first.x)
        let perpendicular = SIMD2(-first.y, first.x)
        let sign = simd_dot(perpendicular, second) >= 0 ? 1.0 : -1.0
        let targetSecond = firstAngle + sign * .pi / 2
        var secondAngle = atan2(second.y, second.x)
        while secondAngle - targetSecond > .pi / 2 { secondAngle -= .pi }
        while secondAngle - targetSecond < -.pi / 2 { secondAngle += .pi }
        let firstSnappedAngle = firstAngle + (secondAngle - targetSecond) / 2
        let secondSnappedAngle = firstSnappedAngle + sign * .pi / 2
        return (
            SIMD2(cos(firstSnappedAngle), sin(firstSnappedAngle)),
            SIMD2(cos(secondSnappedAngle), sin(secondSnappedAngle))
        )
    }

    private static func footprint(
        points: [SIMD2<Double>], normals: [SIMD2<Double>], signs: [Double],
        requireEveryBoundary: Bool
    ) throws -> [SIMD2<Double>] {
        var intersections: [SIMD2<Double>] = []
        for first in points.indices {
            for second in points.indices where second > first {
                let n1 = normals[first], n2 = normals[second]
                let determinant = n1.x * n2.y - n1.y * n2.x
                guard abs(determinant) > 0.000_001 else { continue }
                let c1 = simd_dot(n1, points[first]), c2 = simd_dot(n2, points[second])
                let point = SIMD2(
                    (c1 * n2.y - n1.y * c2) / determinant,
                    (n1.x * c2 - c1 * n2.x) / determinant
                )
                let inside = points.indices.allSatisfy { index in
                    signs[index] * simd_dot(normals[index], point - points[index]) >= -0.000_01
                }
                if inside && !intersections.contains(where: { simd_distance($0, point) < 0.000_1 }) {
                    intersections.append(point)
                }
            }
        }
        guard intersections.count >= 3 else { throw StorageMarkerGeometryError.invalidFootprint }
        let centre = intersections.reduce(.zero, +) / Double(intersections.count)
        let ordered = intersections.sorted {
            atan2($0.y - centre.y, $0.x - centre.x)
                < atan2($1.y - centre.y, $1.x - centre.x)
        }
        guard polygonArea(ordered) >= minimumAreaSquareMetres else {
            throw StorageMarkerGeometryError.invalidFootprint
        }
        if requireEveryBoundary {
            for index in points.indices {
                let touches = ordered.filter {
                    abs(simd_dot(normals[index], $0 - points[index])) <= 0.000_1
                }.count
                guard touches >= 2 else { throw StorageMarkerGeometryError.invalidFootprint }
            }
        }
        return ordered
    }

    private static func polygonArea(_ polygon: [SIMD2<Double>]) -> Double {
        abs(polygon.indices.reduce(0.0) { value, index in
            let next = polygon[(index + 1) % polygon.count]
            return value + polygon[index].x * next.y - next.x * polygon[index].y
        }) / 2
    }

    private static func polygonCentroid(_ polygon: [SIMD2<Double>]) -> SIMD2<Double> {
        var crossSum = 0.0, xSum = 0.0, ySum = 0.0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            let cross = polygon[index].x * next.y - next.x * polygon[index].y
            crossSum += cross
            xSum += (polygon[index].x + next.x) * cross
            ySum += (polygon[index].y + next.y) * cross
        }
        guard abs(crossSum) > 0.000_001 else {
            return polygon.reduce(.zero, +) / Double(polygon.count)
        }
        return SIMD2(xSum / (3 * crossSum), ySum / (3 * crossSum))
    }

    private static func distance(
        _ point: SIMD2<Double>, toSegmentFrom start: SIMD2<Double>, to end: SIMD2<Double>
    ) -> Double {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0 else { return simd_distance(point, start) }
        let t = min(max(simd_dot(point - start, segment) / lengthSquared, 0), 1)
        return simd_distance(point, start + segment * t)
    }
}
