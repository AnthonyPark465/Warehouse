import Foundation

// Command-line entry point for the SYNTHETIC ablation of the measurement
// pipeline. Built and run by scripts/evaluate-ablation.sh; not part of the app.
//
// Usage: evaluate-ablation [output.md] [provenance]

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 && !arguments[1].isEmpty ? arguments[1] : nil
let provenance = arguments.count > 2 ? arguments[2] : nil
let mainSeed: UInt64 = 20_261_009
let freeSpaceSeed: UInt64 = 20_261_010

let mainCases = MeasurementEvaluation.cases(generatorSeed: mainSeed, scale: .full)
let freeSpaceCases = MeasurementAblation.freeSpaceCases(generatorSeed: freeSpaceSeed, scale: .full)
let markdown = MeasurementAblation.markdown(
    mainCases: mainCases,
    mainRows: MeasurementAblation.runMain(mainCases),
    freeSpaceCases: freeSpaceCases,
    freeSpaceRows: MeasurementAblation.runFreeSpace(freeSpaceCases),
    mainSeed: mainSeed,
    freeSpaceSeed: freeSpaceSeed,
    provenance: provenance
)

if let outputPath {
    try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("Wrote SYNTHETIC ablation (not device accuracy) to \(outputPath)")
} else {
    print(markdown)
}
