import Foundation
import simd

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
    }

    func contains(_ point: SIMD3<Float>, margin: Float = 0) -> Bool {
        let local = coordinates(of: point)
        return local.y >= lowerOffset - margin
            && local.y <= upperOffset + margin
            && Self.pointInPolygon(SIMD2(local.x, local.z), polygon: polygon, margin: margin)
    }

    func isNearBoundary(_ point: SIMD3<Float>, distance: Float) -> Bool {
        let local = coordinates(of: point)
        let horizontal = SIMD2(local.x, local.z)
        let nearSide = polygon.indices.contains {
            Self.distance(
                from: horizontal,
                toSegmentFrom: polygon[$0],
                to: polygon[($0 + 1) % polygon.count]
            ) <= distance
        }
        return nearSide
            || abs(local.y - upperOffset) <= distance
    }

    func coordinates(of point: SIMD3<Float>) -> SIMD3<Float> {
        let offset = point - origin
        return SIMD3(
            simd_dot(offset, axisU),
            simd_dot(offset, normal),
            simd_dot(offset, axisV)
        )
    }

    private static func pointInPolygon(
        _ point: SIMD2<Float>,
        polygon: [SIMD2<Float>],
        margin: Float
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        if polygon.indices.contains(where: {
            distance(
                from: point,
                toSegmentFrom: polygon[$0],
                to: polygon[($0 + 1) % polygon.count]
            ) <= margin
        }) {
            return true
        }
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
        return inside
    }

    private static func distance(
        from point: SIMD2<Float>,
        toSegmentFrom start: SIMD2<Float>,
        to end: SIMD2<Float>
    ) -> Float {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0 else { return simd_distance(point, start) }
        let t = min(max(simd_dot(point - start, segment) / lengthSquared, 0), 1)
        return simd_distance(point, start + segment * t)
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

    func isNearBoundary(_ point: SIMD3<Float>, distance: Float) -> Bool {
        switch self {
        case .box(let volume):
            guard volume.contains(point, margin: distance) else { return false }
            let offset = point - volume.centre
            return abs(abs(simd_dot(offset, volume.axisX)) - volume.halfExtents.x) <= distance
                || abs(abs(simd_dot(offset, volume.axisY)) - volume.halfExtents.y) <= distance
                || abs(abs(simd_dot(offset, volume.axisZ)) - volume.halfExtents.z) <= distance
        case .polygonalPrism(let prism):
            return prism.isNearBoundary(point, distance: distance)
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
}

struct LiDARFusionIntegrationResult: Equatable {
    let acceptedPointCount: Int
    let rejectedOutsideVolumeCount: Int
    let nearBoundaryCount: Int
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
}

/// Central configuration for object isolation and measurement. Distances are
/// metres. Defaults target hand-sized products, not rooms or furniture.
struct LiDARFusionConfiguration: Equatable {
    /// Spatial fusion resolution; smaller values improve detail but need more samples.
    var voxelSize: Float = 0.003
    /// A voxel must be seen in this many distinct frames.
    var minimumFrameObservations = 3
    /// Minimum accepted frames and segmented voxels required before finishing.
    var minimumFusedFrameCount = 20
    var minimumStableVoxelCount = 120
    /// Small allowance at the locked crop boundary for LiDAR quantization.
    var cropMargin: Float = 0.003
    /// Product points this close to an ROI face trigger a possible-cropping warning.
    var boundaryWarningDistance: Float = 0.006
    /// Removes noisy returns immediately above the support while retaining its height.
    var supportPlaneNoiseBand: Float = 0.006
    /// Vertical histogram resolution used for horizontal support-plane detection.
    var supportPlaneBinSize: Float = 0.003
    /// Region-growing reach in voxels; 2 bridges ordinary 3 mm LiDAR gaps.
    var connectivityRadiusInVoxels = 2
    /// The selected seed must be reasonably close to retained target geometry.
    var maximumSeedDistance: Float = 0.08
    /// Robust oriented-bound percentiles.
    var lowerPercentile = 0.01
    var upperPercentile = 0.99
    /// Live estimates must agree this many times before becoming stable.
    var stableEstimateCount = 3
    /// A dimension increase beyond this is frozen as likely nearby geometry.
    var dimensionJumpThreshold = 0.25
    /// Estimates in a candidate series may vary by this fraction.
    var estimateConsistencyTolerance = 0.08

    static let smallObject = LiDARFusionConfiguration()
}

/// Quantizes registered world points into voxels, rejects points outside one
/// locked selection, keeps temporally repeated geometry, removes the support
/// plane, grows from the user's seed, and measures an oriented footprint.
final class LiDARVoxelFusionEngine {
    private struct VoxelKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private struct Voxel {
        var positionSum: SIMD3<Float>
        var frameObservations: Int
    }

    let configuration: LiDARFusionConfiguration
    private var selection: (region: LiDARSpatialRegion, seed: SIMD3<Float>)?
    private var voxels: [VoxelKey: Voxel] = [:]

    init(configuration: LiDARFusionConfiguration = .smallObject) {
        self.configuration = configuration
    }

    var voxelCount: Int { voxels.count }

    func lockSelection(volume: LiDARScanVolume, seed: SIMD3<Float>) {
        lockSelection(region: .box(volume), seed: seed)
    }

    func lockSelection(region: LiDARSpatialRegion, seed: SIMD3<Float>) {
        selection = (region, seed)
        voxels.removeAll(keepingCapacity: true)
    }

    func reset() {
        selection = nil
        voxels.removeAll(keepingCapacity: true)
    }

    /// Adds at most one averaged observation per voxel for each camera frame.
    /// The locked volume is enforced here, before a point can enter fusion.
    @discardableResult
    func integrate(framePoints: [SIMD3<Float>]) -> LiDARFusionIntegrationResult {
        guard let selection else {
            return LiDARFusionIntegrationResult(
                acceptedPointCount: 0,
                rejectedOutsideVolumeCount: framePoints.count,
                nearBoundaryCount: 0
            )
        }

        var sums: [VoxelKey: SIMD3<Float>] = [:]
        var counts: [VoxelKey: Int] = [:]
        var rejected = 0
        var nearBoundary = 0
        sums.reserveCapacity(framePoints.count)

        for point in framePoints where point.x.isFinite && point.y.isFinite && point.z.isFinite {
            guard selection.region.contains(point, margin: configuration.cropMargin) else {
                rejected += 1
                continue
            }
            if selection.region.isNearBoundary(
                point,
                distance: configuration.boundaryWarningDistance
            ) {
                nearBoundary += 1
            }
            let key = voxelKey(for: point)
            sums[key, default: .zero] += point
            counts[key, default: 0] += 1
        }

        for (key, sum) in sums {
            guard let count = counts[key], count > 0 else { continue }
            let frameAverage = sum / Float(count)
            if var voxel = voxels[key] {
                voxel.positionSum += frameAverage
                voxel.frameObservations += 1
                voxels[key] = voxel
            } else {
                voxels[key] = Voxel(positionSum: frameAverage, frameObservations: 1)
            }
        }

        return LiDARFusionIntegrationResult(
            acceptedPointCount: counts.count,
            rejectedOutsideVolumeCount: rejected,
            nearBoundaryCount: nearBoundary
        )
    }

    func measurement() -> LiDARFusionMeasurement? {
        guard let selection else { return nil }
        let stable = voxels.filter {
            $0.value.frameObservations >= configuration.minimumFrameObservations
        }
        guard stable.count >= configuration.minimumStableVoxelCount else { return nil }

        let stablePoints = stable.mapValues {
            $0.positionSum / Float($0.frameObservations)
        }
        let localCoordinates = stablePoints.mapValues {
            selection.region.coordinates(of: $0)
        }
        guard let supportCoordinate = detectSupportPlane(
            in: localCoordinates.values.map(\.y)
        ) else {
            return nil
        }

        // The support itself is removed, but supportY remains the lower height
        // boundary so the contact-noise band does not shorten the object.
        let aboveSupport = stablePoints.filter {
            guard let local = localCoordinates[$0.key] else { return false }
            return local.y > supportCoordinate + configuration.supportPlaneNoiseBand
        }
        guard aboveSupport.count >= configuration.minimumStableVoxelCount else { return nil }

        // Tight connectivity first, so a separate object a few millimetres
        // away cannot bridge into the product; the configured (wider) radius
        // remains a fallback for sparse coverage with LiDAR holes.
        let tightRadius = min(1, configuration.connectivityRadiusInVoxels)
        var selected = selectComponent(
            in: aboveSupport,
            radius: tightRadius,
            seed: selection.seed
        )
        if selected == nil, tightRadius < configuration.connectivityRadiusInVoxels {
            selected = selectComponent(
                in: aboveSupport,
                radius: configuration.connectivityRadiusInVoxels,
                seed: selection.seed
            )
        }
        guard let component = selected else { return nil }

        let points = component.compactMap { aboveSupport[$0] }
        guard let bounds = orientedBounds(
            points: points,
            region: selection.region,
            supportCoordinate: supportCoordinate
        ) else { return nil }

        let centre = bounds.worldCentre
        // Express review points in the measured box's own basis (X = length,
        // Y = height, Z = width) so the 3D viewer's axis-aligned box outline
        // lines up with the cloud even for rotated objects.
        let lengthAxis = bounds.extentU >= bounds.extentV
            ? bounds.worldAxisU
            : bounds.worldAxisV
        let widthAxis = bounds.extentU >= bounds.extentV
            ? bounds.worldAxisV
            : bounds.worldAxisU
        let heightAxis = selection.region.axisY
        let displayStep = max(1, points.count / 4_000)
        let displayPoints = points.enumerated().compactMap { index, point -> SIMD3<Float>? in
            guard index.isMultiple(of: displayStep) else { return nil }
            let offset = point - centre
            return SIMD3<Float>(
                simd_dot(offset, lengthAxis),
                simd_dot(offset, heightAxis),
                simd_dot(offset, widthAxis)
            )
        }
        let averageObservations = component.reduce(0.0) { partial, key in
            partial + Double(stable[key]?.frameObservations ?? 0)
        } / Double(component.count)

        return LiDARFusionMeasurement(
            dimensionsCM: ObjectDimensions(
                length: Double(max(bounds.extentU, bounds.extentV)) * 100,
                width: Double(min(bounds.extentU, bounds.extentV)) * 100,
                height: Double(bounds.maximumHeight - supportCoordinate) * 100
            ),
            centredPointsInMetres: displayPoints,
            worldPointsInMetres: points,
            boundingBoxCornersWorld: bounds.corners,
            touchesRegionBoundary: points.contains {
                selection.region.isNearBoundary(
                    $0,
                    distance: configuration.boundaryWarningDistance
                )
            },
            fusedVoxelCount: component.count,
            averageObservationsPerVoxel: averageObservations,
            supportPlaneY: (
                selection.region.referenceOrigin
                    + selection.region.axisY * supportCoordinate
            ).y
        )
    }

    private func voxelKey(for point: SIMD3<Float>) -> VoxelKey {
        VoxelKey(
            x: Int32(floor(point.x / configuration.voxelSize)),
            y: Int32(floor(point.y / configuration.voxelSize)),
            z: Int32(floor(point.z / configuration.voxelSize))
        )
    }

    private func detectSupportPlane(in heights: [Float]) -> Float? {
        guard !heights.isEmpty else { return nil }
        var bins: [Int32: [Float]] = [:]
        for height in heights {
            let bin = Int32((height / configuration.supportPlaneBinSize).rounded())
            bins[bin, default: []].append(height)
        }
        let minimumPlaneSamples = max(
            24,
            Int(Double(heights.count) * 0.04)
        )
        let candidates = bins.filter { $0.value.count >= minimumPlaneSamples }
        if let lowest = candidates.min(by: { $0.key < $1.key }) {
            return lowest.value.reduce(0, +) / Float(lowest.value.count)
        }
        return percentile(heights, fraction: 0.02)
    }

    /// The qualifying component nearest the user's aim point, or nil when no
    /// sufficiently large component lies within the maximum seed distance —
    /// measuring unrelated geometry is worse than measuring nothing.
    private func selectComponent(
        in points: [VoxelKey: SIMD3<Float>],
        radius: Int,
        seed: SIMD3<Float>
    ) -> Set<VoxelKey>? {
        let components = connectedComponents(in: points, radius: radius).filter {
            $0.count >= configuration.minimumStableVoxelCount
        }
        guard let component = components.min(by: {
            componentDistanceSquared($0, points: points, seed: seed)
                < componentDistanceSquared($1, points: points, seed: seed)
        }) else { return nil }
        let distance = sqrt(
            componentDistanceSquared(component, points: points, seed: seed)
        )
        guard distance <= configuration.maximumSeedDistance else { return nil }
        return component
    }

    private func connectedComponents(
        in points: [VoxelKey: SIMD3<Float>],
        radius radiusInVoxels: Int
    ) -> [Set<VoxelKey>] {
        var unvisited = Set(points.keys)
        var components: [Set<VoxelKey>] = []
        let radius = Int32(radiusInVoxels)

        while let seed = unvisited.first {
            unvisited.remove(seed)
            var queue = [seed]
            var cursor = 0
            var component: Set<VoxelKey> = [seed]
            while cursor < queue.count {
                let key = queue[cursor]
                cursor += 1
                for dx in -radius...radius {
                    for dy in -radius...radius {
                        for dz in -radius...radius
                        where dx != 0 || dy != 0 || dz != 0 {
                            let neighbour = VoxelKey(
                                x: key.x + dx,
                                y: key.y + dy,
                                z: key.z + dz
                            )
                            if unvisited.remove(neighbour) != nil {
                                component.insert(neighbour)
                                queue.append(neighbour)
                            }
                        }
                    }
                }
            }
            components.append(component)
        }
        return components
    }

    private func componentDistanceSquared(
        _ component: Set<VoxelKey>,
        points: [VoxelKey: SIMD3<Float>],
        seed: SIMD3<Float>
    ) -> Float {
        component.reduce(.greatestFiniteMagnitude) { distance, key in
            guard let point = points[key] else { return distance }
            return min(distance, simd_distance_squared(point, seed))
        }
    }

    private func orientedBounds(
        points: [SIMD3<Float>],
        region: LiDARSpatialRegion,
        supportCoordinate: Float
    ) -> (
        extentU: Float,
        extentV: Float,
        maximumHeight: Float,
        worldCentre: SIMD3<Float>,
        corners: [SIMD3<Float>],
        worldAxisU: SIMD3<Float>,
        worldAxisV: SIMD3<Float>
    )? {
        guard points.count >= 3 else { return nil }
        let local = points.map { region.coordinates(of: $0) }
        let meanX = local.reduce(0) { $0 + $1.x } / Float(local.count)
        let meanZ = local.reduce(0) { $0 + $1.z } / Float(local.count)

        var xx: Float = 0
        var zz: Float = 0
        var xz: Float = 0
        for point in local {
            let x = point.x - meanX
            let z = point.z - meanZ
            xx += x * x
            zz += z * z
            xz += x * z
        }

        let angle = 0.5 * atan2(2 * xz, xx - zz)
        let axisU = SIMD2<Float>(cos(angle), sin(angle))
        let axisV = SIMD2<Float>(-sin(angle), cos(angle))
        let horizontal = local.map { SIMD2<Float>($0.x - meanX, $0.z - meanZ) }
        let u = horizontal.map { simd_dot($0, axisU) }
        let v = horizontal.map { simd_dot($0, axisV) }
        let heights = local.map(\.y)

        guard let lowU = percentile(u, fraction: configuration.lowerPercentile),
              let highU = percentile(u, fraction: configuration.upperPercentile),
              let lowV = percentile(v, fraction: configuration.lowerPercentile),
              let highV = percentile(v, fraction: configuration.upperPercentile),
              let maximumHeight = percentile(
                heights,
                fraction: configuration.upperPercentile
              ),
              maximumHeight > supportCoordinate
        else { return nil }

        let localCentre = axisU * ((lowU + highU) / 2)
            + axisV * ((lowV + highV) / 2)
        let horizontalCentre = SIMD2<Float>(meanX, meanZ) + localCentre
        let verticalCentre = (supportCoordinate + maximumHeight) / 2
        let worldCentre = worldPoint(
            horizontal: horizontalCentre,
            height: verticalCentre,
            region: region
        )
        let localAxisU = axisU
        let localAxisV = axisV
        let rectangleCentre = horizontalCentre
        let halfU = (highU - lowU + configuration.voxelSize) / 2
        let halfV = (highV - lowV + configuration.voxelSize) / 2
        let adjustedMaximumHeight = maximumHeight + configuration.voxelSize / 2
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for height in [supportCoordinate, adjustedMaximumHeight] {
            let horizontalCorners: [SIMD2<Float>] = [
                rectangleCentre - localAxisU * halfU - localAxisV * halfV,
                rectangleCentre + localAxisU * halfU - localAxisV * halfV,
                rectangleCentre + localAxisU * halfU + localAxisV * halfV,
                rectangleCentre - localAxisU * halfU + localAxisV * halfV
            ]
            for horizontalCorner in horizontalCorners {
                corners.append(
                    worldPoint(
                        horizontal: horizontalCorner,
                        height: height,
                        region: region
                    )
                )
            }
        }
        return (
            extentU: highU - lowU + configuration.voxelSize,
            extentV: highV - lowV + configuration.voxelSize,
            maximumHeight: adjustedMaximumHeight,
            worldCentre: worldCentre,
            corners: corners,
            worldAxisU: region.axisX * axisU.x + region.axisZ * axisU.y,
            worldAxisV: region.axisX * axisV.x + region.axisZ * axisV.y
        )
    }

    private func worldPoint(
        horizontal: SIMD2<Float>,
        height: Float,
        region: LiDARSpatialRegion
    ) -> SIMD3<Float> {
        region.referenceOrigin
            + region.axisX * horizontal.x
            + region.axisY * height
            + region.axisZ * horizontal.y
    }

    private func percentile(_ values: [Float], fraction: Double) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sorted[lower] }
        let weight = Float(position - Double(lower))
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

enum LiDARMeasurementDecision: Equatable {
    case warmingUp
    case accepted(ObjectDimensions)
    case frozen(ObjectDimensions, message: String)
}

/// Prevents one changed estimate from replacing the most recent stable result.
struct LiDARMeasurementStabilizer {
    private let configuration: LiDARFusionConfiguration
    private(set) var stable: ObjectDimensions?
    private var candidate: ObjectDimensions?
    private var candidateCount = 0

    init(configuration: LiDARFusionConfiguration = .smallObject) {
        self.configuration = configuration
    }

    mutating func reset() {
        stable = nil
        candidate = nil
        candidateCount = 0
    }

    mutating func consider(_ estimate: ObjectDimensions) -> LiDARMeasurementDecision {
        if let candidate, dimensionsAreConsistent(candidate, estimate) {
            candidateCount += 1
            self.candidate = averaged(candidate, estimate, count: candidateCount)
        } else {
            candidate = estimate
            candidateCount = 1
        }

        guard let stable else {
            if candidateCount >= configuration.stableEstimateCount, let candidate {
                self.stable = candidate
                return .accepted(candidate)
            }
            return .warmingUp
        }

        if dimensionsAreConsistent(stable, estimate) {
            candidate = nil
            candidateCount = 0
            return .accepted(stable)
        }

        let isJump = zip(estimate.values, stable.values).contains {
            $1 > 0 && ($0 - $1) / $1 > configuration.dimensionJumpThreshold
        }
        if candidateCount >= configuration.stableEstimateCount, let candidate {
            self.stable = candidate
            self.candidate = nil
            candidateCount = 0
            return .accepted(candidate)
        }

        let message = isJump
            ? "Possible nearby object detected. Keep other objects outside the scan box."
            : "Measurement changed. Hold the scan steady while it is verified."
        return .frozen(stable, message: message)
    }

    private func dimensionsAreConsistent(
        _ lhs: ObjectDimensions,
        _ rhs: ObjectDimensions
    ) -> Bool {
        zip(lhs.values, rhs.values).allSatisfy {
            let scale = max(max(abs($0), abs($1)), 0.001)
            return abs($0 - $1) / scale <= configuration.estimateConsistencyTolerance
        }
    }

    private func averaged(
        _ accumulated: ObjectDimensions,
        _ newValue: ObjectDimensions,
        count: Int
    ) -> ObjectDimensions {
        let previousWeight = Double(count - 1)
        return ObjectDimensions(
            length: (accumulated.length * previousWeight + newValue.length) / Double(count),
            width: (accumulated.width * previousWeight + newValue.width) / Double(count),
            height: (accumulated.height * previousWeight + newValue.height) / Double(count)
        )
    }
}
