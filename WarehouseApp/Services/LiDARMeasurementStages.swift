import Foundation
import simd

// Pure, order-independent stages of the object-measurement pipeline. Every
// stage takes plain values and returns a result struct, so each can be tested
// and inspected in isolation. Inputs are sorted by voxel key before they get
// here; no stage iterates a Dictionary or Set to produce output.

struct LiDARVoxelKey: Hashable, Comparable {
    let x: Int32
    let y: Int32
    let z: Int32

    static func < (lhs: LiDARVoxelKey, rhs: LiDARVoxelKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }

    func offset(by delta: (Int32, Int32, Int32)) -> LiDARVoxelKey {
        LiDARVoxelKey(x: x &+ delta.0, y: y &+ delta.1, z: z &+ delta.2)
    }

    static func containing(_ point: SIMD3<Float>, cellSize: Float) -> LiDARVoxelKey {
        LiDARVoxelKey(
            x: Int32(floor(point.x / cellSize)),
            y: Int32(floor(point.y / cellSize)),
            z: Int32(floor(point.z / cellSize))
        )
    }
}

/// Lookup from voxel key to position in an array of voxels. Component
/// selection asks for every neighbour of every voxel on each analysis; a
/// flat table with a cheap integer hash answers several times faster than
/// `Dictionary`, whose keyed hashing dominated that stage.
struct LiDARVoxelIndex {
    private var keys: [LiDARVoxelKey]
    /// Array index for the key in the same slot; -1 marks an empty slot.
    private var indices: [Int32]
    private let mask: Int

    init(_ voxels: [LiDARStableVoxel]) {
        var capacity = 16
        while capacity < voxels.count * 2 { capacity <<= 1 }
        mask = capacity - 1
        keys = [LiDARVoxelKey](repeating: LiDARVoxelKey(x: 0, y: 0, z: 0), count: capacity)
        indices = [Int32](repeating: -1, count: capacity)
        for (index, voxel) in voxels.enumerated() {
            var slot = Self.slot(for: voxel.key, mask: mask)
            while indices[slot] >= 0, keys[slot] != voxel.key { slot = (slot + 1) & mask }
            keys[slot] = voxel.key
            indices[slot] = Int32(index)
        }
    }

    subscript(key: LiDARVoxelKey) -> Int? {
        var slot = Self.slot(for: key, mask: mask)
        while indices[slot] >= 0 {
            if keys[slot] == key { return Int(indices[slot]) }
            slot = (slot + 1) & mask
        }
        return nil
    }

    private static func slot(for key: LiDARVoxelKey, mask: Int) -> Int {
        var hash = UInt64(UInt32(bitPattern: key.x)) &* 0x9E37_79B9_7F4A_7C15
        hash ^= UInt64(UInt32(bitPattern: key.y)) &* 0xC2B2_AE3D_27D4_EB4F
        hash ^= UInt64(UInt32(bitPattern: key.z)) &* 0x1656_67B1_9E37_79F9
        hash ^= hash >> 29
        return Int(truncatingIfNeeded: hash) & mask
    }
}

/// A voxel that passed temporal filtering.
struct LiDARStableVoxel: Equatable {
    let key: LiDARVoxelKey
    /// Mean observed world position.
    let position: SIMD3<Float>
    /// Position in region coordinates: x/z horizontal, y along the height axis.
    let local: SIMD3<Float>
    let observations: Int
}

enum LiDARStatistics {
    static func percentile(sorted: [Float], fraction: Double) -> Float? {
        guard !sorted.isEmpty else { return nil }
        let position = Double(sorted.count - 1) * min(max(fraction, 0), 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = Float(position - Double(lower))
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// First index whose value is not less than `value`.
    static func lowerBound(_ sorted: [Float], _ value: Float) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// First index whose value is greater than `value`.
    static func upperBound(_ sorted: [Float], _ value: Float) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

// MARK: - Support-plane estimation

struct LiDARSupportPlaneEstimate: Equatable {
    enum Method: String {
        case histogramPeak
        case percentileFallback
    }

    /// Height of the supporting surface along the region's vertical axis.
    /// This value, not the lowest retained product point, is the lower
    /// boundary of the measured height.
    let coordinate: Float
    let method: Method
    let inlierCount: Int
    /// Robust noise of the plane, estimated from samples below it only so
    /// product points standing on the plane cannot inflate it.
    let residual: Float?
    /// Thickness removed above `coordinate`.
    let removalBand: Float
    let removalBandWasCapped: Bool

    var removalThreshold: Float { coordinate + removalBand }
}

enum LiDARSupportPlaneEstimator {
    static func estimate(
        heights: [Float],
        configuration: LiDARFusionConfiguration
    ) -> LiDARSupportPlaneEstimate? {
        guard !heights.isEmpty else { return nil }
        let sorted = heights.sorted()
        let binSize = configuration.supportPlaneBinSize
        var counts: [Int32: Int] = [:]
        for height in sorted {
            counts[Int32((height / binSize).rounded()), default: 0] += 1
        }
        let minimumSamples = max(
            configuration.supportPlaneMinimumSamples,
            Int(Double(sorted.count) * configuration.supportPlaneMinimumFraction)
        )
        guard var peak = counts.filter({ $0.value >= minimumSamples }).keys.min() else {
            guard let fallback = LiDARStatistics.percentile(
                sorted: sorted,
                fraction: configuration.supportPlaneFallbackPercentile
            ) else { return nil }
            return LiDARSupportPlaneEstimate(
                coordinate: fallback,
                method: .percentileFallback,
                inlierCount: 0,
                residual: nil,
                removalBand: configuration.supportPlaneNoiseBand,
                removalBandWasCapped: false
            )
        }

        // The lowest populated bin is the lower noise tail of the plane.
        // Using it directly places the support too low and inflates height.
        for _ in 0..<configuration.supportPlanePeakClimbBins {
            guard let current = counts[peak],
                  let next = counts[peak + 1],
                  next > current
            else { break }
            peak += 1
        }

        var coordinate = Float(peak) * binSize
        let window = binSize * 1.5
        var inlierCount = 0
        for _ in 0..<2 {
            let low = LiDARStatistics.lowerBound(sorted, coordinate - window)
            let high = LiDARStatistics.upperBound(sorted, coordinate + window)
            guard high > low else { break }
            inlierCount = high - low
            let middle = low + (high - low) / 2
            coordinate = (high - low).isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2
                : sorted[middle]
        }

        let belowLow = LiDARStatistics.lowerBound(
            sorted,
            coordinate - configuration.maximumSupportPlaneNoiseBand
        )
        let belowHigh = LiDARStatistics.upperBound(sorted, coordinate)
        var residual: Float = 0
        if belowHigh > belowLow {
            var sum: Float = 0
            for index in belowLow..<belowHigh {
                let deviation = sorted[index] - coordinate
                sum += deviation * deviation
            }
            residual = (sum / Float(belowHigh - belowLow)).squareRoot()
        }

        let wantedBand = max(
            configuration.supportPlaneNoiseBand,
            configuration.supportPlaneNoiseSigmaMultiplier * residual
        )
        return LiDARSupportPlaneEstimate(
            coordinate: coordinate,
            method: .histogramPeak,
            inlierCount: inlierCount,
            residual: residual,
            removalBand: min(wantedBand, configuration.maximumSupportPlaneNoiseBand),
            removalBandWasCapped: wantedBand > configuration.maximumSupportPlaneNoiseBand
        )
    }
}

// MARK: - Component selection

struct LiDARComponentSelection: Equatable {
    enum Mode: String {
        case strict
        case expanded
    }

    enum FallbackReason: String {
        /// No strictly connected component near the seed reached object size.
        case noQualifyingStrictComponent
    }

    /// Indices into the input array, ascending.
    var selectedIndices: [Int] = []
    var mode = Mode.strict
    var fallbackReason: FallbackReason?
    var failure: LiDARMeasurementReasonCode?
    var selected: LiDARComponentStatistics?
    var absorbedFragmentCount = 0
    var absorbedVoxelCount = 0
    var rejectedComponentCount = 0
    var rejectedVoxelCount = 0
    var rejected: [LiDARComponentStatistics] = []
    var nearbyObjectDetected = false
    /// Voxels in loose fragments within bridging reach of the selected
    /// strict component and of nothing else. They are never absorbed.
    var looseFragmentVoxelCount = 0
    var significantFragmentsExcluded = false
    /// Voxel pairs within bridging reach left unjoined because the space
    /// between them was observed to be empty.
    var freeSpaceBlockedBridgeCount = 0
    /// Voxels in rejected fragment groups (below object size, above a noise
    /// speck) within the proximity-warning distance of the selection.
    var nearbyFragmentVoxelCount = 0
    /// The selection exists only as bridged fragments, and comparably many
    /// more fragments lie just beyond bridging reach of it: it is a piece
    /// of a larger surface, not an object.
    var selectionLooksPartial = false
}

/// Isolates the object nearest the seed.
///
/// 1. Strict pass: 26-neighbour connected components ("units").
/// 2. Units that reach object size on their own are never merged with
///    anything else. Smaller units ("fragments") are grouped with each other
///    at the expanded radius, and each group records which object-sized units
///    it touches.
/// 3. The candidate nearest the seed wins: an object-sized unit, or a
///    fragment group that reaches object size only when bridged.
/// 4. Expanded connectivity is used, and recorded, only when the winner is a
///    bridged group. An object-sized strict unit is never extended; loose
///    fragments beside it are reported, not absorbed.
/// 5. A bridged winner with a large share of unbridged fragments close
///    beside it is flagged as partial: the reach joined a few pieces of a
///    patchy surface and left the rest out.
///
/// When `isObservedEmpty` is supplied, step 2 does not bridge two voxels if
/// any voxel on the line between them was observed to be empty: a hole in a
/// scanned surface has no ray through it, a gap between two objects does.
enum LiDARComponentSelector {
    private struct Candidate {
        var units: [Int]
        var voxelCount: Int
        var seedDistanceSquared: Float
        var isStrictUnit: Bool
        var touchedUnits: Set<Int>

        var firstUnit: Int { units[0] }
    }

    static func select(
        voxels: [LiDARStableVoxel],
        seed: SIMD3<Float>,
        configuration: LiDARFusionConfiguration,
        isObservedEmpty: ((LiDARVoxelKey) -> Bool)? = nil
    ) -> LiDARComponentSelection {
        var result = LiDARComponentSelection()
        guard !voxels.isEmpty else {
            result.failure = .insufficientConnectedGeometry
            return result
        }

        let indexByKey = LiDARVoxelIndex(voxels)

        // 1. Strict units, numbered by their lowest voxel key.
        let strictRadius = max(1, configuration.strictConnectivityRadiusInVoxels)
        let strictOffsets = offsets(outerRadius: strictRadius, innerRadius: 0)
        var unitOf = [Int](repeating: -1, count: voxels.count)
        var units: [[Int]] = []
        for start in voxels.indices where unitOf[start] < 0 {
            let unit = units.count
            var members = [start]
            unitOf[start] = unit
            var cursor = 0
            while cursor < members.count {
                let key = voxels[members[cursor]].key
                cursor += 1
                for delta in strictOffsets {
                    if let neighbour = indexByKey[key.offset(by: delta)],
                       unitOf[neighbour] < 0 {
                        unitOf[neighbour] = unit
                        members.append(neighbour)
                    }
                }
            }
            units.append(members)
        }

        let minimum = configuration.minimumStableVoxelCount
        let qualifies = units.map { $0.count >= minimum }
        // Units that are never bridged. With conditional connectivity off
        // (ablation), nothing is frozen and one radius applies to everything.
        let frozen = qualifies.map { $0 && configuration.connectivityIsConditional }
        let unitSeedDistanceSquared = units.map { members in
            members.reduce(Float.greatestFiniteMagnitude) {
                min($0, simd_distance_squared(voxels[$1].position, seed))
            }
        }

        // 2. Bridge fragments at the expanded radius. Object-sized units are
        // never unioned; a fragment only records that it touches them.
        var parent = Array(units.indices)
        func root(_ unit: Int) -> Int {
            var current = unit
            while parent[current] != current { current = parent[current] }
            return current
        }
        var touched = [Set<Int>](repeating: [], count: units.count)
        let expandedRadius = max(strictRadius, configuration.connectivityRadiusInVoxels)
        if expandedRadius > strictRadius {
            let reachSquared = Int32(expandedRadius * expandedRadius)
            let bridges = offsets(outerRadius: expandedRadius, innerRadius: strictRadius)
                .filter { $0.0 * $0.0 + $0.1 * $0.1 + $0.2 * $0.2 <= reachSquared }
                .map { (delta: $0, between: voxelsBetween($0)) }
            for index in voxels.indices where !frozen[unitOf[index]] {
                let unit = unitOf[index]
                let key = voxels[index].key
                for bridge in bridges {
                    guard let neighbour = indexByKey[key.offset(by: bridge.delta)] else { continue }
                    let other = unitOf[neighbour]
                    guard other != unit else { continue }
                    if let isObservedEmpty,
                       bridge.between.contains(where: { isObservedEmpty(key.offset(by: $0)) }) {
                        result.freeSpaceBlockedBridgeCount += 1
                        continue
                    }
                    if frozen[other] {
                        touched[unit].insert(other)
                    } else {
                        let a = root(unit)
                        let b = root(other)
                        if a != b { parent[max(a, b)] = min(a, b) }
                    }
                }
            }
        }

        // 3. Candidates in deterministic unit order.
        var candidates: [Candidate] = []
        var groupIndexByRoot: [Int: Int] = [:]
        for unit in units.indices {
            if frozen[unit] {
                candidates.append(Candidate(
                    units: [unit],
                    voxelCount: units[unit].count,
                    seedDistanceSquared: unitSeedDistanceSquared[unit],
                    isStrictUnit: true,
                    touchedUnits: []
                ))
                continue
            }
            let groupRoot = root(unit)
            if let existing = groupIndexByRoot[groupRoot] {
                candidates[existing].units.append(unit)
                candidates[existing].voxelCount += units[unit].count
                candidates[existing].seedDistanceSquared = min(
                    candidates[existing].seedDistanceSquared,
                    unitSeedDistanceSquared[unit]
                )
                candidates[existing].touchedUnits.formUnion(touched[unit])
            } else {
                groupIndexByRoot[groupRoot] = candidates.count
                candidates.append(Candidate(
                    units: [unit],
                    voxelCount: units[unit].count,
                    seedDistanceSquared: unitSeedDistanceSquared[unit],
                    isStrictUnit: false,
                    touchedUnits: touched[unit]
                ))
            }
        }

        let objectSized = candidates.indices.filter { candidates[$0].voxelCount >= minimum }
        guard !objectSized.isEmpty else {
            result.failure = .insufficientConnectedGeometry
            result.rejectedComponentCount = candidates.count
            result.rejectedVoxelCount = voxels.count
            return result
        }
        let maximumSeedDistanceSquared =
            configuration.maximumSeedDistance * configuration.maximumSeedDistance
        let reachable = objectSized.filter {
            candidates[$0].seedDistanceSquared <= maximumSeedDistanceSquared
        }
        guard let winner = reachable.min(by: { lhs, rhs in
            let a = candidates[lhs]
            let b = candidates[rhs]
            if a.seedDistanceSquared != b.seedDistanceSquared {
                return a.seedDistanceSquared < b.seedDistanceSquared
            }
            if a.isStrictUnit != b.isStrictUnit { return a.isStrictUnit }
            if a.voxelCount != b.voxelCount { return a.voxelCount > b.voxelCount }
            return a.firstUnit < b.firstUnit
        }) else {
            // Measuring unrelated geometry is worse than measuring nothing.
            result.failure = .noObjectNearSeed
            result.rejectedComponentCount = candidates.count
            result.rejectedVoxelCount = voxels.count
            return result
        }

        // 4. An object-sized strict unit is taken as it is: strict
        // segmentation recovered sufficient geometry, so nothing is bridged
        // onto it. Only a winner that exists solely as bridged fragments
        // uses, and records, expanded connectivity.
        let selectedCandidates: Set<Int> = [winner]
        var ownFragments: Set<Int> = []
        if candidates[winner].isStrictUnit {
            let anchor = candidates[winner].firstUnit
            ownFragments = Set(candidates.indices.filter {
                !candidates[$0].isStrictUnit && candidates[$0].touchedUnits == [anchor]
            })
            let looseVoxels = ownFragments.reduce(0) { $0 + candidates[$1].voxelCount }
            let total = candidates[winner].voxelCount + looseVoxels
            result.looseFragmentVoxelCount = looseVoxels
            result.significantFragmentsExcluded = looseVoxels > 0
                && Double(looseVoxels)
                >= configuration.fragmentationWarningFraction * Double(total)
        } else if candidates[winner].units.count > 1 {
            result.mode = .expanded
            result.fallbackReason = .noQualifyingStrictComponent
            result.absorbedFragmentCount = candidates[winner].units.count
            result.absorbedVoxelCount = candidates[winner].voxelCount
        }

        var selectedIndices: [Int] = []
        for candidate in selectedCandidates.sorted() {
            for unit in candidates[candidate].units {
                selectedIndices.append(contentsOf: units[unit])
            }
        }
        selectedIndices.sort()
        result.selectedIndices = selectedIndices
        result.selected = LiDARComponentStatistics(
            voxelCount: selectedIndices.count,
            seedDistanceMetres: Double(
                selectedCandidates.reduce(Float.greatestFiniteMagnitude) {
                    min($0, candidates[$1].seedDistanceSquared)
                }.squareRoot()
            ),
            gapToSelectedMetres: nil,
            qualifiesAsObject: true
        )

        // 5. Describe what was rejected, and how close it came.
        let proximity = configuration.neighbourProximityWarningDistance
        var selectedCells: [LiDARVoxelKey: [Int]] = [:]
        for index in selectedIndices {
            selectedCells[
                .containing(voxels[index].position, cellSize: proximity),
                default: []
            ].append(index)
        }
        let cellOffsets = offsets(outerRadius: 1, innerRadius: -1)
        func gap(of candidate: Candidate) -> Float? {
            var best = proximity * proximity
            var found = false
            for unit in candidate.units {
                for index in units[unit] {
                    let position = voxels[index].position
                    let cell = LiDARVoxelKey.containing(position, cellSize: proximity)
                    for delta in cellOffsets {
                        guard let members = selectedCells[cell.offset(by: delta)] else { continue }
                        for member in members {
                            let distance = simd_distance_squared(
                                position,
                                voxels[member].position
                            )
                            if distance <= best {
                                best = distance
                                found = true
                            }
                        }
                    }
                }
            }
            return found ? best.squareRoot() : nil
        }

        var described: [(statistics: LiDARComponentStatistics, order: Int)] = []
        for index in candidates.indices where !selectedCandidates.contains(index) {
            let candidate = candidates[index]
            result.rejectedComponentCount += 1
            result.rejectedVoxelCount += candidate.voxelCount
            guard candidate.voxelCount >= configuration.minimumReportedComponentVoxelCount
            else { continue }
            let gapMetres = gap(of: candidate)
            if gapMetres != nil, !ownFragments.contains(index) {
                result.nearbyObjectDetected = true
            }
            if gapMetres != nil, candidate.voxelCount < minimum {
                result.nearbyFragmentVoxelCount += candidate.voxelCount
            }
            described.append((
                LiDARComponentStatistics(
                    voxelCount: candidate.voxelCount,
                    seedDistanceMetres: Double(candidate.seedDistanceSquared.squareRoot()),
                    gapToSelectedMetres: gapMetres.map(Double.init),
                    qualifiesAsObject: candidate.voxelCount >= minimum
                ),
                index
            ))
        }
        described.sort { lhs, rhs in
            let a = lhs.statistics.gapToSelectedMetres ?? .greatestFiniteMagnitude
            let b = rhs.statistics.gapToSelectedMetres ?? .greatestFiniteMagnitude
            if a != b { return a < b }
            if lhs.statistics.voxelCount != rhs.statistics.voxelCount {
                return lhs.statistics.voxelCount > rhs.statistics.voxelCount
            }
            return lhs.order < rhs.order
        }
        result.rejected = described
            .prefix(configuration.maximumReportedRejectedComponents)
            .map(\.statistics)
        result.selectionLooksPartial = result.mode == .expanded
            && Double(result.nearbyFragmentVoxelCount)
            >= configuration.partialSelectionFragmentFraction
            * Double(selectedIndices.count + result.nearbyFragmentVoxelCount)
        return result
    }

    /// Offsets of every voxel the straight line between the centres of a
    /// voxel and the one at `delta` passes through, excluding both ends.
    /// Exact integer arithmetic, so the line from B to A crosses the same
    /// voxels as the line from A to B. A line through an edge or corner
    /// enters the voxel diagonally opposite; those it only touches are not
    /// counted.
    static func voxelsBetween(
        _ delta: (Int32, Int32, Int32)
    ) -> [(Int32, Int32, Int32)] {
        let distance = [abs(Int(delta.0)), abs(Int(delta.1)), abs(Int(delta.2))]
        let step = [Int(delta.0).signum(), Int(delta.1).signum(), Int(delta.2).signum()]
        // Along axis a the line crosses its k-th boundary at parameter
        // (2k + 1) / (2 · distance[a]); compared here as cross-multiplied
        // integers.
        var crossed = [0, 0, 0]
        var position = [0, 0, 0]
        var cells: [(Int32, Int32, Int32)] = []
        let total = distance[0] + distance[1] + distance[2]
        while crossed[0] + crossed[1] + crossed[2] < total {
            var first: [Int] = []
            for axis in 0..<3 where crossed[axis] < distance[axis] {
                guard let leader = first.first else {
                    first = [axis]
                    continue
                }
                let candidate = (2 * crossed[axis] + 1) * distance[leader]
                let current = (2 * crossed[leader] + 1) * distance[axis]
                if candidate < current {
                    first = [axis]
                } else if candidate == current {
                    first.append(axis)
                }
            }
            for axis in first {
                crossed[axis] += 1
                position[axis] += step[axis]
            }
            cells.append((Int32(position[0]), Int32(position[1]), Int32(position[2])))
        }
        // The last cell reached is the far end itself.
        return Array(cells.dropLast())
    }

    /// Offsets with Chebyshev distance in `(innerRadius, outerRadius]`.
    private static func offsets(
        outerRadius: Int,
        innerRadius: Int
    ) -> [(Int32, Int32, Int32)] {
        let outer = Int32(outerRadius)
        let inner = Int32(innerRadius)
        var result: [(Int32, Int32, Int32)] = []
        for dx in -outer...outer {
            for dy in -outer...outer {
                for dz in -outer...outer
                where max(abs(dx), max(abs(dy), abs(dz))) > inner {
                    result.append((dx, dy, dz))
                }
            }
        }
        return result
    }
}

// MARK: - Bounds estimation

struct LiDARBoundsEstimate: Equatable {
    /// Footprint axes in the region's horizontal plane.
    let axisU: SIMD2<Float>
    let axisV: SIMD2<Float>
    let yawRadians: Float
    /// Percentile-trimmed bounds along each axis.
    let lowU: Float
    let highU: Float
    let lowV: Float
    let highV: Float
    let trimmedTop: Float
    /// Untrimmed bounds along each axis.
    let fullLowU: Float
    let fullHighU: Float
    let fullLowV: Float
    let fullHighV: Float
    let fullTop: Float
    /// Lower height boundary: the support-plane coordinate.
    let supportCoordinate: Float
    let compensation: Float

    var extentU: Float { highU - lowU + compensation }
    var extentV: Float { highV - lowV + compensation }
    var top: Float { trimmedTop + compensation / 2 }
    var height: Float { top - supportCoordinate }
    var uIsLength: Bool { extentU >= extentV }

    private func dimensions(u: Float, v: Float, height: Float) -> ObjectDimensions {
        ObjectDimensions(
            length: Double(max(u, v)) * 100,
            width: Double(min(u, v)) * 100,
            height: Double(height) * 100
        )
    }

    var measuredDimensionsCM: ObjectDimensions {
        dimensions(u: extentU, v: extentV, height: height)
    }

    var trimmedExtentsCM: ObjectDimensions {
        dimensions(u: highU - lowU, v: highV - lowV, height: trimmedTop - supportCoordinate)
    }

    var fullExtentsCM: ObjectDimensions {
        dimensions(
            u: fullHighU - fullLowU,
            v: fullHighV - fullLowV,
            height: fullTop - supportCoordinate
        )
    }
}

/// Finds the yaw whose robust 2D bounds have the smallest area. PCA weights by
/// point density, so an unevenly scanned face would pull its principal axis
/// away from the product's edges; an area search does not.
enum LiDARBoundsEstimator {
    private struct AxisBounds {
        var low: Float
        var high: Float
        var fullLow: Float
        var fullHigh: Float
    }

    private struct Candidate {
        var angle: Float
        var area: Float
        var u: AxisBounds
        var v: AxisBounds
    }

    /// `local` must be in a deterministic order (ascending voxel key).
    static func estimate(
        local: [SIMD3<Float>],
        supportCoordinate: Float,
        configuration: LiDARFusionConfiguration
    ) -> LiDARBoundsEstimate? {
        guard local.count >= 3 else { return nil }
        let horizontal = local.map { SIMD2<Float>($0.x, $0.z) }
        let heights = local.map { $0.y }.sorted()
        guard let trimmedTop = LiDARStatistics.percentile(
            sorted: heights,
            fraction: configuration.upperPercentile
        ),
            let fullTop = heights.last,
            trimmedTop > supportCoordinate
        else { return nil }

        // The yaw search does not need every voxel; the extents below do.
        let searchPoints: [SIMD2<Float>]
        if horizontal.count > configuration.orientationSearchPointLimit {
            let stride = max(1, horizontal.count / configuration.orientationSearchPointLimit)
            searchPoints = horizontal.enumerated().compactMap {
                $0.offset.isMultiple(of: stride) ? $0.element : nil
            }
        } else {
            searchPoints = horizontal
        }

        let quarterTurn = Float.pi / 2
        let coarseStep = configuration.orientationCoarseStepDegrees * .pi / 180
        let fineStep = configuration.orientationFineStepDegrees * .pi / 180
        guard coarseStep > 0, fineStep > 0 else { return nil }
        let improvement = 1 - configuration.orientationTieTolerance

        var best: Candidate?
        let coarseCount = max(1, Int((quarterTurn / coarseStep).rounded()))
        for index in 0..<coarseCount {
            guard let current = candidate(
                at: Float(index) * coarseStep,
                points: searchPoints,
                configuration: configuration
            ) else { continue }
            if best == nil || current.area < best!.area * improvement { best = current }
        }
        guard let coarseBest = best else { return nil }

        // A rectangle's yaw repeats every quarter turn.
        let fineCount = max(1, Int((coarseStep / fineStep).rounded()))
        for offset in -fineCount...fineCount where offset != 0 {
            var angle = coarseBest.angle + Float(offset) * fineStep
            while angle < 0 { angle += quarterTurn }
            while angle >= quarterTurn { angle -= quarterTurn }
            guard let current = candidate(
                at: angle,
                points: searchPoints,
                configuration: configuration
            ) else { continue }
            if current.area < best!.area * improvement { best = current }
        }
        guard let searchBest = best,
              let final = candidate(
                at: searchBest.angle,
                points: horizontal,
                configuration: configuration
              )
        else { return nil }

        return LiDARBoundsEstimate(
            axisU: SIMD2<Float>(cos(final.angle), sin(final.angle)),
            axisV: SIMD2<Float>(-sin(final.angle), cos(final.angle)),
            yawRadians: final.angle,
            lowU: final.u.low,
            highU: final.u.high,
            lowV: final.v.low,
            highV: final.v.high,
            trimmedTop: trimmedTop,
            fullLowU: final.u.fullLow,
            fullHighU: final.u.fullHigh,
            fullLowV: final.v.fullLow,
            fullHighV: final.v.fullHigh,
            fullTop: fullTop,
            supportCoordinate: supportCoordinate,
            compensation: configuration.extentQuantizationCompensation
        )
    }

    private static func candidate(
        at angle: Float,
        points: [SIMD2<Float>],
        configuration: LiDARFusionConfiguration
    ) -> Candidate? {
        let axisU = SIMD2<Float>(cos(angle), sin(angle))
        let axisV = SIMD2<Float>(-sin(angle), cos(angle))
        var u = [Float](repeating: 0, count: points.count)
        var v = [Float](repeating: 0, count: points.count)
        for index in points.indices {
            u[index] = simd_dot(points[index], axisU)
            v[index] = simd_dot(points[index], axisV)
        }
        u.sort()
        v.sort()
        guard let uBounds = bounds(sorted: u, configuration: configuration),
              let vBounds = bounds(sorted: v, configuration: configuration)
        else { return nil }
        let area = (uBounds.high - uBounds.low) * (vBounds.high - vBounds.low)
        guard area.isFinite, area > 0 else { return nil }
        return Candidate(angle: angle, area: area, u: uBounds, v: vBounds)
    }

    private static func bounds(
        sorted: [Float],
        configuration: LiDARFusionConfiguration
    ) -> AxisBounds? {
        guard let low = LiDARStatistics.percentile(
            sorted: sorted,
            fraction: configuration.lowerPercentile
        ),
            let high = LiDARStatistics.percentile(
                sorted: sorted,
                fraction: configuration.upperPercentile
            ),
            let fullLow = sorted.first,
            let fullHigh = sorted.last
        else { return nil }
        return AxisBounds(low: low, high: high, fullLow: fullLow, fullHigh: fullHigh)
    }
}

// MARK: - Coverage

struct LiDARSurfaceCoverage: Equatable {
    /// Occupied fraction of each footprint side: low U, high U, low V, high V.
    let sideSupportFractions: [Double]
    let topCoverageFraction: Double

    func sparseSides(minimumFraction: Double) -> [Int] {
        sideSupportFractions.indices.filter { sideSupportFractions[$0] < minimumFraction }
    }
}

/// Measures how well the selected points support each face that defines a
/// dimension. A dimension bounded by a side with almost no points on it is
/// defined by one edge, not a surface.
enum LiDARCoverageAnalyzer {
    static func surfaceCoverage(
        local: [SIMD3<Float>],
        bounds: LiDARBoundsEstimate,
        configuration: LiDARFusionConfiguration
    ) -> LiDARSurfaceCoverage {
        let voxel = configuration.voxelSize
        let band = configuration.sideSupportBandInVoxels * voxel
        let lengthU = max(bounds.highU - bounds.lowU, voxel)
        let lengthV = max(bounds.highV - bounds.lowV, voxel)
        let binsU = max(1, Int((lengthU / voxel).rounded(.up)))
        let binsV = max(1, Int((lengthV / voxel).rounded(.up)))
        var sides = [
            [Bool](repeating: false, count: binsV),
            [Bool](repeating: false, count: binsV),
            [Bool](repeating: false, count: binsU),
            [Bool](repeating: false, count: binsU)
        ]
        var topCells = [Bool](repeating: false, count: binsU * binsV)

        for point in local {
            let horizontal = SIMD2<Float>(point.x, point.z)
            let u = simd_dot(horizontal, bounds.axisU)
            let v = simd_dot(horizontal, bounds.axisV)
            let binU = min(max(Int((u - bounds.lowU) / voxel), 0), binsU - 1)
            let binV = min(max(Int((v - bounds.lowV) / voxel), 0), binsV - 1)
            if abs(u - bounds.lowU) <= band { sides[0][binV] = true }
            if abs(u - bounds.highU) <= band { sides[1][binV] = true }
            if abs(v - bounds.lowV) <= band { sides[2][binU] = true }
            if abs(v - bounds.highV) <= band { sides[3][binU] = true }
            if point.y >= bounds.trimmedTop - band {
                topCells[binU * binsV + binV] = true
            }
        }

        func fraction(_ cells: [Bool]) -> Double {
            Double(cells.lazy.filter { $0 }.count) / Double(cells.count)
        }
        return LiDARSurfaceCoverage(
            sideSupportFractions: sides.map(fraction),
            topCoverageFraction: fraction(topCells)
        )
    }

    /// True when a dense vertical sheet of voxels lies inside the footprint.
    ///
    /// A single scanned object is a shell: slices through its interior hold
    /// only the thin outline of its top and sides. Two objects closer than
    /// the voxel grid can resolve join into one component, and their facing
    /// sides then appear as a slice many times denser than its neighbours.
    static func hasInteriorPartition(
        local: [SIMD3<Float>],
        bounds: LiDARBoundsEstimate,
        configuration: LiDARFusionConfiguration
    ) -> Bool {
        let voxel = configuration.voxelSize
        let margin = max(1, configuration.interiorPartitionEdgeMarginInVoxels)
        for (axis, low, high) in [
            (bounds.axisU, bounds.lowU, bounds.highU),
            (bounds.axisV, bounds.lowV, bounds.highV)
        ] {
            let sliceCount = Int(((high - low) / voxel).rounded(.up))
            guard sliceCount >= 2 * margin + 3 else { continue }
            var counts = [Int](repeating: 0, count: sliceCount)
            for point in local {
                let coordinate = simd_dot(SIMD2<Float>(point.x, point.z), axis)
                let slice = Int((coordinate - low) / voxel)
                if slice >= 0, slice < sliceCount { counts[slice] += 1 }
            }
            let interior = Array(counts[margin..<(sliceCount - margin)])
            let median = interior.sorted()[interior.count / 2]
            let threshold = max(
                Double(configuration.interiorPartitionMinimumVoxels),
                configuration.interiorPartitionDensityRatio * Double(median)
            )
            if interior.contains(where: { Double($0) >= threshold }) { return true }
        }
        return false
    }

    /// Arc, in degrees, of the smallest sector containing every occupied
    /// azimuth bin. Zero when all viewpoints fall in one bin.
    static func viewpointSpanDegrees(occupiedBins: [Bool], binDegrees: Int) -> Double {
        let count = occupiedBins.count
        let occupied = occupiedBins.indices.filter { occupiedBins[$0] }
        guard count > 0, let first = occupied.first else { return 0 }
        var largestGap = 0
        for (position, bin) in occupied.enumerated() {
            let next = position + 1 < occupied.count ? occupied[position + 1] : first + count
            largestGap = max(largestGap, next - bin - 1)
        }
        return Double(max(count - largestGap - 1, 0) * binDegrees)
    }
}
