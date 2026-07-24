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

struct LiDARFusionIntegrationResult: Equatable {
    let acceptedPointCount: Int
    let rejectedOutsideVolumeCount: Int
}

struct LiDARFusionMeasurement: Equatable {
    let dimensionsCM: ObjectDimensions
    let centredPointsInMetres: [SIMD3<Float>]
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
    private var selection: (volume: LiDARScanVolume, seed: SIMD3<Float>)?
    private var voxels: [VoxelKey: Voxel] = [:]

    init(configuration: LiDARFusionConfiguration = .smallObject) {
        self.configuration = configuration
    }

    var voxelCount: Int { voxels.count }

    func lockSelection(volume: LiDARScanVolume, seed: SIMD3<Float>) {
        selection = (volume, seed)
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
                rejectedOutsideVolumeCount: framePoints.count
            )
        }

        var sums: [VoxelKey: SIMD3<Float>] = [:]
        var counts: [VoxelKey: Int] = [:]
        var rejected = 0
        sums.reserveCapacity(framePoints.count)

        for point in framePoints where point.x.isFinite && point.y.isFinite && point.z.isFinite {
            guard selection.volume.contains(point, margin: configuration.cropMargin) else {
                rejected += 1
                continue
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
            rejectedOutsideVolumeCount: rejected
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
        guard let supportY = detectSupportPlane(in: Array(stablePoints.values)) else {
            return nil
        }

        // The support itself is removed, but supportY remains the lower height
        // boundary so the contact-noise band does not shorten the object.
        let aboveSupport = stablePoints.filter {
            $0.value.y > supportY + configuration.supportPlaneNoiseBand
        }
        guard aboveSupport.count >= configuration.minimumStableVoxelCount else { return nil }

        guard let seedKey = aboveSupport.min(by: {
            simd_distance_squared($0.value, selection.seed)
                < simd_distance_squared($1.value, selection.seed)
        })?.key,
        let seedPoint = aboveSupport[seedKey],
        simd_distance(seedPoint, selection.seed) <= configuration.maximumSeedDistance
        else { return nil }

        let component = connectedComponent(from: seedKey, in: aboveSupport)
        guard component.count >= configuration.minimumStableVoxelCount else { return nil }

        let points = component.compactMap { aboveSupport[$0] }
        guard let bounds = orientedBounds(points: points, supportY: supportY) else { return nil }

        let centre = SIMD3<Float>(
            bounds.worldCentre.x,
            (supportY + bounds.maximumY) / 2,
            bounds.worldCentre.y
        )
        let displayStep = max(1, points.count / 4_000)
        let displayPoints = points.enumerated().compactMap { index, point in
            index.isMultiple(of: displayStep) ? point - centre : nil
        }
        let averageObservations = component.reduce(0.0) { partial, key in
            partial + Double(stable[key]?.frameObservations ?? 0)
        } / Double(component.count)

        return LiDARFusionMeasurement(
            dimensionsCM: ObjectDimensions(
                length: Double(max(bounds.extentU, bounds.extentV)) * 100,
                width: Double(min(bounds.extentU, bounds.extentV)) * 100,
                height: Double(bounds.maximumY - supportY) * 100
            ),
            centredPointsInMetres: displayPoints,
            fusedVoxelCount: component.count,
            averageObservationsPerVoxel: averageObservations,
            supportPlaneY: supportY
        )
    }

    private func voxelKey(for point: SIMD3<Float>) -> VoxelKey {
        VoxelKey(
            x: Int32(floor(point.x / configuration.voxelSize)),
            y: Int32(floor(point.y / configuration.voxelSize)),
            z: Int32(floor(point.z / configuration.voxelSize))
        )
    }

    private func detectSupportPlane(in points: [SIMD3<Float>]) -> Float? {
        guard !points.isEmpty else { return nil }
        var bins: [Int32: [Float]] = [:]
        for point in points {
            let bin = Int32((point.y / configuration.supportPlaneBinSize).rounded())
            bins[bin, default: []].append(point.y)
        }
        let minimumPlaneSamples = max(
            24,
            Int(Double(points.count) * 0.04)
        )
        let candidates = bins.filter { $0.value.count >= minimumPlaneSamples }
        if let lowest = candidates.min(by: { $0.key < $1.key }) {
            return lowest.value.reduce(0, +) / Float(lowest.value.count)
        }
        return percentile(points.map(\.y), fraction: 0.02)
    }

    private func connectedComponent(
        from seed: VoxelKey,
        in points: [VoxelKey: SIMD3<Float>]
    ) -> Set<VoxelKey> {
        var unvisited = Set(points.keys)
        guard unvisited.remove(seed) != nil else { return [] }
        var queue = [seed]
        var cursor = 0
        var component: Set<VoxelKey> = [seed]
        let radius = Int32(configuration.connectivityRadiusInVoxels)

        while cursor < queue.count {
            let key = queue[cursor]
            cursor += 1
            for dx in -radius...radius {
                for dy in -radius...radius {
                    for dz in -radius...radius where dx != 0 || dy != 0 || dz != 0 {
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
        return component
    }

    private func orientedBounds(
        points: [SIMD3<Float>],
        supportY: Float
    ) -> (
        extentU: Float,
        extentV: Float,
        maximumY: Float,
        worldCentre: SIMD2<Float>
    )? {
        guard points.count >= 3 else { return nil }
        let meanX = points.reduce(0) { $0 + $1.x } / Float(points.count)
        let meanZ = points.reduce(0) { $0 + $1.z } / Float(points.count)

        var xx: Float = 0
        var zz: Float = 0
        var xz: Float = 0
        for point in points {
            let x = point.x - meanX
            let z = point.z - meanZ
            xx += x * x
            zz += z * z
            xz += x * z
        }

        let angle = 0.5 * atan2(2 * xz, xx - zz)
        let axisU = SIMD2<Float>(cos(angle), sin(angle))
        let axisV = SIMD2<Float>(-sin(angle), cos(angle))
        let horizontal = points.map { SIMD2<Float>($0.x - meanX, $0.z - meanZ) }
        let u = horizontal.map { simd_dot($0, axisU) }
        let v = horizontal.map { simd_dot($0, axisV) }
        let y = points.map(\.y)

        guard let lowU = percentile(u, fraction: configuration.lowerPercentile),
              let highU = percentile(u, fraction: configuration.upperPercentile),
              let lowV = percentile(v, fraction: configuration.lowerPercentile),
              let highV = percentile(v, fraction: configuration.upperPercentile),
              let maximumY = percentile(y, fraction: configuration.upperPercentile),
              maximumY > supportY
        else { return nil }

        let localCentre = axisU * ((lowU + highU) / 2)
            + axisV * ((lowV + highV) / 2)
        return (
            extentU: highU - lowU + configuration.voxelSize,
            extentV: highV - lowV + configuration.voxelSize,
            maximumY: maximumY + configuration.voxelSize / 2,
            worldCentre: SIMD2<Float>(meanX, meanZ) + localCentre
        )
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
