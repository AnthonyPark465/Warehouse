import Foundation
#if canImport(WarehouseApp)
@testable import WarehouseApp
#endif

// SYNTHETIC EVALUATION. Replays generated receive/pick sequences through the
// placement engine under several area-selection policies and compares them.
// Every number describes behaviour on the generator in this file. None of it
// is a measurement of a real stock room.
//
// Integrity notes:
// - The workload model is invented, not fitted to data: one fixed set of four
//   storage areas, eight product sizes, independent random receives and picks.
// - "Moves per pick" uses the engine's own front-access rule (a product is
//   blocked by anything in front of it in the same lane). That rule is known
//   to be pessimistic for open floor areas that can be reached from above.
// - It counts direct blockers only. The blockers are assumed to be set aside
//   and put back for free: staging space, blockers of blockers, and the moves
//   to restore them are not counted, which flatters any policy that blocks.
// - No product in the catalogue may be stacked, matching the app's default
//   for products with unknown fragility, so areas fill in two dimensions.
// - The shipped cross-area order was chosen with these results in view (an
//   earlier order that also compared distance from the front between areas
//   did slightly worse and was dropped), so for that policy these are
//   in-family results, not held-out performance.
// - Timings are from the machine that ran the tool, not from an iPhone.

enum PlacementEvaluation {
    enum Scale {
        case quick, full
        var seedCount: Int { self == .quick ? 2 : 12 }
        var eventCount: Int { self == .quick ? 30 : 160 }
    }

    struct SKU {
        let id: String
        let dimensions: PackageDimensions
        let weightKG: Double
        /// 0...1, the engine's expected retrieval frequency for this product.
        let pickFrequency: Double
        /// Relative share of receive events.
        let receiveShare: Double
    }

    enum Event: Equatable {
        case receive(sku: Int)
        case pick(sku: Int)
    }

    struct Policy {
        let name: String
        let summary: String
        let choose: (PackagePlacementProfile, [ShelfState]) -> (shelfID: String, result: ProductPlacementResult)?
    }

    struct Outcome: Equatable {
        var policy: String
        var seed: UInt64
        var receives = 0
        var failedReceives = 0
        var receivesBeforeFirstFailure = 0
        var picks = 0
        var unservedPicks = 0
        var movesForPicks = 0
        var picksNeedingMoves = 0
        var peakFloorCoverage = 0.0
        /// Occupied volumes at the end of the run, for invariant checks.
        var finalShelves: [ShelfState] = []
    }

    /// Wall-clock cost of one policy decision. Kept apart from `Outcome` so
    /// outcomes stay reproducible.
    struct Timing {
        var decisions = 0
        var totalSeconds = 0.0
        var maximumSeconds = 0.0
    }

    // MARK: Generator

    static let catalogue: [SKU] = [
        .init(id: "book", dimensions: .init(widthCM: 22, heightCM: 2, depthCM: 28), weightKG: 0.5, pickFrequency: 0.8, receiveShare: 5),
        .init(id: "shoebox", dimensions: .init(widthCM: 20, heightCM: 12, depthCM: 33), weightKG: 1.2, pickFrequency: 0.6, receiveShare: 5),
        .init(id: "small-carton", dimensions: .init(widthCM: 30, heightCM: 20, depthCM: 25), weightKG: 3, pickFrequency: 0.5, receiveShare: 4),
        .init(id: "medium-carton", dimensions: .init(widthCM: 40, heightCM: 30, depthCM: 40), weightKG: 8, pickFrequency: 0.4, receiveShare: 3),
        .init(id: "tall-box", dimensions: .init(widthCM: 30, heightCM: 55, depthCM: 30), weightKG: 6, pickFrequency: 0.2, receiveShare: 2),
        .init(id: "large-carton", dimensions: .init(widthCM: 60, heightCM: 40, depthCM: 50), weightKG: 14, pickFrequency: 0.15, receiveShare: 2),
        .init(id: "flat-pack", dimensions: .init(widthCM: 100, heightCM: 10, depthCM: 60), weightKG: 9, pickFrequency: 0.1, receiveShare: 1),
        .init(id: "crate", dimensions: .init(widthCM: 80, heightCM: 50, depthCM: 60), weightKG: 20, pickFrequency: 0.05, receiveShare: 1)
    ]

    /// Four areas in the order the app lists them (by label). The floor bay is
    /// skewed by two degrees, as a hand-placed boundary would be.
    static func warehouse() -> [ShelfState] {
        let areas: [(name: String, surface: SpaceSurfaceType, width: Double, height: Double, depth: Double, skew: Double)] = [
            ("Bench", .workbench, 150, 60, 70, 0),
            ("Floor bay", .floor, 140, 120, 160, 2),
            ("Shelf A", .shelf, 90, 35, 40, 0),
            ("Shelf B", .shelf, 120, 45, 50, 0)
        ]
        return areas.enumerated().map { index, area in
            let angle = area.skew * .pi / 180
            let boundary = [(0.0, 0.0), (area.width, 0.0), (area.width, area.depth), (0.0, area.depth)].map {
                Vector2D($0.0 * cos(angle) - $0.1 * sin(angle), $0.0 * sin(angle) + $0.1 * cos(angle))
            }
            let space = ScannedSpaceGeometry(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000010\(index)")!,
                geometryType: .openSpace, surfaceType: area.surface,
                rawBoundary2D: boundary, suggestedBoundary2D: boundary,
                approvedBoundary2D: boundary, excludedRegions2D: [],
                localOrigin: Vector3D(0, 0, 0), localXAxis: Vector3D(1, 0, 0),
                localYAxis: Vector3D(0, 0, 1), localVerticalAxis: Vector3D(0, 1, 0),
                bottomPlane: CodablePlane(origin: Vector3D(0, 0, 0), normal: Vector3D(0, 1, 0)),
                topDefinition: .manualLimitCM(area.height), heightCM: area.height,
                accessDirections: [Vector3D(0, 0, 1)],
                confidence: SpaceConfidence(baseSurface: 0.9, boundary: 0.9, corners: 0.9,
                    walls: nil, surfaceEdges: 0.9, height: 1),
                approval: .approved, geometryVersion: 2,
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
                name: area.name
            )
            // The generator's own areas are valid by construction.
            return try! OpenSpacePlacementAdapter.shelfState(from: space)
        }
    }

    static func events(seed: UInt64, count: Int) -> [Event] {
        var random = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            random.unit() < 0.62
                ? .receive(sku: random.index(weights: catalogue.map(\.receiveShare)))
                : .pick(sku: random.index(weights: catalogue.map(\.pickFrequency)))
        }
    }

    static func profile(for sku: SKU) -> PackagePlacementProfile {
        var metadata = ProductPlacementMetadata.conservative
        metadata.weightKG = sku.weightKG
        metadata.expectedRetrievalFrequency = sku.pickFrequency
        // Turning on the spot is allowed; tipping onto another face is not.
        metadata.mayRotateAutomatically = true
        return PackagePlacementProfile(
            productId: sku.id, dimensions: sku.dimensions, weightKG: sku.weightKG,
            demandVelocity: sku.pickFrequency, metadata: metadata
        )
    }

    // MARK: Policies

    /// Areas that accept the product, in listed order, with each area's own best position.
    private static func acceptingAreas(
        _ package: PackagePlacementProfile, _ shelves: [ShelfState]
    ) -> [(shelf: ShelfState, result: ProductPlacementResult)] {
        shelves.compactMap { shelf in
            PlacementEngine.calculate(package: package, shelf: shelf).recommendation.map { (shelf, $0) }
        }
    }

    static let policies: [Policy] = [
        Policy(
            name: "First listed",
            summary: "Baseline. The first area in the app's list that accepts the product, as a worker picking from the top of the menu would."
        ) { package, shelves in
            for shelf in shelves {
                if let result = PlacementEngine.calculate(package: package, shelf: shelf).recommendation {
                    return (shelf.id, result)
                }
            }
            return nil
        },
        Policy(
            name: "Emptiest area",
            summary: "Baseline. The accepting area with the most free volume: \"put it where there is room\"."
        ) { package, shelves in
            acceptingAreas(package, shelves).max { $0.shelf.freeVolumeCM3 < $1.shelf.freeVolumeCM3 }
                .map { ($0.shelf.id, $0.result) }
        },
        Policy(
            name: "Position rank only",
            summary: "The single-area ranking compared directly between areas, with no cross-area rule."
        ) { package, shelves in
            acceptingAreas(package, shelves).max { $0.result.rank < $1.result.rank }
                .map { ($0.shelf.id, $0.result) }
        },
        Policy(
            name: shippedPolicyName,
            summary: "`PlacementEngine.calculate(package:shelves:)`, the app's cross-area search: fewest products to move, then the area with the least free room that still accepts the product."
        ) { package, shelves in
            let calculation = PlacementEngine.calculate(package: package, shelves: shelves)
            guard let shelfID = calculation.recommendedShelfID,
                  let result = calculation.recommendation else { return nil }
            return (shelfID, result)
        },
        Policy(
            name: experimentalPolicyName,
            summary: "**Not in the app.** Tightest-fit area, but the product is pushed to the deepest position it can reach instead of the engine's front-most choice. Included to measure how much capacity the front-first ranking gives up, and what that costs in access."
        ) { package, shelves in
            shelves.compactMap { shelf -> (shelf: ShelfState, result: ProductPlacementResult)? in
                PlacementEngine.calculate(package: package, shelf: shelf).evaluations.compactMap(\.result)
                    .max { ($0.position.z, $0.rank) < ($1.position.z, $1.rank) }
                    .map { (shelf, $0) }
            }
            .min { $0.shelf.freeVolumeCM3 < $1.shelf.freeVolumeCM3 }
            .map { ($0.shelf.id, $0.result) }
        }
    ]

    static let shippedPolicyName = "App cross-area search"
    static let experimentalPolicyName = "Experiment: deepest position"

    // MARK: Simulation

    private struct StoredUnit {
        var sku: Int
        var shelfID: String
        var placementID: String
    }

    static func run(
        _ policy: Policy, seed: UInt64, events: [Event], warehouse: [ShelfState], timing: inout Timing
    ) -> Outcome {
        var outcome = Outcome(policy: policy.name, seed: seed)
        var shelves = warehouse
        var units: [StoredUnit] = []
        let floorArea = warehouse.reduce(0.0) { $0 + polygonArea($1.footprintPolygon) }
        var coveredArea = 0.0
        var hasFailed = false
        let clock = ContinuousClock()

        for event in events {
            switch event {
            case .receive(let sku):
                outcome.receives += 1
                let package = profile(for: catalogue[sku])
                var choice: (shelfID: String, result: ProductPlacementResult)?
                let elapsed = clock.measure { choice = policy.choose(package, shelves) }
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
                timing.decisions += 1
                timing.totalSeconds += seconds
                timing.maximumSeconds = max(timing.maximumSeconds, seconds)
                guard let choice, let index = shelves.firstIndex(where: { $0.id == choice.shelfID }) else {
                    outcome.failedReceives += 1
                    hasFailed = true
                    continue
                }
                if !hasFailed { outcome.receivesBeforeFirstFailure += 1 }
                shelves[index] = ShelfStateOperations.applying(result: choice.result, package: package, to: shelves[index])
                units.append(StoredUnit(sku: sku, shelfID: choice.shelfID, placementID: choice.result.id))
                coveredArea += catalogue[sku].dimensions.widthCM * catalogue[sku].dimensions.depthCM
                outcome.peakFloorCoverage = max(outcome.peakFloorCoverage, coveredArea / floorArea)

            case .pick(let sku):
                outcome.picks += 1
                // A worker takes whichever unit of the product is easiest to reach.
                let reachable = units.indices.filter { units[$0].sku == sku }.map { index in
                    (index: index, blockers: blockerCount(of: units[index], in: shelves))
                }.min { $0.blockers < $1.blockers }
                guard let pick = reachable,
                      let index = shelves.firstIndex(where: { $0.id == units[pick.index].shelfID }),
                      let next = try? ShelfStateOperations.removing(
                          id: units[pick.index].placementID, from: shelves[index],
                          expectedVersion: shelves[index].version
                      ) else {
                    outcome.unservedPicks += 1
                    continue
                }
                outcome.movesForPicks += pick.blockers
                if pick.blockers > 0 { outcome.picksNeedingMoves += 1 }
                shelves[index] = next
                coveredArea -= catalogue[sku].dimensions.widthCM * catalogue[sku].dimensions.depthCM
                units.remove(at: pick.index)
            }
        }
        outcome.finalShelves = shelves
        return outcome
    }

    /// Products that must be moved aside before `unit` can come out the front.
    private static func blockerCount(of unit: StoredUnit, in shelves: [ShelfState]) -> Int {
        guard let shelf = shelves.first(where: { $0.id == unit.shelfID }) else { return 0 }
        return shelf.products.filter { other in
            other.id != unit.placementID && PlacementEngine.productsBlockedBy(
                other.volume, in: shelf,
                gripClearance: PlacementToleranceConfiguration.warehouse.retrievalClearanceCM
            ).contains { $0.id == unit.placementID }
        }.count
    }

    private static func polygonArea(_ polygon: [SIMD2<Double>]) -> Double {
        abs(polygon.indices.reduce(0.0) { value, index in
            let next = polygon[(index + 1) % polygon.count]
            return value + polygon[index].x * next.y - next.x * polygon[index].y
        }) / 2
    }

    static func runAll(generatorSeed: UInt64, scale: Scale) -> (outcomes: [Outcome], timings: [String: Timing]) {
        let warehouse = warehouse()
        var outcomes: [Outcome] = []
        var timings: [String: Timing] = [:]
        for offset in 0..<scale.seedCount {
            let seed = generatorSeed &+ UInt64(offset)
            let events = events(seed: seed, count: scale.eventCount)
            for policy in policies {
                var timing = timings[policy.name] ?? Timing()
                outcomes.append(run(policy, seed: seed, events: events, warehouse: warehouse, timing: &timing))
                timings[policy.name] = timing
            }
        }
        return (outcomes, timings)
    }

    // MARK: Report

    struct Summary: Equatable {
        var policy: String
        var runs: Int
        var failedReceiveRate: Double
        var receivesBeforeFirstFailure: Double
        var unservedPickRate: Double
        var movesPerServedPick: Double
        var picksNeedingMovesRate: Double
        var peakFloorCoverage: Double
        /// Sequences with fewer / more failed receives than the first policy.
        var sequencesBetterThanBaseline: Int
        var sequencesWorseThanBaseline: Int
    }

    static func summarize(_ outcomes: [Outcome]) -> [Summary] {
        policies.compactMap { policy in
            let runs = outcomes.filter { $0.policy == policy.name }
            guard !runs.isEmpty else { return nil }
            func total(_ value: (Outcome) -> Int) -> Double { Double(runs.reduce(0) { $0 + value($1) }) }
            let served = total { $0.picks - $0.unservedPicks }
            let baseline = Dictionary(uniqueKeysWithValues: outcomes
                .filter { $0.policy == policies[0].name }.map { ($0.seed, $0.failedReceives) })
            return Summary(
                policy: policy.name, runs: runs.count,
                failedReceiveRate: total(\.failedReceives) / max(total(\.receives), 1),
                receivesBeforeFirstFailure: total(\.receivesBeforeFirstFailure) / Double(runs.count),
                unservedPickRate: total(\.unservedPicks) / max(total(\.picks), 1),
                movesPerServedPick: total(\.movesForPicks) / max(served, 1),
                picksNeedingMovesRate: total(\.picksNeedingMoves) / max(served, 1),
                peakFloorCoverage: runs.reduce(0.0) { $0 + $1.peakFloorCoverage } / Double(runs.count),
                sequencesBetterThanBaseline: runs.filter { $0.failedReceives < (baseline[$0.seed] ?? 0) }.count,
                sequencesWorseThanBaseline: runs.filter { $0.failedReceives > (baseline[$0.seed] ?? 0) }.count
            )
        }
    }

    static func markdown(
        summaries: [Summary], timings: [String: Timing], generatorSeed: UInt64, scale: Scale, provenance: String?
    ) -> String {
        func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
        var lines = [
            "# Synthetic placement evaluation",
            "",
            "> **SYNTHETIC RESULTS.** Every number below comes from generated receive and",
            "> pick sequences (`WarehouseAppTests/PlacementEvaluation.swift`) replayed",
            "> through the placement engine. They show how area-selection policies",
            "> compare on that generator. They are **not** measurements of a real stock",
            "> room and must not be quoted as such.",
            "",
            "Regenerate with `./scripts/evaluate-placement.sh`. Generator seed `\(generatorSeed)`, "
                + "\(scale.seedCount) sequences of \(scale.eventCount) events, \(warehouse().count) storage areas, "
                + "\(catalogue.count) product sizes.\(provenance.map { " Built from \($0)." } ?? "")",
            "",
            "## How to read this (synthetic)",
            "",
            "- Every policy replays the **same** event sequences against the same empty warehouse.",
            "- Each policy only chooses the **area**; the position inside it is the single-area engine's own recommendation. The one exception is **\(experimentalPolicyName)**, which also overrides the position. Every position used, by any policy, passed all of the engine's safety rules.",
            "- **Failed receives**: no area accepted the product. Lower is better.",
            "- **Fewer / more failures**: in how many sequences the policy had fewer, or more, failed receives than the first baseline on the same events. A lead that does not hold across most sequences is noise.",
            "- **Receives before first failure**: how long the warehouse absorbs stock before the first refusal. Higher is better.",
            "- **Unserved picks**: the product was asked for but none was stored. This includes picks that arrive before any receive, so compare policies rather than reading the level.",
            "- **Moves per pick**: products standing directly in front of the picked one in the same lane. Lower is better. This is optimistic for any policy that blocks: the blockers are assumed to be set aside and put back for free, so staging space, blockers of blockers, and the moves to restore them are not counted.",
            "- **Peak floor coverage**: largest share of all floor area under stored products (raw product footprint). Nothing in this catalogue may be stacked.",
            "- The moves metric uses the engine's front-access rule, which is pessimistic for open floor areas reachable from above.",
            "- The workload is invented, and the shipped policy's order was chosen with these results in view. These are in-family results, not held-out performance.",
            "",
            "## Policies",
            ""
        ]
        lines += policies.map { "- **\($0.name)**: \($0.summary)" }
        lines += [
            "",
            "## Results (synthetic, mean over \(summaries.first?.runs ?? 0) sequences)",
            "",
            "| Policy | Failed receives | Fewer / more failures than \(policies[0].name) | Receives before first failure | Unserved picks | Moves per pick | Picks needing a move | Peak floor coverage |",
            "|---|---:|---:|---:|---:|---:|---:|---:|"
        ]
        lines += summaries.map { summary in
            "| \(summary.policy) | \(percent(summary.failedReceiveRate)) | "
                + "\(summary.sequencesBetterThanBaseline) / \(summary.sequencesWorseThanBaseline) of \(summary.runs) | "
                + String(format: "%.1f", summary.receivesBeforeFirstFailure)
                + " | \(percent(summary.unservedPickRate)) | "
                + String(format: "%.2f", summary.movesPerServedPick)
                + " | \(percent(summary.picksNeedingMovesRate)) | \(percent(summary.peakFloorCoverage)) |"
        }
        lines += [
            "",
            "## Decision time (this machine, not an iPhone)",
            "",
            "Wall-clock time for one policy decision, which includes calculating every area it considers. Not reproducible between runs.",
            "",
            "| Policy | Mean (ms) | Slowest (ms) |",
            "|---|---:|---:|"
        ]
        lines += policies.compactMap { policy in
            timings[policy.name].map { timing in
                "| \(policy.name) | " + String(format: "%.1f", timing.totalSeconds / Double(max(timing.decisions, 1)) * 1000)
                    + " | " + String(format: "%.1f", timing.maximumSeconds * 1000) + " |"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// SplitMix64: the same integer stream on every run.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func index(weights: [Double]) -> Int {
        var remaining = unit() * weights.reduce(0, +)
        for (index, weight) in weights.enumerated() {
            remaining -= weight
            if remaining < 0 { return index }
        }
        return weights.count - 1
    }
}
