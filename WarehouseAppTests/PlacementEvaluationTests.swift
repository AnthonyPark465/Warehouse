import XCTest
@testable import WarehouseApp

/// Checks the synthetic placement evaluation itself: that it is reproducible
/// and that every policy leaves the warehouse in a physically valid state.
/// The comparison between policies is in `docs/placement-evaluation-synthetic.md`.
final class PlacementEvaluationTests: XCTestCase {
    private static let quick = PlacementEvaluation.runAll(generatorSeed: 7, scale: .quick)

    func testEventsAreReproducibleAndSeedDependent() {
        let first = PlacementEvaluation.events(seed: 7, count: 60)
        XCTAssertEqual(first, PlacementEvaluation.events(seed: 7, count: 60))
        XCTAssertNotEqual(first, PlacementEvaluation.events(seed: 8, count: 60))
        XCTAssertTrue(first.contains { if case .receive = $0 { true } else { false } })
        XCTAssertTrue(first.contains { if case .pick = $0 { true } else { false } })
    }

    func testOutcomesAreReproducible() throws {
        let policy = try XCTUnwrap(
            PlacementEvaluation.policies.first { $0.name == PlacementEvaluation.shippedPolicyName }
        )
        let events = PlacementEvaluation.events(seed: 11, count: 24)
        var timing = PlacementEvaluation.Timing()
        func run() -> PlacementEvaluation.Outcome {
            PlacementEvaluation.run(
                policy, seed: 11, events: events, warehouse: PlacementEvaluation.warehouse(), timing: &timing
            )
        }
        var first = run(), second = run()
        XCTAssertEqual(first.finalShelves.map(\.products), second.finalShelves.map(\.products))
        // Shelf states carry the wall-clock time of their last update.
        first.finalShelves = []
        second.finalShelves = []
        XCTAssertEqual(first, second)
    }

    func testEveryPolicyReplaysTheSameEventsAndLeavesAValidWarehouse() {
        let outcomes = Self.quick.outcomes
        XCTAssertEqual(
            outcomes.count,
            PlacementEvaluation.policies.count * PlacementEvaluation.Scale.quick.seedCount
        )
        for outcome in outcomes {
            let sameSeed = outcomes.filter { $0.seed == outcome.seed }
            XCTAssertEqual(Set(sameSeed.map(\.receives)).count, 1)
            XCTAssertEqual(Set(sameSeed.map(\.picks)).count, 1)
            XCTAssertLessThanOrEqual(outcome.failedReceives, outcome.receives)
            XCTAssertLessThanOrEqual(outcome.unservedPicks, outcome.picks)
            for shelf in outcome.finalShelves {
                // Overlapping or out-of-bounds occupancy invalidates the shelf state.
                XCTAssertEqual(ShelfScanValidator.rejectionReasons(for: shelf), [], "\(outcome.policy), \(shelf.label)")
            }
        }
    }

    func testReportIsLabelledSyntheticAndListsEveryPolicy() {
        let markdown = PlacementEvaluation.markdown(
            summaries: PlacementEvaluation.summarize(Self.quick.outcomes), timings: Self.quick.timings,
            generatorSeed: 7, scale: .quick, provenance: nil
        )
        XCTAssertTrue(markdown.contains("SYNTHETIC RESULTS"))
        XCTAssertTrue(markdown.contains("not** measurements of a real stock"))
        for policy in PlacementEvaluation.policies {
            XCTAssertTrue(markdown.contains("| \(policy.name) |"), policy.name)
        }
    }
}
