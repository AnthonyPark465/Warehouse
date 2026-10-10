import Foundation
import simd

enum ManualMeasurementGeometryError: LocalizedError, Equatable {
    case tooFewPoints
    case duplicatePoints
    case zeroArea
    case selfIntersection
    case notCoplanar(maximumDeviationCM: Double)
    case invalidHeight
    case invalidWorldUp
    case topBelowBase
    case pointOutsideFootprint(name: String)

    var errorDescription: String? {
        switch self {
        case .tooFewPoints:
            "Place at least three boundary points."
        case .duplicatePoints:
            "Two boundary points are too close. Undo and place the point on a different corner."
        case .zeroArea:
            "The boundary has no measurable area. Replace points that lie on the same line."
        case .selfIntersection:
            "Boundary edges cross each other. Undo or replace the highlighted point."
        case .notCoplanar(let deviation):
            "Boundary points are not on the same base level (maximum deviation \(deviation.formatted(.number.precision(.fractionLength(1)))) cm)."
        case .invalidHeight:
            "The measured height is below 1 mm or greater than 25 m. Replace the top point."
        case .invalidWorldUp:
            "The AR session did not provide a valid gravity-aligned up direction. Restart measurement."
        case .topBelowBase:
            "The top point is below the fitted base plane. Replace it from above the product."
        case .pointOutsideFootprint(let name):
            "The \(name) point is far outside the base boundary. Replace it while aiming at the product."
        }
    }
}

struct FittedMeasurementPlane: Equatable {
    let origin: SIMD3<Double>
    let normal: SIMD3<Double>
    let axisU: SIMD3<Double>
    let axisV: SIMD3<Double>
    let maximumDeviation: Double

    func project(_ point: SIMD3<Double>) -> SIMD2<Double> {
        let offset = point - origin
        return SIMD2(simd_dot(offset, axisU), simd_dot(offset, axisV))
    }

    func signedDistance(to point: SIMD3<Double>) -> Double {
        simd_dot(point - origin, normal)
    }
}

struct OrientedFootprint: Equatable {
    let lengthMetres: Double
    let widthMetres: Double
    let areaSquareMetres: Double
    let perimeterMetres: Double
    let orientationRadians: Double
    let rectangle2D: [SIMD2<Double>]
}

struct BoundaryMeasurement: Equatable {
    let plane: FittedMeasurementPlane
    let projectedBoundary: [SIMD2<Double>]
    let footprint: OrientedFootprint
}

enum ManualMeasurementGeometry {
    /// Keeps accidental double-taps distinct without imposing a practical
    /// minimum product footprint.
    static let minimumPointSpacingMetres = 0.001
    /// Real tabletop taps scatter more than the old 2 cm limit allowed. Up to
    /// 3.5 cm is accepted; scatter past `planeDeviationPenaltyStartMetres`
    /// lowers confidence instead of hard-rejecting the boundary (D11).
    static let maximumPlaneDeviationMetres = 0.035
    /// Below this deviation the confidence penalty matches the historical
    /// behaviour; the 2–3.5 cm band adds an extra penalty.
    static let planeDeviationPenaltyStartMetres = 0.02
    /// Slack for bottom/top limit markers relative to the fitted base plane.
    /// Named so `height()` and bottom-marker placement stay at the same 3 cm
    /// even though the boundary-fit tolerance above was relaxed (D2/D6).
    static let limitMarkerPlaneSlackMetres = 0.03
    static let minimumHeightMetres = 0.001
    static let maximumHeightMetres = 25.0
    /// ARKit world tracking with `.gravity` alignment uses +Y as world up.
    static let arKitWorldUp = SIMD3<Double>(0, 1, 0)

    static func measureBoundary(_ worldPoints: [SIMD3<Float>]) throws -> BoundaryMeasurement {
        guard worldPoints.count >= 3 else {
            throw ManualMeasurementGeometryError.tooFewPoints
        }
        let points = worldPoints.map(SIMD3<Double>.init)
        for first in points.indices {
            for second in points.indices where second > first {
                if simd_distance(points[first], points[second]) < minimumPointSpacingMetres {
                    throw ManualMeasurementGeometryError.duplicatePoints
                }
            }
        }

        let plane = try fitPlane(to: points)
        guard plane.maximumDeviation <= maximumPlaneDeviationMetres else {
            throw ManualMeasurementGeometryError.notCoplanar(
                maximumDeviationCM: plane.maximumDeviation * 100
            )
        }
        var polygon = points.map(plane.project)
        if hasSelfIntersection(polygon) {
            // Corners tapped in Z/diagonal order still describe one footprint;
            // retry in angular order around the centroid before rejecting (D10).
            let reordered = angularBoundaryOrder(polygon).map { polygon[$0] }
            guard !hasSelfIntersection(reordered) else {
                throw ManualMeasurementGeometryError.selfIntersection
            }
            polygon = reordered
        }
        let signedArea = polygonArea(polygon)
        guard abs(signedArea) > 0.000_000_1 else {
            throw ManualMeasurementGeometryError.zeroArea
        }

        let perimeter = polygon.indices.reduce(0.0) { result, index in
            result + simd_distance(polygon[index], polygon[(index + 1) % polygon.count])
        }
        let hull = convexHull(polygon)
        guard let rectangle = minimumAreaRectangle(for: hull) else {
            throw ManualMeasurementGeometryError.zeroArea
        }
        // Do not impose warehouse-size limits on a valid boundary. AR points
        // still have to produce finite, nonzero geometry.
        guard rectangle.lengthMetres.isFinite,
              rectangle.widthMetres.isFinite,
              rectangle.lengthMetres > 0,
              rectangle.widthMetres > 0
        else {
            throw ManualMeasurementGeometryError.zeroArea
        }
        return BoundaryMeasurement(
            plane: plane,
            projectedBoundary: polygon,
            footprint: OrientedFootprint(
                lengthMetres: rectangle.lengthMetres,
                widthMetres: rectangle.widthMetres,
                areaSquareMetres: abs(signedArea),
                perimeterMetres: perimeter,
                orientationRadians: rectangle.orientationRadians,
                rectangle2D: rectangle.rectangle2D
            )
        )
    }

    static func height(
        top: SIMD3<Float>,
        bottom: SIMD3<Float>,
        boundary: BoundaryMeasurement,
        worldUp: SIMD3<Double> = arKitWorldUp
    ) throws -> Double {
        let top3 = SIMD3<Double>(top)
        let bottom3 = SIMD3<Double>(bottom)
        let worldUpLength = simd_length(worldUp)
        guard worldUpLength.isFinite, worldUpLength > 0 else {
            throw ManualMeasurementGeometryError.invalidWorldUp
        }
        let normalizedWorldUp = worldUp / worldUpLength
        let signedHeight = simd_dot(top3 - bottom3, normalizedWorldUp)
        let measuredHeight = abs(signedHeight)
        let lowerPoint = signedHeight >= 0 ? bottom3 : top3
        let upperPoint = signedHeight >= 0 ? top3 : bottom3

        guard boundary.plane.signedDistance(to: upperPoint) >= -0.005 else {
            throw ManualMeasurementGeometryError.topBelowBase
        }
        guard measuredHeight >= minimumHeightMetres,
              measuredHeight <= maximumHeightMetres
        else {
            throw ManualMeasurementGeometryError.invalidHeight
        }
        guard abs(boundary.plane.signedDistance(to: lowerPoint))
                <= limitMarkerPlaneSlackMetres
        else {
            throw ManualMeasurementGeometryError.pointOutsideFootprint(name: "bottom")
        }
        let margin = max(boundary.footprint.lengthMetres, boundary.footprint.widthMetres) * 0.25
        guard point(boundary.plane.project(lowerPoint), near: boundary.projectedBoundary, margin: margin) else {
            throw ManualMeasurementGeometryError.pointOutsideFootprint(name: "bottom")
        }
        guard point(boundary.plane.project(upperPoint), near: boundary.projectedBoundary, margin: margin) else {
            throw ManualMeasurementGeometryError.pointOutsideFootprint(name: "top")
        }
        return measuredHeight
    }

    /// Bottom/top limit markers must sit on the fitted base plane (within the
    /// 3 cm slack) and inside the boundary footprint plus a 25% margin, the
    /// same rules `height()` enforces after the fact (D2/D6).
    static func limitMarkerIsOnBase(
        _ worldPoint: SIMD3<Float>,
        boundary: BoundaryMeasurement
    ) -> Bool {
        let point3 = SIMD3<Double>(worldPoint)
        guard abs(boundary.plane.signedDistance(to: point3))
                <= limitMarkerPlaneSlackMetres
        else { return false }
        let margin = max(
            boundary.footprint.lengthMetres,
            boundary.footprint.widthMetres
        ) * 0.25
        return point(
            boundary.plane.project(point3),
            near: boundary.projectedBoundary,
            margin: margin
        )
    }

    /// Vertex order sorted by angle around the centroid. Taps made in a
    /// Z/diagonal pattern come back as a simple polygon in this order.
    static func angularBoundaryOrder(_ polygon: [SIMD2<Double>]) -> [Int] {
        guard polygon.count >= 3 else { return Array(polygon.indices) }
        let centroid = polygon.reduce(.zero, +) / Double(polygon.count)
        return polygon.indices.sorted {
            atan2(polygon[$0].y - centroid.y, polygon[$0].x - centroid.x)
                < atan2(polygon[$1].y - centroid.y, polygon[$1].x - centroid.x)
        }
    }

    /// Non-nil when the tapped marker order self-intersects but the angular
    /// order does not: the permutation that repairs the boundary. Callers
    /// apply it to their marker storage so the rendered outline and the scan
    /// prism match the measured footprint (D10).
    static func repairedBoundaryOrder(_ worldPoints: [SIMD3<Float>]) -> [Int]? {
        guard worldPoints.count >= 3 else { return nil }
        let points = worldPoints.map(SIMD3<Double>.init)
        guard let plane = try? fitPlane(to: points) else { return nil }
        let polygon = points.map(plane.project)
        guard hasSelfIntersection(polygon) else { return nil }
        let order = angularBoundaryOrder(polygon)
        let reordered = order.map { polygon[$0] }
        return hasSelfIntersection(reordered) ? nil : order
    }

    /// A point guaranteed to lie inside the polygon: the area centroid when
    /// it is interior, otherwise the centroid of the largest ear-clipped
    /// triangle, which is interior by construction. The vertex centroid can
    /// fall outside a concave footprint and mis-seed region growing (D12).
    static func interiorSeedPoint(for polygon: [SIMD2<Double>]) -> SIMD2<Double>? {
        guard polygon.count >= 3 else { return nil }
        let area = polygonArea(polygon)
        if abs(area) > 1e-9 {
            var centroid = SIMD2<Double>.zero
            for index in polygon.indices {
                let current = polygon[index]
                let next = polygon[(index + 1) % polygon.count]
                centroid += (current + next)
                    * (current.x * next.y - next.x * current.y)
            }
            centroid /= 6 * area
            if pointInPolygon(centroid, polygon: polygon) { return centroid }
        }
        let indices = triangulationIndices(for: polygon)
        var best: (area: Double, centroid: SIMD2<Double>)?
        for start in stride(from: 0, to: indices.count, by: 3) {
            let a = polygon[Int(indices[start])]
            let b = polygon[Int(indices[start + 1])]
            let c = polygon[Int(indices[start + 2])]
            let triangleArea = abs(cross(b - a, c - a)) / 2
            if best == nil || triangleArea > best!.area {
                best = (triangleArea, (a + b + c) / 3)
            }
        }
        return best?.centroid
            ?? polygon.reduce(.zero, +) / Double(polygon.count)
    }

    /// Reuses the fusion prism's even-odd/edge test rather than duplicating a
    /// second point-in-polygon implementation.
    static func pointInPolygon(
        _ point: SIMD2<Double>,
        polygon: [SIMD2<Double>]
    ) -> Bool {
        LiDARPolygonalPrism.pointInPolygon(
            SIMD2<Float>(Float(point.x), Float(point.y)),
            polygon: polygon.map { SIMD2<Float>(Float($0.x), Float($0.y)) },
            margin: 0
        )
    }

    /// Fits a least-squares plane. The normal is the eigenvector associated
    /// with the smallest eigenvalue of the points' covariance matrix.
    static func fitPlane(to points: [SIMD3<Double>]) throws -> FittedMeasurementPlane {
        guard points.count >= 3 else { throw ManualMeasurementGeometryError.tooFewPoints }
        let origin = points.reduce(.zero, +) / Double(points.count)
        var matrix = simd_double3x3()
        for point in points {
            let offset = point - origin
            matrix += simd_double3x3(rows: [
                offset.x * offset,
                offset.y * offset,
                offset.z * offset
            ])
        }
        matrix.columns.0 /= Double(points.count)
        matrix.columns.1 /= Double(points.count)
        matrix.columns.2 /= Double(points.count)
        // Inverse iteration converges on the covariance eigenvector with the
        // smallest eigenvalue (the least-squares plane normal). A very small
        // diagonal regularizer keeps exactly planar data invertible.
        let regularizer = 1e-10
        matrix.columns.0.x += regularizer
        matrix.columns.1.y += regularizer
        matrix.columns.2.z += regularizer
        let inverse = matrix.inverse
        var normal = simd_normalize(SIMD3<Double>(0.37, 0.71, 0.53))
        for _ in 0..<16 {
            normal = simd_normalize(inverse * normal)
        }
        guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else {
            throw ManualMeasurementGeometryError.zeroArea
        }
        // Keep the normal generally upward for predictable signed height.
        if normal.y < 0 { normal = -normal }
        let reference = abs(normal.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let axisU = simd_normalize(simd_cross(reference, normal))
        let axisV = simd_normalize(simd_cross(normal, axisU))
        let deviation = points.map { abs(simd_dot($0 - origin, normal)) }.max() ?? 0
        return FittedMeasurementPlane(
            origin: origin,
            normal: normal,
            axisU: axisU,
            axisV: axisV,
            maximumDeviation: deviation
        )
    }

    static func polygonArea(_ points: [SIMD2<Double>]) -> Double {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(0) { sum, index in
            let next = points[(index + 1) % points.count]
            return sum + points[index].x * next.y - next.x * points[index].y
        } / 2
    }

    static func hasSelfIntersection(_ points: [SIMD2<Double>]) -> Bool {
        guard points.count >= 4 else { return false }
        for first in points.indices {
            let firstNext = (first + 1) % points.count
            for second in points.indices {
                let secondNext = (second + 1) % points.count
                if first == second || firstNext == second || secondNext == first { continue }
                if segmentsIntersect(points[first], points[firstNext], points[second], points[secondNext]) {
                    return true
                }
            }
        }
        return false
    }

    /// A point guaranteed to lie inside a simple polygon: its area centroid
    /// when that is interior, otherwise the centroid of its largest
    /// triangle. The vertex mean of a concave outline can fall outside it.
    static func interiorPoint(of polygon: [SIMD2<Double>]) -> SIMD2<Double>? {
        guard polygon.count >= 3 else { return nil }
        let signedArea = polygonArea(polygon)
        if abs(signedArea) > 1e-12 {
            var centroid = SIMD2<Double>.zero
            for index in polygon.indices {
                let current = polygon[index]
                let next = polygon[(index + 1) % polygon.count]
                centroid += (current + next) * cross(current, next)
            }
            centroid /= 6 * signedArea
            if contains(centroid, in: polygon) { return centroid }
        }
        let indices = triangulationIndices(for: polygon)
        var best: (area: Double, centre: SIMD2<Double>)?
        for start in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = polygon[Int(indices[start])]
            let b = polygon[Int(indices[start + 1])]
            let c = polygon[Int(indices[start + 2])]
            let area = abs(cross(b - a, c - a)) / 2
            if best == nil || area > best!.area {
                best = (area, (a + b + c) / 3)
            }
        }
        return best?.centre
    }

    /// Even-odd point-in-polygon test.
    static func contains(_ point: SIMD2<Double>, in polygon: [SIMD2<Double>]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    /// Ear-clipping triangulation preserves concave footprint boundaries, so
    /// the translucent AR fill never extends outside the user's polygon.
    static func triangulationIndices(for polygon: [SIMD2<Double>]) -> [UInt32] {
        guard polygon.count >= 3 else { return [] }
        var remaining = Array(polygon.indices)
        if polygonArea(polygon) < 0 { remaining.reverse() }
        var triangles: [UInt32] = []
        var attempts = 0
        while remaining.count > 3, attempts < polygon.count * polygon.count {
            var clipped = false
            for position in remaining.indices {
                let previous = remaining[(position - 1 + remaining.count) % remaining.count]
                let current = remaining[position]
                let next = remaining[(position + 1) % remaining.count]
                guard cross(polygon[current] - polygon[previous], polygon[next] - polygon[current]) > 1e-12 else {
                    continue
                }
                let containsPoint = remaining.contains { candidate in
                    guard candidate != previous, candidate != current, candidate != next else { return false }
                    return pointInTriangle(
                        polygon[candidate],
                        polygon[previous],
                        polygon[current],
                        polygon[next]
                    )
                }
                guard !containsPoint else { continue }
                triangles += [UInt32(previous), UInt32(current), UInt32(next)]
                remaining.remove(at: position)
                clipped = true
                break
            }
            if !clipped { break }
            attempts += 1
        }
        if remaining.count == 3 {
            triangles += remaining.map(UInt32.init)
        }
        return triangles
    }

    private static func segmentsIntersect(
        _ a: SIMD2<Double>,
        _ b: SIMD2<Double>,
        _ c: SIMD2<Double>,
        _ d: SIMD2<Double>
    ) -> Bool {
        let abC = cross(b - a, c - a)
        let abD = cross(b - a, d - a)
        let cdA = cross(d - c, a - c)
        let cdB = cross(d - c, b - c)
        return abC * abD < -1e-10 && cdA * cdB < -1e-10
    }

    private static func cross(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>) -> Double {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    private static func pointInTriangle(
        _ point: SIMD2<Double>,
        _ a: SIMD2<Double>,
        _ b: SIMD2<Double>,
        _ c: SIMD2<Double>
    ) -> Bool {
        let first = cross(b - a, point - a)
        let second = cross(c - b, point - b)
        let third = cross(a - c, point - c)
        return first >= -1e-12 && second >= -1e-12 && third >= -1e-12
    }

    private static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        var lower: [SIMD2<Double>] = []
        for point in sorted {
            while lower.count >= 2,
                  cross(
                    lower[lower.count - 1] - lower[lower.count - 2],
                    point - lower[lower.count - 1]
                  ) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [SIMD2<Double>] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                  cross(
                    upper[upper.count - 1] - upper[upper.count - 2],
                    point - upper[upper.count - 1]
                  ) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Rotating-calipers equivalent: evaluate the hull bounding box at every
    /// hull-edge angle and retain the rectangle with the smallest area.
    private static func minimumAreaRectangle(
        for hull: [SIMD2<Double>]
    ) -> (lengthMetres: Double, widthMetres: Double, orientationRadians: Double, rectangle2D: [SIMD2<Double>])? {
        guard hull.count >= 3 else { return nil }
        var best: (
            area: Double,
            length: Double,
            width: Double,
            orientation: Double,
            corners: [SIMD2<Double>]
        )?
        for index in hull.indices {
            let edge = hull[(index + 1) % hull.count] - hull[index]
            let angle = atan2(edge.y, edge.x)
            let cosine = cos(angle)
            let sine = sin(angle)
            let rotated = hull.map {
                SIMD2($0.x * cosine + $0.y * sine, -$0.x * sine + $0.y * cosine)
            }
            let minX = rotated.map(\.x).min()!
            let maxX = rotated.map(\.x).max()!
            let minY = rotated.map(\.y).min()!
            let maxY = rotated.map(\.y).max()!
            let sizeX = maxX - minX
            let sizeY = maxY - minY
            let area = sizeX * sizeY
            if best == nil || area < best!.area {
                let corners = [
                    SIMD2(minX, minY), SIMD2(maxX, minY),
                    SIMD2(maxX, maxY), SIMD2(minX, maxY)
                ].map {
                    SIMD2($0.x * cosine - $0.y * sine, $0.x * sine + $0.y * cosine)
                }
                let length = max(sizeX, sizeY)
                let width = min(sizeX, sizeY)
                let orientation = sizeX >= sizeY ? angle : angle + .pi / 2
                best = (area, length, width, orientation, corners)
            }
        }
        guard let best else { return nil }
        return (best.length, best.width, best.orientation, best.corners)
    }

    private static func point(
        _ point: SIMD2<Double>,
        near polygon: [SIMD2<Double>],
        margin: Double
    ) -> Bool {
        guard let minX = polygon.map(\.x).min(), let maxX = polygon.map(\.x).max(),
              let minY = polygon.map(\.y).min(), let maxY = polygon.map(\.y).max()
        else { return false }
        return point.x >= minX - margin && point.x <= maxX + margin
            && point.y >= minY - margin && point.y <= maxY + margin
    }

}
