import XCTest
@testable import WarehouseApp

final class LiDARVoxelFusionEngineTests: XCTestCase {
    private let configuration = LiDARFusionConfiguration.smallObject

    func testSixCentimetreCylinderOnTableMeasuresSixBySixByEight() throws {
        let measurement = try measure(
            frames: repeatedFrames(cylinderPoints() + tablePoints())
        )

        assertCylinderDimensions(measurement.dimensionsCM)
        XCTAssertGreaterThan(measurement.averageObservationsPerVoxel, 5)
        XCTAssertEqual(measurement.supportPlaneY, 0, accuracy: configuration.voxelSize)
    }

    func testPolygonalRegionIsOnlyACropAndDoesNotBecomeProductDimensions() throws {
        let engine = makePolygonEngine(
            halfWidth: 0.12,
            upperOffset: 0.20
        )
        for frame in repeatedFrames(cylinderPoints() + tablePoints(extent: 0.11)) {
            engine.integrate(framePoints: frame)
        }

        let measurement = try XCTUnwrap(engine.measurement())
        assertCylinderDimensions(measurement.dimensionsCM)
        XCTAssertLessThan(measurement.dimensionsCM.length, 8)
        XCTAssertLessThan(measurement.dimensionsCM.height, 10)
        XCTAssertFalse(measurement.touchesRegionBoundary)
    }

    func testFiveCentimetreProductHeightIsSupportedInsideTallerRegion() throws {
        let engine = makePolygonEngine(
            halfWidth: 0.10,
            upperOffset: 0.15
        )
        for frame in repeatedFrames(
            cylinderPoints(radius: 0.025, height: 0.05)
                + tablePoints(extent: 0.09)
        ) {
            engine.integrate(framePoints: frame)
        }

        let measurement = try XCTUnwrap(engine.measurement())
        XCTAssertEqual(measurement.dimensionsCM.length, 5, accuracy: voxelToleranceCM)
        XCTAssertEqual(measurement.dimensionsCM.width, 5, accuracy: voxelToleranceCM)
        XCTAssertEqual(measurement.dimensionsCM.height, 5, accuracy: voxelToleranceCM)
    }

    func testPolygonalRegionRejectsOutsidePointsBeforeFusion() {
        let engine = makePolygonEngine()
        let result = engine.integrate(framePoints: [
            SIMD3<Float>(0, 0.04, 0),
            SIMD3<Float>(0.20, 0.04, 0),
            SIMD3<Float>(0, 0.20, 0)
        ])

        XCTAssertEqual(result.acceptedPointCount, 1)
        XCTAssertEqual(result.rejectedOutsideVolumeCount, 2)
        XCTAssertEqual(engine.voxelCount, 1)
    }

    func testNearbyLargeObjectDoesNotMateriallyChangeSelectedCylinder() throws {
        let cylinderAndTable = cylinderPoints() + tablePoints()
        let baseline = try measure(frames: repeatedFrames(cylinderAndTable))
        let nearby = boxSurfacePoints(
            size: SIMD3<Float>(0.16, 0.09, 0.12),
            centre: SIMD3<Float>(0.15, 0.045, 0),
            yaw: 0
        )
        let withNearby = try measure(
            frames: repeatedFrames(cylinderAndTable + nearby),
            halfExtents: SIMD3<Float>(0.085, 0.10, 0.085)
        )

        assertCylinderDimensions(withNearby.dimensionsCM)
        assertDimensions(
            withNearby.dimensionsCM,
            equalTo: baseline.dimensionsCM,
            accuracy: voxelToleranceCM
        )
        XCTAssertLessThan(withNearby.dimensionsCM.length, 8)
    }

    func testTransientOneFrameOutliersDoNotAffectDimensions() throws {
        var frames = repeatedFrames(cylinderPoints() + tablePoints())
        frames[0] += [
            SIMD3<Float>(0.065, 0.12, 0.06),
            SIMD3<Float>(-0.065, 0.11, -0.06),
            SIMD3<Float>(0.07, 0.04, -0.065)
        ]

        let measurement = try measure(frames: frames)
        assertCylinderDimensions(measurement.dimensionsCM)
    }

    func testHorizontalTableIsRemovedButRemainsLowerHeightBoundary() throws {
        let measurement = try measure(
            frames: repeatedFrames(cylinderPoints() + tablePoints(extent: 0.20)),
            halfExtents: SIMD3<Float>(0.10, 0.10, 0.10)
        )

        XCTAssertEqual(measurement.supportPlaneY, 0, accuracy: configuration.voxelSize)
        XCTAssertEqual(measurement.dimensionsCM.height, 8, accuracy: voxelToleranceCM)
        XCTAssertLessThan(measurement.dimensionsCM.length, 8)
        XCTAssertLessThan(measurement.dimensionsCM.width, 8)
    }

    func testRotatedRectangularObjectUsesOrientedBounds() throws {
        let object = boxSurfacePoints(
            size: SIMD3<Float>(0.08, 0.06, 0.04),
            centre: SIMD3<Float>(0, 0.03, 0),
            yaw: .pi * 35 / 180
        )
        let measurement = try measure(
            frames: repeatedFrames(object + tablePoints())
        )

        XCTAssertEqual(measurement.dimensionsCM.length, 8, accuracy: voxelToleranceCM)
        XCTAssertEqual(measurement.dimensionsCM.width, 4, accuracy: voxelToleranceCM)
        XCTAssertEqual(measurement.dimensionsCM.height, 6, accuracy: voxelToleranceCM)
    }

    func testSuddenDimensionJumpIsFrozenThenRecoveryKeepsStableResult() throws {
        var stabilizer = LiDARMeasurementStabilizer(configuration: configuration)
        let cylinder = ObjectDimensions(length: 6, width: 6, height: 8)
        let nearbyJump = ObjectDimensions(length: 16, width: 12, height: 9)

        XCTAssertEqual(stabilizer.consider(cylinder), .warmingUp)
        XCTAssertEqual(stabilizer.consider(cylinder), .warmingUp)
        XCTAssertEqual(stabilizer.consider(cylinder), .accepted(cylinder))

        let decision = stabilizer.consider(nearbyJump)
        guard case .frozen(let frozen, let message) = decision else {
            return XCTFail("A one-estimate jump must be frozen")
        }
        XCTAssertEqual(frozen, cylinder)
        XCTAssertEqual(
            message,
            "Possible nearby object detected. Keep other objects outside the scan box."
        )
        XCTAssertEqual(stabilizer.consider(cylinder), .accepted(cylinder))
        XCTAssertEqual(stabilizer.stable, cylinder)
    }

    func testLockedVolumeRejectsPointsBeforeFusion() {
        let engine = makeEngine()
        let result = engine.integrate(framePoints: [
            SIMD3<Float>(0, 0.04, 0),
            SIMD3<Float>(0.30, 0.04, 0),
            SIMD3<Float>(0, 0.04, -0.30)
        ])

        XCTAssertEqual(result.acceptedPointCount, 1)
        XCTAssertEqual(result.rejectedOutsideVolumeCount, 2)
        XCTAssertEqual(engine.voxelCount, 1)
    }

    func testRequiresMultiFrameConsensus() {
        let engine = makeEngine()
        engine.integrate(framePoints: cylinderPoints() + tablePoints())

        XCTAssertNil(engine.measurement())
    }

    private var voxelToleranceCM: Double {
        Double(configuration.voxelSize * 2 * 100)
    }

    private func makeEngine(
        halfExtents: SIMD3<Float> = SIMD3<Float>(0.07, 0.10, 0.07)
    ) -> LiDARVoxelFusionEngine {
        let engine = LiDARVoxelFusionEngine(configuration: configuration)
        engine.lockSelection(
            volume: LiDARScanVolume(
                centre: SIMD3<Float>(0, 0.05, 0),
                halfExtents: halfExtents
            ),
            seed: SIMD3<Float>(0.03, 0.04, 0)
        )
        return engine
    }

    private func makePolygonEngine(
        halfWidth: Float = 0.10,
        upperOffset: Float = 0.15
    ) -> LiDARVoxelFusionEngine {
        let engine = LiDARVoxelFusionEngine(configuration: configuration)
        let region = LiDARPolygonalPrism(
            origin: .zero,
            axisU: SIMD3<Float>(1, 0, 0),
            axisV: SIMD3<Float>(0, 0, 1),
            normal: SIMD3<Float>(0, 1, 0),
            polygon: [
                SIMD2<Float>(-halfWidth, -halfWidth),
                SIMD2<Float>(halfWidth, -halfWidth),
                SIMD2<Float>(halfWidth, halfWidth),
                SIMD2<Float>(-halfWidth, halfWidth)
            ],
            lowerOffset: -0.005,
            upperOffset: upperOffset
        )
        engine.lockSelection(
            region: .polygonalPrism(region),
            seed: SIMD3<Float>(0, 0.02, 0)
        )
        return engine
    }

    private func measure(
        frames: [[SIMD3<Float>]],
        halfExtents: SIMD3<Float> = SIMD3<Float>(0.07, 0.10, 0.07)
    ) throws -> LiDARFusionMeasurement {
        let engine = makeEngine(halfExtents: halfExtents)
        for frame in frames {
            engine.integrate(framePoints: frame)
        }
        return try XCTUnwrap(engine.measurement())
    }

    private func repeatedFrames(
        _ points: [SIMD3<Float>],
        count: Int = 7
    ) -> [[SIMD3<Float>]] {
        Array(repeating: points, count: count)
    }

    private func cylinderPoints(
        radius: Float = 0.03,
        height: Float = 0.08
    ) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        let angleCount = 96
        let verticalCount = Int(height / 0.0025)

        for verticalIndex in 0...verticalCount {
            let y = Float(verticalIndex) * height / Float(verticalCount)
            for angleIndex in 0..<angleCount {
                let angle = Float(angleIndex) * 2 * .pi / Float(angleCount)
                points.append(
                    SIMD3<Float>(cos(angle) * radius, y, sin(angle) * radius)
                )
            }
        }
        for radialIndex in 0...12 {
            let currentRadius = radius * Float(radialIndex) / 12
            for angleIndex in 0..<angleCount {
                let angle = Float(angleIndex) * 2 * .pi / Float(angleCount)
                points.append(
                    SIMD3<Float>(
                        cos(angle) * currentRadius,
                        height,
                        sin(angle) * currentRadius
                    )
                )
            }
        }
        return points
    }

    private func tablePoints(extent: Float = 0.14) -> [SIMD3<Float>] {
        let steps = Int(extent / 0.004)
        return (-steps...steps).flatMap { xIndex in
            (-steps...steps).map { zIndex in
                SIMD3<Float>(
                    Float(xIndex) * 0.004,
                    0,
                    Float(zIndex) * 0.004
                )
            }
        }
    }

    private func boxSurfacePoints(
        size: SIMD3<Float>,
        centre: SIMD3<Float>,
        yaw: Float
    ) -> [SIMD3<Float>] {
        let spacing: Float = 0.0025
        let xSteps = max(Int(size.x / spacing), 1)
        let ySteps = max(Int(size.y / spacing), 1)
        let zSteps = max(Int(size.z / spacing), 1)
        var points: [SIMD3<Float>] = []

        func append(_ local: SIMD3<Float>) {
            let rotated = SIMD3<Float>(
                cos(yaw) * local.x + sin(yaw) * local.z,
                local.y,
                -sin(yaw) * local.x + cos(yaw) * local.z
            )
            points.append(rotated + centre)
        }

        for xIndex in 0...xSteps {
            let x = -size.x / 2 + size.x * Float(xIndex) / Float(xSteps)
            for yIndex in 0...ySteps {
                let y = -size.y / 2 + size.y * Float(yIndex) / Float(ySteps)
                append(SIMD3<Float>(x, y, -size.z / 2))
                append(SIMD3<Float>(x, y, size.z / 2))
            }
        }
        for zIndex in 0...zSteps {
            let z = -size.z / 2 + size.z * Float(zIndex) / Float(zSteps)
            for yIndex in 0...ySteps {
                let y = -size.y / 2 + size.y * Float(yIndex) / Float(ySteps)
                append(SIMD3<Float>(-size.x / 2, y, z))
                append(SIMD3<Float>(size.x / 2, y, z))
            }
        }
        for xIndex in 0...xSteps {
            let x = -size.x / 2 + size.x * Float(xIndex) / Float(xSteps)
            for zIndex in 0...zSteps {
                let z = -size.z / 2 + size.z * Float(zIndex) / Float(zSteps)
                append(SIMD3<Float>(x, -size.y / 2, z))
                append(SIMD3<Float>(x, size.y / 2, z))
            }
        }
        return points
    }

    private func assertCylinderDimensions(
        _ dimensions: ObjectDimensions,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(dimensions.length, 6, accuracy: voxelToleranceCM, file: file, line: line)
        XCTAssertEqual(dimensions.width, 6, accuracy: voxelToleranceCM, file: file, line: line)
        XCTAssertEqual(dimensions.height, 8, accuracy: voxelToleranceCM, file: file, line: line)
    }

    private func assertDimensions(
        _ lhs: ObjectDimensions,
        equalTo rhs: ObjectDimensions,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.length, rhs.length, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
    }
}
