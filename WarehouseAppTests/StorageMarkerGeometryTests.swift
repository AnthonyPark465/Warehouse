import XCTest
import simd
@testable import WarehouseApp

final class StorageMarkerGeometryTests: XCTestCase {
    func testXAxisWallNormalCreatesVerticalBoundaryPlane() throws {
        let boundary = try XCTUnwrap(StorageWallGeometry.boundary(
            hitPositionWorld: Vector3D(0.5, 0.7, 0.1),
            wallNormalWorld: Vector3D(1, 0, 0),
            source: .verticalPlaneAnchor, confidence: 0.9, base: base
        ))

        XCTAssertEqual(boundary.wallPlane?.normal, Vector3D(1, 0, 0))
        XCTAssertEqual(
            simd_dot(try XCTUnwrap(boundary.wallPlane).normal.simd, base.verticalAxisWorld.simd),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(boundary.rawNormal2D, Vector2D(1, 0))
    }

    func testZAxisWallNormalCreatesVerticalBoundaryPlane() throws {
        let boundary = try XCTUnwrap(StorageWallGeometry.boundary(
            hitPositionWorld: Vector3D(0.1, 0.7, 0.4),
            wallNormalWorld: Vector3D(0, 0, 1),
            source: .verticalPlaneAnchor, confidence: 0.9, base: base
        ))

        XCTAssertEqual(boundary.wallPlane?.normal, Vector3D(0, 0, 1))
        XCTAssertEqual(boundary.rawNormal2D, Vector2D(0, 1))
    }

    func testNoisyWallNormalIsProjectedIntoBasePlane() throws {
        let boundary = try XCTUnwrap(StorageWallGeometry.boundary(
            hitPositionWorld: Vector3D(0.5, 0.7, 0.1),
            wallNormalWorld: Vector3D(0.98, 0.12, 0.05),
            source: .localLiDARMesh, confidence: 0.8, base: base
        ))
        let planeNormal = try XCTUnwrap(boundary.wallPlane).normal.simd
        let expected = simd_normalize(SIMD3<Double>(0.98, 0, 0.05))

        XCTAssertEqual(planeNormal.x, expected.x, accuracy: 0.000_001)
        XCTAssertEqual(planeNormal.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(planeNormal.z, expected.z, accuracy: 0.000_001)
        XCTAssertNotEqual(boundary.wallNormalWorld, boundary.wallPlane?.normal)
    }

    func testFloorLikeNormalIsRejectedAsWallBoundary() {
        XCTAssertNil(StorageWallGeometry.boundary(
            hitPositionWorld: Vector3D(0.2, 0, 0.1),
            wallNormalWorld: Vector3D(0.05, 0.99, 0.02),
            source: .verticalPlaneAnchor, confidence: 0.9, base: base
        ))
    }

    func testBoundaryPointIsWallAndBasePlaneIntersection() throws {
        let hit = Vector3D(0.5, 0.8, 0.3)
        let boundary = try XCTUnwrap(StorageWallGeometry.boundary(
            hitPositionWorld: hit, wallNormalWorld: Vector3D(0.98, 0.12, 0.05),
            source: .localLiDARMesh, confidence: 0.8, base: base
        ))
        let plane = try XCTUnwrap(boundary.wallPlane)
        let intersection = base.originWorld.simd
            + base.widthAxisWorld.simd * boundary.rawPoint2D.x
            + base.depthAxisWorld.simd * boundary.rawPoint2D.y

        XCTAssertEqual(
            simd_dot(plane.normal.simd, intersection - hit.simd), 0, accuracy: 0.000_001
        )
        XCTAssertEqual(
            simd_dot(base.verticalAxisWorld.simd, intersection - base.originWorld.simd),
            0,
            accuracy: 0.000_001
        )
    }

    func testBoundaryVisualBasisMapsPlaneNormalAndKeepsPlaneVertical() throws {
        let visual = try XCTUnwrap(StorageWallGeometry.visualBasis(
            boundaryNormalWorld: Vector3D(1, 0, 0),
            baseNormalWorld: Vector3D(0, 1, 0)
        ))

        XCTAssertEqual(visual.normalAxisWorld, Vector3D(1, 0, 0))
        XCTAssertEqual(visual.upAxisWorld, Vector3D(0, 1, 0))
        XCTAssertEqual(
            simd_dot(visual.rightAxisWorld.simd, visual.normalAxisWorld.simd),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            simd_dot(visual.upAxisWorld.simd, visual.normalAxisWorld.simd),
            0,
            accuracy: 0.000_001
        )
    }

    func testFourWallPlanesCreateExpectedFootprintAndAutomaticInterior() throws {
        let result = try StorageMarkerGeometryBuilder.build(boundaries: rectangleWalls())

        XCTAssertEqual(result.boundaries.count, 4)
        XCTAssertEqual(result.raw.count, 4)
        XCTAssertEqual(result.interior.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(result.interior.y, 0, accuracy: 0.000_001)
        XCTAssertTrue(StorageMarkerGeometryBuilder.contains(result.interior, polygon: result.raw))
        for boundary in result.boundaries {
            XCTAssertGreaterThanOrEqual(
                boundary.insideSign * simd_dot(
                    boundary.rawNormal2D.simd,
                    result.interior - boundary.rawPoint2D.simd
                ),
                0
            )
        }
    }

    func testExactlyFourUserPlacedBoundaryMarkersAreRequired() {
        XCTAssertThrowsError(try StorageMarkerGeometryBuilder.build(
            boundaries: Array(rectangleWalls().prefix(3))
        )) { error in
            XCTAssertEqual(error as? StorageMarkerGeometryError, .wrongBoundaryCount)
        }
        XCTAssertThrowsError(try StorageMarkerGeometryBuilder.build(
            boundaries: rectangleWalls() + [
                line(point: SIMD2(0.7, 0), normal: SIMD2(1, 0))
            ]
        )) { error in
            XCTAssertEqual(error as? StorageMarkerGeometryError, .wrongBoundaryCount)
        }
    }

    func testWallMarkerHeightDoesNotChangeFloorBoundaryAndHitIsNotProjected() throws {
        let low = try XCTUnwrap(StorageWallGeometry.boundary(
            hitPositionWorld: Vector3D(0.5, 0.3, -0.2),
            wallNormalWorld: Vector3D(1, 0, 0),
            source: .verticalPlaneAnchor, confidence: 0.9, base: base
        ))
        let high = try XCTUnwrap(StorageWallGeometry.boundary(
            hitPositionWorld: Vector3D(0.5, 0.9, 0.25),
            wallNormalWorld: Vector3D(1, 0, 0),
            source: .localLiDARMesh, confidence: 0.8, base: base
        ))

        XCTAssertEqual(low.rawPoint2D.x, high.rawPoint2D.x, accuracy: 0.000_001)
        XCTAssertEqual(low.rawPoint2D.y, high.rawPoint2D.y, accuracy: 0.000_001)
        XCTAssertEqual(low.hitPositionWorld?.y, 0.3)
        XCTAssertEqual(high.hitPositionWorld?.y, 0.9)
        XCTAssertNotEqual(low.hitPositionWorld, high.hitPositionWorld)
    }

    func testSixtyCentimetreVolumeStartsAtSelectedBasePlane() throws {
        let selectedBase = StorageBasePlaneCoordinateSystem(
            originWorld: Vector3D(3, 2, 4),
            widthAxisWorld: Vector3D(1, 0, 0),
            depthAxisWorld: Vector3D(0, 0, 1),
            verticalAxisWorld: Vector3D(0, 1, 0)
        )
        let outline = try XCTUnwrap(StorageVolumeGeometry.outline(
            footprint2D: [Vector2D(0, 0), Vector2D(1.2, 0),
                          Vector2D(1.2, 0.6), Vector2D(0, 0.6)],
            base: selectedBase,
            heightCM: 60
        ))

        XCTAssertEqual(outline.heightMetres, 0.60, accuracy: 0.000_001)
        XCTAssertTrue(outline.bottomVerticesWorld.allSatisfy { abs($0.y - 2) < 0.000_001 })
        XCTAssertTrue(outline.topVerticesWorld.allSatisfy { abs($0.y - 2.6) < 0.000_001 })
        for index in outline.bottomVerticesWorld.indices {
            let extrusion = outline.topVerticesWorld[index].simd
                - outline.bottomVerticesWorld[index].simd
            XCTAssertEqual(extrusion.x, 0, accuracy: 0.000_001)
            XCTAssertEqual(extrusion.y, 0.60, accuracy: 0.000_001)
            XCTAssertEqual(extrusion.z, 0, accuracy: 0.000_001)
        }
    }

    func testIrregularPolygonProducesMatchingOutlineAreaAndVolume() throws {
        let footprint = [
            Vector2D(0, 0), Vector2D(2, 0), Vector2D(1.5, 1), Vector2D(0, 1)
        ]
        let outline = try XCTUnwrap(StorageVolumeGeometry.outline(
            footprint2D: footprint, base: base, heightCM: 60
        ))

        XCTAssertEqual(outline.footprint2D, footprint)
        XCTAssertEqual(outline.bottomVerticesWorld.count, footprint.count)
        XCTAssertEqual(outline.topVerticesWorld.count, footprint.count)
        XCTAssertEqual(outline.floorAreaSquareMetres, 1.75, accuracy: 0.000_001)
        XCTAssertEqual(outline.volumeCubicMetres, 1.05, accuracy: 0.000_001)
        XCTAssertNil(outline.rectangularDimensions)
    }

    func testChangingHeightUpdatesTopAndVolumeButNotBottom() throws {
        let footprint = [
            Vector2D(0, 0), Vector2D(1, 0), Vector2D(1, 0.5), Vector2D(0, 0.5)
        ]
        let short = try XCTUnwrap(StorageVolumeGeometry.outline(
            footprint2D: footprint, base: base, heightCM: 60
        ))
        let tall = try XCTUnwrap(StorageVolumeGeometry.outline(
            footprint2D: footprint, base: base, heightCM: 90
        ))

        XCTAssertEqual(short.bottomVerticesWorld, tall.bottomVerticesWorld)
        XCTAssertNotEqual(short.topVerticesWorld, tall.topVerticesWorld)
        XCTAssertEqual(short.volumeCubicMetres, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(tall.volumeCubicMetres, 0.45, accuracy: 0.000_001)
        let dimensions = try XCTUnwrap(short.rectangularDimensions)
        XCTAssertEqual(dimensions.widthMetres, 1, accuracy: 0.000_001)
        XCTAssertEqual(dimensions.depthMetres, 0.5, accuracy: 0.000_001)
    }

    func testRemovingBoundaryInvalidatesVolumePreview() throws {
        let geometry = try StorageMarkerGeometryBuilder.build(boundaries: rectangleWalls())
        var draft = draft(from: geometry)
        XCTAssertNotNil(draft.volumeOutline(useCorrectedFootprint: true, heightCM: 60))

        draft.boundaries.removeLast()

        XCTAssertNil(draft.volumeOutline(useCorrectedFootprint: true, heightCM: 60))
    }

    func testNearRightAngleWallsProduceCorrectionWhileRawEvidenceIsPreserved() throws {
        let walls = [
            wall(hit: Vector3D(-0.51, 0.4, 0), normal: Vector3D(0.999, 0, 0.045)),
            wall(hit: Vector3D(0.49, 0.8, 0), normal: Vector3D(0.998, 0, 0.055)),
            wall(hit: Vector3D(0, 0.3, -0.41), normal: Vector3D(-0.035, 0, 0.999)),
            wall(hit: Vector3D(0, 0.9, 0.39), normal: Vector3D(-0.045, 0, 0.999))
        ]
        let result = try StorageMarkerGeometryBuilder.build(boundaries: walls)

        XCTAssertNotNil(result.corrected)
        XCTAssertEqual(result.boundaries.map(\.hitPositionWorld), walls.map(\.hitPositionWorld))
        XCTAssertTrue(result.boundaries.allSatisfy { $0.correctedNormal2D != nil })
    }

    func testIntentionalObliqueWallsAreNotForcedToRectangle() throws {
        let walls = [
            line(point: SIMD2(-0.55, 0), normal: SIMD2(1, 0)),
            line(point: SIMD2(0.55, 0), normal: SIMD2(1, 0)),
            line(point: SIMD2(0, -0.45), normal: simd_normalize(SIMD2(0.35, 0.94))),
            line(point: SIMD2(0, 0.45), normal: simd_normalize(SIMD2(-0.35, 0.94)))
        ]
        let result = try StorageMarkerGeometryBuilder.build(boundaries: walls)

        XCTAssertNil(result.corrected)
        XCTAssertTrue(StorageMarkerGeometryBuilder.contains(result.interior, polygon: result.raw))
    }

    func testInvalidWallCombinationsAndDuplicateWallsAreRejected() {
        XCTAssertThrowsError(try StorageMarkerGeometryBuilder.build(boundaries: [
            line(point: SIMD2(-0.5, 0), normal: SIMD2(1, 0)),
            line(point: SIMD2(-0.499, 0), normal: SIMD2(1, 0)),
            line(point: SIMD2(0, -0.4), normal: SIMD2(0, 1)),
            line(point: SIMD2(0, 0.4), normal: SIMD2(0, 1))
        ])) { error in
            XCTAssertEqual(error as? StorageMarkerGeometryError, .duplicateBoundary)
        }
        XCTAssertThrowsError(try StorageMarkerGeometryBuilder.build(boundaries: [
            line(point: SIMD2(-0.6, 0), normal: SIMD2(1, 0)),
            line(point: SIMD2(-0.2, 0), normal: SIMD2(1, 0)),
            line(point: SIMD2(0.2, 0), normal: SIMD2(1, 0)),
            line(point: SIMD2(0.6, 0), normal: SIMD2(1, 0))
        ]))
    }

    func testGeneralizedBoundaryEvidencePersists() throws {
        let geometry = try StorageMarkerGeometryBuilder.build(boundaries: rectangleWalls())
        let record = draft(from: geometry).record(approvedCorrected: true, heightCM: 45)
        let decoded = try JSONDecoder().decode(
            StorageMarkerMeasurementRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.boundaries.count, 4)
        XCTAssertEqual(decoded.boundaries.map(\.source), [
            .verticalPlaneAnchor, .verticalPlaneAnchor,
            .verticalPlaneAnchor, .verticalPlaneAnchor
        ])
        XCTAssertTrue(decoded.isValidForPlacement)
    }

    func testNewPersistenceContainsBasePlaneAndOnlyFourUserMarkers() throws {
        let geometry = try StorageMarkerGeometryBuilder.build(boundaries: rectangleWalls())
        let record = draft(from: geometry).record(approvedCorrected: true, heightCM: 45)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )

        XCTAssertNotNil(object["basePlaneOriginWorld"])
        XCTAssertNil(object["surfacePointWorld"])
        XCTAssertNil(object["interiorReference2D"])
        XCTAssertNil(object["surfaceMarker"])
        XCTAssertNil(object["baseMarker"])
        XCTAssertEqual((object["boundaries"] as? [Any])?.count, 4)
    }

    func testLegacyPersistedBaseOriginAndInteriorFieldStillDecode() throws {
        let geometry = try StorageMarkerGeometryBuilder.build(boundaries: rectangleWalls())
        let record = draft(from: geometry).record(approvedCorrected: true, heightCM: 45)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        object["schemaVersion"] = 2
        object["surfacePointWorld"] = object.removeValue(forKey: "basePlaneOriginWorld")
        object["interiorReference2D"] = ["x": geometry.interior.x, "y": geometry.interior.y]

        let decoded = try JSONDecoder().decode(
            StorageMarkerMeasurementRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.basePlaneOriginWorld, record.basePlaneOriginWorld)
        XCTAssertEqual(decoded.boundaries.count, 4)
        XCTAssertTrue(decoded.isValidForPlacement)
    }

    func testMarkerVolumeFlowsIntoPlacementAndEnforcesHeight() throws {
        let geometry = try StorageMarkerGeometryBuilder.build(boundaries: rectangleWalls())
        let draft = draft(from: geometry)
        let record = draft.record(approvedCorrected: true, heightCM: 45)
        let centimetres = record.approvedFootprint2D.map { Vector2D($0.x * 100, $0.y * 100) }
        let space = ScannedSpaceGeometry(
            id: draft.id, geometryType: .openSpace, surfaceType: .shelf,
            rawBoundary2D: record.rawFootprint2D.map { Vector2D($0.x * 100, $0.y * 100) },
            suggestedBoundary2D: record.correctedFootprint2D?.map { Vector2D($0.x * 100, $0.y * 100) },
            approvedBoundary2D: centimetres, excludedRegions2D: [],
            localOrigin: draft.basePlaneOriginWorld, localXAxis: draft.localXAxisWorld,
            localYAxis: draft.localDepthAxisWorld, localVerticalAxis: draft.verticalAxisWorld,
            bottomPlane: CodablePlane(origin: draft.basePlaneOriginWorld, normal: draft.verticalAxisWorld),
            topDefinition: .manualLimitCM(45), heightCM: 45,
            accessDirections: [Vector3D(0, 0, 1)],
            confidence: .init(baseSurface: 0.9, boundary: 0.9, corners: 0.9,
                              walls: nil, surfaceEdges: 0.9, height: 1),
            approval: .approved, geometryVersion: 9,
            createdAt: .now, updatedAt: .now,
            measurementMethod: .markerBoundaries,
            markerMeasurement: record
        )
        let shelf = try OpenSpacePlacementAdapter.shelfState(from: space)
        let valid = PlacementEngine.calculate(package: package(heightCM: 20), shelf: shelf)
        XCTAssertNotNil(valid.recommendation)
        XCTAssertLessThanOrEqual(
            valid.recommendation!.position.y + valid.recommendation!.orientedDimensions.heightCM,
            45
        )

        let tooTall = PlacementEngine.calculate(package: package(heightCM: 46), shelf: shelf)
        XCTAssertNil(tooTall.recommendation)
        XCTAssertTrue(tooTall.evaluations.flatMap(\.rejectionReasons).contains(.outsideBoundary))
    }

    func testWallAlignmentAngleIsTheSmallestTurnThatSquaresTheFootprint() throws {
        func rectangle(turnedBy degrees: Double) -> [SIMD2<Double>] {
            let angle = degrees * .pi / 180
            return [SIMD2(-0.3, -0.2), SIMD2(0.3, -0.2), SIMD2(0.3, 0.2), SIMD2(-0.3, 0.2)].map {
                SIMD2($0.x * cos(angle) - $0.y * sin(angle), $0.x * sin(angle) + $0.y * cos(angle))
            }
        }
        func degrees(_ polygon: [SIMD2<Double>]) throws -> Double {
            try XCTUnwrap(StorageMarkerGeometryBuilder.wallAlignmentAngle(of: polygon)) * 180 / .pi
        }

        XCTAssertEqual(try degrees(rectangle(turnedBy: 0)), 0, accuracy: 0.000_001)
        XCTAssertEqual(try degrees(rectangle(turnedBy: 17)), 17, accuracy: 0.000_001)
        XCTAssertEqual(try degrees(rectangle(turnedBy: -30)), -30, accuracy: 0.000_001)
        // Past 45° the nearer alignment is the other way round.
        XCTAssertEqual(try degrees(rectangle(turnedBy: 70)), -20, accuracy: 0.000_001)
        // The order the corners are listed in makes no difference.
        XCTAssertEqual(try degrees(rectangle(turnedBy: 17).reversed()), 17, accuracy: 0.000_001)
        XCTAssertNil(StorageMarkerGeometryBuilder.wallAlignmentAngle(of: []))
    }

    func testAligningToWallsSquaresTheFootprintWithoutMovingItInTheWorld() throws {
        let captured = try turnedDraft(degrees: 20)
        let aligned = captured.alignedToWalls(useCorrectedFootprint: true)

        // Every edge of the stored footprint now runs along a local axis.
        let footprint = try XCTUnwrap(aligned.correctedFootprint2D).map(\.simd)
        for index in footprint.indices {
            let edge = footprint[(index + 1) % footprint.count] - footprint[index]
            XCTAssertEqual(min(abs(edge.x), abs(edge.y)), 0, accuracy: 0.000_001)
        }
        // The axes turned by the capture angle and are still a right-handed
        // horizontal pair.
        let width = aligned.localXAxisWorld.simd, depth = aligned.localDepthAxisWorld.simd
        XCTAssertEqual(simd_length(width), 1, accuracy: 0.000_001)
        XCTAssertEqual(simd_dot(width, depth), 0, accuracy: 0.000_001)
        XCTAssertEqual(
            abs(simd_dot(depth, captured.localDepthAxisWorld.simd)),
            cos(20 * Double.pi / 180),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            simd_dot(simd_cross(width, aligned.verticalAxisWorld.simd), depth),
            simd_dot(
                simd_cross(captured.localXAxisWorld.simd, captured.verticalAxisWorld.simd),
                captured.localDepthAxisWorld.simd
            ),
            accuracy: 0.000_001
        )
        // The outline is where it was.
        let before = try XCTUnwrap(captured.volumeOutline(useCorrectedFootprint: true, heightCM: 40))
        let after = try XCTUnwrap(aligned.volumeOutline(useCorrectedFootprint: true, heightCM: 40))
        for (a, b) in zip(before.bottomVerticesWorld, after.bottomVerticesWorld) {
            XCTAssertEqual(simd_distance(a.simd, b.simd), 0, accuracy: 0.000_001)
        }
        XCTAssertEqual(after.floorAreaSquareMetres, before.floorAreaSquareMetres, accuracy: 0.000_001)
        // Wall evidence is untouched, and the record still passes validation.
        XCTAssertEqual(aligned.boundaries.map(\.hitPositionWorld), captured.boundaries.map(\.hitPositionWorld))
        XCTAssertEqual(aligned.boundaries.map(\.wallPlane), captured.boundaries.map(\.wallPlane))
        XCTAssertTrue(aligned.record(approvedCorrected: true, heightCM: 40).isValidForPlacement)
        // Already aligned: nothing changes.
        let again = aligned.alignedToWalls(useCorrectedFootprint: true)
        for (a, b) in zip(again.correctedFootprint2D ?? [], aligned.correctedFootprint2D ?? []) {
            XCTAssertEqual(simd_distance(a.simd, b.simd), 0, accuracy: 0.000_001)
        }
    }

    func testProductIsPlacedSquareToTheWallsHoweverThePhoneWasHeld() throws {
        // A 60 × 40 cm area scanned with the phone turned 20° from the walls.
        let captured = try turnedDraft(degrees: 20)
        let unaligned = try shelf(from: captured)
        let aligned = try shelf(from: captured.alignedToWalls(useCorrectedFootprint: true))

        // Unaligned, the local bounding box is larger than the area itself:
        // products are set along axes that are not the walls'.
        XCTAssertGreaterThan(
            unaligned.boundary.dimensions.widthCM * unaligned.boundary.dimensions.depthCM,
            60 * 40 * 1.3
        )
        // Aligned, the bounding box is the area.
        let dimensions = [aligned.boundary.dimensions.widthCM, aligned.boundary.dimensions.depthCM].sorted()
        XCTAssertEqual(dimensions[0], 40, accuracy: 0.01)
        XCTAssertEqual(dimensions[1], 60, accuracy: 0.01)

        // A 55 × 35 cm product only fits when set square to the walls.
        let wide = PackagePlacementProfile(
            productId: "wide",
            dimensions: .init(widthCM: 55, heightCM: 10, depthCM: 35),
            weightKG: 1, demandVelocity: 0.5,
            metadata: package(heightCM: 10).metadata
        )
        var rotatable = wide
        rotatable.metadata.mayRotateAutomatically = true
        XCTAssertNil(PlacementEngine.calculate(package: rotatable, shelf: unaligned).recommendation)
        XCTAssertNotNil(PlacementEngine.calculate(package: rotatable, shelf: aligned).recommendation)
    }

    /// Four walls of a 60 × 40 cm rectangle, measured in capture axes turned
    /// `degrees` from the walls.
    private func turnedDraft(degrees: Double) throws -> StorageMarkerDraft {
        let angle = degrees * .pi / 180
        func normal(_ x: Double, _ y: Double) -> SIMD2<Double> {
            SIMD2(x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle))
        }
        let geometry = try StorageMarkerGeometryBuilder.build(boundaries: [
            line(point: normal(-0.3, 0), normal: normal(1, 0)),
            line(point: normal(0.3, 0), normal: normal(1, 0)),
            line(point: normal(0, -0.2), normal: normal(0, 1)),
            line(point: normal(0, 0.2), normal: normal(0, 1))
        ])
        XCTAssertNotNil(geometry.corrected)
        return draft(from: geometry)
    }

    private func shelf(from draft: StorageMarkerDraft) throws -> ShelfState {
        let record = draft.record(approvedCorrected: true, heightCM: 45)
        func centimetres(_ points: [Vector2D]) -> [Vector2D] {
            points.map { Vector2D($0.x * 100, $0.y * 100) }
        }
        return try OpenSpacePlacementAdapter.shelfState(from: ScannedSpaceGeometry(
            id: draft.id, geometryType: .openSpace, surfaceType: .shelf,
            rawBoundary2D: centimetres(record.rawFootprint2D),
            suggestedBoundary2D: record.correctedFootprint2D.map(centimetres),
            approvedBoundary2D: centimetres(record.approvedFootprint2D), excludedRegions2D: [],
            localOrigin: draft.basePlaneOriginWorld, localXAxis: draft.localXAxisWorld,
            localYAxis: draft.localDepthAxisWorld, localVerticalAxis: draft.verticalAxisWorld,
            bottomPlane: CodablePlane(origin: draft.basePlaneOriginWorld, normal: draft.verticalAxisWorld),
            topDefinition: .manualLimitCM(45), heightCM: 45,
            accessDirections: [Vector3D(0, 0, 1)],
            confidence: .init(baseSurface: 0.9, boundary: 0.9, corners: 0.9,
                              walls: nil, surfaceEdges: 0.9, height: 1),
            approval: .approved, geometryVersion: 9,
            createdAt: .now, updatedAt: .now,
            measurementMethod: .markerBoundaries,
            markerMeasurement: record
        ))
    }

    private var base: StorageBasePlaneCoordinateSystem {
        .init(
            originWorld: Vector3D(0, 0, 0),
            widthAxisWorld: Vector3D(1, 0, 0),
            depthAxisWorld: Vector3D(0, 0, 1),
            verticalAxisWorld: Vector3D(0, 1, 0)
        )
    }

    private func rectangleWalls() -> [StorageBoundary] {
        [
            wall(hit: Vector3D(-0.5, 0.3, 0), normal: Vector3D(1, 0, 0)),
            wall(hit: Vector3D(0.5, 0.9, 0), normal: Vector3D(1, 0, 0)),
            wall(hit: Vector3D(0, 0.5, -0.4), normal: Vector3D(0, 0, 1)),
            wall(hit: Vector3D(0, 0.7, 0.4), normal: Vector3D(0, 0, 1))
        ]
    }

    private func wall(hit: Vector3D, normal: Vector3D) -> StorageBoundary {
        StorageWallGeometry.boundary(
            hitPositionWorld: hit, wallNormalWorld: normal,
            source: .verticalPlaneAnchor, confidence: 0.9, base: base
        )!
    }

    private func line(point: SIMD2<Double>, normal: SIMD2<Double>) -> StorageBoundary {
        let worldNormal = Vector3D(normal.x, 0, normal.y)
        return StorageBoundary(
            id: UUID(), rawPoint2D: Vector2D(point), rawNormal2D: Vector2D(normal),
            correctedNormal2D: nil, insideSign: 1,
            hitPositionWorld: Vector3D(point.x, 0.5, point.y),
            wallNormalWorld: worldNormal,
            wallPlane: CodablePlane(origin: Vector3D(point.x, 0.5, point.y), normal: worldNormal),
            source: .verticalPlaneAnchor, confidence: 0.9
        )
    }

    private func draft(from geometry: StorageMarkerGeometryResult) -> StorageMarkerDraft {
        StorageMarkerDraft(
            id: UUID(), selectedPlaneIdentifier: UUID(),
            basePlaneOriginWorld: Vector3D(0, 0, 0),
            localXAxisWorld: Vector3D(1, 0, 0),
            localDepthAxisWorld: Vector3D(0, 0, 1),
            verticalAxisWorld: Vector3D(0, 1, 0),
            horizontalDeviationDegrees: 1,
            boundaries: geometry.boundaries,
            rawFootprint2D: geometry.raw.map(Vector2D.init),
            correctedFootprint2D: geometry.corrected?.map(Vector2D.init),
            correctionAppliedAutomatically: false,
            correctionMaximumMovementMetres: geometry.maximumCorrection,
            confidence: 0.9,
            deviceHasLiDAR: true
        )
    }

    private func package(heightCM: Double) -> PackagePlacementProfile {
        PackagePlacementProfile(
            productId: "marker-product",
            dimensions: .init(widthCM: 20, heightCM: heightCM, depthCM: 20),
            weightKG: 1, demandVelocity: 0.5,
            metadata: ProductPlacementMetadata(
                weightKG: 1, retrievalPriority: .normal, expectedRetrievalFrequency: 0.5,
                expirationUrgency: 0, isFragile: false, permittedRestingFaces: [.bottom],
                mustRemainUpright: true, mayRotateAutomatically: false, requiredClearanceCM: 0,
                stacking: .conservative, quantityArrangement: .singleUnit
            )
        )
    }
}
