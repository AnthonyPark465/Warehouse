import XCTest
@testable import WarehouseApp

final class SpaceGeometryTests: XCTestCase {
    func testApprovedSpaceRoundTripsWithoutChangingScale() throws {
        let value = space()
        try SpaceGeometryValidator.validate(value)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ScannedSpaceGeometry.self, from: data)

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.heightCM, 120)
        XCTAssertEqual(decoded.approvedBoundary2D[1].x, 100)
    }

    func testInvalidManualHeightsAndUnapprovedGeometryAreRejected() {
        var value = space()
        value.heightCM = .nan
        XCTAssertThrowsError(try SpaceGeometryValidator.validate(value))
        value = space()
        value.approval = .draft
        XCTAssertThrowsError(try SpaceGeometryValidator.validate(value))
        value = space()
        value.heightCM = 0
        XCTAssertThrowsError(try SpaceGeometryValidator.validate(value))
    }

    func testReversedWindingAndNegativeLocalCoordinatesRemainValid() throws {
        var value = space()
        let boundary = [
            Vector2D(-50, -50), Vector2D(-50, 50),
            Vector2D(50, 50), Vector2D(50, -50)
        ]
        value.rawBoundary2D = boundary
        value.approvedBoundary2D = boundary

        try SpaceGeometryValidator.validate(value)
        XCTAssertEqual(try OpenSpacePlacementAdapter.shelfState(from: value).boundary.minimum.x, -50)
    }

    func testConcavePolygonIsSupportedButSelfIntersectingPolygonIsRejected() throws {
        var concave = space()
        let concaveBoundary = [
            Vector2D(0, 0), Vector2D(100, 0), Vector2D(100, 100),
            Vector2D(60, 100), Vector2D(60, 40), Vector2D(40, 40),
            Vector2D(40, 100), Vector2D(0, 100)
        ]
        concave.rawBoundary2D = concaveBoundary
        concave.approvedBoundary2D = concaveBoundary
        try SpaceGeometryValidator.validate(concave)

        var crossing = space()
        let crossingBoundary = [
            Vector2D(0, 0), Vector2D(100, 100), Vector2D(0, 100),
            Vector2D(100, 0), Vector2D(50, -10)
        ]
        crossing.rawBoundary2D = crossingBoundary
        crossing.approvedBoundary2D = crossingBoundary
        XCTAssertThrowsError(try SpaceGeometryValidator.validate(crossing)) {
            XCTAssertEqual($0 as? SpaceGeometryError, .invalidBoundary)
        }
    }

    func testExcludedRegionOutsideBoundaryIsRejected() {
        var value = space()
        value.excludedRegions2D = [[
            Vector2D(90, 90), Vector2D(110, 90),
            Vector2D(110, 110), Vector2D(90, 110)
        ]]
        XCTAssertThrowsError(try SpaceGeometryValidator.validate(value)) {
            XCTAssertEqual($0 as? SpaceGeometryError, .invalidExcludedRegion)
        }
    }

    func testPlacementNeverCrossesExcludedRegion() throws {
        var value = space()
        value.excludedRegions2D = [[
            Vector2D(20, 20), Vector2D(80, 20),
            Vector2D(80, 80), Vector2D(20, 80)
        ]]
        let state = try OpenSpacePlacementAdapter.shelfState(from: value)
        let package = PackagePlacementProfile(
            productId: "large", dimensions: .init(widthCM: 88, heightCM: 20, depthCM: 88),
            weightKG: 1, demandVelocity: 0.5,
            metadata: ProductPlacementMetadata(
                weightKG: 1, retrievalPriority: .normal, expectedRetrievalFrequency: 0.5,
                expirationUrgency: 0, isFragile: false, permittedRestingFaces: [.bottom],
                mustRemainUpright: true, mayRotateAutomatically: false, requiredClearanceCM: 0,
                stacking: .conservative, quantityArrangement: .singleUnit
            )
        )
        let result = PlacementEngine.calculate(package: package, shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.flatMap(\.rejectionReasons).contains(.outsideBoundary))
    }

    func testOpenSpaceAdapterPreservesSurfaceHeightAndTypeLabel() throws {
        let state = try OpenSpacePlacementAdapter.shelfState(from: space(surface: .tabletop))
        XCTAssertEqual(state.boundary.dimensions.heightCM, 120)
        XCTAssertEqual(state.label, "Scanned Tabletop")
        XCTAssertEqual(state.geometry?.measurementMetadata.unit, .centimetres)
    }

    func testNewlyScannedEmptyRectangularSpaceAcceptsNormalProduct() throws {
        let state = try OpenSpacePlacementAdapter.shelfState(from: space())
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = 2
        metadata.requiredClearanceCM = 2
        let product = PackagePlacementProfile(
            productId: "normal-product",
            dimensions: .init(widthCM: 30, heightCM: 20, depthCM: 25),
            weightKG: 2,
            demandVelocity: 0.5,
            metadata: metadata,
            measurementUncertaintyCM: .init(widthCM: 1, heightCM: 1, depthCM: 1)
        )

        XCTAssertNotNil(PlacementEngine.calculate(package: product, shelf: state).recommendation)
    }

    func testSkewedScannedQuadrilateralStillAdmitsStraightInsertion() throws {
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = 0.5
        metadata.mayRotateAutomatically = true
        let book = PackagePlacementProfile(
            productId: "book",
            dimensions: .init(widthCM: 21.8, heightCM: 1.6, depthCM: 27.9),
            weightKG: 0.5,
            demandVelocity: 0.5,
            metadata: metadata,
            measurementUncertaintyCM: .init(widthCM: 0, heightCM: 0, depthCM: 0)
        )
        // A hand-placed boundary is never exactly aligned with the local axes.
        for degrees in [-5.0, -2, -0.5, 0, 0.5, 1, 2, 5, 10] {
            let angle = degrees * .pi / 180
            let quadrilateral = [(0.0, 0.0), (137.9, 0.0), (137.9, 162.0), (0.0, 162.0)].map {
                Vector2D($0.0 * cos(angle) - $0.1 * sin(angle), $0.0 * sin(angle) + $0.1 * cos(angle))
            }
            let state = try OpenSpacePlacementAdapter.shelfState(from: space(boundary: quadrilateral))
            let result = PlacementEngine.calculate(package: book, shelf: state)
            XCTAssertNotNil(result.recommendation, "\(degrees)°: \(result.failureMessage ?? "")")
        }
    }

    func testPocketBehindFootprintWallHasNoStraightInsertionPath() throws {
        // The notch at x 40...100, z 30...60 closes off the rear strip from the front.
        let footprint = [
            Vector2D(0, 0), Vector2D(100, 0), Vector2D(100, 30), Vector2D(40, 30),
            Vector2D(40, 60), Vector2D(100, 60), Vector2D(100, 100), Vector2D(0, 100)
        ]
        let state = try OpenSpacePlacementAdapter.shelfState(from: space(boundary: footprint))
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = 2
        metadata.mayRotateAutomatically = false
        let product = PackagePlacementProfile(
            productId: "wide-product",
            dimensions: .init(widthCM: 45, heightCM: 10, depthCM: 31),
            weightKG: 2,
            demandVelocity: 0.5,
            metadata: metadata,
            measurementUncertaintyCM: .init(widthCM: 0, heightCM: 0, depthCM: 0)
        )

        let result = PlacementEngine.calculate(package: product, shelf: state)
        XCTAssertNil(result.recommendation)
        XCTAssertTrue(result.evaluations.contains { $0.rejectionReasons == [.noInsertionPath] })
    }

    func testSlantedSideWallIsNotTreatedAsPartOfTheOpening() throws {
        // A sheared area: both side walls lean 60 cm to one side over 100 cm of depth.
        let footprint = [Vector2D(0, 0), Vector2D(40, 0), Vector2D(100, 100), Vector2D(60, 100)]
        let state = try OpenSpacePlacementAdapter.shelfState(from: space(boundary: footprint))
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = 2
        metadata.mayRotateAutomatically = false
        let product = PackagePlacementProfile(
            productId: "small-product",
            dimensions: .init(widthCM: 18, heightCM: 10, depthCM: 18),
            weightKG: 2,
            demandVelocity: 0.5,
            metadata: metadata,
            measurementUncertaintyCM: .init(widthCM: 0, heightCM: 0, depthCM: 0)
        )

        let result = PlacementEngine.calculate(package: product, shelf: state)
        XCTAssertNotNil(result.recommendation, result.failureMessage ?? "")
        // Pushed straight in from the 0...40 cm front edge, nothing can end up beyond x = 40.
        for placement in result.evaluations.compactMap(\.result) {
            XCTAssertLessThanOrEqual(placement.position.x + placement.orientedDimensions.widthCM, 40)
        }
        XCTAssertTrue(result.evaluations.contains { $0.rejectionReasons == [.noInsertionPath] })
    }

    func testProductTouchingSafetyMarginExactlyFits() throws {
        let state = try OpenSpacePlacementAdapter.shelfState(from: space())
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = 1
        metadata.requiredClearanceCM = 1
        let product = PackagePlacementProfile(
            productId: "exact-margin",
            dimensions: .init(widthCM: 96, heightCM: 10, depthCM: 96),
            weightKG: 1,
            demandVelocity: 0.5,
            metadata: metadata,
            measurementUncertaintyCM: .init(widthCM: 1, heightCM: 1, depthCM: 1)
        )
        var tolerance = PlacementToleranceConfiguration.warehouse
        tolerance.minimumLinearToleranceCM = 0
        tolerance.percentageTolerance = 0
        tolerance.lowConfidenceMultiplier = 1

        XCTAssertEqual(PlacementEngine.usableDimensions(of: state).widthCM, 98)
        XCTAssertNotNil(PlacementEngine.calculate(
            package: product, shelf: state, tolerance: tolerance
        ).recommendation)
    }

    func testCornerMeasurementProvenanceRoundTrips() throws {
        var value = space()
        value.geometryVersion = 3
        value.measurementMethod = .lidarCornerPlacement
        value.measuredCorners = [MeasuredSpaceCornerRecord(
            id: UUID(),
            originalWorldPosition: Vector3D(0.1, 0.02, 0.2),
            projectedWorldPosition: Vector3D(0.1, 0, 0.2),
            localBoundaryPositionMetres: Vector2D(0.1, 0.2),
            sampleCount: 12,
            positionalVariance: 0.000_004,
            depthVariance: 0.000_006,
            projectionDistance: 0.02,
            measurementDistance: 1.4,
            measurementSource: .smoothedSceneDepth,
            trackingState: .normal,
            confidenceScore: 0.91,
            timestamp: Date(timeIntervalSince1970: 2)
        )]

        let decoded = try JSONDecoder().decode(
            ScannedSpaceGeometry.self,
            from: JSONEncoder().encode(value)
        )
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.measurementMethod, .lidarCornerPlacement)
        XCTAssertEqual(decoded.measuredCorners?.first?.sampleCount, 12)
    }

    private func space(
        surface: SpaceSurfaceType = .floor,
        boundary: [Vector2D] = [Vector2D(0, 0), Vector2D(100, 0), Vector2D(100, 100), Vector2D(0, 100)]
    ) -> ScannedSpaceGeometry {
        return ScannedSpaceGeometry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            geometryType: .openSpace, surfaceType: surface,
            rawBoundary2D: boundary, suggestedBoundary2D: boundary,
            approvedBoundary2D: boundary, excludedRegions2D: [],
            localOrigin: Vector3D(0, 0, 0), localXAxis: Vector3D(1, 0, 0),
            localYAxis: Vector3D(0, 0, 1), localVerticalAxis: Vector3D(0, 1, 0),
            bottomPlane: CodablePlane(origin: Vector3D(0, 0, 0), normal: Vector3D(0, 1, 0)),
            topDefinition: .manualLimitCM(120), heightCM: 120,
            accessDirections: [Vector3D(0, 0, 1)],
            confidence: SpaceConfidence(baseSurface: 0.9, boundary: 0.9, corners: 0.9,
                walls: nil, surfaceEdges: 0.8, height: 0.9),
            approval: .approved, geometryVersion: 2,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
