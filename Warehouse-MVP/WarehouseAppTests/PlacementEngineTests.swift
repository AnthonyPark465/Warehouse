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
