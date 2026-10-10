import Foundation
import simd
#if canImport(WarehouseApp)
@testable import WarehouseApp
#endif

// DEVICE REPLAY. Runs scans recorded on a phone (`LiDARScanRecording`)
// through the pipeline again, once per variant, and compares the results
// with dimensions measured by hand. Unlike the synthetic evaluation and
// ablation, the input here is real depth data, so these are the numbers
// that can support a statement about accuracy, within the limits of the
// scans and the ground truth supplied.

/// Hand-measured dimensions of one product, in centimetres.
struct ReplayGroundTruth: Equatable {
    var product: String
    var dimensions: ObjectDimensions

    /// Parses `product,length_cm,width_cm,height_cm[,notes]` rows. The two
    /// horizontal dimensions may be given in either order. Lines that do not
    /// parse (the header, blanks, comments) are skipped.
    static func parse(csv: String) -> [ReplayGroundTruth] {
        csv.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4,
                  !fields[0].isEmpty, !fields[0].hasPrefix("#"),
                  let a = Double(fields[1]), let b = Double(fields[2]), let height = Double(fields[3]),
                  a > 0, b > 0, height > 0
            else { return nil }
            return ReplayGroundTruth(
                product: fields[0],
                dimensions: ObjectDimensions(length: max(a, b), width: min(a, b), height: height)
            )
        }
    }

    static func key(_ product: String) -> String {
        product.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

struct ReplayScan {
    var fileName: String
    var recording: LiDARScanRecording
    var truth: ObjectDimensions?
    /// One result per variant, in `MeasurementReplay.variants` order.
    var results: [AblationResult] = []

    var step: String {
        let step = recording.header.step.trimmingCharacters(in: .whitespaces)
        return step.isEmpty ? "(no test named)" : step
    }
}

struct ReplayAccuracy: Equatable {
    var scanCount = 0
    var offered = 0
    var refused = 0
    var lengthAbsoluteErrorCM: Double?
    var widthAbsoluteErrorCM: Double?
    var heightAbsoluteErrorCM: Double?
    var heightSignedErrorCM: Double?
    var worstAbsoluteErrorCM: Double?
}

enum MeasurementReplay {
    static let variants: [AblationVariant] = [
        .full,
        .heightFromRetainedPoints,
        .unconditionalConnectivity,
        .wideReach,
        .wideReachWithFreeSpace
    ]

    /// Processes the frames exactly as the app does: no extra analysis after
    /// the last frame, so the full variant should reproduce the live result.
    static func replay(
        _ recording: LiDARScanRecording,
        configuration: LiDARFusionConfiguration
    ) -> AblationResult? {
        guard let region = recording.region, let seed = recording.seed else { return nil }
        let session = LiDARMeasurementSession(configuration: configuration)
        session.begin(region: region, seed: seed)
        for frame in recording.frames { session.process(frame) }
        let report = session.report
        return AblationResult(
            dimensions: report.reportedDimensionsCM,
            status: report.decision.status,
            reasons: report.decision.failures + report.decision.warnings + report.decision.fallbacks
        )
    }

    static func run(
        recordings: [(fileName: String, recording: LiDARScanRecording)],
        truths: [ReplayGroundTruth]
    ) -> [ReplayScan] {
        var truthByProduct: [String: ObjectDimensions] = [:]
        for truth in truths { truthByProduct[ReplayGroundTruth.key(truth.product)] = truth.dimensions }
        return recordings.map { fileName, recording in
            var scan = ReplayScan(
                fileName: fileName,
                recording: recording,
                truth: truthByProduct[ReplayGroundTruth.key(recording.header.label)]
            )
            scan.results = variants.map {
                replay(recording, configuration: $0.configuration)
                    ?? AblationResult(dimensions: nil, status: .refused, reasons: [])
            }
            return scan
        }
    }

    /// True when the replayed full pipeline gives the result the app stored.
    static func reproducesLiveResult(_ scan: ReplayScan) -> Bool? {
        guard let live = scan.recording.liveResult, let replayed = scan.results.first else {
            return nil
        }
        guard live.decision.status == replayed.status else { return false }
        switch (live.reportedDimensionsCM, replayed.dimensions) {
        case (nil, nil):
            return true
        case (let a?, let b?):
            return zip(a.values, b.values).allSatisfy { abs($0 - $1) < 0.05 }
        default:
            return false
        }
    }

    static func accuracy(_ scans: [ReplayScan], variant index: Int) -> ReplayAccuracy {
        var accuracy = ReplayAccuracy()
        var length: [Double] = []
        var width: [Double] = []
        var height: [Double] = []
        for scan in scans {
            guard let truth = scan.truth else { continue }
            accuracy.scanCount += 1
            guard let offered = scan.results[index].offered else {
                accuracy.refused += 1
                continue
            }
            accuracy.offered += 1
            length.append(offered.length - truth.length)
            width.append(offered.width - truth.width)
            height.append(offered.height - truth.height)
        }
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        accuracy.lengthAbsoluteErrorCM = mean(length.map(abs))
        accuracy.widthAbsoluteErrorCM = mean(width.map(abs))
        accuracy.heightAbsoluteErrorCM = mean(height.map(abs))
        accuracy.heightSignedErrorCM = mean(height)
        accuracy.worstAbsoluteErrorCM = (length + width + height).map(abs).max()
        return accuracy
    }

    // MARK: Report

    static func markdown(scans: [ReplayScan], provenance: String? = nil) -> String {
        func cm(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "n/a"
        }
        func signed(_ value: Double?) -> String {
            value.map { String(format: "%+.2f", $0) } ?? "n/a"
        }
        func dims(_ value: ObjectDimensions?) -> String {
            value.map { String(format: "%.1f × %.1f × %.1f", $0.length, $0.width, $0.height) } ?? "—"
        }
        let devices = Set(scans.map {
            "\($0.recording.header.deviceModel), iOS \($0.recording.header.systemVersion)"
        }).sorted()
        let withTruth = scans.filter { $0.truth != nil }
        let reproduced = scans.compactMap(reproducesLiveResult)
        let incomplete = scans.filter { $0.recording.liveResult == nil }.count
        // A frame processed as the scan was stopped moves the pipeline's
        // report one frame past what the screen showed.
        let shownDiffers = scans.filter { scan in
            guard let live = scan.recording.liveResult, let status = live.shownStatus else {
                return false
            }
            return status != live.decision.status.rawValue
                || live.shownDimensionsCM != live.reportedDimensionsCM
        }.count
        var lines: [String] = [
            "# Device replay of the measurement pipeline",
            "",
            "> **DEVICE RECORDINGS.** \(scans.count) scans recorded by the app and replayed",
            "> through the pipeline on a Mac. Errors are differences from the",
            "> hand-measured dimensions supplied with the recordings, so they are only",
            "> as good as those measurements. They describe these products, this",
            "> device and this operator, and nothing wider.",
            "",
            "Regenerate with `./scripts/replay-measurement.sh`.\(provenance.map { " Built from \($0)." } ?? "")",
            "",
            "## Recordings",
            "",
            "- Scans: \(scans.count), of which \(withTruth.count) have ground truth.",
            "- Devices: \(devices.isEmpty ? "none" : devices.joined(separator: "; ")).",
            "- Replay check: the full pipeline reproduced the app's stored result for",
            "  \(reproduced.filter { $0 }.count) of \(reproduced.count) scans.\(incomplete > 0 ? " \(incomplete) recordings have no stored result (the app closed mid-scan)." : "")",
            "- In \(shownDiffers) scans the result on screen when the scan was stopped",
            "  differed from the pipeline's final report, because a frame was still",
            "  being processed. The replay follows the pipeline's report.",
            "",
            "## Variants",
            ""
        ]
        for variant in variants {
            lines.append("- **\(variant.name)**: \(variant.summary)")
        }
        lines += [
            "",
            "## Accuracy, all scans with ground truth",
            "",
            "Errors are over offered results (accepted or qualified) only.",
            ""
        ]
        func accuracyTable(_ subset: [ReplayScan]) -> [String] {
            var table = [
                "| Variant | Offered | Refused | Length error, mean abs (cm) | Width error, mean abs (cm) | Height error, mean abs (cm) | Height error, mean signed (cm) | Worst error (cm) |",
                "|---|---:|---:|---:|---:|---:|---:|---:|"
            ]
            for (index, variant) in variants.enumerated() {
                let a = accuracy(subset, variant: index)
                table.append("| \(variant.name) | \(a.offered) of \(a.scanCount) | \(a.refused) | \(cm(a.lengthAbsoluteErrorCM)) | \(cm(a.widthAbsoluteErrorCM)) | \(cm(a.heightAbsoluteErrorCM)) | \(signed(a.heightSignedErrorCM)) | \(cm(a.worstAbsoluteErrorCM)) |")
            }
            return table
        }
        lines += accuracyTable(scans)

        let steps = Dictionary(grouping: scans, by: \.step)
        for step in steps.keys.sorted() {
            guard let members = steps[step] else { continue }
            lines += ["", "## Test: \(step)", ""]
            if members.contains(where: { $0.truth != nil }) {
                lines += accuracyTable(members)
                lines.append("")
            }
            lines += [
                "| Scan | Product | True L × W × H (cm) | Shown in app | " + variants.map(\.name).joined(separator: " | ") + " |",
                "|---|---|---|---|" + variants.map { _ in "---|" }.joined()
            ]
            for scan in members {
                let live = scan.recording.liveResult.map {
                    "\(dims($0.shownDimensionsCM ?? $0.reportedDimensionsCM)) \($0.shownStatus ?? $0.decision.status.rawValue)"
                } ?? "not stored"
                let cells = scan.results.map { result -> String in
                    let reasons = result.reasons.map(\.rawValue).joined(separator: ", ")
                    return "\(dims(result.dimensions)) \(result.status.rawValue)\(reasons.isEmpty ? "" : " (\(reasons))")"
                }
                lines.append("| \(scan.fileName) | \(scan.recording.header.label) | \(dims(scan.truth)) | \(live) | \(cells.joined(separator: " | ")) |")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
