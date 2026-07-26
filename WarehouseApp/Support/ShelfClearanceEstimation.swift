import Foundation
import simd

struct ShelfClearanceConfiguration: Equatable {
    /// Rays start this far above the surface, skipping shelf-lip contact noise.
    var minimumClearanceM: Float = 0.05
    /// Longest upward search; beyond this the shelf is treated as open-topped.
    var maximumSearchLengthM: Float = 2.5
    /// Fraction of rays that must hit before an obstruction is trusted.
    var minimumHitFraction: Double = 0.3
    /// Robust low percentile of hit heights used as the clearance.
    var clearancePercentile: Double = 0.05
    /// Horizontal inset from the mapped outline before sampling, so rays
    /// don't graze shelf uprights at the polygon edge.
    var footprintInsetM: Float = 0.02
    /// Approximate number of upward rays across the footprint.
    var targetSampleCount: Int = 16

    static let shelf = ShelfClearanceConfiguration()
}

struct ShelfClearanceEstimate: Equatable {
    let freeHeightCM: Double
    /// 0...1 — how many rays found the obstruction.
    let hitFraction: Double
}

enum ShelfClearanceEstimator {
    /// Grid of XZ sample points inside the tapped outline (plane-local space).
    static func samplePoints(
        insidePolygon polygon: [SIMD2<Float>],
        configuration: ShelfClearanceConfiguration = .shelf
    ) -> [SIMD2<Float>] {
        guard polygon.count >= 3 else { return [] }
        let xValues = polygon.map(\.x)
        let yValues = polygon.map(\.y)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max(),
              maxX - minX > configuration.footprintInsetM * 2,
              maxY - minY > configuration.footprintInsetM * 2
        else { return [] }

        let side = max(1, Int(Double(configuration.targetSampleCount).squareRoot().rounded(.up)))
        let cellWidth = (maxX - minX) / Float(side)
        let cellHeight = (maxY - minY) / Float(side)

        var points: [SIMD2<Float>] = []
        for row in 0..<side {
            for column in 0..<side {
                let candidate = SIMD2<Float>(
                    minX + (Float(column) + 0.5) * cellWidth,
                    minY + (Float(row) + 0.5) * cellHeight
                )
                if contains(polygon: polygon, point: candidate),
                   distanceToEdges(of: polygon, from: candidate) >= configuration.footprintInsetM {
                    points.append(candidate)
                }
            }
        }
        return points
    }

    /// Reduces per-ray heights above the surface (metres; nil = no hit within
    /// the search length) to one free height. Returns nil for open tops.
    static func estimate(
        hitHeightsM: [Float?],
        configuration: ShelfClearanceConfiguration = .shelf
    ) -> ShelfClearanceEstimate? {
        guard !hitHeightsM.isEmpty else { return nil }
        let validHits = hitHeightsM
            .compactMap { $0 }
            .filter { $0 >= configuration.minimumClearanceM }
            .sorted()
        let hitFraction = Double(validHits.count) / Double(hitHeightsM.count)
        guard hitFraction >= configuration.minimumHitFraction else { return nil }

        let clearanceM = percentile(of: validHits, configuration.clearancePercentile)
        return ShelfClearanceEstimate(
            freeHeightCM: Double(clearanceM) * 100,
            hitFraction: hitFraction
        )
    }

    /// Even-odd point-in-polygon test in plane-local XZ space.
    static func contains(polygon: [SIMD2<Float>], point: SIMD2<Float>) -> Bool {
        var isInside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let crossingX = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if point.x < crossingX {
                    isInside.toggle()
                }
            }
            previous = index
        }
        return isInside
    }

    private static func distanceToEdges(
        of polygon: [SIMD2<Float>],
        from point: SIMD2<Float>
    ) -> Float {
        var shortest = Float.greatestFiniteMagnitude
        var previous = polygon.count - 1
        for index in polygon.indices {
            let start = polygon[previous]
            let end = polygon[index]
            let segment = end - start
            let lengthSquared = simd_length_squared(segment)
            let projection = lengthSquared > 0
                ? simd_clamp(simd_dot(point - start, segment) / lengthSquared, 0, 1)
                : 0
            shortest = min(shortest, simd_distance(point, start + projection * segment))
            previous = index
        }
        return shortest
    }

    private static func percentile(of sortedValues: [Float], _ fraction: Double) -> Float {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = fraction * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(lowerIndex + 1, sortedValues.count - 1)
        let weight = Float(position - Double(lowerIndex))
        return sortedValues[lowerIndex] * (1 - weight) + sortedValues[upperIndex] * weight
    }
}
