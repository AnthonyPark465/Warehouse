import Foundation
import simd
#if canImport(WarehouseApp)
@testable import WarehouseApp
#endif

// SYNTHETIC ABLATION. Runs the same generated scans through the pipeline
// with one mechanism switched off or on at a time, so the contribution of
// each can be read off directly. Like `MeasurementEvaluation`, every number
// describes behaviour on the generator in `SyntheticScanFixtures.swift`;
// none is a measurement of accuracy on a physical iPhone.
//
// Integrity notes:
// - Part 1 reuses the cases of the main synthetic evaluation unchanged.
// - Part 2's cases were written to exercise free-space gating: surfaces that
//   return depth only in patches, and pairs of such objects a resolvable
//   distance apart. They show the mechanism does what it is designed to do
//   on that construction. They do not show how often real products look
//   like that, or that a phone's depth map resolves such gaps.
// - Part 2 models occlusion, because free-space evidence is a statement
//   about rays. The main evaluation does not.

struct AblationVariant {
    var name: String
    var summary: String
    var configuration: LiDARFusionConfiguration

    static let full = AblationVariant(
        name: "Full pipeline",
        summary: "The app's default configuration.",
        configuration: .smallObject
    )

    /// Step B off: height over the retained product voxels.
    static let heightFromRetainedPoints: AblationVariant = {
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.heightUsesSupportCoordinate = false
        return AblationVariant(
            name: "Height from retained points",
            summary: "Support still removed for segmentation, but height is measured from the lowest product voxel left, not from the support coordinate.",
            configuration: configuration
        )
    }()

    /// Step C off: one fixed connectivity radius for everything.
    static let unconditionalConnectivity: AblationVariant = {
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.connectivityIsConditional = false
        return AblationVariant(
            name: "Unconditional connectivity",
            summary: "Every component is bridged at the expanded reach, object-sized or not.",
            configuration: configuration
        )
    }()

    static let wideReachVoxels = 5

    static let wideReach: AblationVariant = {
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.connectivityRadiusInVoxels = wideReachVoxels
        return AblationVariant(
            name: "Wide reach",
            summary: "Fragments are bridged across up to \(wideReachVoxels) voxels (\(wideReachVoxels * 3) mm) instead of 2. No free-space check.",
            configuration: configuration
        )
    }()

    static let wideReachWithFreeSpace: AblationVariant = {
        var configuration = wideReach.configuration
        configuration.freeSpaceGatingEnabled = true
        return AblationVariant(
            name: "Wide reach + free space",
            summary: "The same reach, but a gap that depth rays were seen passing through is not bridged.",
            configuration: configuration
        )
    }()

    static let defaultWithFreeSpace: AblationVariant = {
        var configuration = LiDARFusionConfiguration.smallObject
        configuration.freeSpaceGatingEnabled = true
        return AblationVariant(
            name: "Default reach + free space",
            summary: "Free-space check at the app's 2-voxel reach.",
            configuration: configuration
        )
    }()
}

struct AblationCase {
    enum Family: String, CaseIterable {
        /// One dense object: a control.
        case dense
        /// One dense object with a dense neighbour: a control.
        case denseNeighbour
        /// One object whose surface returns depth only in patches.
        case patchy
        /// Two such objects a resolvable distance apart.
        case patchyPair
    }

    var name: String
    var family: Family
    var scene: SyntheticScene
    var plan: SyntheticScanPlan
    var region: LiDARSpatialRegion
    var seed: SIMD3<Float>

    var truth: ObjectDimensions { scene.target.trueDimensionsCM }
}

struct AblationResult {
    var dimensions: ObjectDimensions?
    var status: LiDARAcceptanceStatus
    var reasons: [LiDARMeasurementReasonCode]
    /// Synthetic scenes with a second object only: the share of the selected
    /// voxels that lie on that object and not on the target.
    var neighbourShare: Double?

    var offered: ObjectDimensions? { status == .refused ? nil : dimensions }
}

struct AblationTally: Equatable {
    var caseCount = 0
    /// Offered, and every dimension within the margin of the truth.
    var offeredCorrect = 0
    /// Offered with a dimension above the truth by more than the margin.
    var offeredOversized = 0
    /// Offered with a dimension below the truth by more than the margin.
    var offeredUndersized = 0
    var refused = 0
    /// Refused, and the estimate behind the refusal was oversized.
    var refusedOversized = 0
    /// Offered, with more than `MeasurementAblation.neighbourShareLimit` of
    /// the selected voxels lying on the second object. Counted whatever the
    /// dimensions say.
    var offeredWithNeighbourVoxels = 0
}

enum MeasurementAblation {
    static let variantsOnMainCases: [AblationVariant] = [
        .full, .heightFromRetainedPoints, .unconditionalConnectivity
    ]
    static let variantsOnFreeSpaceCases: [AblationVariant] = [
        .full, .defaultWithFreeSpace, .wideReach, .wideReachWithFreeSpace
    ]

    /// Above this share of neighbour voxels a selection counts as containing
    /// the neighbour. Noise puts a stray voxel or two on the wrong side.
    static let neighbourShareLimit = 0.02
    /// A voxel belongs to an object when it lies within this of its solid.
    static let membershipMargin: Float = 0.003

    static func run(
        _ configuration: LiDARFusionConfiguration,
        frames: [LiDARDepthFrame],
        region: LiDARSpatialRegion,
        seed: SIMD3<Float>,
        scene: SyntheticScene? = nil
    ) -> AblationResult {
        let report = LiDARMeasurementSession(configuration: configuration).run(
            frames,
            region: region,
            seed: seed
        )
        return AblationResult(
            dimensions: report.reportedDimensionsCM,
            status: report.decision.status,
            reasons: report.decision.failures + report.decision.warnings + report.decision.fallbacks,
            neighbourShare: scene.flatMap { neighbourShare(report.measurement, scene: $0) }
        )
    }

    /// Ground-truth membership of the selected voxels, which the generator
    /// knows and dimensions alone do not show.
    static func neighbourShare(
        _ measurement: LiDARFusionMeasurement?,
        scene: SyntheticScene
    ) -> Double? {
        guard let points = measurement?.worldPointsInMetres, !points.isEmpty,
              scene.objects.count > 1
        else { return nil }
        let lift = SIMD3<Float>(0, scene.supportHeight, 0)
        let target = scene.target
        let others = scene.objects.dropFirst()
        let foreign = points.filter { point in
            let local = point - lift
            return !target.contains(local, margin: membershipMargin)
                && others.contains { $0.contains(local, margin: membershipMargin) }
        }
        return Double(foreign.count) / Double(points.count)
    }

    static func isUndersized(_ dimensions: ObjectDimensions, truth: ObjectDimensions) -> Bool {
        zip(dimensions.values, truth.values).contains {
            $1 - $0 > max(
                MeasurementEvaluation.oversizeMarginCM,
                MeasurementEvaluation.oversizeMarginFraction * $1
            )
        }
    }

    static func tally(_ results: [(result: AblationResult, truth: ObjectDimensions)]) -> AblationTally {
        var tally = AblationTally(caseCount: results.count)
        for (result, truth) in results {
            let oversized = result.dimensions.map {
                MeasurementEvaluation.isOversized($0, truth: truth)
            } ?? false
            guard let offered = result.offered else {
                tally.refused += 1
                if oversized { tally.refusedOversized += 1 }
                continue
            }
            if let share = result.neighbourShare, share > neighbourShareLimit {
                tally.offeredWithNeighbourVoxels += 1
            }
            // Exclusive classes: a result with one dimension too large and
            // another too small counts as oversized.
            if oversized {
                tally.offeredOversized += 1
            } else if isUndersized(offered, truth: truth) {
                tally.offeredUndersized += 1
            } else {
                tally.offeredCorrect += 1
            }
        }
        return tally
    }

    // MARK: Part 1: steps B and C on the main evaluation cases

    struct MainRow {
        var variant: AblationVariant
        /// Isolated cases, offered results only.
        var isolatedOffered = 0
        var isolatedCount = 0
        var heightSignedErrorCM: Double?
        var heightAbsoluteErrorCM: Double?
        var footprintAbsoluteErrorCM: Double?
        /// Neighbour and background cases.
        var crowded = AblationTally()
        /// Cases the pipeline should answer: everything except `clipped`
        /// and `deficient`.
        var answerable = AblationTally()
        var results: [AblationResult] = []
    }

    static func runMain(_ cases: [EvaluationCase]) -> [MainRow] {
        let frames = cases.map { SyntheticScanner.frames(scene: $0.scene, plan: $0.plan) }
        return variantsOnMainCases.map { variant in
            var row = MainRow(variant: variant)
            row.results = zip(cases, frames).map { testCase, frames in
                run(variant.configuration, frames: frames, region: testCase.region, seed: testCase.seed)
            }
            let paired = Array(zip(cases, row.results))
            let isolated = paired.filter { $0.0.category == .isolated }
            row.isolatedCount = isolated.count
            var heightErrors: [Double] = []
            var footprintErrors: [Double] = []
            for (testCase, result) in isolated {
                guard let offered = result.offered else { continue }
                row.isolatedOffered += 1
                heightErrors.append(offered.height - testCase.truth.height)
                footprintErrors.append(abs(offered.length - testCase.truth.length))
                footprintErrors.append(abs(offered.width - testCase.truth.width))
            }
            func mean(_ values: [Double]) -> Double? {
                values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
            row.heightSignedErrorCM = mean(heightErrors)
            row.heightAbsoluteErrorCM = mean(heightErrors.map(abs))
            row.footprintAbsoluteErrorCM = mean(footprintErrors)
            row.crowded = tally(paired
                .filter { $0.0.category == .neighbour || $0.0.category == .background }
                .map { ($0.1, $0.0.truth) })
            row.answerable = tally(paired
                .filter { $0.0.category != .clipped && $0.0.category != .deficient }
                .map { ($0.1, $0.0.truth) })
            return row
        }
    }

    // MARK: Part 2: free-space gating on purpose-built cases

    static func freeSpaceCases(
        generatorSeed: UInt64 = 20_261_010,
        scale: MeasurementEvaluation.Scale = .full
    ) -> [AblationCase] {
        var random = SyntheticRandom(seed: generatorSeed)
        let multiplier = scale == .full ? 1 : 0
        var cases: [AblationCase] = []

        func randomBox() -> SyntheticObject {
            let a = random.uniform(0.05...0.12)
            let b = random.uniform(0.04...0.09)
            return SyntheticObject(
                shape: .box(size: SIMD3<Float>(max(a, b), random.uniform(0.04...0.11), min(a, b))),
                baseCentre: .zero,
                yaw: random.uniform(0...(.pi / 2))
            )
        }
        func patchy(_ object: SyntheticObject) -> SyntheticObject {
            var object = object
            object.patches = (random.uniform(0.010...0.014), random.uniform(0.007...0.010))
            return object
        }
        /// A second box beside the target along its length axis.
        func neighbour(of target: SyntheticObject, gap: Float) -> SyntheticObject {
            guard case .box(let size) = target.shape else {
                preconditionFailure("randomBox must return a box")
            }
            let other = SIMD3<Float>(
                random.uniform(0.04...0.08),
                random.uniform(0.04...0.11),
                random.uniform(0.04...0.09)
            )
            return SyntheticObject(
                shape: .box(size: other),
                baseCentre: target.rotate(SIMD3<Float>(size.x / 2 + gap + other.x / 2, 0, 0)),
                yaw: target.yaw
            )
        }
        func add(_ name: String, _ family: AblationCase.Family, _ objects: [SyntheticObject]) {
            var plan = SyntheticScanPlan(
                frameCount: scale == .full ? 36 : 24,
                depthNoiseSigma: 0.001,
                dropoutFraction: 0.1,
                seed: random.next()
            )
            plan.modelsOcclusion = true
            cases.append(AblationCase(
                name: name,
                family: family,
                scene: SyntheticScene(objects: objects, supportHalfExtent: 0.22),
                plan: plan,
                region: SyntheticRegions.prism(halfWidth: 0.22, upperOffset: 0.20),
                seed: SyntheticRegions.seed()
            ))
        }

        for index in 0..<(1 + 5 * multiplier) {
            add("dense-\(index)", .dense, [randomBox()])
        }
        for index in 0..<(1 + 5 * multiplier) {
            let target = randomBox()
            let gap = random.uniform(0.008...0.018)
            add(
                "dense-neighbour-\(index)-gap\(Int((gap * 1000).rounded()))mm",
                .denseNeighbour,
                [target, neighbour(of: target, gap: gap)]
            )
        }
        for index in 0..<(1 + 9 * multiplier) {
            add("patchy-\(index)", .patchy, [patchy(randomBox())])
        }
        for index in 0..<(1 + 13 * multiplier) {
            let target = patchy(randomBox())
            let gap = random.uniform(0.008...0.018)
            add(
                "patchy-pair-\(index)-gap\(Int((gap * 1000).rounded()))mm",
                .patchyPair,
                [target, patchy(neighbour(of: target, gap: gap))]
            )
        }
        return cases
    }

    struct FreeSpaceRow {
        var variant: AblationVariant
        var byFamily: [AblationCase.Family: AblationTally] = [:]
        var results: [AblationResult] = []
    }

    static func runFreeSpace(_ cases: [AblationCase]) -> [FreeSpaceRow] {
        let frames = cases.map { SyntheticScanner.frames(scene: $0.scene, plan: $0.plan) }
        return variantsOnFreeSpaceCases.map { variant in
            var row = FreeSpaceRow(variant: variant)
            row.results = zip(cases, frames).map { testCase, frames in
                run(
                    variant.configuration,
                    frames: frames,
                    region: testCase.region,
                    seed: testCase.seed,
                    scene: testCase.scene
                )
            }
            for family in AblationCase.Family.allCases {
                row.byFamily[family] = tally(zip(cases, row.results)
                    .filter { $0.0.family == family }
                    .map { ($0.1, $0.0.truth) })
            }
            return row
        }
    }

    // MARK: Report

    static func markdown(
        mainCases: [EvaluationCase],
        mainRows: [MainRow],
        freeSpaceCases: [AblationCase],
        freeSpaceRows: [FreeSpaceRow],
        mainSeed: UInt64,
        freeSpaceSeed: UInt64,
        provenance: String? = nil
    ) -> String {
        func cm(_ value: Double?) -> String {
            value.map { String(format: "%+.2f", $0) } ?? "n/a"
        }
        func unsigned(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "n/a"
        }
        func dims(_ value: ObjectDimensions?) -> String {
            value.map { String(format: "%.1f × %.1f × %.1f", $0.length, $0.width, $0.height) } ?? "—"
        }
        func cell(_ result: AblationResult) -> String {
            "\(dims(result.dimensions)) \(result.status.rawValue)"
        }
        let margin = String(
            format: "max(%.1f cm, %.0f%%)",
            MeasurementEvaluation.oversizeMarginCM,
            MeasurementEvaluation.oversizeMarginFraction * 100
        )
        var lines: [String] = [
            "# Synthetic ablation of the measurement pipeline",
            "",
            "> **SYNTHETIC RESULTS.** Every number below comes from generated scans",
            "> (`WarehouseAppTests/SyntheticScanFixtures.swift`). They show what each",
            "> mechanism contributes on that generator. They are **not** measurements",
            "> of accuracy on an iPhone and must not be quoted as such. The same",
            "> comparison on recorded device scans is produced by",
            "> `scripts/replay-measurement.sh`.",
            "",
            "Regenerate with `./scripts/evaluate-ablation.sh`. Generator seeds",
            "`\(mainSeed)` (part 1) and `\(freeSpaceSeed)` (part 2).\(provenance.map { " Built from \($0)." } ?? "")",
            "",
            "## How to read this (synthetic)",
            "",
            "- Each variant differs in **one** setting from the variant it is compared",
            "  with: the full pipeline, except that *Wide reach + free space* is",
            "  compared with *Wide reach*. All variants see identical frames.",
            "- **Offered** means accepted or qualified: a result the user would get.",
            "- **Correct** means offered with every dimension within \(margin)",
            "  of the truth. That margin is loose: it exists to tell a merged or",
            "  truncated result from a sound one, not to grade accuracy.",
            "- **Oversized** and **undersized** are offered results outside the margin.",
            "  The classes are exclusive: a result with one dimension too large and",
            "  another too small counts as oversized.",
            "- These are in-family results. The generator, the scenarios and the",
            "  pipeline's thresholds were written by the same authors.",
            "",
            "## Part 1: steps B and C (synthetic)",
            "",
            "The \(mainCases.count) cases of `docs/measurement-evaluation-synthetic.md`, without",
            "occlusion, exactly as that report runs them.",
            ""
        ]
        for row in mainRows {
            lines.append("- **\(row.variant.name)**: \(row.variant.summary)")
        }
        lines += [
            "",
            "| Variant | Isolated offered | Height error, mean signed (cm) | Height error, mean absolute (cm) | Length/width error, mean absolute (cm) | Crowded: correct | Crowded: oversized offered | Crowded: oversized refused | Answerable cases refused |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
        ]
        for row in mainRows {
            lines.append("| \(row.variant.name) | \(row.isolatedOffered) of \(row.isolatedCount) | \(cm(row.heightSignedErrorCM)) | \(unsigned(row.heightAbsoluteErrorCM)) | \(unsigned(row.footprintAbsoluteErrorCM)) | \(row.crowded.offeredCorrect) of \(row.crowded.caseCount) | \(row.crowded.offeredOversized) | \(row.crowded.refusedOversized) | \(row.answerable.refused) of \(row.answerable.caseCount) |")
        }
        lines += [
            "",
            "Notes:",
            "",
            "- Height error uses `isolated` cases only, offered results only.",
            "- \"Crowded\" is the `neighbour` and `background` categories. \"Answerable\"",
            "  is every category except `clipped` and `deficient`.",
            "- Unconditional connectivity bridges one missing voxel between any two",
            "  components. It differs from the full pipeline wherever two components",
            "  lie within that reach: a neighbouring object, or pieces of the same",
            "  object, which is why the `sparse` cases change from accepted to",
            "  qualified.",
            "",
            "### Cases where a variant differs from the full pipeline (synthetic)",
            "",
            "| Case | True L × W × H (cm) | " + mainRows.map(\.variant.name).joined(separator: " | ") + " |",
            "|---|---|" + mainRows.map { _ in "---|" }.joined()
        ]
        for (index, testCase) in mainCases.enumerated() {
            let cells = mainRows.map { cell($0.results[index]) }
            // Height-only variants change every row slightly; list a row
            // when the decision or a footprint dimension changed.
            let reference = mainRows[0].results[index]
            let differs = mainRows.dropFirst().contains { row in
                let other = row.results[index]
                if other.status != reference.status { return true }
                guard let a = other.dimensions, let b = reference.dimensions else {
                    return (other.dimensions == nil) != (reference.dimensions == nil)
                }
                return abs(a.length - b.length) > 0.3 || abs(a.width - b.width) > 0.3
            }
            if differs {
                lines.append("| \(testCase.name) | \(dims(testCase.truth)) | \(cells.joined(separator: " | ")) |")
            }
        }
        lines += [
            "",
            "## Part 2: free-space gating (synthetic)",
            "",
            "\(freeSpaceCases.count) purpose-built cases **with occlusion modelled**. A \"patchy\"",
            "object returns depth only in square tiles 10–14 mm wide separated by",
            "unscanned strips 7–10 mm wide, so its surface never forms an",
            "object-sized component at strict connectivity. A \"patchy pair\" is two",
            "such objects 8–18 mm apart.",
            ""
        ]
        for row in freeSpaceRows {
            lines.append("- **\(row.variant.name)**: \(row.variant.summary)")
        }
        for family in AblationCase.Family.allCases {
            let title: String
            switch family {
            case .dense: title = "Dense object alone (control)"
            case .denseNeighbour: title = "Dense object with a dense neighbour 8–18 mm away (control)"
            case .patchy: title = "Patchy object alone"
            case .patchyPair: title = "Two patchy objects 8–18 mm apart"
            }
            lines += [
                "",
                "### \(title) (synthetic)",
                "",
                "| Variant | Correct | Oversized offered | Undersized offered | Refused | of which the refused estimate was oversized | Offered containing neighbour voxels |",
                "|---|---:|---:|---:|---:|---:|---:|"
            ]
            let hasNeighbour = family == .denseNeighbour || family == .patchyPair
            for row in freeSpaceRows {
                let tally = row.byFamily[family] ?? AblationTally()
                let membership = hasNeighbour ? "\(tally.offeredWithNeighbourVoxels)" : "n/a"
                lines.append("| \(row.variant.name) | \(tally.offeredCorrect) of \(tally.caseCount) | \(tally.offeredOversized) | \(tally.offeredUndersized) | \(tally.refused) | \(tally.refusedOversized) | \(membership) |")
            }
        }
        lines += [
            "",
            "What this does and does not show:",
            "",
            "- It shows the designed behaviour on a constructed surface: a wider",
            "  reach recovers a patchy object, and free-space evidence stops that",
            "  reach from joining two such objects across a gap rays passed through.",
            "- \"Containing neighbour voxels\" uses the generator's own knowledge of",
            "  which object each selected voxel lies on (more than",
            "  \(Int(neighbourShareLimit * 100))% on the second object), so a result can",
            "  be seen to be the target alone and not merely target-sized.",
            "- The construction favours the mechanism. The missing strips are",
            "  regular; the solid still hides everything behind it perfectly; rays",
            "  come from dense surface samples, not a camera's pixel grid; noise is",
            "  small and independent, with no mixed pixels at silhouettes, no",
            "  depth-map smoothing and no pose error. One generator, one seed.",
            "- It does not show that real products fragment this way, that an",
            "  iPhone's depth map resolves gaps of this size, or that grazing rays",
            "  at real silhouettes do not block bridges that should be made.",
            "  Recorded device scans are needed for each of those.",
            "",
            "### Per-case results, part 2 (synthetic)",
            "",
            "| Case | True L × W × H (cm) | " + freeSpaceRows.map(\.variant.name).joined(separator: " | ") + " |",
            "|---|---|" + freeSpaceRows.map { _ in "---|" }.joined()
        ]
        for (index, testCase) in freeSpaceCases.enumerated() {
            let cells = freeSpaceRows.map { cell($0.results[index]) }
            lines.append("| \(testCase.name) | \(dims(testCase.truth)) | \(cells.joined(separator: " | ")) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
