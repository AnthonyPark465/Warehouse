import Foundation
import simd

/// One face of a locked scan region. Boundary contact is reported per face so
/// the user can be told which limit the product reaches.
enum LiDARRegionFace: Hashable, Comparable {
    case bottom
    case top
    /// Box: 0 = −X, 1 = +X, 2 = −Z, 3 = +Z. Prism: polygon edge `index → index + 1`.
    case side(Int)

    var label: String {
        switch self {
        case .bottom: "bottom"
        case .top: "top"
        case .side(let index): "side\(index)"
        }
    }

    private var sortKey: Int {
        switch self {
        case .bottom: -2
        case .top: -1
        case .side(let index): index
        }
    }

    static func < (lhs: LiDARRegionFace, rhs: LiDARRegionFace) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

/// A world-space box locked when capture begins. Its axes remain fixed even as
/// the camera moves around the object.
struct LiDARScanVolume: Equatable {
    let centre: SIMD3<Float>
    let axisX: SIMD3<Float>
    let axisY: SIMD3<Float>
    let axisZ: SIMD3<Float>
    let halfExtents: SIMD3<Float>

    init(
        centre: SIMD3<Float>,
        axisX: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        axisY: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        axisZ: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        halfExtents: SIMD3<Float>
    ) {
        self.centre = centre
        self.axisX = simd_normalize(axisX)
        self.axisY = simd_normalize(axisY)
        self.axisZ = simd_normalize(axisZ)
        self.halfExtents = halfExtents
    }

    func contains(_ point: SIMD3<Float>, margin: Float = 0) -> Bool {
        let offset = point - centre
        return abs(simd_dot(offset, axisX)) <= halfExtents.x + margin
            && abs(simd_dot(offset, axisY)) <= halfExtents.y + margin
            && abs(simd_dot(offset, axisZ)) <= halfExtents.z + margin
    }

    func faces(near point: SIMD3<Float>, distance: Float) -> [LiDARRegionFace] {
        let offset = point - centre
        let x = simd_dot(offset, axisX)
        let y = simd_dot(offset, axisY)
        let z = simd_dot(offset, axisZ)
        var faces: [LiDARRegionFace] = []
        if abs(y + halfExtents.y) <= distance { faces.append(.bottom) }
        if abs(y - halfExtents.y) <= distance { faces.append(.top) }
        if abs(x + halfExtents.x) <= distance { faces.append(.side(0)) }
        if abs(x - halfExtents.x) <= distance { faces.append(.side(1)) }
        if abs(z + halfExtents.z) <= distance { faces.append(.side(2)) }
        if abs(z - halfExtents.z) <= distance { faces.append(.side(3)) }
        return faces
    }

    var transform: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(axisX, 0),
            SIMD4<Float>(axisY, 0),
            SIMD4<Float>(axisZ, 0),
            SIMD4<Float>(centre, 1)
        )
    }
}

/// User-defined polygon plus lower/upper offsets along its fitted plane normal.
/// This is a spatial crop only; its extents are never reported as product dimensions.
struct LiDARPolygonalPrism: Equatable {
    let origin: SIMD3<Float>
    let axisU: SIMD3<Float>
    let axisV: SIMD3<Float>
    let normal: SIMD3<Float>
    let polygon: [SIMD2<Float>]
    let lowerOffset: Float
    let upperOffset: Float
    /// Horizontal bounding box of the polygon for cheap rejection before the
    /// exact per-edge tests; computed once at init, not per point.
    let polygonMin: SIMD2<Float>
    let polygonMax: SIMD2<Float>

    init(
        origin: SIMD3<Float>,
        axisU: SIMD3<Float>,
        axisV: SIMD3<Float>,
        normal: SIMD3<Float>,
        polygon: [SIMD2<Float>],
        lowerOffset: Float,
        upperOffset: Float
    ) {
        self.origin = origin
        self.axisU = simd_normalize(axisU)
        self.axisV = simd_normalize(axisV)
        self.normal = simd_normalize(normal)
        self.polygon = polygon
        self.lowerOffset = min(lowerOffset, upperOffset)
        self.upperOffset = max(lowerOffset, upperOffset)
        var low = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var high = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for vertex in polygon {
            low = simd_min(low, vertex)
            high = simd_max(high, vertex)
        }
        self.polygonMin = low
        self.polygonMax = high
    }

    func contains(_ point: SIMD3<Float>, margin: Float = 0) -> Bool {
        let local = coordinates(of: point)
        guard local.y >= lowerOffset - margin, local.y <= upperOffset + margin else {
            return false
        }
        let horizontal = SIMD2(local.x, local.z)
        guard horizontal.x >= polygonMin.x - margin,
              horizontal.x <= polygonMax.x + margin,
              horizontal.y >= polygonMin.y - margin,
              horizontal.y <= polygonMax.y + margin
        else { return false }
        return Self.pointInPolygon(horizontal, polygon: polygon, margin: margin)
    }

    func faces(near point: SIMD3<Float>, distance: Float) -> [LiDARRegionFace] {
        let local = coordinates(of: point)
        var faces: [LiDARRegionFace] = []
        if abs(local.y - lowerOffset) <= distance { faces.append(.bottom) }
        if abs(local.y - upperOffset) <= distance { faces.append(.top) }
        let horizontal = SIMD2(local.x, local.z)
        // Beyond the expanded bounding box nothing can be near an edge.
        guard horizontal.x >= polygonMin.x - distance,
              horizontal.x <= polygonMax.x + distance,
              horizontal.y >= polygonMin.y - distance,
              horizontal.y <= polygonMax.y + distance
        else { return faces }
        let distanceSquared = distance * distance
        for index in polygon.indices where Self.distanceSquared(
            from: horizontal,
            toSegmentFrom: polygon[index],
            to: polygon[(index + 1) % polygon.count]
        ) <= distanceSquared {
            faces.append(.side(index))
        }
        return faces
    }

    func coordinates(of point: SIMD3<Float>) -> SIMD3<Float> {
        let offset = point - origin
        return SIMD3(
            simd_dot(offset, axisU),
            simd_dot(offset, normal),
            simd_dot(offset, axisV)
        )
    }

    static func pointInPolygon(
        _ point: SIMD2<Float>,
        polygon: [SIMD2<Float>],
        margin: Float
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        // Even-odd first: it is branch-cheap and settles the common case
        // (clearly inside / clearly outside) without any square roots.
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let crossingX = (b.x - a.x) * (point.y - a.y)
                    / (b.y - a.y) + a.x
                if point.x < crossingX { inside.toggle() }
            }
            previous = current
        }
        if inside { return true }
        guard margin > 0 else { return false }
        // Outside the polygon: accept only points within the margin band.
        let marginSquared = margin * margin
        return polygon.indices.contains {
            distanceSquared(
                from: point,
                toSegmentFrom: polygon[$0],
                to: polygon[($0 + 1) % polygon.count]
            ) <= marginSquared
        }
    }

    private static func distanceSquared(
        from point: SIMD2<Float>,
        toSegmentFrom start: SIMD2<Float>,
        to end: SIMD2<Float>
    ) -> Float {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0 else { return simd_distance_squared(point, start) }
        let t = min(max(simd_dot(point - start, segment) / lengthSquared, 0), 1)
        return simd_distance_squared(point, start + segment * t)
    }
}

enum LiDARSpatialRegion: Equatable {
    case box(LiDARScanVolume)
    case polygonalPrism(LiDARPolygonalPrism)

    func contains(_ point: SIMD3<Float>, margin: Float = 0) -> Bool {
        switch self {
        case .box(let volume): volume.contains(point, margin: margin)
        case .polygonalPrism(let prism): prism.contains(point, margin: margin)
        }
    }

    /// Region faces within `distance` of a point that lies inside the region.
    func faces(near point: SIMD3<Float>, distance: Float) -> [LiDARRegionFace] {
        switch self {
        case .box(let volume): volume.faces(near: point, distance: distance)
        case .polygonalPrism(let prism): prism.faces(near: point, distance: distance)
        }
    }

    var referenceOrigin: SIMD3<Float> {
        switch self {
        case .box(let volume): volume.centre
        case .polygonalPrism(let prism): prism.origin
        }
    }

    var axisX: SIMD3<Float> {
        switch self {
        case .box(let volume): volume.axisX
        case .polygonalPrism(let prism): prism.axisU
        }
    }

    var axisY: SIMD3<Float> {
        switch self {
        case .box(let volume): volume.axisY
        case .polygonalPrism(let prism): prism.normal
        }
    }

    var axisZ: SIMD3<Float> {
        switch self {
        case .box(let volume): volume.axisZ
        case .polygonalPrism(let prism): prism.axisV
        }
    }

    func coordinates(of point: SIMD3<Float>) -> SIMD3<Float> {
        let offset = point - referenceOrigin
        return SIMD3(
            simd_dot(offset, axisX),
            simd_dot(offset, axisY),
            simd_dot(offset, axisZ)
        )
    }

    func worldPoint(horizontal: SIMD2<Float>, height: Float) -> SIMD3<Float> {
        referenceOrigin
            + axisX * horizontal.x
            + axisY * height
            + axisZ * horizontal.y
    }

    /// World-axis-aligned box enclosing the region.
    var worldBounds: (lower: SIMD3<Float>, upper: SIMD3<Float>) {
        var corners: [SIMD3<Float>] = []
        switch self {
        case .box(let volume):
            for x in [-volume.halfExtents.x, volume.halfExtents.x] {
                for y in [-volume.halfExtents.y, volume.halfExtents.y] {
                    for z in [-volume.halfExtents.z, volume.halfExtents.z] {
                        corners.append(
                            volume.centre + volume.axisX * x + volume.axisY * y + volume.axisZ * z
                        )
                    }
                }
            }
        case .polygonalPrism(let prism):
            for vertex in prism.polygon {
                for offset in [prism.lowerOffset, prism.upperOffset] {
                    corners.append(worldPoint(horizontal: vertex, height: offset))
                }
            }
        }
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in corners {
            lower = simd_min(lower, corner)
            upper = simd_max(upper, corner)
        }
        return (lower, upper)
    }
}
