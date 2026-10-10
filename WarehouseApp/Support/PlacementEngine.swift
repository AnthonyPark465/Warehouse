import Foundation
import simd

enum ShelfStateOperationError: LocalizedError, Equatable {
    case staleVersion(expected: Int, actual: Int)
    case invalidPlacement
    case dependentPlacementExists

    var errorDescription: String? {
        switch self {
        case .staleVersion(let expected, let actual):
            "Storage state changed from version \(expected) to \(actual). Recalculate placement."
        case .invalidPlacement:
            "The placement is no longer valid for the current storage state."
        case .dependentPlacementExists:
            "Remove products above this supporting product first."
        }
    }
}

/// Pure operational-state mutations shared by Firestore transactions and unit
/// tests. Geometry scan history remains in `spaces`; this `ShelfState` is the
/// canonical occupancy, obstacle, rating, barcode, and version record.
enum ShelfStateOperations {
    static func confirming(
        result: ProductPlacementResult,
        package: PackagePlacementProfile,
        in shelf: ShelfState
    ) throws -> ShelfState {
        guard result.shelfVersion == shelf.version else {
            throw ShelfStateOperationError.staleVersion(expected: result.shelfVersion, actual: shelf.version)
        }
        guard !shelf.products.contains(where: { $0.id == result.id }) else {
            throw ShelfStateOperationError.invalidPlacement
        }
        let calculation = PlacementEngine.calculate(package: package, shelf: shelf)
        let candidates = [calculation.recommendation].compactMap { $0 } + calculation.alternatives
        guard candidates.contains(where: { $0.id == result.id }) else {
            throw ShelfStateOperationError.invalidPlacement
        }
        return applying(result: result, package: package, to: shelf)
    }

    /// Records `result` as occupancy without re-validating it. Callers must
    /// already hold a result calculated against exactly this shelf state.
    static func applying(
        result: ProductPlacementResult,
        package: PackagePlacementProfile,
        to shelf: ShelfState
    ) -> ShelfState {
        var next = shelf
        next.products.append(StoredProductPlacement(
            id: result.id, productID: package.productId, productType: package.productType,
            compartmentID: result.compartmentID,
            volume: AxisAlignedVolume(
                id: result.id, minimum: result.position, dimensions: result.orientedDimensions
            ),
            orientation: result.orientation,
            weightKG: package.weightKG,
            priority: package.metadata.retrievalPriority,
            retrievalFrequency: package.metadata.expectedRetrievalFrequency,
            stacking: package.metadata.stacking,
            supportingProductIDs: result.supportingProductIDs,
            blockedProductIDs: result.blockedProductIDs
        ))
        next.version += 1
        next.updatedAt = .now
        return next
    }

    static func removing(id: String, from shelf: ShelfState, expectedVersion: Int) throws -> ShelfState {
        guard shelf.version == expectedVersion else {
            throw ShelfStateOperationError.staleVersion(expected: expectedVersion, actual: shelf.version)
        }
        guard shelf.products.contains(where: { $0.id == id }) else {
            throw ShelfStateOperationError.invalidPlacement
        }
        guard !shelf.products.contains(where: { $0.supportingProductIDs.contains(id) }) else {
            throw ShelfStateOperationError.dependentPlacementExists
        }
        var next = shelf
        next.products.removeAll { $0.id == id }
        next.version += 1
        next.updatedAt = .now
        return next
    }
}

enum ShelfScanValidator {
    static let precisePlacementMinimumConfidence = 0.62

    static func rejectionReasons(for shelf: ShelfState) -> [PlacementRejectionCode] {
        var reasons: [PlacementRejectionCode] = []
        if !shelf.scanQuality.hasClosedBoundary || shelf.scanQuality.missingSurfaceCount > 0 ||
            !validVolume(shelf.boundary) ||
            shelf.compartments.contains(where: {
                !validVolume($0.volume) || !contains(shelf.boundary, $0.volume) ||
                    $0.ratedWeightKG.map { !$0.isFinite || $0 <= 0 } == true
            }) ||
            shelf.obstacles.contains(where: { !validVolume($0.volume) }) ||
            shelf.products.contains(where: {
                !validVolume($0.volume) ||
                    $0.weightKG.map { !$0.isFinite || $0 <= 0 } ?? true
            }) ||
            shelf.ratedWeightKG.map({ !$0.isFinite || $0 <= 0 }) == true ||
            !shelf.scanQuality.confidence.isFinite ||
            !(0...1).contains(shelf.scanQuality.confidence) ||
            !shelf.scanQuality.trackingDriftCM.isFinite || shelf.scanQuality.trackingDriftCM < 0 ||
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
        // `version` is the operational occupancy revision, not a geometry
        // schema number. Legacy shelves without geometry remain valid against
        // their conservative axis-aligned boundary after confirmations.
        if let geometry = shelf.geometry, !geometry.isApproved {
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
        // Placement paths are expressed with z=0 at the opening and +z going
        // into storage. Reject a reversed or sideways opening instead of
        // silently validating motion along the wrong axis.
        return vector.x.isFinite && vector.y.isFinite && vector.z.isFinite &&
            abs(vector.x) < 0.15 && abs(vector.y) < 0.15 && vector.z > 0.95
    }

    static func validCoordinateSystem(_ coordinateSystem: ShelfLocalCoordinateSystem) -> Bool {
        let width = coordinateSystem.widthAxis.simd
        let up = coordinateSystem.upAxis.simd
        let depth = coordinateSystem.depthAxis.simd
        let origin = coordinateSystem.anchorOrigin
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite else { return false }
        let vectors = [width, up, depth]
        guard vectors.allSatisfy({ vector in
            vector.x.isFinite && vector.y.isFinite && vector.z.isFinite &&
                abs(simd_length(vector) - 1) < 0.05
        }), abs(simd_dot(width, up)) < 0.1,
            abs(simd_dot(width, depth)) < 0.1,
            abs(simd_dot(up, depth)) < 0.1 else { return false }
        return simd_dot(simd_cross(width, up), depth) > 0.9
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

    private static func validVolume(_ volume: AxisAlignedVolume) -> Bool {
        let values = [
            volume.minimum.x, volume.minimum.y, volume.minimum.z,
            volume.dimensions.widthCM, volume.dimensions.heightCM, volume.dimensions.depthCM
        ]
        return values.allSatisfy(\.isFinite) &&
            volume.dimensions.widthCM > 0 && volume.dimensions.heightCM > 0 &&
            volume.dimensions.depthCM > 0
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
        activeReservations: [PlacementReservation] = [],
        tolerance: PlacementToleranceConfiguration = .warehouse,
        reach: ReachConfiguration = .warehouse,
        handling: HandlingPolicy = .warehouse
    ) -> PlacementCalculation {
        guard package.weightKG.isFinite, package.weightKG > 0,
              package.weightKG <= PlacementWorkflow.maximumWeightKG else {
            return .init(recommendation: nil, alternatives: [], evaluations: [
                .init(identifier: "product-weight", result: nil, rejectionReasons: [.weightLimit])
            ], failureMessage: "Enter a finite positive product weight before automatic placement.")
        }
        guard validDimensions(package.dimensions), validUncertainty(package.measurementUncertaintyCM) else {
            return .init(recommendation: nil, alternatives: [], evaluations: [
                .init(identifier: "product-dimensions", result: nil, rejectionReasons: [.invalidDimensions])
            ], failureMessage: "Enter finite positive product dimensions no larger than 5000 cm. Measurement uncertainty cannot be negative.")
        }
        let liveReservations = activeReservations.filter { $0.shelfID == shelf.id && $0.expiresAt > Date() }
        guard liveReservations.isEmpty else {
            return .init(recommendation: nil, alternatives: [], evaluations: [
                .init(identifier: "storage-lock", result: nil, rejectionReasons: [.activeReservation])
            ], failureMessage: "Another placement operation currently holds this storage area. Retry after it is confirmed, cancelled, or expires.")
        }
        var package = package
        package.metadata = package.metadata.conservativeForAutomaticPlacement
        // The profile value is the worker's validated form entry for this run.
        // Persisted metadata supplies the remaining handling rules only.
        package.metadata.weightKG = package.weightKG
        package = PackagePlacementProfile(
            productId: package.productId, dimensions: package.dimensions,
            weightKG: package.weightKG, demandVelocity: package.demandVelocity,
            productType: package.productType, metadata: package.metadata,
            measurementUncertaintyCM: package.measurementUncertaintyCM
        )
        let scanReasons = ShelfScanValidator.rejectionReasons(for: shelf)
        guard scanReasons.isEmpty,
              ShelfScanValidator.validFrontDirection(shelf.primaryFrontDirection),
              ShelfScanValidator.validCoordinateSystem(shelf.coordinateSystem) else {
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
                let candidates = candidateOrigins(
                    in: compartment, orientation: orientation.orientedDimensions, shelf: shelf
                )
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
            let reasons = actionableFailureReasons(
                package: package, shelf: shelf, effectiveDimensions: effective,
                orientations: orientations, evaluations: evaluations
            )
            return .init(recommendation: nil, alternatives: [], evaluations: evaluations,
                failureMessage: reasons.joined(separator: " "))
        }
        return .init(recommendation: best, alternatives: Array(valid.dropFirst().prefix(4)),
                     evaluations: evaluations, failureMessage: nil)
    }

    /// Searches every storage area and recommends the best area and position
    /// together. Each area is calculated independently by the single-area
    /// engine, so every safety rule applies unchanged.
    static func calculate(
        package: PackagePlacementProfile,
        shelves: [ShelfState],
        activeReservations: [PlacementReservation] = [],
        tolerance: PlacementToleranceConfiguration = .warehouse,
        reach: ReachConfiguration = .warehouse,
        handling: HandlingPolicy = .warehouse
    ) -> CrossAreaPlacementCalculation {
        var calculations: [String: PlacementCalculation] = [:]
        var best: (shelf: ShelfState, result: ProductPlacementResult)?
        for shelf in shelves.sorted(by: { $0.id < $1.id }) {
            let calculation = calculate(
                package: package, shelf: shelf, activeReservations: activeReservations,
                tolerance: tolerance, reach: reach, handling: handling
            )
            calculations[shelf.id] = calculation
            guard let result = calculation.recommendation else { continue }
            if let current = best, !prefersArea(shelf, result, over: current.shelf, current.result) { continue }
            best = (shelf, result)
        }
        guard best == nil else {
            return .init(calculations: calculations, recommendedShelfID: best?.shelf.id, failureMessage: nil)
        }
        guard !shelves.isEmpty else {
            return .init(calculations: [:], recommendedShelfID: nil,
                         failureMessage: "No saved storage areas are available. Measure and save one first.")
        }
        let reasons = shelves.map { shelf in
            "\(shelf.displayLabel): \(calculations[shelf.id]?.failureMessage ?? "No valid position.")"
        }
        return .init(calculations: calculations, recommendedShelfID: nil,
                     failureMessage: (["No saved storage area accepts this product."] + reasons).joined(separator: "\n"))
    }

    /// Cross-area order. A position's rank is only meaningful inside its own
    /// area, so areas are compared first on the products that would have to be
    /// moved, then on how little free room the area has left, which keeps the
    /// larger areas open for products that fit nowhere else. Comparing distance
    /// from the front between areas was tried and did not help on
    /// `docs/placement-evaluation-synthetic.md`.
    static func prefersArea(
        _ shelf: ShelfState, _ result: ProductPlacementResult,
        over otherShelf: ShelfState, _ other: ProductPlacementResult
    ) -> Bool {
        let rank = result.rank, otherRank = other.rank
        if rank.criticalProductBlockingCount != otherRank.criticalProductBlockingCount {
            return rank.criticalProductBlockingCount < otherRank.criticalProductBlockingCount
        }
        if rank.requiredMoveCount != otherRank.requiredMoveCount {
            return rank.requiredMoveCount < otherRank.requiredMoveCount
        }
        let free = shelf.freeVolumeCM3, otherFree = otherShelf.freeVolumeCM3
        if free != otherFree { return free < otherFree }
        if rank != otherRank { return rank > otherRank }
        return shelf.id < otherShelf.id
    }

    static func effectiveDimensions(
        package: PackagePlacementProfile,
        shelf: ShelfState,
        configuration: PlacementToleranceConfiguration
    ) -> PackageDimensions {
        let confidence = shelf.scanQuality.confidence
        let multiplier = confidence < 0.75 ? configuration.lowConfidenceMultiplier : 1
        func axis(_ measured: Double, _ explicit: Double) -> Double {
            let inferred = (configuration.minimumLinearToleranceCM + measured * configuration.percentageTolerance) * multiplier
            // Explicit scan uncertainty replaces inferred uncertainty; clearance is added exactly once.
            let uncertainty = explicit.isFinite && explicit >= 0 ? max(explicit, inferred) : inferred
            return measured + uncertainty + max(package.metadata.requiredClearanceCM, 0)
        }
        return PackageDimensions(
            widthCM: axis(package.dimensions.widthCM, package.measurementUncertaintyCM.widthCM),
            heightCM: axis(package.dimensions.heightCM, package.measurementUncertaintyCM.heightCM),
            depthCM: axis(package.dimensions.depthCM, package.measurementUncertaintyCM.depthCM)
        )
    }

    static func usableDimensions(of shelf: ShelfState) -> PackageDimensions {
        let margin = max(shelf.geometry?.placementSafetyMarginCM ?? 0, 0)
        return PackageDimensions(
            widthCM: max(0, shelf.boundary.dimensions.widthCM - margin * 2),
            heightCM: max(0, shelf.boundary.dimensions.heightCM),
            depthCM: max(0, shelf.boundary.dimensions.depthCM - margin * 2)
        )
    }

    private static func validDimensions(_ dimensions: PackageDimensions) -> Bool {
        [dimensions.widthCM, dimensions.heightCM, dimensions.depthCM].allSatisfy {
            $0.isFinite && $0 > 0 && $0 <= PlacementWorkflow.maximumDimensionCM
        }
    }

    private static func validUncertainty(_ dimensions: PackageDimensions) -> Bool {
        [dimensions.widthCM, dimensions.heightCM, dimensions.depthCM].allSatisfy {
            $0.isFinite && $0 >= 0 && $0 <= PlacementWorkflow.maximumDimensionCM
        }
    }

    private static func actionableFailureReasons(
        package: PackagePlacementProfile,
        shelf: ShelfState,
        effectiveDimensions: PackageDimensions,
        orientations: [ProductOrientation],
        evaluations: [PlacementCandidateEvaluation]
    ) -> [String] {
        let rejected = evaluations.filter { $0.result == nil && !$0.rejectionReasons.isEmpty }
        let minimumRejectionCount = rejected.map { $0.rejectionReasons.count }.min() ?? 0
        // Explain the candidates closest to succeeding. Invalid generated
        // origins often have several incidental failures and would otherwise
        // drown out the actual blocker.
        let codes = rejected
            .filter { $0.rejectionReasons.count == minimumRejectionCount }
            .flatMap(\.rejectionReasons)
        let available = usableDimensions(of: shelf)
        let fitsBoundingBox = orientations.contains { orientation in
            let dimensions = orientation.orientedDimensions
            return dimensions.widthCM <= available.widthCM + 0.0001 &&
                dimensions.heightCM <= available.heightCM + 0.0001 &&
                dimensions.depthCM <= available.depthCM + 0.0001
        }
        var counts = Dictionary(grouping: codes, by: { $0 }).mapValues(\.count)
        if fitsBoundingBox,
           (shelf.geometry == nil || evaluations.contains(where: {
               !$0.rejectionReasons.contains(.outsideBoundary)
           })) {
            counts.removeValue(forKey: .outsideBoundary)
            if counts.isEmpty {
                let nonBoundaryCodes = rejected.flatMap(\.rejectionReasons).filter { $0 != .outsideBoundary }
                counts = Dictionary(grouping: nonBoundaryCodes, by: { $0 }).mapValues(\.count)
            }
        }
        var messages: [(PlacementRejectionCode, String)] = []

        if counts[.outsideBoundary] != nil {
            if !fitsBoundingBox {
                let closest = orientations.min { lhs, rhs in
                    overflow(lhs.orientedDimensions, available) < overflow(rhs.orientedDimensions, available)
                }?.orientedDimensions ?? effectiveDimensions
                let rotationNote = package.metadata.mayRotateAutomatically
                    ? "" : " Automatic rotation is not permitted for this product."
                messages.append((.outsideBoundary,
                    "Product requires \(dimensionText(closest)) after uncertainty and clearance; selected usable space is \(dimensionText(available)).\(rotationNote)"))
            } else {
                messages.append((.outsideBoundary,
                    "The product's rectangular footprint does not fit inside the approved boundary and safety margin."))
            }
        }
        if counts[.noInsertionPath] != nil {
            messages.append((.noInsertionPath,
                "The product fits inside the space but cannot pass through the opening on the supported straight insertion path."))
        }
        let openingObstacle = shelf.obstacles.contains { [.door, .lip].contains($0.kind) }
        if counts[.collision] != nil && !openingObstacle {
            let message: String
            if !shelf.products.isEmpty {
                message = "The selected area contains recorded occupancy that blocks all candidates."
            } else if !shelf.obstacles.isEmpty {
                message = "A recorded divider, door, lip, or other obstacle blocks all candidates."
            } else {
                message = "Recorded geometry blocks all candidates."
            }
            messages.append((.collision, message))
        }
        if counts[.weightLimit] != nil {
            let limit = shelf.compartments.compactMap(\.ratedWeightKG).min() ?? shelf.ratedWeightKG
            let suffix = limit.map { " The applicable limit is \($0.formatted(.number.precision(.fractionLength(1)))) kg." } ?? ""
            messages.append((.weightLimit,
                "The entered \(package.weightKG.formatted(.number.precision(.fractionLength(1)))) kg weight exceeds a known load or support limit.\(suffix)"))
        }
        if counts[.insufficientSupport] != nil || counts[.unstable] != nil {
            messages.append((.insufficientSupport,
                "No candidate has enough verified support area with its centre of mass supported."))
        }
        if counts[.stackingRule] != nil {
            messages.append((.stackingRule,
                "The remaining candidates violate the product or supporting item's stacking rules."))
        }
        if counts[.criticalProductBlocked] != nil || counts[.noRemovalPath] != nil {
            messages.append((.criticalProductBlocked,
                "Every remaining candidate would block safe access to a recorded product."))
        }

        let priority: [PlacementRejectionCode] = [
            .outsideBoundary, .collision, .noInsertionPath, .weightLimit,
            .insufficientSupport, .stackingRule, .criticalProductBlocked
        ]
        let ordered = messages.sorted { first, second in
            let firstIndex = priority.firstIndex(of: first.0) ?? priority.count
            let secondIndex = priority.firstIndex(of: second.0) ?? priority.count
            if firstIndex != secondIndex { return firstIndex < secondIndex }
            return (counts[first.0] ?? 0) > (counts[second.0] ?? 0)
        }.map(\.1)
        return Array(ordered.prefix(3)).isEmpty
            ? ["Review the permitted orientation, verified support, entered weight, and opening access; none of the current candidates satisfies every safety rule."]
            : Array(ordered.prefix(3))
    }

    private static func overflow(_ product: PackageDimensions, _ available: PackageDimensions) -> Double {
        max(product.widthCM - available.widthCM, 0) +
            max(product.heightCM - available.heightCM, 0) +
            max(product.depthCM - available.depthCM, 0)
    }

    private static func dimensionText(_ dimensions: PackageDimensions) -> String {
        let format: (Double) -> String = { value in
            value.formatted(.number.precision(.fractionLength(1)))
        }
        return "\(format(dimensions.widthCM)) × \(format(dimensions.heightCM)) × \(format(dimensions.depthCM)) cm (W × H × D)"
    }

    private static func allowedOrientations(
        package: PackagePlacementProfile,
        effectiveDimensions: PackageDimensions
    ) -> [ProductOrientation] {
        let metadata = package.metadata
        let restingFaces: [RestingFace]
        if metadata.mustRemainUpright {
            restingFaces = metadata.permittedRestingFaces.contains(.bottom) ? [.bottom] : []
        } else if metadata.mayRotateAutomatically {
            restingFaces = RestingFace.allCases.filter(metadata.permittedRestingFaces.contains)
        } else {
            restingFaces = metadata.permittedRestingFaces.contains(.bottom) ? [.bottom] : []
        }
        return restingFaces.flatMap { restingFace -> [ProductOrientation] in
            let forwardFaces = metadata.mayRotateAutomatically
                ? RestingFace.allCases.filter { $0.axis != restingFace.axis }
                : [.front].filter { $0.axis != restingFace.axis }
            return forwardFaces.enumerated().map { index, forwardFace in
                let dimensions = orientedDimensions(
                    effectiveDimensions, restingFace: restingFace, forwardFace: forwardFace
                )
                return ProductOrientation(
                    restingFace: restingFace, forwardFace: forwardFace,
                    orientedDimensions: dimensions,
                    yawQuarterTurns: yawQuarterTurns(restingFace: restingFace, forwardFace: forwardFace, fallback: index)
                )
            }
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
        var seen: Set<Vector3D> = []
        let sortedXs = xs.sorted(), sortedZs = zs.sorted()
        for y in ys.sorted() {
            for z in sortedZs {
                for x in sortedXs {
                    let value = Vector3D(rounded(x), rounded(y), rounded(z))
                    if seen.insert(value).inserted { result.append(value) }
                }
            }
        }
        return result
    }

    private static func evaluate(
        identifier: String,
        origin: Vector3D,
        orientation: ProductOrientation,
        package: PackagePlacementProfile,
        shelf: ShelfState,
        compartment: ShelfCompartment,
        tolerance: PlacementToleranceConfiguration,
        reach: ReachConfiguration,
        handling: HandlingPolicy
    ) -> PlacementCandidateEvaluation {
        let dimensions = orientation.orientedDimensions
        let volume = AxisAlignedVolume(id: identifier, minimum: origin, dimensions: dimensions)
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
        let requiredSupport = package.metadata.stacking.requiresFullBaseSupport
            ? 1 : package.metadata.stacking.minimumSupportRatio
        if support.ratio + 0.0001 < requiredSupport { rejected.append(.insufficientSupport) }
        if !support.centreSupported { rejected.append(.unstable) }
        if !support.rulesValid { rejected.append(.stackingRule) }
        if !support.weightValid { rejected.append(.weightLimit) }

        let insertion = insertionPath(for: volume, compartment: compartment, shelf: shelf, clearance: tolerance.insertionClearanceCM)
        if insertion == nil { rejected.append(.noInsertionPath) }

        let blocked = (productsBlockedBy(
            volume, in: shelf, gripClearance: tolerance.retrievalClearanceCM
        ) + support.supportingProducts).reduce(into: [StoredProductPlacement]()) { result, product in
            if !result.contains(where: { $0.id == product.id }) { result.append(product) }
        }
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
        let depthRange = max(compartment.volume.dimensions.depthCM - dimensions.depthCM, 1)
        let frontScore = 1 - clamp((origin.z - compartment.volume.minimum.z) / depthRange)
        let preferredMid = (reach.minimumPreferredHeightCM + reach.maximumPreferredHeightCM) / 2
        let heightDistance = abs(volume.maximum.y - preferredMid)
        let safeHeight = 1 - clamp(heightDistance / max(preferredMid, 1))
        let accessibility = clamp(1 - Double(requiredMoves.count) * 0.25) * 0.65 + frontScore * 0.35
        let space = 1 - clamp((compartment.volume.dimensions.volumeCM3 - dimensions.volumeCM3) /
                              max(compartment.volume.dimensions.volumeCM3, 1))
        let demand = max(
            package.metadata.expectedRetrievalFrequency,
            Double(package.metadata.retrievalPriority.rawValue) / 5,
            clamp(package.metadata.expirationUrgency)
        )
        let stackAccessibilityCost = support.supportingProducts.reduce(0.0) {
            $0 + max($1.retrievalFrequency, Double($1.priority.rawValue) / 5)
        }
        let retrievalCost = demand * (1 - frontScore) * 4 + stackAccessibilityCost * 2
        let fragmentation = fragmentationPenalty(for: volume, in: compartment, shelf: shelf)
        let rank = PlacementRank(
            criticalProductBlockingCount: critical.count,
            higherPriorityBlockingCost: blockingCost,
            requiredMoveCount: requiredMoves.count,
            expectedRetrievalCost: retrievalCost,
            fragmentationPenalty: fragmentation,
            accessibilityScore: accessibility,
            safeHeightScore: safeHeight,
            frontScore: frontScore,
            stabilityScore: support.ratio,
            spaceEfficiencyScore: space
        )
        var warnings: [String] = []
        if package.metadata.isFragile == nil { warnings.append("Fragility is unknown; stacking above this product is disabled.") }
        if shelf.ratedWeightKG == nil && compartment.ratedWeightKG == nil { warnings.append("Shelf load rating is unknown.") }
        let rotation = orientation.yawQuarterTurns
        let supportText = support.supportingProducts.first.map { " Set it on top of product \($0.id)." } ?? " Set it directly on the storage surface."
        let instructions = placementInstructions(
            shelf: shelf, compartment: compartment, origin: origin,
            orientation: orientation, supportText: supportText
        )
        let removal = Array(insertion.reversed())
        let result = ProductPlacementResult(
            id: identifier, shelfID: shelf.id, compartmentID: compartment.id,
            productID: package.productId, shelfVersion: shelf.version, position: origin,
            quarterTurns: rotation, orientedDimensions: dimensions, orientation: orientation,
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
            // 1.5 mm is deliberately smaller than normal warehouse clearance:
            // support must be coplanar, not merely near the candidate.
            approximately(product.volume.maximum.y, volume.minimum.y, epsilon: 0.15) &&
            horizontalOverlapArea(product.volume, volume) > 0
        }
        let baseArea = max(volume.dimensions.widthCM * volume.dimensions.depthCM, 0.0001)
        // Multi-support balancing is intentionally outside this MVP.
        guard supporters.count == 1, let supporter = supporters.first else {
            return .init(ratio: 0, centreSupported: false, rulesValid: false,
                         weightValid: false, supportingProducts: supporters)
        }
        let ratio = min(horizontalOverlapArea(supporter.volume, volume) / baseArea, 1)
        let centre = Vector3D(volume.minimum.x + volume.dimensions.widthCM / 2, volume.minimum.y,
                              volume.minimum.z + volume.dimensions.depthCM / 2)
        let centreSupported = horizontalContains(supporter.volume, centre)
        let descendants = supportedDescendants(of: supporter.id, in: shelf.products)
        let directChildren = shelf.products.filter { $0.supportingProductIDs == [supporter.id] }
        let typeAllowed = !(supporter.stacking.prohibitedProductTypesAbove?.contains(package.productType) ?? false)
            && (supporter.stacking.allowedProductTypesAbove?.contains(package.productType) ?? true)
        let countAllowed = supporter.stacking.maximumItemsAbove.map { descendants.count + 1 <= $0 } ?? true
        let identicalAllowed = supporter.stacking.maximumIdenticalStackCount.map { limit in
            descendants.filter { $0.productID == package.productId }.count + 1 <= limit
        } ?? true
        let heightAllowed = supporter.stacking.maximumTotalStackHeight.map {
            volume.maximum.y - supporter.volume.minimum.y <= $0 + 0.0001
        } ?? true
        let supporterAccessible = supporter.priority != .critical
        let rulesValid = package.metadata.stacking.canBePlacedOnAnotherProduct
            && supporter.stacking.canSupportProductsAbove
            && supporter.stacking.hasValidSupportConfiguration
            && !supporter.stacking.fragileTopSurface
            && typeAllowed && countAllowed && identicalAllowed && heightAllowed
            && supporterAccessible && directChildren.count == descendants.count
        let cumulativeWeight = descendants.compactMap(\.weightKG).reduce(0, +) + package.weightKG
        let weightValid = supporter.stacking.maximumSupportedWeight.map {
            $0.isFinite && $0 > 0 && cumulativeWeight <= $0 + 0.0001
        } ?? false
        return .init(ratio: ratio, centreSupported: centreSupported, rulesValid: rulesValid,
                     weightValid: weightValid, supportingProducts: supporters)
    }

    private static func supportedDescendants(
        of supporterID: String,
        in products: [StoredProductPlacement]
    ) -> [StoredProductPlacement] {
        var discovered: Set<String> = []
        var frontier = [supporterID]
        while let current = frontier.popLast() {
            for child in products where child.supportingProductIDs.contains(current) && !discovered.contains(child.id) {
                discovered.insert(child.id)
                frontier.append(child.id)
            }
        }
        return products.filter { discovered.contains($0.id) }
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
                      swept.maximum.y <= compartment.volume.maximum.y
                else { return nil }
            }
            guard sweepClearsFootprintWalls(shelf, swept) else { return nil }
            path.append(swept.minimum)
        }
        return path
    }

    /// Stored products that cannot be taken out through the front while
    /// `newVolume` is in place: same lane, further back.
    static func productsBlockedBy(
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

    private static func orientedDimensions(
        _ dimensions: PackageDimensions,
        restingFace: RestingFace,
        forwardFace: RestingFace
    ) -> PackageDimensions {
        func length(for axis: Int) -> Double {
            switch axis {
            case 0: dimensions.widthCM
            case 1: dimensions.heightCM
            default: dimensions.depthCM
            }
        }
        let remainingAxis = Set([0, 1, 2]).subtracting([restingFace.axis, forwardFace.axis]).first ?? 0
        return PackageDimensions(
            widthCM: length(for: remainingAxis),
            heightCM: length(for: restingFace.axis),
            depthCM: length(for: forwardFace.axis)
        )
    }

    private static func yawQuarterTurns(
        restingFace: RestingFace,
        forwardFace: RestingFace,
        fallback: Int
    ) -> Int {
        if restingFace == .bottom {
            return [.front, .right, .back, .left].firstIndex(of: forwardFace) ?? fallback
        }
        return fallback % 4
    }

    private static func placementInstructions(
        shelf: ShelfState,
        compartment: ShelfCompartment,
        origin: Vector3D,
        orientation: ProductOrientation,
        supportText: String
    ) -> String {
        let fromFront = max(origin.z - compartment.volume.minimum.z, 0)
        // Width, up, and depth form a right-handed frame, so shelf-local width
        // increases toward the left of someone facing in from the front.
        let fromRight = max(origin.x - compartment.volume.minimum.x, 0)
        let fromLeft = max(compartment.volume.maximum.x
            - (origin.x + orientation.orientedDimensions.widthCM), 0)
        let horizontal = fromLeft <= fromRight
            ? "\(fromLeft.formatted(.number.precision(.fractionLength(0)))) cm from the left side"
            : "\(fromRight.formatted(.number.precision(.fractionLength(0)))) cm from the right side"
        // A single compartment is the whole storage area; naming it adds nothing.
        let destination = shelf.compartments.count > 1
            ? "\(shelf.displayLabel), \(compartment.label)" : shelf.displayLabel
        return "Place the product in \(destination).\(supportText) "
            + "Put its \(orientation.restingFace.rawValue) face down and its \(orientation.forwardFace.rawValue) face toward the front edge. "
            + "Facing in from the front edge, leave \(fromFront.formatted(.number.precision(.fractionLength(0)))) cm in front of the product and keep it \(horizontal)."
    }

    /// Explainable MVP fragmentation metric: penalize narrow side/rear gaps
    /// and volume trapped behind the candidate. This is deliberately local and
    /// deterministic; it leaves room for future look-ahead without using it now.
    private static func fragmentationPenalty(
        for volume: AxisAlignedVolume,
        in compartment: ShelfCompartment,
        shelf: ShelfState
    ) -> Double {
        let left = max(volume.minimum.x - compartment.volume.minimum.x, 0)
        let right = max(compartment.volume.maximum.x - volume.maximum.x, 0)
        let behind = max(compartment.volume.maximum.z - volume.maximum.z, 0)
        let sliverLimit = 10.0
        let sliverPenalty = [left, right, behind].reduce(0.0) { total, gap in
            guard gap > 0, gap < sliverLimit else { return total }
            return total + (sliverLimit - gap) / sliverLimit
        }
        let laneBlocked = shelf.products.contains {
            intervalOverlap($0.volume.minimum.x, $0.volume.maximum.x,
                            volume.minimum.x, volume.maximum.x) > 0
                && $0.volume.minimum.z > volume.maximum.z
        }
        let trappedVolumeRatio = behind * volume.dimensions.widthCM * volume.dimensions.heightCM
            / max(compartment.volume.dimensions.volumeCM3, 1)
        return sliverPenalty + trappedVolumeRatio + (laneBlocked ? 1 : 0)
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

/// Footprint edges that face the front. These form the opening a product
/// passes through on a straight insertion; every other edge is a wall.
private func openingEdgeIndices(of polygon: [SIMD2<Double>]) -> Set<Int> {
    let doubledArea = polygon.indices.reduce(0.0) { value, index in
        let next = polygon[(index + 1) % polygon.count]
        return value + polygon[index].x * next.y - next.x * polygon[index].y
    }
    func edge(_ index: Int) -> SIMD2<Double> { polygon[(index + 1) % polygon.count] - polygon[index] }
    // The outward normal of a front-facing edge points toward smaller depth. An
    // edge that runs mostly front to back is a side wall, however it is skewed.
    let facingFront = polygon.indices.filter { edge($0).x * doubledArea > 0 }
    let opening = facingFront.filter { abs(edge($0).x) >= abs(edge($0).y) }
    if !opening.isEmpty { return Set(opening) }
    // A steeply skewed footprint still has a front: its most front-facing edge.
    let frontmost = facingFront.max {
        abs(edge($0).x) / simd_length(edge($0)) < abs(edge($1).x) / simd_length(edge($1))
    }
    return Set([frontmost].compactMap { $0 })
}

extension ShelfState {
    /// Usable footprint in shelf-local centimetres, as (width, depth) points.
    var footprintPolygon: [SIMD2<Double>] {
        approvedFootprint(self) ?? [
            SIMD2(boundary.minimum.x, boundary.minimum.z),
            SIMD2(boundary.maximum.x, boundary.minimum.z),
            SIMD2(boundary.maximum.x, boundary.maximum.z),
            SIMD2(boundary.minimum.x, boundary.maximum.z)
        ]
    }

    /// Indices of the `footprintPolygon` edges that make up the front opening.
    var footprintOpeningEdgeIndices: Set<Int> { openingEdgeIndices(of: footprintPolygon) }

    /// Bounding volume not yet claimed by stored products or obstacles.
    var freeVolumeCM3: Double {
        let claimed = (products.map(\.volume) + obstacles.map(\.volume)).reduce(0.0) {
            $0 + $1.dimensions.volumeCM3
        }
        return max(boundary.dimensions.volumeCM3 - claimed, 0)
    }
}

private func containsShelfGeometry(
    _ shelf: ShelfState,
    _ volume: AxisAlignedVolume
) -> Bool {
    guard contains(shelf.boundary, volume) else { return false }
    guard let polygon = approvedFootprint(shelf) else { return true }
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
    let crossesConcaveBoundary = corners.indices.contains { rectangleIndex in
        polygon.indices.contains { polygonIndex in
            segmentsCross(
                corners[rectangleIndex], corners[(rectangleIndex + 1) % corners.count],
                polygon[polygonIndex], polygon[(polygonIndex + 1) % polygon.count]
            )
        }
    }
    guard insideOuter, !crossesConcaveBoundary else { return false }
    let exclusions = shelf.geometry?.excludedRegions?.map {
        $0.map { SIMD2($0.x, $0.z) }
    } ?? []
    return !exclusions.contains { excluded in
        polygonsOverlap(corners, excluded)
            || corners.contains { distanceToPolygonBoundary($0, polygon: excluded) < margin }
    }
}

/// Footprint test for one step of a straight insertion. Edges of the approved
/// footprint that face the front are the opening: the product crosses them on
/// the way in, so neither containment nor the safety margin applies to them
/// until the product has reached its final position. Every other edge is a wall.
private func sweepClearsFootprintWalls(
    _ shelf: ShelfState,
    _ volume: AxisAlignedVolume
) -> Bool {
    guard let polygon = approvedFootprint(shelf) else { return true }
    let margin = max(shelf.geometry?.placementSafetyMarginCM ?? 0, 0)
    let corners = [
        SIMD2(volume.minimum.x, volume.minimum.z),
        SIMD2(volume.maximum.x, volume.minimum.z),
        SIMD2(volume.maximum.x, volume.maximum.z),
        SIMD2(volume.minimum.x, volume.maximum.z)
    ]
    let opening = openingEdgeIndices(of: polygon)
    let walls = polygon.indices.filter { !opening.contains($0) }.map {
        (polygon[$0], polygon[($0 + 1) % polygon.count])
    }
    let crossesWall = corners.indices.contains { index in
        walls.contains {
            segmentsCross(corners[index], corners[(index + 1) % corners.count], $0.0, $0.1)
        }
    }
    let crowdsWall = corners.contains { corner in
        pointInPolygon(corner, polygon: polygon) && walls.contains {
            distanceToSegment(corner, $0.0, $0.1) + 0.0001 < margin
        }
    }
    guard !crossesWall, !crowdsWall else { return false }
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
