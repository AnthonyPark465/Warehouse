import XCTest
import simd
@testable import WarehouseApp

/// Keeps the SYNTHETIC evaluation honest and runnable. The full comparison
/// is produced by `scripts/evaluate-measurement.sh`; this runs a small
/// subset so a broken harness fails the suite.
final class MeasurementEvaluationTests: XCTestCase {
    private static let outcomes = MeasurementEvaluation.run(
        MeasurementEvaluation.cases(scale: .smoke)
    )
    private var summary: EvaluationSummary {
        MeasurementEvaluation.summarize(Self.outcomes, generatorSeed: 20_261_009)
    }

    func testEvaluationCoversEveryCategoryAndIsLabelledSynthetic() {
        let summary = summary
        for category in EvaluationCase.Category.allCases {
            XCTAssertGreaterThan(summary.categoryCounts[category.rawValue] ?? 0, 0, category.rawValue)
        }
        XCTAssertTrue(summary.label.contains("SYNTHETIC"))

        let markdown = MeasurementEvaluation.markdown(summary: summary, outcomes: Self.outcomes)
        XCTAssertTrue(markdown.contains("SYNTHETIC RESULTS"))
        XCTAssertTrue(markdown.contains("not** measurements"))
        // Every results table says what it is, even when read on its own.
        for heading in markdown.split(separator: "\n").filter({ $0.hasPrefix("## ") }) {
            XCTAssertTrue(heading.contains("(synthetic)"), String(heading))
        }
    }

    func testEvaluationIsReproducible() {
        let cases = Array(MeasurementEvaluation.cases(scale: .smoke).prefix(3))
        let first = MeasurementEvaluation.run(cases)
        let second = MeasurementEvaluation.run(cases)

        XCTAssertEqual(first.map(\.strengthened), second.map(\.strengthened))
        XCTAssertEqual(first.map(\.baseline), second.map(\.baseline))
        XCTAssertEqual(first.map(\.seededBaseline), second.map(\.seededBaseline))
        XCTAssertEqual(first.map(\.status), second.map(\.status))
        XCTAssertEqual(first.map(\.strengthened), Self.outcomes.prefix(3).map(\.strengthened))
    }

    func testDifferentGeneratorSeedsProduceDifferentCases() {
        let first = MeasurementEvaluation.cases(generatorSeed: 1, scale: .smoke)
        let second = MeasurementEvaluation.cases(generatorSeed: 2, scale: .smoke)
        XCTAssertNotEqual(first.map(\.truth), second.map(\.truth))
    }

    func testAccuracyUsesIsolatedCasesOnlyAndFalseAlarmsUseEveryUnclippedCase() {
        let summary = summary
        let isolatedCount = summary.categoryCounts[EvaluationCase.Category.isolated.rawValue] ?? 0
        let clippedCount = summary.categoryCounts[EvaluationCase.Category.clipped.rawValue] ?? 0

        XCTAssertEqual(summary.strengthenedIsolated.caseCount, isolatedCount)
        XCTAssertEqual(summary.seededIsolated.caseCount, isolatedCount)
        XCTAssertEqual(summary.unclippedCaseCount, summary.caseCount - clippedCount)
    }

    func testMetricsAreComputedFromSignedAndAbsoluteErrors() {
        let truth = ObjectDimensions(length: 10, width: 5, height: 4)
        let metrics = MeasurementEvaluation.metrics([
            (ObjectDimensions(length: 11, width: 5, height: 3), truth),
            (nil, truth)
        ])

        XCTAssertEqual(metrics.caseCount, 2)
        XCTAssertEqual(metrics.answeredCount, 1)
        XCTAssertEqual(metrics.meanAbsoluteErrorCM ?? -1, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(metrics.maximumAbsoluteErrorCM ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(metrics.medianAbsoluteErrorCM ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(metrics.meanSignedErrorCM ?? -1, 0, accuracy: 1e-9)
    }

    func testRepeatabilityIsTheSampleStandardDeviationAcrossRuns() {
        let runs = [
            ObjectDimensions(length: 10, width: 5, height: 4),
            ObjectDimensions(length: 12, width: 5, height: 4)
        ]
        // Length deviates by √2; width and height not at all.
        XCTAssertEqual(
            MeasurementEvaluation.repeatability([runs]) ?? -1,
            2.0.squareRoot() / 3,
            accuracy: 1e-9
        )
        XCTAssertNil(MeasurementEvaluation.repeatability([[runs[0]]]))
    }

    func testOversizeMarginScalesWithTheDimension() {
        let truth = ObjectDimensions(length: 20, width: 4, height: 4)
        XCTAssertFalse(MeasurementEvaluation.isOversized(
            ObjectDimensions(length: 22.9, width: 4.9, height: 4),
            truth: truth
        ))
        XCTAssertTrue(MeasurementEvaluation.isOversized(
            ObjectDimensions(length: 23.1, width: 4, height: 4),
            truth: truth
        ))
        XCTAssertTrue(MeasurementEvaluation.isOversized(
            ObjectDimensions(length: 20, width: 5.1, height: 4),
            truth: truth
        ))
    }

    /// The mechanism in one comparison, on identical frames: measuring
    /// height from the points left after the floor band is removed comes up
    /// short; measuring from the retained support coordinate does not.
    func testRetainedSupportCoordinateAvoidsTheHeightLossOfFloorRemoval() throws {
        let object = SyntheticObject(shape: .box(size: SIMD3<Float>(0.08, 0.06, 0.04)), baseCentre: .zero)
        let frames = SyntheticScanner.frames(
            scene: SyntheticScene(objects: [object], supportHalfExtent: 0.10),
            plan: SyntheticScanPlan(frameCount: 24)
        )
        let region = SyntheticRegions.prism()

        let baseline = try XCTUnwrap(
            BaselineMeasurementPipeline.naive.measure(frames: frames, region: region)
        )
        // The same baseline with the floor coordinate retained recovers it.
        let retained = try XCTUnwrap(
            BaselineMeasurementPipeline.seeded.measure(
                frames: frames,
                region: region,
                seed: SyntheticRegions.seed()
            )
        )
        let strengthened = try XCTUnwrap(
            LiDARMeasurementSession().run(frames, region: region, seed: SyntheticRegions.seed())
                .reportedDimensionsCM
        )

        XCTAssertLessThan(baseline.height, 6 - 0.4)
        XCTAssertGreaterThan(retained.height, 6 - 0.2)
        XCTAssertGreaterThan(strengthened.height, 6 - 0.1)
    }
}
