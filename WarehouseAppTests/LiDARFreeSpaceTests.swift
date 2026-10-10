import XCTest
import simd
@testable import WarehouseApp

/// Free-space evidence and the ablation switches, on SYNTHETIC input (see
/// `SyntheticScanFixtures.swift`). They verify logic and reported evidence;
/// they are not evidence of behaviour on a device.
final class LiDARFreeSpaceTests: XCTestCase {
    private let cell = SyntheticVoxelShapes.voxelSize

    // MARK: Grid

    func testRayMarksTheVoxelsItCrossesAndStopsShortOfItsHit() throws {
        var grid = try makeGrid()
        grid.integrate(
            camera: centre(-30, 2, 2),
            points: [centre(10, 2, 2)],
            stopShort: 2 * cell,
            frame: 1
        )

        XCTAssertEqual(grid.rayCount, 1)
        XCTAssertEqual(grid.frameCount(at: key(-15, 2, 2)), 1)
        XCTAssertEqual(grid.frameCount(at: key(5, 2, 2)), 1)
        // Within the margin of the hit, and the hit itself: not free space.
        XCTAssertEqual(grid.frameCount(at: key(9, 2, 2)), 0)
        XCTAssertEqual(grid.frameCount(at: key(10, 2, 2)), 0)
        // Beyond the hit, and beside the ray.
        XCTAssertEqual(grid.frameCount(at: key(12, 2, 2)), 0)
        XCTAssertEqual(grid.frameCount(at: key(5, 3, 2)), 0)
    }

    func testAFrameCountsOncePerVoxelAndFramesAccumulate() throws {
        var grid = try makeGrid()
        // Two rays down the same row in one frame.
        grid.integrate(
            camera: centre(-30, 2, 2),
            points: [centre(10, 2, 2), centre(14, 2, 2)],
            stopShort: 2 * cell,
            frame: 1
        )
        XCTAssertEqual(grid.frameCount(at: key(0, 2, 2)), 1)
        let observed = grid.observedVoxelCount

        grid.integrate(camera: centre(-30, 2, 2), points: [centre(10, 2, 2)], stopShort: 2 * cell, frame: 2)
        XCTAssertEqual(grid.frameCount(at: key(0, 2, 2)), 2)
        // A second look at the same voxels observes nothing new.
        XCTAssertEqual(grid.observedVoxelCount, observed)
        XCTAssertEqual(grid.rayCount, 3)

        grid.removeAll()
        XCTAssertEqual(grid.frameCount(at: key(0, 2, 2)), 0)
        XCTAssertEqual(grid.rayCount, 0)
        XCTAssertEqual(grid.observedVoxelCount, 0)
    }

    func testDiagonalRayMarksAConnectedLineOfVoxels() throws {
        var grid = try makeGrid()
        grid.integrate(
            camera: centre(-12, -9, -7),
            points: [centre(14, 11, 9)],
            stopShort: 0.001,
            frame: 1
        )

        // Every voxel centre sampled densely along the ray was marked.
        let start = centre(-12, -9, -7)
        let end = centre(14, 11, 9)
        for step in 0...400 {
            let point = start + (end - start) * (Float(step) / 400) * 0.9
            XCTAssertEqual(
                grid.frameCount(at: .containing(point, cellSize: cell)),
                1,
                "step \(step)"
            )
        }
    }

    func testRayThroughCellCornersMarksOnlyTheCellsItEnters() throws {
        var grid = try makeGrid()
        // Along the diagonal of a row of cells: every boundary is crossed at
        // a cell edge. The cells beside the diagonal are only touched.
        grid.integrate(camera: centre(0, 0, 0), points: [centre(4, 4, 0)], stopShort: 0, frame: 1)

        for step in Int32(0)...3 {
            XCTAssertEqual(grid.frameCount(at: key(step, step, 0)), 1, "\(step)")
            XCTAssertEqual(grid.frameCount(at: key(step + 1, step, 0)), 0, "\(step)")
            XCTAssertEqual(grid.frameCount(at: key(step, step + 1, 0)), 0, "\(step)")
        }
        XCTAssertEqual(grid.observedVoxelCount, 5)
    }

    func testRayThatStartsAndEndsInsideOneCellMarksOnlyThatCell() throws {
        var grid = try makeGrid()
        // Wholly inside cell (0, 0, 0), ending just short of its far face.
        let start = SIMD3<Float>(0.9995, 0.5, 0.5) * cell
        let end = SIMD3<Float>(0.99975, 0.5, 0.5) * cell
        grid.integrate(camera: start, points: [end], stopShort: 0, frame: 1)

        XCTAssertEqual(grid.frameCount(at: key(0, 0, 0)), 1)
        XCTAssertEqual(grid.frameCount(at: key(1, 0, 0)), 0)
        XCTAssertEqual(grid.observedVoxelCount, 1)
    }

    func testCellsAreTheVoxelsFusionAddresses() throws {
        // A coarse cell size whose multiples are not exact in binary, and a
        // region away from the origin: the worst case for agreement between
        // the grid's indexing and `LiDARVoxelKey.containing`.
        let coarse: Float = 0.1
        var grid = try XCTUnwrap(LiDARFreeSpaceGrid(
            region: .box(LiDARScanVolume(
                centre: SIMD3<Float>(0.75, 0.75, 0.75),
                halfExtents: SIMD3<Float>(repeating: 0.45)
            )),
            cellSize: coarse,
            margin: 0,
            maximumCellCount: 10_000
        ))
        // Parallel to the x axis at y = z = 0.5, which sits on a boundary.
        let camera = SIMD3<Float>(0.35, 0.5, 0.5)
        grid.integrate(camera: camera, points: [SIMD3<Float>(1.15, 0.5, 0.5)], stopShort: 0, frame: 1)

        let expected = LiDARVoxelKey.containing(camera, cellSize: coarse)
        XCTAssertEqual(grid.frameCount(at: expected), 1)
        XCTAssertEqual(
            grid.frameCount(at: LiDARVoxelKey(x: expected.x, y: expected.y - 1, z: expected.z)),
            0
        )
        XCTAssertEqual(
            grid.frameCount(at: LiDARVoxelKey(x: expected.x, y: expected.y, z: expected.z - 1)),
            0
        )
    }

    func testRaysThatMissTheRegionOrEndBeforeItAreIgnored() throws {
        var grid = try makeGrid()
        grid.integrate(
            camera: SIMD3<Float>(1, 1, 1),
            points: [
                SIMD3<Float>(1, 1, 2),
                // Aimed at the region but returns long before reaching it.
                SIMD3<Float>(0.9, 0.9, 0.9),
                SIMD3<Float>(.nan, 0, 0)
            ],
            stopShort: 2 * cell,
            frame: 1
        )

        XCTAssertEqual(grid.rayCount, 0)
        XCTAssertEqual(grid.observedVoxelCount, 0)
        XCTAssertEqual(grid.frameCount(at: key(1_000, 0, 0)), 0)
    }

    func testRegionNeedingTooManyCellsIsNotTracked() {
        XCTAssertNil(LiDARFreeSpaceGrid(
            region: boxRegion(halfExtent: 0.06),
            cellSize: cell,
            margin: 0,
            maximumCellCount: 1_000
        ))
    }

    // MARK: Component selection

    func testAGapSeenThroughIsNotBridgedButAnUnobservedOneIs() {
        // Two strips of five voxels with one empty voxel between them. Each
        // is too small to be an object; together they reach object size.
        let strips = column(x: 0) + column(x: 2)
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.minimumStableVoxelCount = 8
        configuration.maximumSeedDistance = 1

        let unobserved = select(strips, configuration)
        XCTAssertEqual(unobserved.mode, .expanded)
        XCTAssertEqual(unobserved.selected?.voxelCount, 10)

        let neverEmpty = select(strips, configuration) { _ in false }
        XCTAssertEqual(neverEmpty.selectedIndices, unobserved.selectedIndices)
        XCTAssertEqual(neverEmpty.freeSpaceBlockedBridgeCount, 0)

        let seenThrough = select(strips, configuration) { $0.x == 1 }
        XCTAssertEqual(seenThrough.failure, .insufficientConnectedGeometry)
        // Five facing pairs, each met from both sides.
        XCTAssertEqual(seenThrough.freeSpaceBlockedBridgeCount, 10)
    }

    func testOneEmptyVoxelAnywhereOnTheLineBlocksALongerBridge() {
        let strips = column(x: 0) + column(x: 4)
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.minimumStableVoxelCount = 8
        configuration.maximumSeedDistance = 1
        configuration.connectivityRadiusInVoxels = 4

        XCTAssertEqual(select(strips, configuration).selected?.voxelCount, 10)
        XCTAssertEqual(
            select(strips, configuration) { $0.x == 3 }.failure,
            .insufficientConnectedGeometry
        )
        // Empty space off the line between the strips does not block.
        XCTAssertEqual(
            select(strips, configuration) { $0.y > 10 }.selected?.voxelCount,
            10
        )
    }

    func testTheLineBetweenTwoVoxelsCoversEveryVoxelItCrossesInBothDirections() {
        func cells(_ delta: (Int32, Int32, Int32)) -> Set<LiDARVoxelKey> {
            Set(LiDARComponentSelector.voxelsBetween(delta).map { key($0.0, $0.1, $0.2) })
        }
        XCTAssertEqual(cells((2, 0, 0)), [key(1, 0, 0)])
        XCTAssertEqual(cells((1, 1, 1)), [])
        // Through a shared edge: only the voxel entered, not the two touched.
        XCTAssertEqual(cells((2, 2, 0)), [key(1, 1, 0)])
        // A knight's move crosses two voxels.
        XCTAssertEqual(cells((2, 1, 0)), [key(1, 0, 0), key(1, 1, 0)])
        XCTAssertEqual(cells((5, 0, 0)).count, 4)

        // From the far end the same voxels are crossed.
        for delta: (Int32, Int32, Int32) in [(2, 1, 0), (3, -2, 1), (4, 1, -3), (0, 5, 2), (-3, 3, 1)] {
            let forward = cells(delta)
            let backward = Set(cells((-delta.0, -delta.1, -delta.2)).map {
                key($0.x + delta.0, $0.y + delta.1, $0.z + delta.2)
            })
            XCTAssertEqual(forward, backward, "\(delta)")
            XCTAssertFalse(forward.contains(key(0, 0, 0)))
            XCTAssertFalse(forward.contains(key(delta.0, delta.1, delta.2)))
        }
    }

    func testABridgeIsBlockedWhicheverEndItIsTestedFrom() {
        // A at (0,0,0) and B at (2,1,0); their line crosses (1,0,0) and (1,1,0).
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.minimumStableVoxelCount = 2
        configuration.maximumSeedDistance = 1
        configuration.connectivityRadiusInVoxels = 3
        let pair = [key(0, 0, 0), key(2, 1, 0)]

        XCTAssertEqual(select(pair, configuration).selected?.voxelCount, 2)
        for empty in [key(1, 0, 0), key(1, 1, 0)] {
            let result = select(pair, configuration) { $0 == empty }
            XCTAssertEqual(result.failure, .insufficientConnectedGeometry, "\(empty)")
            XCTAssertEqual(result.freeSpaceBlockedBridgeCount, 2, "\(empty)")
        }
    }

    func testUnconditionalConnectivityAbsorbsWhatConditionalConnectivityLeavesOut() {
        // A plate that is object-sized on its own, and a fragment one empty
        // voxel away.
        var keys: [LiDARVoxelKey] = []
        for x in Int32(0)...2 { for y in Int32(0)...2 { keys.append(key(x, y, 0)) } }
        let plateCount = keys.count
        keys += (Int32(0)...2).map { key(4, $0, 0) }
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.minimumStableVoxelCount = plateCount
        configuration.maximumSeedDistance = 1

        let conditional = select(keys, configuration)
        XCTAssertEqual(conditional.mode, .strict)
        XCTAssertEqual(conditional.selected?.voxelCount, plateCount)
        XCTAssertEqual(conditional.looseFragmentVoxelCount, 3)

        configuration.connectivityIsConditional = false
        let unconditional = select(keys, configuration)
        XCTAssertEqual(unconditional.mode, .expanded)
        XCTAssertEqual(unconditional.selected?.voxelCount, plateCount + 3)
    }

    // MARK: Pipeline

    func testGatingIsOffByDefaultAndLeavesNoEvidence() {
        let report = scan(SyntheticScene(objects: [box], supportHalfExtent: 0.10), .smallObject)

        XCTAssertFalse(LiDARFusionConfiguration.smallObject.freeSpaceGatingEnabled)
        XCTAssertNil(report.evidence.freeSpace)
        XCTAssertNotNil(report.evidence.components)
        XCTAssertNil(report.evidence.components?.freeSpaceBlockedBridgeCount)
    }

    func testGatingDoesNotChangeADenselyScannedObject() throws {
        let scene = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        let plain = scan(scene, .smallObject)
        let gated = scan(scene, gating())

        XCTAssertEqual(gated.reportedDimensionsCM, plain.reportedDimensionsCM)
        XCTAssertEqual(gated.decision, plain.decision)
        let freeSpace = try XCTUnwrap(gated.evidence.freeSpace)
        XCTAssertTrue(freeSpace.wasAvailable)
        XCTAssertGreaterThan(freeSpace.rayCount, 0)
        XCTAssertGreaterThan(freeSpace.observedVoxelCount, 0)
        XCTAssertEqual(gated.evidence.components?.freeSpaceBlockedBridgeCount, 0)
    }

    func testGatingWithoutCameraPositionsIsReportedUnavailableAndChangesNothing() throws {
        let scene = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        var plan = occludedPlan()
        plan.reportsCameraPosition = false
        let plain = scan(scene, .smallObject, plan: plan)
        let gated = scan(scene, gating(), plan: plan)

        XCTAssertEqual(gated.reportedDimensionsCM, plain.reportedDimensionsCM)
        XCTAssertEqual(try XCTUnwrap(gated.evidence.freeSpace).wasAvailable, false)
        XCTAssertNil(gated.evidence.components?.freeSpaceBlockedBridgeCount)
    }

    func testFreeSpaceSeparatesTwoPatchyObjectsThatAWiderReachAloneJoins() throws {
        var target = box
        target.patches = (0.012, 0.009)
        var neighbour = target
        neighbour.baseCentre = SIMD3<Float>(0.08 + 0.012, 0, 0)
        let scene = SyntheticScene(objects: [target, neighbour], supportHalfExtent: 0.16)
        let region = SyntheticRegions.prism(halfWidth: 0.16, upperOffset: 0.12)
        var wide = LiDARFusionConfiguration.smallObject
        wide.connectivityRadiusInVoxels = 5

        // The surface never forms an object at strict connectivity, so the
        // default reach has nothing to offer.
        XCTAssertEqual(scan(scene, .smallObject, region: region).decision.status, .refused)

        // A reach long enough to recover the surface also joins the pair.
        let joined = scan(scene, wide, region: region)
        XCTAssertGreaterThan(try XCTUnwrap(joined.reportedDimensionsCM).length, 15)

        // The table was seen between them, so with free space they stay apart.
        let separated = scan(scene, gating(wide), region: region)
        let dimensions = try XCTUnwrap(separated.reportedDimensionsCM)
        XCTAssertEqual(dimensions.length, 8, accuracy: 0.6)
        XCTAssertEqual(dimensions.width, 5, accuracy: 0.6)
        XCTAssertEqual(dimensions.height, 6, accuracy: 0.6)
        // The decision is not asserted: the tiles' uneven slices can trip the
        // interior-partition check, which is a separate matter from selection.
        XCTAssertGreaterThan(
            try XCTUnwrap(separated.evidence.components?.freeSpaceBlockedBridgeCount),
            0
        )
    }

    func testFreeSpaceStillLetsAWiderReachRecoverOnePatchyObject() throws {
        var target = box
        target.patches = (0.012, 0.009)
        let scene = SyntheticScene(objects: [target], supportHalfExtent: 0.12)
        var wide = LiDARFusionConfiguration.smallObject
        wide.connectivityRadiusInVoxels = 5

        let report = scan(scene, gating(wide))

        let dimensions = try XCTUnwrap(report.reportedDimensionsCM)
        XCTAssertEqual(dimensions.length, 8, accuracy: 0.6)
        XCTAssertEqual(dimensions.width, 5, accuracy: 0.6)
        XCTAssertEqual(dimensions.height, 6, accuracy: 0.6)
        XCTAssertEqual(
            report.evidence.components?.connectivityMode,
            LiDARComponentSelection.Mode.expanded.rawValue
        )
    }

    func testCoordinateResetDiscardsFreeSpaceEvidence() throws {
        var frames = SyntheticScanner.frames(
            scene: SyntheticScene(objects: [box], supportHalfExtent: 0.10),
            plan: occludedPlan()
        )
        let engine = LiDARVoxelFusionEngine(configuration: gating())
        engine.lockSelection(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        for frame in frames.dropLast() { engine.integrate(frame: frame) }
        let before = try XCTUnwrap(engine.analyze().freeSpace)

        frames[frames.count - 1].coordinateEpoch = 1
        let result = engine.integrate(frame: frames[frames.count - 1])
        XCTAssertTrue(result.evidenceWasInvalidated)

        // Only the frame after the reset remains. With too little geometry
        // the analysis stops before the free-space stage, so read the count
        // through a second engine fed that frame alone.
        let single = LiDARVoxelFusionEngine(configuration: gating())
        single.lockSelection(region: SyntheticRegions.prism(), seed: SyntheticRegions.seed())
        single.integrate(frame: frames[frames.count - 1])
        XCTAssertGreaterThan(before.rayCount, frames[frames.count - 1].points.count)
        XCTAssertEqual(engine.freeSpaceRayCount, single.freeSpaceRayCount)
        XCTAssertLessThan(engine.freeSpaceRayCount, before.rayCount)
    }

    func testHeightFromRetainedPointsIsShortByTheRemovedBand() throws {
        var scene = SyntheticScene(objects: [box], supportHalfExtent: 0.10)
        scene.supportNoiseSigma = 0.001
        var plan = occludedPlan()
        plan.depthNoiseSigma = 0.001
        var ablated = LiDARFusionConfiguration.smallObject
        ablated.heightUsesSupportCoordinate = false

        let full = try XCTUnwrap(scan(scene, .smallObject, plan: plan).reportedDimensionsCM)
        let short = try XCTUnwrap(scan(scene, ablated, plan: plan).reportedDimensionsCM)

        XCTAssertEqual(full.height, 6, accuracy: 0.4)
        XCTAssertLessThan(short.height, full.height - 0.3)
        XCTAssertEqual(short.length, full.length)
        XCTAssertEqual(short.width, full.width)
    }

    // MARK: Fixtures

    func testOcclusionHidesWhatStandsBehindASolid() {
        let cylinder = SyntheticObject(
            shape: .cylinder(radius: 0.03, height: 0.08),
            baseCentre: SIMD3<Float>(0.2, 0, 0)
        )
        let through = (SIMD3<Float>(0.3, 0.03, 0), SIMD3<Float>(-0.3, 0.03, 0))
        XCTAssertTrue(box.blocks(from: through.0, to: through.1))
        XCTAssertTrue(cylinder.blocks(from: SIMD3(0.5, 0.04, 0), to: SIMD3(0, 0.04, 0)))
        // A point on the face turned toward the viewer is not hidden by its
        // own object.
        XCTAssertFalse(box.blocks(from: through.0, to: SIMD3<Float>(0.04, 0.03, 0)))
        XCTAssertFalse(cylinder.blocks(from: SIMD3(0.5, 0.04, 0), to: SIMD3(0.23, 0.04, 0)))
        // Passing over or beside it.
        XCTAssertFalse(box.blocks(from: SIMD3(0.3, 0.2, 0), to: SIMD3(-0.3, 0.2, 0)))
        XCTAssertFalse(box.blocks(from: SIMD3(0.3, 0.03, 0.1), to: SIMD3(-0.3, 0.03, 0.1)))

        let wall = SyntheticObject(
            shape: .box(size: SIMD3<Float>(0.2, 0.15, 0.02)),
            baseCentre: SIMD3<Float>(0, 0, 0.08)
        )
        let scene = SyntheticScene(objects: [box, wall], supportHalfExtent: 0.12)
        var plan = occludedPlan()
        plan.modelsOcclusion = false
        let open = SyntheticScanner.frames(scene: scene, plan: plan)
        let occluded = SyntheticScanner.frames(scene: scene, plan: occludedPlan())
        XCTAssertLessThan(
            occluded.map(\.points.count).reduce(0, +),
            open.map(\.points.count).reduce(0, +)
        )
    }

    func testPatchesLeaveUnscannedStripsOnEveryFace() {
        var random = SyntheticRandom(seed: 1)
        let whole = box.surfacePoints(random: &random)
        var patchy = box
        patchy.patches = (0.012, 0.009)
        let kept = patchy.surfacePoints(random: &random)

        XCTAssertLessThan(kept.count, whole.count * 2 / 3)
        XCTAssertGreaterThan(kept.count, whole.count / 5)
        // Nothing survives in the first strip of the top face.
        XCTAssertFalse(kept.contains {
            $0.normal.y > 0.5 && $0.position.x > 0.0125 && $0.position.x < 0.0205
        })
    }

    // MARK: Helpers

    private let box = SyntheticObject(
        shape: .box(size: SIMD3<Float>(0.08, 0.06, 0.05)),
        baseCentre: .zero
    )

    private func gating(
        _ configuration: LiDARFusionConfiguration = .smallObject
    ) -> LiDARFusionConfiguration {
        var configuration = configuration
        configuration.freeSpaceGatingEnabled = true
        return configuration
    }

    private func occludedPlan() -> SyntheticScanPlan {
        var plan = SyntheticScanPlan(frameCount: 24)
        plan.modelsOcclusion = true
        return plan
    }

    private func scan(
        _ scene: SyntheticScene,
        _ configuration: LiDARFusionConfiguration,
        plan: SyntheticScanPlan? = nil,
        region: LiDARSpatialRegion = SyntheticRegions.prism()
    ) -> LiDARMeasurementReport {
        LiDARMeasurementSession(configuration: configuration).run(
            SyntheticScanner.frames(scene: scene, plan: plan ?? occludedPlan()),
            region: region,
            seed: SyntheticRegions.seed()
        )
    }

    private func boxRegion(halfExtent: Float) -> LiDARSpatialRegion {
        .box(LiDARScanVolume(centre: .zero, halfExtents: SIMD3(repeating: halfExtent)))
    }

    private func makeGrid() throws -> LiDARFreeSpaceGrid {
        try XCTUnwrap(LiDARFreeSpaceGrid(
            region: boxRegion(halfExtent: 0.06),
            cellSize: cell,
            margin: 0,
            maximumCellCount: 1_000_000
        ))
    }

    private func key(_ x: Int32, _ y: Int32, _ z: Int32) -> LiDARVoxelKey {
        LiDARVoxelKey(x: x, y: y, z: z)
    }

    private func centre(_ x: Int32, _ y: Int32, _ z: Int32) -> SIMD3<Float> {
        SyntheticVoxelShapes.centre(x, y, z)
    }

    private func column(x: Int32) -> [LiDARVoxelKey] {
        (Int32(0)...4).map { key(x, $0, 0) }
    }

    private func select(
        _ keys: [LiDARVoxelKey],
        _ configuration: LiDARFusionConfiguration,
        isObservedEmpty: ((LiDARVoxelKey) -> Bool)? = nil
    ) -> LiDARComponentSelection {
        let voxels = keys.sorted().map { key -> LiDARStableVoxel in
            let position = centre(key.x, key.y, key.z)
            return LiDARStableVoxel(key: key, position: position, local: position, observations: 3)
        }
        return LiDARComponentSelector.select(
            voxels: voxels,
            seed: centre(0, 0, 0),
            configuration: configuration,
            isObservedEmpty: isObservedEmpty
        )
    }
}
