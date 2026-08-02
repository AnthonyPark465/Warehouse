import Foundation
import simd

enum ShelfScanValidator {
    static let precisePlacementMinimumConfidence = 0.62

    static func rejectionReasons(for shelf: ShelfState) -> [PlacementRejectionCode] {
        var reasons: [PlacementRejectionCode] = []
        let dimensions = shelf.boundary.dimensions
        if !shelf.scanQuality.hasClosedBoundary || shelf.scanQuality.missingSurfaceCount > 0 ||
            dimensions.widthCM <= 0 || dimensions.heightCM <= 0 || dimensions.depthCM <= 0 ||
            shelf.compartments.contains(where: { $0.volume.dimensions.volumeCM3 <= 0 }) ||
            hasOverlappingCompartments(shelf.compartments) ||
            shelf.obstacles.contains(where: { obstacle in
                obstacle.compartmentID == nil && !shelf.compartments.isEmpty
            }) {
            reasons.append(.staleShelfState)
        }
        if shelf.scanQuality.confidence < precisePlacementMinimumConfidence ||
            shelf.scanQuality.trackingDriftCM > 5 {
            reasons.append(.lowScanConfidence)
        }
        if shelf.version >= 2 && shelf.geometry?.isApproved != true {
            reasons.append(.staleShelfState)
        }
        if shelf.products.contains(where: { !containsShelfGeometry(shelf, $0.volume) }) ||
            containsDuplicateProducts(shelf.products) || containsOverlappingProducts(shelf.products) {
            reasons.append(.staleShelfState)
        }
        return Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
    }

    static func validFrontDirection(_ direction: Vector3D) -> Bool {
        let vector = direction.normalized
        return vector.x.isFinite && vector.y.isFinite && vector.z.isFinite && abs(vector.y) < 0.35 &&
            hypot(vector.x, vector.z) > 0.9
    }

    private static func hasOverlappingCompartments(_ compartments: [ShelfCompartment]) -> Bool {
        for index in compartments.indices {
            for other in compartments.indices where other > index {
                if overlaps(compartments[index].volume, compartments[other].volume, touchingCounts: false) {
                    return true
                }
            }
        }
        return false
    }

    private static func containsDuplicateProducts(_ products: [StoredProductPlacement]) -> Bool {
        Set(products.map(\.id)).count != products.count
    }

    private static func containsOverlappingProducts(_ products: [StoredProductPlacement]) -> Bool {
        for index in products.indices {
            for other in products.indices where other > index {
                if overlaps(products[index].volume, products[other].volume, touchingCounts: false) {
                    return true
                }
            }
        }
        return false
    }
}

enum PlacementEngine {
    // Kept for compatibility with the original capacity-only recommendation API.
    static let fitClearanceCM = 2.0

    struct Weights {
        let space: Double, distance: Double, affinity: Double, capacity: Double
        static func forScale(_ scale: WarehouseScale) -> Weights {
            switch scale {
            case .small: .init(space: 0.30, distance: 0.35, affinity: 0.15, capacity: 0.20)
            case .growing: .init(space: 0.30, distance: 0.25, affinity: 0.25, capacity: 0.20)
            case .enterprise: .init(space: 0.25, distance: 0.15, affinity: 0.40, capacity: 0.20)
            }
        }
    }

    static func recommend(package: PackagePlacementProfile, locations: [StorageLocation], scale: WarehouseScale) -> [PlacementRecommendation] {
        let weights = Weights.forScale(scale)
        let maxDistance = max(locations.map(\.walkingDistanceM).max() ?? 1, 1)
        return locations.compactMap { location in
            guard package.weightKG <= location.remainingWeightKG,
                  let orientation = legacyBestOrientation(for: package.dimensions, in: location) else { return nil }
            let space = min(package.dimensions.volumeCM3 / max(location.freeVolumeCM3, 1), 1)
            let distance = max(0, 1 - location.walkingDistanceM / maxDistance)
            let affinity = min(max(location.orderAffinity, 0), 1)
            let capacity = min(package.weightKG / max(location.remainingWeightKG, 1), 1)
            let velocity = 0.75 + min(max(package.demandVelocity, 0), 1) * 0.25
            let score = weights.space * space + weights.distance * distance * velocity +
                weights.affinity * affinity + weights.capacity * capacity
            return PlacementRecommendation(location: location, orientation: orientation, score: score,
                spaceEfficiency: space, distanceScore: distance, affinityScore: affinity, capacityScore: capacity)
        }.sorted { $0.score == $1.score ? $0.location.label < $1.location.label : $0.score > $1.score }
    }

    /// Deterministic shelf-local placement. Geometry is centimetres, with z=0
    /// at the opening and +z toward the back.
    static func calculate(
        package: PackagePlacementProfile,
        shelf: ShelfState,
        tolerance: PlacementToleranceConfiguration = .warehouse,
        reach: ReachConfiguration = .warehouse,
        handling: HandlingPolicy = .warehouse
    ) -> PlacementCalculation {
        let scanReasons = ShelfScanValidator.rejectionReasons(for: shelf)
        guard scanReasons.isEmpty, ShelfScanValidator.validFrontDirection(shelf.primaryFrontDirection) else {
            let message = scanReasons.contains(.lowScanConfidence)
                ? "The shelf scan may be incomplete or inaccurate. Rescan the highlighted area before calculating a placement."
                : "The stored shelf state is inconsistent. Reconcile or rescan the shelf before calculating a placement."
            return PlacementCalculation(recommendation: nil, alternatives: [], evaluations: [
                .init(identifier: "shelf-validation", result: nil,
                      rejectionReasons: scanReasons.isEmpty ? [.staleShelfState] : scanReasons)
            ], failureMessage: message)
        }

        let effective = effectiveDimensions(package: package, shelf: shelf, configuration: tolerance)
        let orientations = allowedOrientations(package: package, effectiveDimensions: effective)
        guard !orientations.isEmpty else {
            return .init(recommendation: nil, alternatives: [], evaluations: [
                .init(identifier: "orientation", result: nil, rejectionReasons: [.invalidOrientation])
            ], failureMessage: "No permitted resting orientation fits the product rules.")
        }

        let compartments = shelf.compartments.isEmpty ? [
            ShelfCompartment(id: "shelf-floor", label: shelf.label, volume: shelf.boundary,
                             ratedWeightKG: shelf.ratedWeightKG)
        ] : shelf.compartments
        var evaluations: [PlacementCandidateEvaluation] = []
        for compartment in compartments.sorted(by: { $0.id < $1.id }) {
            for (orientationIndex, orientation) in orientations.enumerated() {
                let candidates = candidateOrigins(in: compartment, orientation: orientation, shelf: shelf)
                for (candidateIndex, origin) in candidates.enumerated() {
                    let identifier = "\(compartment.id)-\(orientationIndex)-\(candidateIndex)-\(origin.x)-\(origin.y)-\(origin.z)"
                    evaluations.append(evaluate(
                        identifier: identifier, origin: origin, orientation: orientation,
                        package: package, shelf: shelf, compartment: compartment,
                        tolerance: tolerance, reach: reach, handling: handling
                    ))
                }
            }
        }

        let valid = evaluations.compactMap(\.result).sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.blockedProductIDs.count != $1.blockedProductIDs.count {
                return $0.blockedProductIDs.count < $1.blockedProductIDs.count
            }
            if $0.quarterTurns != $1.quarterTurns { return $0.quarterTurns < $1.quarterTurns }
            return $0.id < $1.id
        }
        guard let best = valid.first else {
            return .init(recommendation: nil, alternatives: [], evaluations: evaluations,
                failureMessage: "No valid placement was found on this shelf. The remaining spaces are too small after tolerance, unsafe to support, obstructed, or lack a valid insertion and removal path.")
        }
        return .init(recommendation: best, alternatives: Array(valid.dropFirst().prefix(4)),
                     evaluations: evaluations, failureMessage: nil)
    }

    static func effectiveDimensions(
        package: PackagePlacementProfile,
        shelf: ShelfState,
        configuration: PlacementToleranceConfiguration
    ) -> PackageDimensions {
        let confidence = min(shelf.scanQuality.confidence, package.metadata.weightKG == nil ? 0.7 : 1)
        let multiplier = confidence < 0.75 ? configuration.lowConfidenceMultiplier : 1
        func axis(_ measured: Double, _ explicit: Double) -> Double {
            let inferred = (configuration.minimumLinearToleranceCM + measured * configuration.percentageTolerance) * multiplier
            // Explicit scan uncertainty replaces inferred uncertainty; clearance is added exactly once.
            return measured + max(explicit, inferred) + max(package.metadata.requiredClearanceCM, 0)
        }
        return PackageDimensions(
            widthCM: axis(package.dimensions.widthCM, package.measurementUncertaintyCM.widthCM),
            heightCM: axis(package.dimensions.heightCM, package.measurementUncertaintyCM.heightCM),
            depthCM: axis(package.dimensions.depthCM, package.measurementUncertaintyCM.depthCM)
        )
    }

    private static func allowedOrientations(
        package: PackagePlacementProfile,
        effectiveDimensions: PackageDimensions
    ) -> [PackageDimensions] {
        guard package.metadata.mayRotateAutomatically else { return [effectiveDimensions] }
        return effectiveDimensions.orientations.filter { oriented in
            let verticalFace: Set<RestingFace>
            if approximately(oriented.heightCM, effectiveDimensions.heightCM) { verticalFace = [.bottom, .top] }
            else if approximately(oriented.heightCM, effectiveDimensions.widthCM) { verticalFace = [.left, .right] }
            else { verticalFace = [.front, .back] }
            let faceAllowed = !package.metadata.permittedRestingFaces.isDisjoint(with: verticalFace)
            let upright = !package.metadata.mustRemainUpright || approximately(oriented.heightCM, effectiveDimensions.heightCM)
            return faceAllowed && upright
        }
    }

    private static func candidateOrigins(
        in compartment: ShelfCompartment,
        orientation: PackageDimensions,
        shelf: ShelfState
    ) -> [Vector3D] {
        let min = compartment.volume.minimum
        let max = compartment.volume.maximum
        var xs: Set<Double> = [min.x, max.x - orientation.widthCM]
        var ys: Set<Double> = [min.y]
        var zs: Set<Double> = [min.z, max.z - orientation.depthCM]
        if let polygon = approvedFootprint(shelf) {
            let margin = Swift.max(shelf.geometry?.placementSafetyMarginCM ?? 0, 0)
            for point in polygon {
                xs.formUnion([
                    point.x + margin,
                    point.x - orientation.widthCM - margin
                ])
                zs.formUnion([
                    point.y + margin,
                    point.y - orientation.depthCM - margin
                ])
            }
        }
        let geometry = shelf.products.map(\.volume) + shelf.obstacles.map(\.volume)
        for volume in geometry {
            xs.formUnion([volume.minimum.x - orientation.widthCM, volume.maximum.x])
            zs.formUnion([volume.minimum.z - orientation.depthCM, volume.maximum.z])
        }
        for product in shelf.products where product.stacking.canSupportProductsAbove {
            ys.insert(product.volume.maximum.y)
            xs.formUnion([product.volume.minimum.x, product.volume.maximum.x - orientation.widthCM])
            zs.formUnion([product.volume.minimum.z, product.volume.maximum.z - orientation.depthCM])
        }
        var result: [Vector3D] = []
        for y in ys.sorted() {
            for z in zs.sorted() {
                for x in xs.sorted() {
                    let value = Vector3D(rounded(x), rounded(y), rounded(z))
                    if !result.contains(value) { result.append(value) }
                }
            }
        }
        return result
    }

    private static func evaluate(
        identifier: String,
        origin: Vector3D,
        orientation: PackageDimensions,
        package: PackagePlacementProfile,
        shelf: ShelfState,
        compartment: ShelfCompartment,
        tolerance: PlacementToleranceConfiguration,
        reach: ReachConfiguration,
        handling: HandlingPolicy
    ) -> PlacementCandidateEvaluation {
        let volume = AxisAlignedVolume(id: identifier, minimum: origin, dimensions: orientation)
        var rejected: [PlacementRejectionCode] = []
        if !contains(compartment.volume, volume)
            || !containsShelfGeometry(shelf, volume) {
            rejected.append(.outsideBoundary)
        }
        if shelf.obstacles.contains(where: { overlaps($0.volume, volume, touchingCounts: false) }) ||
            shelf.products.contains(where: { overlaps($0.volume, volume, touchingCounts: false) }) { rejected.append(.collision) }
        if let rated = compartment.ratedWeightKG ?? shelf.ratedWeightKG,
           shelf.products.compactMap(\.weightKG).reduce(0, +) + package.weightKG > rated { rejected.append(.weightLimit) }

        let support = supportEvaluation(volume: volume, package: package, shelf: shelf, compartment: compartment)
        if support.ratio + 0.0001 < package.metadata.stacking.minimumSupportRatio { rejected.append(.insufficientSupport) }
        if !support.centreSupported { rejected.append(.unstable) }
        if !support.rulesValid { rejected.append(.stackingRule) }
        if !support.weightValid { rejected.append(.weightLimit) }

        let insertion = insertionPath(for: volume, compartment: compartment, shelf: shelf, clearance: tolerance.insertionClearanceCM)
        if insertion == nil { rejected.append(.noInsertionPath) }

        let blocked = productsBlockedBy(volume, in: shelf, gripClearance: tolerance.retrievalClearanceCM)
        let critical = blocked.filter { $0.priority == .critical }
        if !critical.isEmpty && !handling.allowCriticalBlockingOverride { rejected.append(.criticalProductBlocked) }

        if let heavy = handling.heavyProductThresholdKG, package.weightKG >= heavy {
            if handling.heavyProductsRequireDirectFloorSupport && !support.supportingProducts.isEmpty { rejected.append(.stackingRule) }
            if let maxHeight = reach.heavyProductMaximumHeightCM, volume.maximum.y > maxHeight { rejected.append(.unstable) }
        }
        if volume.maximum.y > reach.absoluteMaximumPlacementHeightCM { rejected.append(.unstable) }

        rejected = Array(Set(rejected)).sorted { $0.rawValue < $1.rawValue }
        guard rejected.isEmpty, let insertion else {
            return .init(identifier: identifier, result: nil, rejectionReasons: rejected)
        }

        let requiredMoves = blocked.map(\.id).sorted()
        let blockingCost = blocked.reduce(0.0) {
            $0 + Double($1.priority.rawValue) * max($1.retrievalFrequency, 0.1)
        }
        let depthRange = max(compartment.volume.dimensions.depthCM - orientation.depthCM, 1)
        let frontScore = 1 - clamp((origin.z - compartment.volume.minimum.z) / depthRange)
        let preferredMid = (reach.minimumPreferredHeightCM + reach.maximumPreferredHeightCM) / 2
        let heightDistance = abs(volume.maximum.y - preferredMid)
        let safeHeight = 1 - clamp(heightDistance / max(preferredMid, 1))
        let accessibility = clamp(1 - Double(requiredMoves.count) * 0.25) * 0.65 + frontScore * 0.35
        let space = 1 - clamp((compartment.volume.dimensions.volumeCM3 - orientation.volumeCM3) /
                              max(compartment.volume.dimensions.volumeCM3, 1))
        let rank = PlacementRank(
            criticalProductBlockingCount: critical.count,
            higherPriorityBlockingCost: blockingCost,
            requiredMoveCount: requiredMoves.count,
            accessibilityScore: accessibility,
            safeHeightScore: safeHeight,
            frontScore: frontScore,
            stabilityScore: support.ratio,
            spaceEfficiencyScore: space
        )
        var warnings: [String] = []
        if package.metadata.weightKG == nil { warnings.append("Weight information is missing. Recommendation is limited to conservative support rules.") }
        if package.metadata.isFragile == nil { warnings.append("Fragility is unknown; stacking above this product is disabled.") }
        if shelf.ratedWeightKG == nil && compartment.ratedWeightKG == nil { warnings.append("Shelf load rating is unknown.") }
        let rotation = quarterTurns(from: package.dimensions, to: orientation)
        let supportText = support.supportingProducts.first.map { " Set it on top of product \($0.id)." } ?? " Set it directly on the shelf surface."
        let rotateText = rotation == 0 ? "Keep its scanned bottom face down." : "Rotate it \(rotation * 90)° clockwise while keeping an allowed resting face down."
        let instructions = "Place the product in \(shelf.label), \(compartment.label).\(supportText) \(rotateText) Align its front face about \(max(origin.z - compartment.volume.minimum.z, 0).formatted(.number.precision(.fractionLength(0)))) cm behind the shelf opening."
        let removal = Array(insertion.reversed())
        let result = ProductPlacementResult(
            id: identifier, shelfID: shelf.id, compartmentID: compartment.id,
            productID: package.productId, shelfVersion: shelf.version, position: origin,
            quarterTurns: rotation, orientedDimensions: orientation,
            supportSurfaceID: support.supportingProducts.first?.volume.id ?? compartment.volume.id,
            supportingProductIDs: support.supportingProducts.map(\.id).sorted(),
            blockedProductIDs: blocked.map(\.id).sorted(), insertionPath: insertion,
            removalPath: removal, requiredMoves: requiredMoves,
            confidence: min(shelf.scanQuality.confidence, warnings.isEmpty ? 1 : 0.72),
            rank: rank, warnings: warnings, instructions: instructions
        )
        return .init(identifier: identifier, result: result, rejectionReasons: [])
    }

    private struct SupportEvaluation {
        var ratio: Double
        var centreSupported: Bool
        var rulesValid: Bool
        var weightValid: Bool
        var supportingProducts: [StoredProductPlacement]
    }

    private static func supportEvaluation(
        volume: AxisAlignedVolume,
        package: PackagePlacementProfile,
        shelf: ShelfState,
        compartment: ShelfCompartment
    ) -> SupportEvaluation {
        if approximately(volume.minimum.y, compartment.volume.minimum.y) {
            return .init(ratio: 1, centreSupported: true, rulesValid: true, weightValid: true, supportingProducts: [])
        }
        let supporters = shelf.products.filter { product in
            approximately(product.volume.maximum.y, volume.minimum.y, epsilon: 0.15) &&
            horizontalOverlapArea(product.volume, volume) > 0
        }
        let baseArea = max(volume.dimensions.widthCM * volume.dimensions.depthCM, 0.0001)
        let ratio = min(supporters.reduce(0.0) { $0 + horizontalOverlapArea($1.volume, volume) } / baseArea, 1)
        let centre = Vector3D(volume.minimum.x + volume.dimensions.widthCM / 2, volume.minimum.y,
                              volume.minimum.z + volume.dimensions.depthCM / 2)
        let centreSupported = supporters.contains { horizontalContains($0.volume, centre) }
        let rulesValid = package.metadata.stacking.canBePlacedOnAnotherProduct && supporters.allSatisfy { support in
            support.stacking.canSupportProductsAbove && !support.stacking.fragileTopSurface &&
            !(support.stacking.prohibitedProductTypesAbove?.contains(package.productType) ?? false) &&
            (support.stacking.allowedProductTypesAbove?.contains(package.productType) ?? true)
        }
        let weightValid = supporters.allSatisfy {
            guard let maximum = $0.stacking.maximumSupportedWeight else { return false }
            return package.weightKG <= maximum
        }
        return .init(ratio: ratio, centreSupported: centreSupported, rulesValid: rulesValid,
                     weightValid: weightValid, supportingProducts: supporters)
    }

    private static func insertionPath(
        for volume: AxisAlignedVolume,
        compartment: ShelfCompartment,
        shelf: ShelfState,
        clearance: Double
    ) -> [Vector3D]? {
        let startZ = compartment.volume.minimum.z - volume.dimensions.depthCM - clearance
        let distance = volume.minimum.z - startZ
        let steps = max(Int(ceil(distance / 2)), 1)
        let geometry = shelf.products.map(\.volume) + shelf.obstacles.map(\.volume)
        var path: [Vector3D] = []
        for step in 0...steps {
            let z = startZ + distance * Double(step) / Double(steps)
            let swept = AxisAlignedVolume(id: "path", minimum: Vector3D(volume.minimum.x, volume.minimum.y, z),
                                          dimensions: volume.dimensions)
            if geometry.contains(where: { overlaps($0, swept, touchingCounts: false) }) { return nil }
            // Once inside the opening, the swept volume must stay within width/height.
            if z >= compartment.volume.minimum.z {
                guard swept.minimum.x >= compartment.volume.minimum.x,
                      swept.maximum.x <= compartment.volume.maximum.x,
                      swept.minimum.y >= compartment.volume.minimum.y,
                      swept.maximum.y <= compartment.volume.maximum.y,
                      containsShelfGeometry(shelf, swept)
                else { return nil }
            }
            path.append(swept.minimum)
        }
        return path
    }

    private static func productsBlockedBy(
        _ newVolume: AxisAlignedVolume,
        in shelf: ShelfState,
        gripClearance: Double
    ) -> [StoredProductPlacement] {
        shelf.products.filter { product in
            let sameLane = intervalOverlap(newVolume.minimum.x - gripClearance, newVolume.maximum.x + gripClearance,
                                           product.volume.minimum.x, product.volume.maximum.x) > 0 &&
                intervalOverlap(newVolume.minimum.y, newVolume.maximum.y,
                                product.volume.minimum.y, product.volume.maximum.y) > 0
            return sameLane && newVolume.minimum.z < product.volume.minimum.z
        }
    }

    private static func legacyBestOrientation(for package: PackageDimensions, in location: StorageLocation) -> PackageDimensions? {
        package.orientations.filter {
            $0.widthCM + fitClearanceCM <= location.freeWidthCM &&
            $0.heightCM + fitClearanceCM <= location.freeHeightCM &&
            $0.depthCM + fitClearanceCM <= location.freeDepthCM
        }.max {
            ($0.widthCM * $0.depthCM) / max(location.freeWidthCM * location.freeDepthCM, 1) <
            ($1.widthCM * $1.depthCM) / max(location.freeWidthCM * location.freeDepthCM, 1)
        }
    }

    private static func quarterTurns(from original: PackageDimensions, to oriented: PackageDimensions) -> Int {
        approximately(original.widthCM, oriented.widthCM) && approximately(original.depthCM, oriented.depthCM) ? 0 : 1
    }
}

// MARK: - Geometry primitives shared by validation and the engine

private func rounded(_ value: Double) -> Double { (value * 1_000).rounded() / 1_000 }
private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
private func approximately(_ a: Double, _ b: Double, epsilon: Double = 0.001) -> Bool { abs(a - b) <= epsilon }

private func contains(_ outer: AxisAlignedVolume, _ inner: AxisAlignedVolume) -> Bool {
    inner.minimum.x >= outer.minimum.x && inner.minimum.y >= outer.minimum.y && inner.minimum.z >= outer.minimum.z &&
        inner.maximum.x <= outer.maximum.x && inner.maximum.y <= outer.maximum.y && inner.maximum.z <= outer.maximum.z
}

private func approvedFootprint(_ shelf: ShelfState) -> [SIMD2<Double>]? {
    guard let geometry = shelf.geometry,
          geometry.isApproved,
          geometry.measurementMetadata.coordinateSpace == .shelfLocal,
          geometry.measurementMetadata.unit == .centimetres,
          geometry.approvedBoundary.count >= 3
    else { return nil }
    return geometry.approvedBoundary.map { SIMD2($0.x, $0.z) }
}

private func containsShelfGeometry(
    _ shelf: ShelfState,
    _ volume: AxisAlignedVolume
) -> Bool {
    guard contains(shelf.boundary, volume) else { return false }
    guard let polygon = approvedFootprint(shelf) else { return shelf.version < 2 }
    let margin = max(shelf.geometry?.placementSafetyMarginCM ?? 0, 0)
    let corners = [
        SIMD2(volume.minimum.x, volume.minimum.z),
        SIMD2(volume.maximum.x, volume.minimum.z),
        SIMD2(volume.maximum.x, volume.maximum.z),
        SIMD2(volume.minimum.x, volume.maximum.z)
    ]
    let insideOuter = corners.allSatisfy {
        pointInPolygon($0, polygon: polygon)
            && distanceToPolygonBoundary($0, polygon: polygon) + 0.0001 >= margin
    }
    guard insideOuter else { return false }
    let exclusions = shelf.geometry?.excludedRegions?.map {
        $0.map { SIMD2($0.x, $0.z) }
    } ?? []
    return !exclusions.contains { excluded in
        polygonsOverlap(corners, excluded)
            || corners.contains { distanceToPolygonBoundary($0, polygon: excluded) < margin }
    }
}

private func polygonsOverlap(_ first: [SIMD2<Double>], _ second: [SIMD2<Double>]) -> Bool {
    guard first.count >= 3, second.count >= 3 else { return false }
    if first.contains(where: { pointInPolygon($0, polygon: second) }) ||
        second.contains(where: { pointInPolygon($0, polygon: first) }) { return true }
    for i in first.indices {
        for j in second.indices where segmentsCross(
            first[i], first[(i + 1) % first.count],
            second[j], second[(j + 1) % second.count]
        ) { return true }
    }
    return false
}

private func segmentsCross(
    _ a: SIMD2<Double>, _ b: SIMD2<Double>,
    _ c: SIMD2<Double>, _ d: SIMD2<Double>
) -> Bool {
    func cross(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double { p.x * q.y - p.y * q.x }
    let abC = cross(b - a, c - a), abD = cross(b - a, d - a)
    let cdA = cross(d - c, a - c), cdB = cross(d - c, b - c)
    return abC * abD < -0.0001 && cdA * cdB < -0.0001
}

private func pointInPolygon(
    _ point: SIMD2<Double>,
    polygon: [SIMD2<Double>]
) -> Bool {
    var inside = false
    var previous = polygon.count - 1
    for current in polygon.indices {
        let a = polygon[current]
        let b = polygon[previous]
        if distanceToSegment(point, a, b) <= 0.0001 { return true }
        if (a.y > point.y) != (b.y > point.y) {
            let crossingX = (b.x - a.x) * (point.y - a.y)
                / (b.y - a.y) + a.x
            if point.x < crossingX { inside.toggle() }
        }
        previous = current
    }
    return inside
}

private func distanceToPolygonBoundary(
    _ point: SIMD2<Double>,
    polygon: [SIMD2<Double>]
) -> Double {
    polygon.indices.reduce(.greatestFiniteMagnitude) { result, index in
        min(
            result,
            distanceToSegment(
                point,
                polygon[index],
                polygon[(index + 1) % polygon.count]
            )
        )
    }
}

private func distanceToSegment(
    _ point: SIMD2<Double>,
    _ start: SIMD2<Double>,
    _ end: SIMD2<Double>
) -> Double {
    let segment = end - start
    let lengthSquared = simd_length_squared(segment)
    guard lengthSquared > 0 else { return simd_distance(point, start) }
    let t = min(max(simd_dot(point - start, segment) / lengthSquared, 0), 1)
    return simd_distance(point, start + segment * t)
}

private func overlaps(_ a: AxisAlignedVolume, _ b: AxisAlignedVolume, touchingCounts: Bool) -> Bool {
    let epsilon = touchingCounts ? -0.0001 : 0.0001
    return a.minimum.x < b.maximum.x - epsilon && a.maximum.x > b.minimum.x + epsilon &&
        a.minimum.y < b.maximum.y - epsilon && a.maximum.y > b.minimum.y + epsilon &&
        a.minimum.z < b.maximum.z - epsilon && a.maximum.z > b.minimum.z + epsilon
}

private func intervalOverlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
    max(0, min(a1, b1) - max(a0, b0))
}

private func horizontalOverlapArea(_ a: AxisAlignedVolume, _ b: AxisAlignedVolume) -> Double {
    intervalOverlap(a.minimum.x, a.maximum.x, b.minimum.x, b.maximum.x) *
        intervalOverlap(a.minimum.z, a.maximum.z, b.minimum.z, b.maximum.z)
}

private func horizontalContains(_ volume: AxisAlignedVolume, _ point: Vector3D) -> Bool {
    point.x >= volume.minimum.x && point.x <= volume.maximum.x &&
        point.z >= volume.minimum.z && point.z <= volume.maximum.z
}
