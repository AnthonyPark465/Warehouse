import Foundation
import simd
#if canImport(WarehouseApp)
@testable import WarehouseApp
#endif

// SYNTHETIC EVALUATION. Compares the measurement pipeline with a deliberately
// simple baseline on generated scans. Every number it produces describes
// behaviour on the generator in `SyntheticScanFixtures.swift`, whose
// simplifications are listed there. None of it is a measurement of accuracy
// on a physical iPhone.
//
// Integrity notes:
// - These are IN-FAMILY regression results, not held-out performance. The
//   cases use the same generative model as the unit tests (surface sampling,
//   visibility, noise, camera orbit, support, region and seed placement) and
//   several of the same scenario families. Pipeline thresholds were chosen
//   with that fixture family in view. Case parameters are drawn from a
//   separate seeded generator, and no threshold was changed after these
//   cases were first run, but the repository history cannot prove that
//   ordering, and an independent generator or physical scans would be
//   expected to give worse numbers.
// - Several case families are built around the pipeline's own thresholds
//   (viewing arcs below the minimum, frame counts below the minimum, cuts
//   near the boundary distance). They check that a rule fires; they do not
//   show the rule is the right one.
// - Neither baseline is the app's previous implementation. Both were
//   written for this comparison and use the pipeline's default voxel size,
//   floor band and wide radius rather than independently chosen values.

/// A single-pass pipeline with no temporal filtering and no acceptance
/// stage: voxelize everything in the region, drop a band above the lowest
/// points, keep one component at a fixed wide radius, and take its extents.
/// It answers whenever it has any geometry.
///
/// Two variants are scored:
/// - **naive**: largest component; height over the points left after the
///   floor band is removed. A sanity floor, intentionally weak.
/// - **seeded**: the component nearest the same seed the app pipeline gets;
///   height from the estimated floor coordinate. Input-matched, still simple.
struct BaselineMeasurementPipeline {
    var voxelSize: Float = 0.003
    var floorPercentile = 0.02
    var floorBand: Float = 0.006
    var connectivityRadius: Int32 = 2
    /// Select the component nearest the seed instead of the largest.
    var usesSeed = false
    /// Measure height from the floor estimate instead of the lowest
    /// remaining point.
    var retainsFloorCoordinate = false

    static let naive = BaselineMeasurementPipeline()
    static let seeded = BaselineMeasurementPipeline(usesSeed: true, retainsFloorCoordinate: true)

    func measure(
        frames: [LiDARDepthFrame],
        region: LiDARSpatialRegion,
        seed: SIMD3<Float> = .zero
    ) -> ObjectDimensions? {
        var sums: [LiDARVoxelKey: (sum: SIMD3<Float>, count: Int)] = [:]
        for frame in frames {
            for point in frame.points where region.contains(point) {
                let key = LiDARVoxelKey.containing(point, cellSize: voxelSize)
                let existing = sums[key] ?? (.zero, 0)
                sums[key] = (existing.sum + point, existing.count + 1)
            }
        }
        let voxels = sums
            .map { (key: $0.key, local: region.coordinates(of: $0.value.sum / Float($0.value.count))) }
            .sorted { $0.key < $1.key }
        guard let floor = LiDARStatistics.percentile(
            sorted: voxels.map(\.local.y).sorted(),
            fraction: floorPercentile
        ) else { return nil }
        let above = voxels.filter { $0.local.y > floor + floorBand }
        guard !above.isEmpty else { return nil }

        var indexByKey: [LiDARVoxelKey: Int] = [:]
        for (index, voxel) in above.enumerated() { indexByKey[voxel.key] = index }
        var visited = [Bool](repeating: false, count: above.count)
        let seedLocal = region.coordinates(of: seed)
        var largest: [Int] = []
        var nearestDistance = Float.greatestFiniteMagnitude
        for start in above.indices where !visited[start] {
            visited[start] = true
            var members = [start]
            var cursor = 0
            while cursor < members.count {
                let key = above[members[cursor]].key
                cursor += 1
                for dx in -connectivityRadius...connectivityRadius {
                    for dy in -connectivityRadius...connectivityRadius {
                        for dz in -connectivityRadius...connectivityRadius {
                            guard let neighbour = indexByKey[key.offset(by: (dx, dy, dz))],
                                  !visited[neighbour]
                            else { continue }
                            visited[neighbour] = true
                            members.append(neighbour)
                        }
                    }
                }
            }
            if usesSeed {
                let distance = members.reduce(Float.greatestFiniteMagnitude) {
                    min($0, simd_distance_squared(above[$1].local, seedLocal))
                }
                if distance < nearestDistance {
                    nearestDistance = distance
                    largest = members
                }
            } else if members.count > largest.count {
                largest = members
            }
        }
        let points = largest.map { above[$0].local }
        guard points.count >= 3 else { return nil }

        // Without the retained coordinate, height is that of what is left
        // after the floor band was removed.
        let heights = points.map(\.y)
        let height = (heights.max() ?? 0)
            - (retainsFloorCoordinate ? floor : (heights.min() ?? 0))
        var best: (area: Float, u: Float, v: Float)?
        for degrees in stride(from: Float(0), to: 90, by: 1) {
            let angle = degrees * .pi / 180
            let axisU = SIMD2<Float>(cos(angle), sin(angle))
            let axisV = SIMD2<Float>(-sin(angle), cos(angle))
            var lowU = Float.greatestFiniteMagnitude, highU = -Float.greatestFiniteMagnitude
            var lowV = Float.greatestFiniteMagnitude, highV = -Float.greatestFiniteMagnitude
            for point in points {
                let horizontal = SIMD2<Float>(point.x, point.z)
                let u = simd_dot(horizontal, axisU)
                let v = simd_dot(horizontal, axisV)
                lowU = min(lowU, u); highU = max(highU, u)
                lowV = min(lowV, v); highV = max(highV, v)
            }
            let area = (highU - lowU) * (highV - lowV)
            if best == nil || area < best!.area { best = (area, highU - lowU, highV - lowV) }
        }
        guard let best else { return nil }
        return ObjectDimensions(
            length: Double(max(best.u, best.v)) * 100,
            width: Double(min(best.u, best.v)) * 100,
            height: Double(height) * 100
        )
    }
}

struct EvaluationCase {
    enum Category: String, CaseIterable, Codable {
        case isolated
        case repeatability
        case neighbour
        case background
        case sparse
        case clipped
        case deficient
    }

    var name: String
    var category: Category
    var scene: SyntheticScene
    var plan: SyntheticScanPlan
    var region: LiDARSpatialRegion
    var seed: SIMD3<Float>
    /// Groups repeatability runs of the same object.
    var group: String?

    var truth: ObjectDimensions { scene.target.trueDimensionsCM }
}

struct EvaluationOutcome {
    var testCase: EvaluationCase
    var strengthened: ObjectDimensions?
    var status: LiDARAcceptanceStatus
    var failures: [LiDARMeasurementReasonCode]
    var warnings: [LiDARMeasurementReasonCode]
    /// Naive baseline: largest component, height over remaining points.
    var baseline: ObjectDimensions?
    /// Seeded baseline: nearest component, height from the floor estimate.
    var seededBaseline: ObjectDimensions?
}

struct EvaluationMetrics: Codable, Equatable {
    var caseCount = 0
    var answeredCount = 0
    /// Mean and worst absolute per-dimension error over answered cases.
    var meanAbsoluteErrorCM: Double?
    var medianAbsoluteErrorCM: Double?
    var maximumAbsoluteErrorCM: Double?
    /// Mean signed error: positive means the pipeline reads large.
    var meanSignedErrorCM: Double?
}

struct EvaluationSummary: Codable, Equatable {
    var label = "SYNTHETIC — generated scans, not device accuracy"
    var generatorSeed: UInt64
    var caseCount: Int
    var categoryCounts: [String: Int]

    /// Dimension error on `isolated` cases only: one complete scan each of
    /// distinct single objects.
    var strengthenedIsolated = EvaluationMetrics()
    var naiveIsolated = EvaluationMetrics()
    var seededIsolated = EvaluationMetrics()

    /// Mean per-dimension standard deviation across noise seeds, over the
    /// runs that produced a usable answer.
    var strengthenedRepeatabilityCM: Double?
    var naiveRepeatabilityCM: Double?
    var seededRepeatabilityCM: Double?
    var repeatabilityRunCount = 0
    /// Runs the strengthened pipeline refused; they are not in its figure.
    var strengthenedRepeatabilityRunsRefused = 0

    /// Neighbour and background cases where a reported dimension exceeds
    /// the truth by more than the margin. This is a proxy for merging: it
    /// also counts any other large over-estimate, and misses contamination
    /// that does not enlarge the result.
    var crowdedCaseCount = 0
    var strengthenedOversizedOffered = 0
    var strengthenedOversizedRefused = 0
    var naiveOversized = 0
    var seededOversized = 0

    /// Clipped cases: the region cuts the product.
    var clippedCaseCount = 0
    var strengthenedClippingDetected = 0
    /// Clipped cases refused for any reason, boundary contact or otherwise.
    var strengthenedClippedRefused = 0
    /// The baselines have no clipping check. These are the clipped cases
    /// for which each returned dimensions anyway.
    var naiveClippedAnswered = 0
    var seededClippedAnswered = 0
    /// Boundary contact reported on any case whose region does not cut the
    /// product.
    var strengthenedClippingFalseAlarms = 0
    var unclippedCaseCount = 0

    /// Share of cases the strengthened pipeline refused, by category.
    var strengthenedRefusalRate: [String: Double] = [:]
    /// Share of cases for which each baseline returned nothing.
    var naiveNoAnswerRate: [String: Double] = [:]
    var seededNoAnswerRate: [String: Double] = [:]
}

enum MeasurementEvaluation {
    /// A reported dimension this far above the truth counts as oversized.
    static let oversizeMarginCM = 1.0
    static let oversizeMarginFraction = 0.15

    enum Scale {
        /// A handful of cases, for the unit-test suite.
        case smoke
        /// The full set, for the command-line tool.
        case full
    }

    static func cases(generatorSeed: UInt64 = 20_261_009, scale: Scale = .full) -> [EvaluationCase] {
        var random = SyntheticRandom(seed: generatorSeed)
        let multiplier = scale == .full ? 1 : 0
        var cases: [EvaluationCase] = []

        func randomBox() -> SyntheticObject {
            let a = random.uniform(0.04...0.14)
            let b = random.uniform(0.03...0.10)
            return SyntheticObject(
                shape: .box(size: SIMD3<Float>(max(a, b), random.uniform(0.03...0.12), min(a, b))),
                baseCentre: .zero,
                yaw: random.uniform(0...(.pi / 2))
            )
        }
        func noisyPlan(_ seed: UInt64) -> SyntheticScanPlan {
            SyntheticScanPlan(
                frameCount: scale == .full ? 36 : 24,
                depthNoiseSigma: 0.001,
                dropoutFraction: 0.1,
                seed: seed
            )
        }
        func add(
            _ name: String,
            _ category: EvaluationCase.Category,
            _ scene: SyntheticScene,
            _ plan: SyntheticScanPlan,
            regionHalfWidth: Float = 0.16,
            upper: Float = 0.20,
            group: String? = nil
        ) {
            cases.append(EvaluationCase(
                name: name,
                category: category,
                scene: scene,
                plan: plan,
                region: SyntheticRegions.prism(halfWidth: regionHalfWidth, upperOffset: upper),
                seed: SyntheticRegions.seed(),
                group: group
            ))
        }

        for index in 0..<(2 + 10 * multiplier) {
            var scene = SyntheticScene(objects: [randomBox()], supportHalfExtent: 0.16)
            scene.supportNoiseSigma = random.uniform(0...0.0015)
            add("isolated-\(index)", .isolated, scene, noisyPlan(random.next()))
        }
        for index in 0..<(1 + 3 * multiplier) {
            let radius = random.uniform(0.02...0.05)
            let scene = SyntheticScene(
                objects: [SyntheticObject(
                    shape: .cylinder(radius: radius, height: random.uniform(0.04...0.12)),
                    baseCentre: .zero
                )],
                supportHalfExtent: 0.16
            )
            add("isolated-cylinder-\(index)", .isolated, scene, noisyPlan(random.next()))
        }

        for objectIndex in 0..<(1 + 2 * multiplier) {
            let object = randomBox()
            for run in 0..<(2 + 6 * multiplier) {
                add(
                    "repeat-\(objectIndex)-\(run)",
                    .repeatability,
                    SyntheticScene(objects: [object], supportHalfExtent: 0.16),
                    noisyPlan(random.next()),
                    group: "repeat-\(objectIndex)"
                )
            }
        }

        for index in 0..<(1 + 11 * multiplier) {
            var target = randomBox()
            target.yaw = 0
            guard case .box(let size) = target.shape else {
                preconditionFailure("randomBox must return a box")
            }
            let gap = random.uniform(0.005...0.030)
            let neighbourSize = SIMD3<Float>(
                random.uniform(0.04...0.08),
                random.uniform(0.04...0.14),
                random.uniform(0.04...0.10)
            )
            let neighbour = SyntheticObject(
                shape: .box(size: neighbourSize),
                baseCentre: SIMD3<Float>(size.x / 2 + gap + neighbourSize.x / 2, 0, 0)
            )
            add(
                "neighbour-\(index)-gap\(Int((gap * 1000).rounded()))mm",
                .neighbour,
                SyntheticScene(objects: [target, neighbour], supportHalfExtent: 0.22),
                noisyPlan(random.next()),
                regionHalfWidth: 0.22
            )
        }

        for index in 0..<(1 + 5 * multiplier) {
            var target = randomBox()
            target.yaw = 0
            guard case .box(let size) = target.shape else {
                preconditionFailure("randomBox must return a box")
            }
            let depth = random.uniform(0.02...0.04)
            let background = SyntheticObject(
                shape: .box(size: SIMD3<Float>(0.24, random.uniform(0.10...0.18), depth)),
                baseCentre: SIMD3<Float>(0, 0, size.z / 2 + random.uniform(0.025...0.06) + depth / 2)
            )
            add(
                "background-\(index)",
                .background,
                SyntheticScene(objects: [target, background], supportHalfExtent: 0.22),
                noisyPlan(random.next()),
                regionHalfWidth: 0.22
            )
        }

        for index in 0..<(1 + 5 * multiplier) {
            var object = randomBox()
            object.retainedFraction = random.uniform(0.3...0.6)
            add(
                "sparse-\(index)",
                .sparse,
                SyntheticScene(objects: [object], supportHalfExtent: 0.16),
                SyntheticScanPlan(frameCount: scale == .full ? 36 : 24, seed: random.next())
            )
        }

        for index in 0..<(2 + 8 * multiplier) {
            var object = randomBox()
            object.yaw = 0
            guard case .box(let size) = object.shape else {
                preconditionFailure("randomBox must return a box")
            }
            // The region is narrower or lower than the product.
            let cutsTop = index.isMultiple(of: 3)
            add(
                "clipped-\(index)-\(cutsTop ? "top" : "side")",
                .clipped,
                SyntheticScene(objects: [object], supportHalfExtent: 0.16),
                noisyPlan(random.next()),
                regionHalfWidth: cutsTop ? 0.16 : size.x / 2 - random.uniform(0.004...0.015),
                upper: cutsTop ? size.y - random.uniform(0.004...0.015) : 0.20
            )
        }

        for index in 0..<(3 + 3 * multiplier) {
            var plan = noisyPlan(random.next())
            let name: String
            switch index % 3 {
            case 0:
                plan.sweepDegrees = random.uniform(15...40)
                name = "narrow-arc"
            case 1:
                plan.frameCount = 10
                name = "few-frames"
            default:
                plan.sweepDegrees = 50
                plan.cameraHeight = 0.02
                name = "one-side-low"
            }
            add(
                "deficient-\(index)-\(name)",
                .deficient,
                SyntheticScene(objects: [randomBox()], supportHalfExtent: 0.16),
                plan
            )
        }
        return cases
    }

    static func run(_ cases: [EvaluationCase]) -> [EvaluationOutcome] {
        return cases.map { testCase in
            let frames = SyntheticScanner.frames(scene: testCase.scene, plan: testCase.plan)
            let report = LiDARMeasurementSession(configuration: .smallObject).run(
                frames,
                region: testCase.region,
                seed: testCase.seed
            )
            return EvaluationOutcome(
                testCase: testCase,
                strengthened: report.reportedDimensionsCM,
                status: report.decision.status,
                failures: report.decision.failures,
                warnings: report.decision.warnings,
                baseline: BaselineMeasurementPipeline.naive.measure(
                    frames: frames,
                    region: testCase.region
                ),
                seededBaseline: BaselineMeasurementPipeline.seeded.measure(
                    frames: frames,
                    region: testCase.region,
                    seed: testCase.seed
                )
            )
        }
    }

    static func isOversized(_ dimensions: ObjectDimensions, truth: ObjectDimensions) -> Bool {
        zip(dimensions.values, truth.values).contains {
            $0 - $1 > max(oversizeMarginCM, oversizeMarginFraction * $1)
        }
    }

    static func metrics(
        _ pairs: [(measured: ObjectDimensions?, truth: ObjectDimensions)]
    ) -> EvaluationMetrics {
        var metrics = EvaluationMetrics(caseCount: pairs.count)
        var errors: [Double] = []
        for pair in pairs {
            guard let measured = pair.measured else { continue }
            metrics.answeredCount += 1
            errors += zip(measured.values, pair.truth.values).map { $0 - $1 }
        }
        guard !errors.isEmpty else { return metrics }
        metrics.meanAbsoluteErrorCM = errors.map(abs).reduce(0, +) / Double(errors.count)
        let sortedAbsolute = errors.map(abs).sorted()
        metrics.medianAbsoluteErrorCM = sortedAbsolute.count.isMultiple(of: 2)
            ? (sortedAbsolute[sortedAbsolute.count / 2 - 1] + sortedAbsolute[sortedAbsolute.count / 2]) / 2
            : sortedAbsolute[sortedAbsolute.count / 2]
        metrics.maximumAbsoluteErrorCM = sortedAbsolute.last
        metrics.meanSignedErrorCM = errors.reduce(0, +) / Double(errors.count)
        return metrics
    }

    /// Mean, over groups and dimensions, of the standard deviation across runs.
    static func repeatability(_ groups: [[ObjectDimensions]]) -> Double? {
        var deviations: [Double] = []
        for group in groups where group.count >= 2 {
            for axis in 0..<3 {
                let values = group.map { $0.values[axis] }
                let mean = values.reduce(0, +) / Double(values.count)
                let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                    / Double(values.count - 1)
                deviations.append(variance.squareRoot())
            }
        }
        guard !deviations.isEmpty else { return nil }
        return deviations.reduce(0, +) / Double(deviations.count)
    }

    static func summarize(_ outcomes: [EvaluationOutcome], generatorSeed: UInt64) -> EvaluationSummary {
        var summary = EvaluationSummary(
            generatorSeed: generatorSeed,
            caseCount: outcomes.count,
            categoryCounts: [:]
        )
        for outcome in outcomes {
            summary.categoryCounts[outcome.testCase.category.rawValue, default: 0] += 1
        }
        func offered(_ outcome: EvaluationOutcome) -> ObjectDimensions? {
            outcome.status == .refused ? nil : outcome.strengthened
        }

        // Dimension error: results the strengthened pipeline offers (a
        // refused result never reaches the user); every answer for the
        // baselines, which cannot refuse.
        let isolated = outcomes.filter { $0.testCase.category == .isolated }
        summary.strengthenedIsolated = metrics(isolated.map { (offered($0), $0.testCase.truth) })
        summary.naiveIsolated = metrics(isolated.map { ($0.baseline, $0.testCase.truth) })
        summary.seededIsolated = metrics(isolated.map { ($0.seededBaseline, $0.testCase.truth) })

        let repeats = outcomes.filter { $0.testCase.group != nil }
        let groups = Dictionary(grouping: repeats) { $0.testCase.group ?? "" }
        let orderedGroups = groups.keys.sorted().compactMap { groups[$0] }
        summary.repeatabilityRunCount = repeats.count
        summary.strengthenedRepeatabilityRunsRefused = repeats.filter { $0.status == .refused }.count
        summary.strengthenedRepeatabilityCM = repeatability(orderedGroups.map { $0.compactMap(offered) })
        summary.naiveRepeatabilityCM = repeatability(orderedGroups.map { $0.compactMap(\.baseline) })
        summary.seededRepeatabilityCM = repeatability(
            orderedGroups.map { $0.compactMap(\.seededBaseline) }
        )

        let crowded = outcomes.filter {
            $0.testCase.category == .neighbour || $0.testCase.category == .background
        }
        summary.crowdedCaseCount = crowded.count
        for outcome in crowded {
            let truth = outcome.testCase.truth
            if let dimensions = outcome.strengthened, isOversized(dimensions, truth: truth) {
                if outcome.status == .refused {
                    summary.strengthenedOversizedRefused += 1
                } else {
                    summary.strengthenedOversizedOffered += 1
                }
            }
            if let dimensions = outcome.baseline, isOversized(dimensions, truth: truth) {
                summary.naiveOversized += 1
            }
            if let dimensions = outcome.seededBaseline, isOversized(dimensions, truth: truth) {
                summary.seededOversized += 1
            }
        }

        let clipped = outcomes.filter { $0.testCase.category == .clipped }
        let unclipped = outcomes.filter { $0.testCase.category != .clipped }
        summary.clippedCaseCount = clipped.count
        summary.strengthenedClippingDetected = clipped.filter {
            $0.failures.contains(.regionBoundaryContact)
        }.count
        summary.strengthenedClippedRefused = clipped.filter { $0.status == .refused }.count
        summary.naiveClippedAnswered = clipped.filter { $0.baseline != nil }.count
        summary.seededClippedAnswered = clipped.filter { $0.seededBaseline != nil }.count
        summary.unclippedCaseCount = unclipped.count
        summary.strengthenedClippingFalseAlarms = unclipped.filter {
            $0.failures.contains(.regionBoundaryContact)
        }.count

        for category in EvaluationCase.Category.allCases {
            let members = outcomes.filter { $0.testCase.category == category }
            guard !members.isEmpty else { continue }
            let count = Double(members.count)
            summary.strengthenedRefusalRate[category.rawValue] =
                Double(members.filter { $0.status == .refused }.count) / count
            summary.naiveNoAnswerRate[category.rawValue] =
                Double(members.filter { $0.baseline == nil }.count) / count
            summary.seededNoAnswerRate[category.rawValue] =
                Double(members.filter { $0.seededBaseline == nil }.count) / count
        }
        return summary
    }

    // MARK: Report

    static func markdown(
        summary: EvaluationSummary,
        outcomes: [EvaluationOutcome],
        provenance: String? = nil
    ) -> String {
        func cm(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "n/a"
        }
        func percent(_ value: Double?) -> String {
            value.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
        }
        func dims(_ value: ObjectDimensions?) -> String {
            value.map { String(format: "%.1f × %.1f × %.1f", $0.length, $0.width, $0.height) } ?? "—"
        }
        let s = summary.strengthenedIsolated
        let n = summary.naiveIsolated
        let d = summary.seededIsolated
        let crowded = summary.crowdedCaseCount
        let clipped = summary.clippedCaseCount
        var lines: [String] = [
            "# Synthetic measurement evaluation",
            "",
            "> **SYNTHETIC RESULTS.** Every number below comes from generated scans",
            "> (`WarehouseAppTests/SyntheticScanFixtures.swift`): exact camera poses,",
            "> Gaussian ray noise, no occlusion between objects. They show how the",
            "> pipeline's logic behaves on that generator. They are **not** measurements",
            "> of accuracy on an iPhone and must not be quoted as such. Physical",
            "> validation is described in `docs/manual-ar-measurement.md`.",
            "",
            "Regenerate with `./scripts/evaluate-measurement.sh`. Generator seed",
            "`\(summary.generatorSeed)`, \(summary.caseCount) cases, default",
            "`LiDARFusionConfiguration.smallObject`.\(provenance.map { " Built from \($0)." } ?? "")",
            "",
            "## How to read this (synthetic)",
            "",
            "- **Strengthened**: `LiDARMeasurementSession`, the app's pipeline.",
            "- **Naive baseline**: single pass, largest component at a fixed wide radius,",
            "  height over the points left after floor removal, no refusal. A sanity",
            "  floor, intentionally weak.",
            "- **Seeded baseline**: the same, but it selects the component nearest the",
            "  seed the app pipeline is given and measures height from its floor",
            "  estimate. Input-matched and still simple. This is the fairer comparison.",
            "- Neither baseline is the app's previous implementation. Both reuse the",
            "  pipeline's default voxel size, floor band and wide radius.",
            "- **These are in-family regression results, not held-out performance.** The",
            "  cases use the same generative model as the unit tests and several of the",
            "  same scenario families, and the pipeline's thresholds were chosen with",
            "  that family in view. No threshold was changed after these cases were",
            "  first run, but the repository history cannot prove that ordering. An",
            "  independent generator or physical scans should be expected to give",
            "  worse numbers.",
            "- `clipped` and `deficient` cases are built around the pipeline's own",
            "  thresholds. They show a rule fires, not that the rule is right.",
            "",
            "## Summary (synthetic)",
            "",
            "| Metric (synthetic) | Strengthened | Seeded baseline | Naive baseline |",
            "|---|---|---|---|",
            "| Isolated cases answered | \(s.answeredCount) of \(s.caseCount) offered | \(d.answeredCount) of \(d.caseCount) | \(n.answeredCount) of \(n.caseCount) |",
            "| Dimension error, mean absolute (cm) | \(cm(s.meanAbsoluteErrorCM)) | \(cm(d.meanAbsoluteErrorCM)) | \(cm(n.meanAbsoluteErrorCM)) |",
            "| Dimension error, median absolute (cm) | \(cm(s.medianAbsoluteErrorCM)) | \(cm(d.medianAbsoluteErrorCM)) | \(cm(n.medianAbsoluteErrorCM)) |",
            "| Dimension error, worst (cm) | \(cm(s.maximumAbsoluteErrorCM)) | \(cm(d.maximumAbsoluteErrorCM)) | \(cm(n.maximumAbsoluteErrorCM)) |",
            "| Dimension error, mean signed (cm) | \(cm(s.meanSignedErrorCM)) | \(cm(d.meanSignedErrorCM)) | \(cm(n.meanSignedErrorCM)) |",
            "| Repeatability, mean std dev across noise seeds (cm) | \(cm(summary.strengthenedRepeatabilityCM)) | \(cm(summary.seededRepeatabilityCM)) | \(cm(summary.naiveRepeatabilityCM)) |",
            "| Oversized result offered in crowded scenes | \(summary.strengthenedOversizedOffered) of \(crowded) | \(summary.seededOversized) of \(crowded) | \(summary.naiveOversized) of \(crowded) |",
            "| Oversized estimate produced but refused | \(summary.strengthenedOversizedRefused) of \(crowded) | n/a (cannot refuse) | n/a (cannot refuse) |",
            "| Clipping reported as boundary contact | \(summary.strengthenedClippingDetected) of \(clipped) | no check | no check |",
            "| Clipped cases refused or unanswered | \(summary.strengthenedClippedRefused) of \(clipped) | \(clipped - summary.seededClippedAnswered) of \(clipped) | \(clipped - summary.naiveClippedAnswered) of \(clipped) |",
            "| Boundary-contact false alarms, all unclipped cases | \(summary.strengthenedClippingFalseAlarms) of \(summary.unclippedCaseCount) | n/a | n/a |",
            "",
            "Notes on the metrics:",
            "",
            "- Dimension error uses the `isolated` category only (distinct single",
            "  objects, one scan each). For the strengthened pipeline it counts only",
            "  results it offers (accepted or qualified); the baselines cannot refuse,",
            "  so every answer counts.",
            "- Mean and worst baseline error are dominated by a few isolated cases in",
            "  which support noise exceeds the baselines' fixed floor band, so support",
            "  residue joins the object (the rows near 31 cm). The median shows the",
            "  typical case.",
            "- Repeatability uses \(summary.repeatabilityRunCount) runs; the strengthened pipeline refused",
            "  \(summary.strengthenedRepeatabilityRunsRefused) of them, and refused runs are left out of its figure.",
            "- \"Oversized\" means any reported dimension more than",
            "  max(\(cm(oversizeMarginCM)) cm, \(percent(oversizeMarginFraction))) above the true value in a scene with a neighbour or",
            "  background object. It is a proxy for merging: it also counts any other",
            "  large over-estimate, and misses contamination that does not enlarge the",
            "  result.",
            "- A baseline that returns nothing for a clipped case has not detected",
            "  clipping; it simply found no geometry.",
            "",
            "## Rejection rate by category (synthetic)",
            "",
            "| Category | Cases | Strengthened refused | Seeded baseline: no answer | Naive baseline: no answer |",
            "|---|---|---|---|---|"
        ]
        for category in EvaluationCase.Category.allCases {
            guard let count = summary.categoryCounts[category.rawValue] else { continue }
            lines.append("| \(category.rawValue) | \(count) | \(percent(summary.strengthenedRefusalRate[category.rawValue])) | \(percent(summary.seededNoAnswerRate[category.rawValue])) | \(percent(summary.naiveNoAnswerRate[category.rawValue])) |")
        }
        lines += [
            "",
            "`clipped` and `deficient` cases are built so that refusal is the intended",
            "outcome. Refusals elsewhere are scans the pipeline would not finish even",
            "though the object was fully scanned.",
            "",
            "## Per-case results (synthetic)",
            "",
            "| Case | True L × W × H (cm) | Strengthened | Decision | Reasons | Seeded baseline | Naive baseline |",
            "|---|---|---|---|---|---|---|"
        ]
        for outcome in outcomes {
            let reasons = (outcome.failures + outcome.warnings).map(\.rawValue).joined(separator: ", ")
            lines.append("| \(outcome.testCase.name) | \(dims(outcome.testCase.truth)) | \(dims(outcome.strengthened)) | \(outcome.status.rawValue) | \(reasons) | \(dims(outcome.seededBaseline)) | \(dims(outcome.baseline)) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
