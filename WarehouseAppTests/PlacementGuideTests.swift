import SceneKit
import XCTest
@testable import WarehouseApp

final class PlacementGuideTests: XCTestCase {
    func testInstructionsUseTheAreaNameAndTheViewersLeftAndRight() throws {
        let state = try OpenSpacePlacementAdapter.shelfState(from: space(name: "  Back room floor "))
        let placement = try XCTUnwrap(PlacementEngine.calculate(package: book(), shelf: state).recommendation)

        XCTAssertEqual(state.label, "Back room floor")
        XCTAssertTrue(placement.instructions.hasPrefix("Place the product in Back room floor. "), placement.instructions)
        // Shelf-local width grows toward the viewer's left, so the low-x side is the right side.
        let fromLowX = placement.position.x - state.boundary.minimum.x
        let fromHighX = state.boundary.maximum.x - (placement.position.x + placement.orientedDimensions.widthCM)
        XCTAssertTrue(
            placement.instructions.contains(fromLowX < fromHighX ? "from the right side" : "from the left side"),
            placement.instructions
        )
    }

    func testUnnamedAreaWithUnknownSurfaceGetsAReadableLabel() throws {
        let state = try OpenSpacePlacementAdapter.shelfState(from: space(name: nil))
        XCTAssertEqual(state.label, "Storage area")
        XCTAssertEqual(state.compartments.first?.label, "Open area")

        var legacy = state
        legacy.label = "Scanned Not sure"
        XCTAssertEqual(legacy.displayLabel, "Storage area")
        let placement = try XCTUnwrap(PlacementEngine.calculate(package: book(), shelf: legacy).recommendation)
        XCTAssertFalse(placement.instructions.contains("Not sure"), placement.instructions)
    }

    func testGuideSceneDrawsTheProductInsideTheStorageVolumeAsSeenFromTheFront() throws {
        let state = try OpenSpacePlacementAdapter.shelfState(from: space(name: nil))
        let placement = try XCTUnwrap(PlacementEngine.calculate(package: book(), shelf: state).recommendation)
        let scene = PlacementGuideScene.make(shelf: state, placement: placement)
        let product = try XCTUnwrap(
            scene.rootNode.childNode(withName: PlacementGuideScene.productName, recursively: true)
        )
        let (low, high) = product.boundingBox
        let halfWidth = Float(state.boundary.dimensions.widthCM / 200)
        let halfDepth = Float(state.boundary.dimensions.depthCM / 200)
        // The outline tubes drawn around the box add a little to its bounds.
        let slack: Float = 0.02

        XCTAssertGreaterThanOrEqual(low.x, -halfWidth - slack)
        XCTAssertLessThanOrEqual(high.x, halfWidth + slack)
        XCTAssertGreaterThanOrEqual(low.z, -halfDepth - slack)
        XCTAssertLessThanOrEqual(high.z, halfDepth + slack)
        XCTAssertGreaterThanOrEqual(low.y, -slack)
        XCTAssertLessThanOrEqual(high.y, Float(state.boundary.dimensions.heightCM / 100) + slack)

        // The front (smallest local depth) is nearest the camera, and local width is mirrored.
        let localCentreX = placement.position.x + placement.orientedDimensions.widthCM / 2
        let localCentreZ = placement.position.z + placement.orientedDimensions.depthCM / 2
        let boundsCentreX = state.boundary.minimum.x + state.boundary.dimensions.widthCM / 2
        let boundsCentreZ = state.boundary.minimum.z + state.boundary.dimensions.depthCM / 2
        XCTAssertEqual((low.x + high.x) / 2, Float(-(localCentreX - boundsCentreX) / 100), accuracy: 0.001)
        XCTAssertEqual((low.z + high.z) / 2, Float(-(localCentreZ - boundsCentreZ) / 100), accuracy: 0.001)
        let camera = try XCTUnwrap(
            scene.rootNode.childNode(withName: PlacementGuideScene.cameraName, recursively: true)
        )
        XCTAssertGreaterThan(camera.simdPosition.z, halfDepth)
    }

    private func book() -> PackagePlacementProfile {
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = 0.5
        metadata.mayRotateAutomatically = true
        return PackagePlacementProfile(
            productId: "book",
            dimensions: .init(widthCM: 21.8, heightCM: 1.6, depthCM: 27.9),
            weightKG: 0.5,
            demandVelocity: 0.5,
            metadata: metadata,
            measurementUncertaintyCM: .init(widthCM: 0, heightCM: 0, depthCM: 0)
        )
    }

    /// A slightly skewed 137.9 x 162 cm floor area, 50 cm high, as a hand-placed scan produces.
    private func space(name: String?) -> ScannedSpaceGeometry {
        let angle = 3.0 * .pi / 180
        let boundary = [(0.0, 0.0), (137.9, 0.0), (137.9, 162.0), (0.0, 162.0)].map {
            Vector2D($0.0 * cos(angle) - $0.1 * sin(angle), $0.0 * sin(angle) + $0.1 * cos(angle))
        }
        return ScannedSpaceGeometry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000077")!,
            geometryType: .openSpace, surfaceType: .unknown,
            rawBoundary2D: boundary, suggestedBoundary2D: boundary,
            approvedBoundary2D: boundary, excludedRegions2D: [],
            localOrigin: Vector3D(0, 0, 0), localXAxis: Vector3D(1, 0, 0),
            localYAxis: Vector3D(0, 0, 1), localVerticalAxis: Vector3D(0, 1, 0),
            bottomPlane: CodablePlane(origin: Vector3D(0, 0, 0), normal: Vector3D(0, 1, 0)),
            topDefinition: .manualLimitCM(50), heightCM: 50,
            accessDirections: [Vector3D(0, 0, 1)],
            confidence: SpaceConfidence(baseSurface: 0.9, boundary: 0.9, corners: 0.9,
                walls: nil, surfaceEdges: 0.8, height: 0.9),
            approval: .approved, geometryVersion: 2,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
            name: name
        )
    }
}
