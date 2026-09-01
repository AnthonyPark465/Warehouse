import XCTest
@testable import WarehouseApp

final class PlacementEngineTests: XCTestCase {
    private let package = PackagePlacementProfile(
        productId: "p1",
        dimensions: PackageDimensions(widthCM: 30, heightCM: 20, depthCM: 25),
        weightKG: 5,
        demandVelocity: 0.7
    )

    func testExcludesLocationsThatAreTooSmall() {
        let location = makeLocation(width: 10, height: 10, depth: 10)
        XCTAssertTrue(PlacementEngine.recommend(
            package: package, locations: [location], scale: .growing
        ).isEmpty)
    }

    func testExcludesLocationsOverWeightCapacity() {
        let location = makeLocation(remainingWeight: 3)
        XCTAssertTrue(PlacementEngine.recommend(
            package: package, locations: [location], scale: .growing
        ).isEmpty)
    }

    func testRotationCanMakePackageFit() {
        let location = makeLocation(width: 27, height: 32, depth: 22)
        let result = PlacementEngine.recommend(
            package: package, locations: [location], scale: .growing
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].orientation.widthCM, 25)
        XCTAssertEqual(result[0].orientation.heightCM, 30)
        XCTAssertEqual(result[0].orientation.depthCM, 20)
    }

    func testRejectsExactFitWithoutHandlingClearance() {
        let location = makeLocation(width: 30, height: 20, depth: 25)
        XCTAssertTrue(PlacementEngine.recommend(
            package: package, locations: [location], scale: .growing
        ).isEmpty)
    }

    func testSmallWarehousePrefersShortTravelWhenOtherInputsMatch() {
        let near = makeLocation(id: "near", distance: 2)
        let far = makeLocation(id: "far", distance: 20)
        let result = PlacementEngine.recommend(
            package: package, locations: [far, near], scale: .small
        )
        XCTAssertEqual(result.first?.location.id, "near")
    }

    private func makeLocation(
        id: String = "loc",
        width: Double = 60,
        height: Double = 60,
        depth: Double = 60,
        remainingWeight: Double = 50,
        distance: Double = 10
    ) -> StorageLocation {
        StorageLocation(
            id: id, label: id, barcode: "LOC-\(id)",
            freeWidthCM: width, freeHeightCM: height, freeDepthCM: depth,
            remainingWeightKG: remainingWeight, walkingDistanceM: distance,
            orderAffinity: 0.5, source: .mapped
        )
    }
}

final class ShelfAwarePlacementEngineTests: XCTestCase {
    func testEmptyShelfProducesFloorPlacementWithPaths() {
        let result = PlacementEngine.calculate(package: package(), shelf: shelf())
        XCTAssertNotNil(result.recommendation)
        XCTAssertEqual(result.recommendation?.position.y, 0)
        XCTAssertFalse(result.recommendation?.insertionPath.isEmpty ?? true)
        XCTAssertFalse(result.recommendation?.removalPath.isEmpty ?? true)
    }

    func testExactFitFailsAfterTolerance() {
        let result = PlacementEngine.calculate(
            package: package(dimensions: .init(widthCM: 60, heightCM: 60, depthCM: 60)),
            shelf: shelf(width: 60, height: 60, depth: 60)
        )
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.outsideBoundary))
    }

    func testRotationMakesProductFit() {
        var metadata = metadata()
        metadata.mayRotateAutomatically = true
        metadata.mustRemainUpright = false
        metadata.permittedRestingFaces = Set(RestingFace.allCases)
        let product = package(dimensions: .init(widthCM: 45, heightCM: 20, depthCM: 30), metadata: metadata)
        let result = PlacementEngine.calculate(package: product, shelf: shelf(width: 35, height: 50, depth: 50))
        XCTAssertNotNil(result.recommendation)
        XCTAssertNotEqual(result.recommendation?.orientedDimensions, product.dimensions)
        XCTAssertNotNil(result.recommendation?.orientation)
    }

    func testForbiddenRestingFaceIsRejected() {
        var rules = metadata()
        rules.mayRotateAutomatically = true
        rules.mustRemainUpright = false
        rules.permittedRestingFaces = [.bottom]
        let result = PlacementEngine.calculate(
            package: package(dimensions: .init(widthCM: 40, heightCM: 10, depthCM: 20), metadata: rules),
            shelf: shelf(width: 25, height: 50, depth: 15)
        )
        XCTAssertNil(result.recommendation)
    }

    func testUprightOnlyProductNeverUsesSideAsRestingFace() {
        var rules = metadata()
        rules.mayRotateAutomatically = true
        rules.mustRemainUpright = true
        rules.permittedRestingFaces = Set(RestingFace.allCases)
        let result = PlacementEngine.calculate(
            package: package(dimensions: .init(widthCM: 40, heightCM: 10, depthCM: 20), metadata: rules),
            shelf: shelf(width: 25, height: 50, depth: 15)
        )
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.allSatisfy { $0.result?.orientation?.restingFace != .left })
    }

    func testEqualDimensionsRemoveDuplicateOrientations() {
        XCTAssertEqual(PackageDimensions(widthCM: 10, heightCM: 10, depthCM: 20).orientations.count, 3)
        XCTAssertEqual(PackageDimensions(widthCM: 10, heightCM: 10, depthCM: 10).orientations.count, 1)
    }

    func testDividerPreventsProductSpanningCompartments() {
        var state = shelf(width: 60, height: 50, depth: 50)
        state.obstacles = [ShelfObstacle(
            id: "divider", compartmentID: "main", kind: .divider,
            volume: volume("divider", 29, 0, 0, 2, 50, 50)
        )]
        let result = PlacementEngine.calculate(
            package: package(dimensions: .init(widthCM: 35, heightCM: 15, depthCM: 20)), shelf: state
        )
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.collision))
    }

    func testFrontLipCanBlockInsertionEvenWhenRearVolumeFits() {
        var state = shelf(width: 40, height: 40, depth: 60)
        state.obstacles = [ShelfObstacle(
            id: "door", compartmentID: "main", kind: .door,
            volume: volume("door", 0, 0, 0, 40, 40, 2)
        )]
        let result = PlacementEngine.calculate(package: package(), shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.noInsertionPath))
    }

    func testLowConfidenceScanRefusesPrecision() {
        var state = shelf()
        state.scanQuality.confidence = 0.3
        let result = PlacementEngine.calculate(package: package(), shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertEqual(result.failureMessage,
            "The shelf scan may be incomplete or inaccurate. Rescan the highlighted area before calculating a placement.")
    }

    func testNearlyVerticalFrontIsInvalid() {
        var state = shelf()
        state.primaryFrontDirection = Vector3D(0, 1, 0)
        XCTAssertNil(PlacementEngine.calculate(package: package(), shelf: state).recommendation)
    }

    func testValidSupportingProductEnablesStackingWhenFloorIsFull() {
        var state = shelf(width: 40, height: 50, depth: 30)
        state.products = [storedProduct(
            id: "support", volume: volume("support", 0, 0, 0, 40, 20, 30),
            stacking: supportingRules(maximumWeight: 20)
        )]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        let result = PlacementEngine.calculate(package: package(metadata: rules), shelf: state)
        XCTAssertEqual(result.recommendation?.supportingProductIDs, ["support"])
        XCTAssertEqual(result.recommendation?.position.y, 20)
    }

    func testNonSupportingProductRejectsStack() {
        var state = shelf(width: 40, height: 50, depth: 30)
        state.products = [storedProduct(id: "base", volume: volume("base", 0, 0, 0, 40, 20, 30),
                                               stacking: .conservative)]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        let result = PlacementEngine.calculate(package: package(metadata: rules), shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.collision))
    }

    func testProductThatDisallowsStackingCannotBePlacedOnSupporter() {
        var state = shelf(width: 40, height: 50, depth: 30)
        state.products = [storedProduct(
            id: "base", volume: volume("base", 0, 0, 0, 40, 20, 30),
            stacking: supportingRules(maximumWeight: 20)
        )]
        let result = PlacementEngine.calculate(package: package(), shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.stackingRule))
    }

    func testFragileSupporterIsRejected() {
        var state = shelf(width: 40, height: 50, depth: 30)
        var fragile = supportingRules(maximumWeight: 20)
        fragile.fragileTopSurface = true
        state.products = [storedProduct(
            id: "base", volume: volume("base", 0, 0, 0, 40, 20, 30), stacking: fragile
        )]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        XCTAssertNil(PlacementEngine.calculate(package: package(metadata: rules), shelf: state).recommendation)
    }

    func testUnknownSupportCapacityIsRejected() {
        var state = shelf(width: 40, height: 50, depth: 30)
        var unknown = supportingRules(maximumWeight: 20)
        unknown.maximumSupportedWeight = nil
        state.products = [storedProduct(
            id: "base", volume: volume("base", 0, 0, 0, 40, 20, 30), stacking: unknown
        )]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        XCTAssertNil(PlacementEngine.calculate(package: package(metadata: rules), shelf: state).recommendation)
    }

    func testCumulativeSupportedWeightIsRejected() {
        var state = shelf(width: 40, height: 60, depth: 30)
        state.products = [
            storedProduct(id: "base", volume: volume("base", 0, 0, 0, 40, 20, 30),
                          stacking: supportingRules(maximumWeight: 8)),
            storedProduct(id: "child", volume: volume("child", 0, 20, 0, 20, 10, 30),
                          stacking: .conservative, supportingProductIDs: ["base"])
        ]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        let result = PlacementEngine.calculate(
            package: package(dimensions: .init(widthCM: 18, heightCM: 10, depthCM: 25), metadata: rules),
            shelf: state
        )
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.weightLimit))
    }

    func testInsufficientFootprintOverlapIsRejected() {
        var state = shelf(width: 30, height: 50, depth: 30)
        state.products = [storedProduct(
            id: "base", volume: volume("base", 0, 0, 0, 18, 20, 30),
            stacking: supportingRules(maximumWeight: 20)
        )]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        let result = PlacementEngine.calculate(
            package: package(dimensions: .init(widthCM: 22, heightCM: 10, depthCM: 25), metadata: rules),
            shelf: state
        )
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.insufficientSupport))
    }

    func testUnsupportedCentreIsRejected() {
        var state = shelf(width: 40, height: 50, depth: 30)
        state.products = [storedProduct(
            id: "base", volume: volume("base", 0, 0, 0, 8, 20, 30),
            stacking: supportingRules(maximumWeight: 20)
        )]
        state.obstacles = [ShelfObstacle(
            id: "floor-blocker", compartmentID: "main", kind: .divider,
            volume: volume("floor-blocker", 8, 0, 0, 32, 20, 30)
        )]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        rules.stacking.requiresFullBaseSupport = false
        rules.stacking.minimumSupportRatio = 0.2
        let result = PlacementEngine.calculate(
            package: package(dimensions: .init(widthCM: 20, heightCM: 10, depthCM: 20), metadata: rules),
            shelf: state
        )
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.unstable))
    }

    func testMaximumTotalStackHeightIsRespected() {
        var state = shelf(width: 40, height: 60, depth: 30)
        var baseRules = supportingRules(maximumWeight: 20)
        baseRules.maximumTotalStackHeight = 25
        state.products = [storedProduct(
            id: "base", volume: volume("base", 0, 0, 0, 40, 20, 30), stacking: baseRules
        )]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        XCTAssertNil(PlacementEngine.calculate(package: package(metadata: rules), shelf: state).recommendation)
    }

    func testSupportWeightLimitIsHardConstraint() {
        var state = shelf(width: 40, height: 50, depth: 30)
        state.products = [storedProduct(
            id: "base", volume: volume("base", 0, 0, 0, 40, 20, 30),
            stacking: supportingRules(maximumWeight: 2)
        )]
        var rules = metadata()
        rules.stacking.canBePlacedOnAnotherProduct = true
        let result = PlacementEngine.calculate(package: package(weight: 5, metadata: rules), shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.weightLimit))
    }

    func testCriticalRearProductCannotBeBlocked() {
        var state = shelf(width: 30, height: 30, depth: 60)
        state.products = [storedProduct(
            id: "critical", volume: volume("critical", 0, 0, 35, 30, 20, 20),
            priority: .critical, stacking: .conservative
        )]
        let result = PlacementEngine.calculate(package: package(), shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.criticalProductBlocked))
    }

    func testSameInputProducesDeterministicRecommendation() {
        let product = package()
        let state = shelf()
        let first = PlacementEngine.calculate(package: product, shelf: state).recommendation
        let second = PlacementEngine.calculate(package: product, shelf: state).recommendation
        XCTAssertEqual(first, second)
    }

    func testUnknownWeightRejectsAutomaticPlacement() {
        let result = PlacementEngine.calculate(package: package(metadata: .conservative), shelf: shelf())
        XCTAssertNil(result.recommendation)
        XCTAssertEqual(result.failureMessage, "Enter a finite positive product weight before automatic placement.")
    }

    func testHighFrequencyProductPrefersFrontCandidate() {
        var rules = metadata()
        rules.expectedRetrievalFrequency = 1
        rules.retrievalPriority = .high
        let result = PlacementEngine.calculate(package: package(metadata: rules), shelf: shelf(depth: 80))
        XCTAssertEqual(result.recommendation?.position.z ?? -1, 0, accuracy: 0.001)
    }

    func testActiveStorageReservationRejectsCalculation() {
        let reservation = PlacementReservation(
            id: "lock", shelfID: "shelf", productID: "other", shelfVersion: 1,
            volume: volume("reserved", 40, 0, 40, 10, 10, 10),
            expiresAt: Date().addingTimeInterval(60), createdBy: "worker"
        )
        let result = PlacementEngine.calculate(
            package: package(), shelf: shelf(), activeReservations: [reservation]
        )
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.activeReservation))
    }

    func testConfirmationUpdatesOccupancyAndVersionAndPreventsReuse() throws {
        let original = shelf()
        let first = try XCTUnwrap(PlacementEngine.calculate(package: package(), shelf: original).recommendation)
        let confirmed = try ShelfStateOperations.confirming(result: first, package: package(), in: original)
        XCTAssertEqual(confirmed.version, original.version + 1)
        XCTAssertEqual(confirmed.products.count, 1)
        let second = try XCTUnwrap(PlacementEngine.calculate(package: package(), shelf: confirmed).recommendation)
        XCTAssertNotEqual(second.position, first.position)
    }

    func testStaleStorageVersionRejectsConfirmation() throws {
        let original = shelf()
        let result = try XCTUnwrap(PlacementEngine.calculate(package: package(), shelf: original).recommendation)
        var stale = original
        stale.version += 1
        XCTAssertThrowsError(try ShelfStateOperations.confirming(result: result, package: package(), in: stale))
    }

    func testSupportingPlacementCannotBeRemovedWhileDependedUpon() {
        var state = shelf()
        state.products = [
            storedProduct(id: "base", volume: volume("base", 0, 0, 0, 30, 10, 30),
                          stacking: supportingRules(maximumWeight: 20)),
            storedProduct(id: "child", volume: volume("child", 0, 10, 0, 20, 10, 20),
                          stacking: .conservative, supportingProductIDs: ["base"])
        ]
        XCTAssertThrowsError(try ShelfStateOperations.removing(id: "base", from: state, expectedVersion: state.version))
    }

    func testOldMetadataDecodesWithConservativeDefaults() throws {
        let decoded = try JSONDecoder().decode(ProductPlacementMetadata.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.weightKG)
        XCTAssertEqual(decoded.permittedRestingFaces, [.bottom])
        XCTAssertFalse(decoded.stacking.canSupportProductsAbove)
        XCTAssertFalse(decoded.stacking.canBePlacedOnAnotherProduct)
    }

    func testOldFirestoreStyleProductUsesConservativePlacementDefaults() throws {
        let json = """
        {"id":"old","name":"Legacy","productCode":"SKU-1","type":"General","totalStock":0,"createdAt":0}
        """
        let product = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        let metadata = product.placementMetadata ?? .conservative
        XCTAssertNil(metadata.weightKG)
        XCTAssertEqual(metadata.permittedRestingFaces, [.bottom])
        XCTAssertFalse(metadata.stacking.canSupportProductsAbove)
    }

    func testOverlappingStoredProductsInvalidateShelfState() {
        var state = shelf()
        state.products = [
            storedProduct(id: "a", volume: volume("a", 0, 0, 0, 20, 20, 20), stacking: .conservative),
            storedProduct(id: "b", volume: volume("b", 10, 0, 0, 20, 20, 20), stacking: .conservative)
        ]
        XCTAssertTrue(ShelfScanValidator.rejectionReasons(for: state).contains(.staleShelfState))
    }

    private func package(
        dimensions: PackageDimensions = .init(widthCM: 20, heightCM: 15, depthCM: 20),
        weight: Double = 5,
        metadata: ProductPlacementMetadata? = nil
    ) -> PackagePlacementProfile {
        var selected = metadata ?? self.metadata()
        if metadata == nil { selected.weightKG = weight }
        return PackagePlacementProfile(
            productId: "new", dimensions: dimensions, weightKG: weight, demandVelocity: 0.5,
            productType: "General", metadata: selected,
            measurementUncertaintyCM: .init(widthCM: 0, heightCM: 0, depthCM: 0)
        )
    }

    private func metadata() -> ProductPlacementMetadata {
        var value = ProductPlacementMetadata.conservative
        value.weightKG = 5
        value.requiredClearanceCM = 0
        value.stacking.minimumSupportRatio = 0.95
        return value
    }

    private func shelf(width: Double = 60, height: Double = 60, depth: Double = 60) -> ShelfState {
        let bounds = volume("bounds", 0, 0, 0, width, height, depth)
        return ShelfState(
            id: "shelf", label: "Shelf A", barcode: "LOC-A", version: 1,
            boundary: bounds,
            coordinateSystem: .init(anchorOrigin: Vector3D(0, 0, 0), widthAxis: Vector3D(1, 0, 0),
                                    upAxis: Vector3D(0, 1, 0), depthAxis: Vector3D(0, 0, 1)),
            primaryFrontDirection: Vector3D(0, 0, 1), secondaryAccessDirections: [],
            compartments: [.init(id: "main", label: "Main", volume: bounds, ratedWeightKG: 100)],
            obstacles: [], products: [],
            scanQuality: .init(hasClosedBoundary: true, missingSurfaceCount: 0, trackingDriftCM: 0,
                               confidence: 0.95, capturedAt: .now),
            ratedWeightKG: 100, updatedAt: .now
        )
    }

    private func volume(_ id: String, _ x: Double, _ y: Double, _ z: Double,
                        _ width: Double, _ height: Double, _ depth: Double) -> AxisAlignedVolume {
        AxisAlignedVolume(id: id, minimum: Vector3D(x, y, z),
                          dimensions: .init(widthCM: width, heightCM: height, depthCM: depth))
    }

    private func supportingRules(maximumWeight: Double) -> StackingRules {
        var rules = StackingRules.conservative
        rules.canSupportProductsAbove = true
        rules.maximumSupportedWeight = maximumWeight
        rules.fragileTopSurface = false
        return rules
    }

    private func storedProduct(
        id: String,
        volume: AxisAlignedVolume,
        priority: RetrievalPriority = .low,
        stacking: StackingRules,
        supportingProductIDs: [String] = []
    ) -> StoredProductPlacement {
        StoredProductPlacement(
            id: id, productID: id, productType: "General", compartmentID: "main",
            volume: volume, weightKG: 5, priority: priority, retrievalFrequency: 0.3,
            stacking: stacking, supportingProductIDs: supportingProductIDs, blockedProductIDs: []
        )
    }
}
