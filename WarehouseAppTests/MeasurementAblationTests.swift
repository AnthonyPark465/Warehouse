import XCTest
import simd
@testable import WarehouseApp

/// Keeps the SYNTHETIC ablation runnable and honestly labelled. The full
/// comparison is produced by `scripts/evaluate-ablation.sh`.
final class MeasurementAblationTests: XCTestCase {
    func testEachVariantDiffersFromTheDefaultInOneSetting() {
        var expected = LiDARFusionConfiguration.smallObject
        expected.heightUsesSupportCoordinate = false
        XCTAssertEqual(AblationVariant.heightFromRetainedPoints.configuration, expected)

        expected = .smallObject
        expected.connectivityIsConditional = false
        XCTAssertEqual(AblationVariant.unconditionalConnectivity.configuration, expected)

        expected = .smallObject
        expected.connectivityRadiusInVoxels = AblationVariant.wideReachVoxels
        XCTAssertEqual(AblationVariant.wideReach.configuration, expected)

        // The free-space variant differs from the wide reach only in gating.
        expected.freeSpaceGatingEnabled = true
        XCTAssertEqual(AblationVariant.wideReachWithFreeSpace.configuration, expected)
        XCTAssertEqual(AblationVariant.full.configuration, .smallObject)
    }

    func testFreeSpaceCasesCoverEveryFamilyModelOcclusionAndAreReproducible() {
        let cases = MeasurementAblation.freeSpaceCases(scale: .smoke)
        for family in AblationCase.Family.allCases {
            XCTAssertTrue(cases.contains { $0.family == family }, family.rawValue)
        }
        XCTAssertTrue(cases.allSatisfy(\.plan.modelsOcclusion))
        XCTAssertEqual(
            cases.map(\.truth),
            MeasurementAblation.freeSpaceCases(scale: .smoke).map(\.truth)
        )
        XCTAssertNotEqual(
            cases.map(\.truth),
            MeasurementAblation.freeSpaceCases(generatorSeed: 3, scale: .smoke).map(\.truth)
        )
    }

    func testTallySeparatesCorrectOversizedUndersizedAndRefused() {
        let truth = ObjectDimensions(length: 10, width: 5, height: 4)
        func result(_ length: Double, _ status: LiDARAcceptanceStatus) -> AblationResult {
            AblationResult(
                dimensions: ObjectDimensions(length: length, width: 5, height: 4),
                status: status,
                reasons: []
            )
        }
        // Target-sized, but a fifth of its voxels lie on the neighbour.
        var contaminated = result(10.2, .accepted)
        contaminated.neighbourShare = 0.2
        var clean = result(10.4, .accepted)
        clean.neighbourShare = 0.001
        let tally = MeasurementAblation.tally([
            (clean, truth),
            (contaminated, truth),
            (result(17, .qualified), truth),
            (result(6, .qualified), truth),
            (result(17, .refused), truth),
            (AblationResult(dimensions: nil, status: .refused, reasons: []), truth)
        ])

        XCTAssertEqual(tally, AblationTally(
            caseCount: 6,
            offeredCorrect: 2,
            offeredOversized: 1,
            offeredUndersized: 1,
            refused: 2,
            refusedOversized: 1,
            offeredWithNeighbourVoxels: 1
        ))
    }

    func testNeighbourShareCountsSelectedVoxelsLyingOnTheSecondObject() throws {
        let target = SyntheticObject(shape: .box(size: SIMD3<Float>(0.08, 0.06, 0.05)), baseCentre: .zero)
        var neighbour = target
        neighbour.baseCentre = SIMD3<Float>(0.1, 0, 0)
        let scene = SyntheticScene(objects: [target, neighbour])
        func measurement(_ points: [SIMD3<Float>]) -> LiDARFusionMeasurement {
            LiDARFusionMeasurement(
                dimensionsCM: ObjectDimensions(length: 8, width: 5, height: 6),
                centredPointsInMetres: [],
                worldPointsInMetres: points,
                boundingBoxCornersWorld: [],
                touchesRegionBoundary: false,
                fusedVoxelCount: points.count,
                averageObservationsPerVoxel: 3,
                supportPlaneY: 0,
                connectivityMode: .strict
            )
        }
        let onTarget = SIMD3<Float>(0.04, 0.03, 0)
        let onNeighbour = SIMD3<Float>(0.06, 0.03, 0)

        XCTAssertEqual(
            MeasurementAblation.neighbourShare(measurement([onTarget, onTarget, onTarget, onNeighbour]), scene: scene),
            0.25
        )
        XCTAssertEqual(MeasurementAblation.neighbourShare(measurement([onTarget]), scene: scene), 0)
        XCTAssertNil(MeasurementAblation.neighbourShare(nil, scene: scene))
        XCTAssertNil(MeasurementAblation.neighbourShare(
            measurement([onTarget]),
            scene: SyntheticScene(objects: [target])
        ))
    }

    func testReportIsLabelledSyntheticAndShowsTheHeightEffect() throws {
        let mainCases = Array(MeasurementEvaluation.cases(scale: .smoke).prefix(2))
        let rows = MeasurementAblation.runMain(mainCases)
        XCTAssertEqual(rows.map(\.variant.name), MeasurementAblation.variantsOnMainCases.map(\.name))

        // Step B: without the retained coordinate, height reads lower.
        let full = try XCTUnwrap(rows[0].heightSignedErrorCM)
        let ablated = try XCTUnwrap(rows[1].heightSignedErrorCM)
        XCTAssertLessThan(ablated, full - 0.3)
        XCTAssertEqual(rows[1].footprintAbsoluteErrorCM, rows[0].footprintAbsoluteErrorCM)

        let markdown = MeasurementAblation.markdown(
            mainCases: mainCases,
            mainRows: rows,
            freeSpaceCases: [],
            freeSpaceRows: [],
            mainSeed: 1,
            freeSpaceSeed: 2
        )
        XCTAssertTrue(markdown.contains("SYNTHETIC RESULTS"))
        XCTAssertTrue(markdown.contains("not** measurements"))
        for heading in markdown.split(separator: "\n").filter({ $0.hasPrefix("## ") }) {
            XCTAssertTrue(heading.contains("(synthetic)"), String(heading))
        }
    }
}
