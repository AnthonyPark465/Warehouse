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

    func testUnknownMetadataWarnsAndUsesShelfSurface() {
        let result = PlacementEngine.calculate(package: package(metadata: .conservative), shelf: shelf())
        XCTAssertTrue(result.recommendation?.warnings.contains(where: { $0.contains("Weight information is missing") }) == true)
        XCTAssertTrue(result.recommendation?.supportingProductIDs.isEmpty == true)
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
        stacking: StackingRules
    ) -> StoredProductPlacement {
        StoredProductPlacement(
            id: id, productID: id, productType: "General", compartmentID: "main",
            volume: volume, weightKG: 5, priority: priority, retrievalFrequency: 0.3,
            stacking: stacking, supportingProductIDs: [], blockedProductIDs: []
        )
    }
}
